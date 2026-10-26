import importlib.util
import os
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
            "night_start_hour": 0,
            "night_end_hour": 8,
            "suspend_gap_seconds": 45,
            "short_messages": ["short"],
            "long_messages": ["long"],
            "night_message": "night",
        }

    def test_first_day_tick_starts_work(self):
        now = epoch(9)
        state, command = SCHEDULER.advance(self.config, None, now)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["deadline"], now + 1800)
        self.assertEqual(command["mode"], "work")
        self.assertTrue(command["allow_escape"])

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

    def test_completed_break_advances_cycle_and_starts_work(self):
        now = epoch(9)
        state = {
            "phase": "break", "break_type": "short", "deadline": now,
            "cycle": 0, "last_tick": now - 15, "night": False,
        }
        state, command = SCHEDULER.advance(self.config, state, now)
        self.assertEqual(state["phase"], "work")
        self.assertEqual(state["cycle"], 1)
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


if __name__ == "__main__":
    unittest.main()
