import importlib.util
import json
import os
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "break_scheduler", ROOT / "tools" / "break-scheduler.py"
)
assert SPEC and SPEC.loader
SCHEDULER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCHEDULER)


def epoch(hour: int, minute: int = 0) -> int:
    return int(datetime(2026, 1, 2, hour, minute, tzinfo=timezone.utc).timestamp())


class BreakSchedulerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.old_tz = os.environ.get("TZ")
        os.environ["TZ"] = "UTC"
        time.tzset()

    @classmethod
    def tearDownClass(cls):
        if cls.old_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = cls.old_tz
        time.tzset()

    def setUp(self):
        self.config = {
            "enabled": True,
            "allow_escape": True,
            "work_seconds": 1800,
            "short_break_seconds": 300,
            "long_break_seconds": 1800,
            "long_break_every": 4,
            "warning_seconds": 10,
            "idle_away_seconds": 180,
            "idle_gate_reset_seconds": 1800,
            "night_start_hour": 0,
            "night_end_hour": 8,
            "suspend_gap_seconds": 45,
            "short_messages": ["short"],
            "long_messages": ["long"],
            "start_work_message": "start",
            "away_message": "away",
            "night_message": "night",
        }

    def test_first_day_tick_starts_work(self):
        now = epoch(9)
        state, command = SCHEDULER.advance(self.config, None, now)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["deadline"], now + 1800)
        self.assertEqual(command["mode"], "work")
        self.assertTrue(command["allow_escape"])
        self.assertEqual(command["interval"], 1)
        self.assertEqual(command["total_intervals"], 4)
        self.assertEqual(command["warning_seconds"], 10)
        self.assertEqual(command["next_break_kind"], "short")

    def test_due_work_imposes_short_break(self):
        now = epoch(9)
        state = {"phase": "work", "deadline": now, "cycle": 0, "last_tick": now - 15, "night": False}
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["break_type"], "short")
        self.assertEqual(command["until"], now + 300)

    def test_fourth_cycle_imposes_long_break(self):
        now = epoch(9)
        state = {"phase": "work", "deadline": now, "cycle": 3, "last_tick": now - 15, "night": False}
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["break_type"], "long")
        self.assertEqual(command["until"], now + 1800)
        self.assertEqual(command["interval"], 4)
        self.assertEqual(command["next_break_kind"], "long")

    def test_manual_request_starts_next_short_break(self):
        now = epoch(9)
        state = {"phase": "work", "deadline": now + 900, "cycle": 0, "last_tick": now, "night": False}
        state, command = SCHEDULER.advance(self.config, state, now, manual_break=True)
        self.assertEqual(state["break_type"], "short")
        self.assertEqual(command["until"], now + 300)

    def test_manual_request_preserves_next_long_break(self):
        now = epoch(9)
        state = {"phase": "work", "deadline": now + 900, "cycle": 3, "last_tick": now, "night": False}
        state, command = SCHEDULER.advance(self.config, state, now, manual_break=True)
        self.assertEqual(state["break_type"], "long")
        self.assertEqual(command["until"], now + 1800)

    def test_manual_request_does_not_extend_active_break(self):
        now = epoch(9)
        state = {
            "phase": "break", "break_type": "short", "deadline": now + 120,
            "cycle": 0, "last_tick": now, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now, manual_break=True)
        self.assertEqual(command["until"], now + 120)

    def test_secure_current_request_is_consumed(self):
        now = epoch(9)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps({"action": "take_break", "requested_at": now}))
            path.chmod(0o600)
            self.assertTrue(SCHEDULER.consume_break_request(now, path, os.getuid()))
            self.assertFalse(path.exists())

    def test_stale_request_is_rejected(self):
        now = epoch(9)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps({"action": "take_break", "requested_at": now - 301}))
            path.chmod(0o600)
            self.assertFalse(SCHEDULER.consume_break_request(now, path, os.getuid()))

    def test_group_readable_request_is_rejected(self):
        now = epoch(9)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps({"action": "take_break", "requested_at": now}))
            path.chmod(0o640)
            self.assertFalse(SCHEDULER.consume_break_request(now, path, os.getuid()))

    def test_negative_warning_time_is_rejected(self):
        self.config["warning_seconds"] = -1
        with self.assertRaisesRegex(ValueError, "warning_seconds"):
            SCHEDULER.advance(self.config, None, epoch(9))

    def test_completed_break_advances_cycle_and_waits_for_start(self):
        now = epoch(9)
        state = {
            "phase": "break", "break_type": "short", "deadline": now,
            "cycle": 0, "last_tick": now - 15, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["phase"], "gate")
        self.assertEqual(state["cycle"], 1)
        self.assertEqual(command["mode"], "gate")
        self.assertEqual(command["message"], "start")

    def test_sleep_that_finishes_break_skips_start_gate(self):
        now = epoch(9)
        state = {
            "phase": "break", "break_type": "short", "deadline": now - 60,
            "cycle": 0, "last_tick": now - 600, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["cycle"], 1)
        self.assertEqual(state["deadline"], now + 1800)
        self.assertEqual(command["mode"], "work")

    def test_night_always_imposes_until_morning(self):
        now = epoch(2)
        state, command = SCHEDULER.advance(self.config, None, now)
        self.assertTrue(state["night"])
        self.assertEqual(command["kind"], "night")
        self.assertEqual(command["until"], epoch(8))

    def test_suspend_longer_than_remaining_work_skips_pending_break(self):
        now = epoch(10)
        state = {
            "phase": "work", "deadline": now - 60, "cycle": 0,
            "last_tick": now - 600, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["cycle"], 1)
        self.assertEqual(state["deadline"], now + 1800)
        self.assertEqual(command["mode"], "work")

    def test_short_suspend_pauses_work_countdown(self):
        now = epoch(10)
        state = {
            "phase": "work", "deadline": now + 900, "cycle": 0,
            "last_tick": now - 300, "night": False,
        }
        state, _ = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["deadline"], now + 1200)

    def test_idle_threshold_reclassifies_idle_time_as_away(self):
        now = epoch(10)
        state = {
            "phase": "work", "deadline": now + 600, "cycle": 0,
            "last_tick": now - 15, "work_started": now - 900,
            "away": False, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now, idle_seconds=300)
        self.assertEqual(state["phase"], "gate")
        self.assertEqual(state["work_remaining"], 900)
        self.assertEqual(command["mode"], "gate")
        self.assertEqual(command["message"], "away")

    def test_work_countdown_stays_paused_at_away_gate(self):
        now = epoch(10)
        state = {
            "phase": "gate", "gate_reason": "away", "gate_started": now - 15,
            "work_remaining": 600, "cycle": 0, "last_tick": now - 15,
            "away": False, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now, idle_seconds=0)
        self.assertEqual(state["phase"], "gate")
        self.assertEqual(state["work_remaining"], 600)
        self.assertEqual(command["mode"], "gate")

    def test_start_button_resumes_preserved_work_countdown(self):
        now = epoch(10)
        state = {
            "phase": "gate", "gate_reason": "away", "gate_started": now - 15,
            "work_remaining": 600, "cycle": 0, "last_tick": now - 15,
            "away": False, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now, start_work=True)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["deadline"], now + 600)
        self.assertEqual(command["mode"], "work")

    def test_long_start_gate_resets_to_full_work_interval(self):
        now = epoch(10)
        state = {
            "phase": "gate", "gate_reason": "away", "gate_started": now - 1800,
            "work_remaining": 300, "cycle": 0, "last_tick": now - 15,
            "away": False, "night": False,
        }
        state, _ = SCHEDULER.advance(self.config, state, now, start_work=True)
        self.assertEqual(state["deadline"], now + 1800)

    def test_secure_start_work_request_is_consumed(self):
        now = epoch(9)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "request.json"
            path.write_text(json.dumps({"action": "start_work", "requested_at": now}))
            path.chmod(0o600)
            self.assertEqual(
                SCHEDULER.consume_request(now, path, os.getuid()), "start_work"
            )
            self.assertFalse(path.exists())

    def test_suspend_and_hid_idle_are_not_counted_twice(self):
        now = epoch(10)
        state = {
            "phase": "work", "deadline": now + 900, "cycle": 0,
            "last_tick": now - 600, "work_started": now - 900,
            "away": False, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now, idle_seconds=600)
        self.assertEqual(state["deadline"], now + 1500)
        self.assertTrue(command["away"])

    def test_idle_away_time_must_be_positive(self):
        self.config["idle_away_seconds"] = 0
        with self.assertRaisesRegex(ValueError, "idle_away_seconds"):
            SCHEDULER.advance(self.config, None, epoch(9))


if __name__ == "__main__":
    unittest.main()
