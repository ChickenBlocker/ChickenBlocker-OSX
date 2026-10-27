#!/usr/bin/env python3
"""Root-owned schedule state machine for the macOS break overlay."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import stat
import subprocess
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any


def validate_config(config: dict[str, Any]) -> None:
    required_positive = (
        "work_seconds",
        "short_break_seconds",
        "long_break_seconds",
        "long_break_every",
        "idle_away_seconds",
        "idle_gate_reset_seconds",
        "suspend_gap_seconds",
    )
    for key in required_positive:
        if not isinstance(config.get(key), int) or config[key] <= 0:
            raise ValueError(f"{key} must be a positive integer")
    for key in ("night_start_hour", "night_end_hour"):
        if not isinstance(config.get(key), int) or not 0 <= config[key] <= 23:
            raise ValueError(f"{key} must be an hour from 0 through 23")
    if config["night_start_hour"] == config["night_end_hour"]:
        raise ValueError("night window must not span the full day")
    if not isinstance(config.get("warning_seconds", 10), int) or config.get("warning_seconds", 10) < 0:
        raise ValueError("warning_seconds must be a non-negative integer")
    for key in ("short_messages", "long_messages"):
        value = config.get(key)
        if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
            raise ValueError(f"{key} must be a non-empty string list")
    if not isinstance(config.get("night_message"), str) or not config["night_message"]:
        raise ValueError("night_message must be a non-empty string")
    for key in ("start_work_message", "away_message"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError(f"{key} must be a non-empty string")


def in_night_window(hour: int, start: int, end: int) -> bool:
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end


def next_night_end(now: int, end_hour: int) -> int:
    current = datetime.fromtimestamp(now)
    end = current.replace(hour=end_hour, minute=0, second=0, microsecond=0)
    if end.timestamp() <= now:
        end += timedelta(days=1)
    return int(end.timestamp())


def fresh_state(config: dict[str, Any], now: int) -> dict[str, Any]:
    return {
        "phase": "work",
        "deadline": now + config["work_seconds"],
        "cycle": 0,
        "last_tick": now,
        "work_started": now,
        "away": False,
        "night": False,
    }


def command_for(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    phase = state["phase"]
    schedule = {
        "interval": int(state["cycle"]) + 1,
        "total_intervals": config["long_break_every"],
        "warning_seconds": config.get("warning_seconds", 10),
        "away": bool(state.get("away", False)),
    }
    if phase == "work":
        return schedule | {
            "mode": "work", "until": state["deadline"], "kind": "work", "message": "",
            "allow_escape": bool(config.get("allow_escape", False)),
            "next_break_kind": (
                "long" if state["cycle"] == config["long_break_every"] - 1 else "short"
            ),
        }
    if phase == "gate":
        reason = state.get("gate_reason", "break")
        return schedule | {
            "mode": "gate", "until": 0, "kind": reason,
            "message": config["away_message"] if reason == "away" else config["start_work_message"],
            "allow_escape": False, "next_break_kind": None,
        }
    kind = state.get("break_type", "short")
    if kind == "night":
        message = config["night_message"]
    elif kind == "long":
        messages = config["long_messages"]
        message = messages[state["cycle"] % len(messages)]
    else:
        messages = config["short_messages"]
        message = messages[state["cycle"] % len(messages)]
    return schedule | {
        "mode": "break", "until": state["deadline"], "kind": kind, "message": message,
        "allow_escape": bool(config.get("allow_escape", False)),
        "next_break_kind": kind,
    }


def advance(
    config: dict[str, Any],
    state: dict[str, Any] | None,
    now: int,
    manual_break: bool = False,
    idle_seconds: int | None = None,
    start_work: bool = False,
) -> tuple[dict[str, Any], dict[str, Any]]:
    validate_config(config)
    if not config.get("enabled", True):
        state = fresh_state(config, now)
        return state, {
            "mode": "work", "until": state["deadline"], "kind": "disabled", "message": "",
            "allow_escape": True,
        }

    local_hour = datetime.fromtimestamp(now).hour
    if in_night_window(local_hour, config["night_start_hour"], config["night_end_hour"]):
        state = {
            "phase": "break",
            "break_type": "night",
            "deadline": next_night_end(now, config["night_end_hour"]),
            "cycle": 0,
            "last_tick": now,
            "night": True,
        }
        return state, command_for(config, state)

    if not state or state.get("night"):
        state = fresh_state(config, now)

    phase = state.get("phase")
    if phase not in ("work", "break", "gate"):
        state = fresh_state(config, now)
        phase = "work"
    state["cycle"] = int(state.get("cycle", 0)) % config["long_break_every"]
    state["night"] = False

    if phase == "gate":
        if start_work:
            held = max(0, now - int(state.get("gate_started", now)))
            remaining = int(state.get("work_remaining", config["work_seconds"]))
            if held >= config["idle_gate_reset_seconds"]:
                remaining = config["work_seconds"]
            state = {
                "phase": "work",
                "deadline": now + max(1, remaining),
                "cycle": state["cycle"],
                "last_tick": now,
                "work_started": now,
                "away": False,
                "night": False,
            }
        else:
            state["last_tick"] = now
        return state, command_for(config, state)

    last_tick = int(state.get("last_tick", now))
    gap = max(0, now - last_tick)
    suspended = phase == "work" and gap > config["suspend_gap_seconds"]
    if suspended:
        remaining = int(state["deadline"]) - last_tick
        if remaining > gap:
            state["deadline"] = int(state["deadline"]) + gap
        else:
            state["cycle"] = (state["cycle"] + 1) % config["long_break_every"]
            state["deadline"] = now + config["work_seconds"]
            state["work_started"] = now

    if phase == "work" and not suspended:
        is_away = idle_seconds is not None and idle_seconds >= config["idle_away_seconds"]
        if is_away:
            if state.get("away", False):
                idle_work_time = gap
            else:
                work_started = int(state.get("work_started", last_tick))
                idle_work_time = min(idle_seconds, max(0, now - work_started))
            state["deadline"] = int(state["deadline"]) + idle_work_time
            state = {
                "phase": "gate",
                "gate_reason": "away",
                "gate_started": now,
                "work_remaining": max(1, int(state["deadline"]) - now),
                "cycle": state["cycle"],
                "last_tick": now,
                "away": False,
                "night": False,
            }
        else:
            state["away"] = False
    elif phase == "work":
        # Suspend handling above already accounts for this gap. Remember the
        # HID state so the same idle interval is not added again next tick.
        state["away"] = idle_seconds is not None and idle_seconds >= config["idle_away_seconds"]
    elif phase != "work":
        state["away"] = False

    if manual_break and state["phase"] == "work":
        is_long = state["cycle"] == config["long_break_every"] - 1
        state["phase"] = "break"
        state["away"] = False
        state["break_type"] = "long" if is_long else "short"
        state["deadline"] = now + (
            config["long_break_seconds"] if is_long else config["short_break_seconds"]
        )

    if state["phase"] == "break" and now >= int(state["deadline"]):
        next_cycle = (state["cycle"] + 1) % config["long_break_every"]
        if gap > config["suspend_gap_seconds"]:
            state = fresh_state(config, now)
            state["cycle"] = next_cycle
        else:
            state = {
                "phase": "gate",
                "gate_reason": "break",
                "gate_started": now,
                "work_remaining": config["work_seconds"],
                "cycle": next_cycle,
                "last_tick": now,
                "away": False,
                "night": False,
            }
    elif state["phase"] == "work" and now >= int(state["deadline"]):
        is_long = state["cycle"] == config["long_break_every"] - 1
        state["phase"] = "break"
        state["break_type"] = "long" if is_long else "short"
        state["deadline"] = now + (
            config["long_break_seconds"] if is_long else config["short_break_seconds"]
        )

    state["last_tick"] = now
    return state, command_for(config, state)


def current_idle_seconds() -> int | None:
    """Return macOS HID idle time, or None when it cannot be determined."""
    try:
        output = subprocess.run(
            ["/usr/sbin/ioreg", "-a", "-c", "IOHIDSystem"],
            check=True,
            capture_output=True,
            timeout=5,
        ).stdout
        registry = plistlib.loads(output)
    except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException):
        return None

    def find_idle_time(value: Any) -> int | None:
        if isinstance(value, dict):
            idle_time = value.get("HIDIdleTime")
            if isinstance(idle_time, int) and not isinstance(idle_time, bool):
                return idle_time
            for child in value.values():
                result = find_idle_time(child)
                if result is not None:
                    return result
        elif isinstance(value, list):
            for child in value:
                result = find_idle_time(child)
                if result is not None:
                    return result
        return None

    nanoseconds = find_idle_time(registry)
    return None if nanoseconds is None else max(0, nanoseconds // 1_000_000_000)


def consume_request(
    now: int,
    path: Path | None = None,
    expected_uid: int | None = None,
) -> str | None:
    """Consume a request from the console user without trusting its contents."""
    if expected_uid is None:
        try:
            expected_uid = os.stat("/dev/console").st_uid
        except OSError:
            return None
    if expected_uid == 0:
        return None
    if path is None:
        path = Path(f"/tmp/com.chickenblocker.break-request.{expected_uid}.json")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        return None

    trusted_action = None
    try:
        metadata = os.fstat(descriptor)
        if (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_uid == expected_uid
            and metadata.st_nlink == 1
            and metadata.st_size <= 1024
            and metadata.st_mode & 0o077 == 0
        ):
            payload = json.loads(os.read(descriptor, 1025).decode("utf-8"))
            requested_at = payload.get("requested_at")
            action = payload.get("action")
            trusted = (
                action in ("take_break", "start_work")
                and isinstance(requested_at, int)
                and not isinstance(requested_at, bool)
                and now - 300 <= requested_at <= now + 30
            )
            if trusted:
                trusted_action = action
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        trusted_action = None
    finally:
        os.close(descriptor)
        try:
            path.unlink()
        except OSError:
            pass
    return trusted_action


def consume_break_request(
    now: int,
    path: Path | None = None,
    expected_uid: int | None = None,
) -> bool:
    return consume_request(now, path, expected_uid) == "take_break"


def atomic_json(path: Path, value: dict[str, Any], mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--command", required=True, type=Path)
    parser.add_argument("--now", type=int)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    config = json.loads(args.config.read_text(encoding="utf-8"))
    validate_config(config)
    if args.check:
        return 0
    try:
        state = json.loads(args.state.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        state = None
    now = args.now or int(time.time())
    request = consume_request(now)
    state, command = advance(
        config,
        state,
        now,
        request == "take_break",
        current_idle_seconds(),
        request == "start_work",
    )
    atomic_json(args.state, state, 0o600)
    atomic_json(args.command, command, 0o644)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
