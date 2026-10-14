#!/usr/bin/env python3
import copy
import importlib.util
import os
import unittest


MODULE_PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)),
                           "sync", "extract_rules.py")
SPEC = importlib.util.spec_from_file_location("extract_rules", MODULE_PATH)
extract_rules = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(extract_rules)


class ForcePopulatedSetsTests(unittest.TestCase):
    def test_populated_set_is_forced_to_block_all_day(self):
        source = {
            "numSets": "2",
            "sites2": "example.com",
            "activeBlock2": False,
            "days2": [False] * 7,
            "times2": "0900-1000",
            "limitMins2": "15",
            "limitPeriod2": "86400",
            "limitOffset2": "4",
            "disable2": True,
            "setName2": "Timed sites",
            "unrelated": {"keep": [1, 2, 3]},
        }
        original = copy.deepcopy(source)

        result = extract_rules.force_populated_sets_always_blocked(source)

        self.assertTrue(result["activeBlock2"])
        self.assertEqual(result["days2"], [True] * 7)
        self.assertEqual(result["times2"], "0000-2359")
        self.assertEqual(result["limitMins2"], "")
        self.assertEqual(result["limitPeriod2"], "")
        self.assertEqual(result["limitOffset2"], "")
        self.assertFalse(result["disable2"])
        self.assertEqual(result["setName2"], "Timed sites")
        self.assertEqual(result["unrelated"], {"keep": [1, 2, 3]})
        self.assertEqual(source, original)

    def test_empty_set_is_inactive_without_rewriting_other_fields(self):
        source = {
            "numSets": 1,
            "sites1": "  ",
            "activeBlock1": True,
            "times1": "1200-1300",
            "disable1": True,
        }

        result = extract_rules.force_populated_sets_always_blocked(source)

        self.assertFalse(result["activeBlock1"])
        self.assertEqual(result["times1"], "1200-1300")
        self.assertTrue(result["disable1"])

    def test_regexp_only_set_is_populated_and_raises_numsets(self):
        source = {
            "numSets": "2",
            "sites6": "",
            "regexpBlock6": "blocked-word",
            "activeBlock6": False,
        }

        result = extract_rules.force_populated_sets_always_blocked(source)

        self.assertEqual(result["numSets"], "6")
        self.assertTrue(result["activeBlock6"])
        self.assertEqual(result["regexpBlock6"], "blocked-word")

    def test_numsets_is_always_clamped_to_supported_range(self):
        cases = [
            ({"numSets": 0}, 1),
            ({"numSets": 99}, 6),
            ({"numSets": "invalid"}, "6"),
            ({}, 6),
        ]
        for source, expected in cases:
            with self.subTest(source=source):
                result = extract_rules.force_populated_sets_always_blocked(source)
                self.assertEqual(result["numSets"], expected)


if __name__ == "__main__":
    unittest.main()
