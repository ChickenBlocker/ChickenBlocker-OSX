#!/usr/bin/env python3
"""Root-owned schedule state machine for the macOS break overlay."""

from __future__ import annotations

import argparse
import json
import os
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
    for key in ("short_messages", "long_messages"):
        value = config.get(key)
        if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
            raise ValueError(f"{key} must be a non-empty string list")
    if not isinstance(config.get("night_message"), str) or not config["night_message"]:
        raise ValueError("night_message must be a non-empty string")


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
        "night": False,
    }


def command_for(config: dict[str, Any], state: dict[str, Any]) -> dict[str, Any]:
    phase = state["phase"]
    if phase == "work":
        return {
            "mode": "work", "until": state["deadline"], "kind": "work", "message": "",
            "allow_escape": bool(config.get("allow_escape", False)),
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
    return {
        "mode": "break", "until": state["deadline"], "kind": kind, "message": message,
        "allow_escape": bool(config.get("allow_escape", False)),
    }


def advance(config: dict[str, Any], state: dict[str, Any] | None, now: int) -> tuple[dict[str, Any], dict[str, Any]]:
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
    if phase not in ("work", "break"):
        state = fresh_state(config, now)
        phase = "work"
    state["cycle"] = int(state.get("cycle", 0)) % config["long_break_every"]
    state["night"] = False

    last_tick = int(state.get("last_tick", now))
    gap = max(0, now - last_tick)
    if phase == "work" and gap > config["suspend_gap_seconds"]:
        remaining = int(state["deadline"]) - last_tick
        if remaining > gap:
            state["deadline"] = int(state["deadline"]) + gap
        else:
            state["cycle"] = (state["cycle"] + 1) % config["long_break_every"]
            state["deadline"] = now + config["work_seconds"]

    if state["phase"] == "break" and now >= int(state["deadline"]):
        state = {
            "phase": "work",
            "deadline": now + config["work_seconds"],
            "cycle": (state["cycle"] + 1) % config["long_break_every"],
            "last_tick": now,
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
    state, command = advance(config, state, args.now or int(time.time()))
    atomic_json(args.state, state, 0o600)
    atomic_json(args.command, command, 0o644)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
