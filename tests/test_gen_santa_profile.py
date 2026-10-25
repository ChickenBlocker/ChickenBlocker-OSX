#!/usr/bin/env python3
import importlib.util
import os
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
MODULE_PATH = os.path.join(ROOT, "tools", "gen-santa-profile.py")
SPEC = importlib.util.spec_from_file_location("gen_santa_profile", MODULE_PATH)
gen_santa_profile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gen_santa_profile)


class SantaCatalogTests(unittest.TestCase):
    def test_production_catalog_contains_reviewed_browser_identities(self):
        rules = gen_santa_profile.load_catalog(
            os.path.join(ROOT, "config", "santa-rules.json"))

        identifiers = {rule["identifier"] for rule in rules}
        self.assertEqual(len(rules), 10)
        self.assertIn("platform:com.apple.Safari", identifiers)
        self.assertIn("EQHXZ8M8AV:com.google.Chrome", identifiers)
        self.assertIn("43AQ936H96:org.mozilla.firefoxdeveloperedition", identifiers)
        self.assertIn("43AQ936H96:org.mozilla.nightly", identifiers)
        self.assertNotIn("43AQ936H96:org.mozilla.firefox", identifiers)

    def test_stable_firefox_identity_is_forbidden(self):
        rule = self._rule("43AQ936H96:org.mozilla.firefox")

        with self.assertRaises(gen_santa_profile.ValidationError):
            gen_santa_profile.validate_catalog({"rules": [rule]})

    def test_verified_firefox_variant_is_allowed(self):
        rule = self._rule("43AQ936H96:org.mozilla.nightly")

        output = gen_santa_profile.validate_catalog({"rules": [rule]})

        self.assertEqual(output[0]["identifier"], rule["identifier"])
        self.assertNotIn("artifact_sha256", output[0])

    def test_third_party_identity_requires_team_id_format(self):
        rule = self._rule("com.google.Chrome")

        with self.assertRaises(gen_santa_profile.ValidationError):
            gen_santa_profile.validate_catalog({"rules": [rule]})

    def test_third_party_identity_requires_verification_evidence(self):
        rule = self._rule("EQHXZ8M8AV:com.google.Chrome")
        del rule["artifact_sha256"]

        with self.assertRaises(gen_santa_profile.ValidationError):
            gen_santa_profile.validate_catalog({"rules": [rule]})

    @staticmethod
    def _rule(identifier):
        return {
            "name": "Test browser",
            "rule_type": "SIGNINGID",
            "identifier": identifier,
            "policy": "BLOCKLIST",
            "enabled": True,
            "verified_version": "1.0",
            "artifact_sha256": "a" * 64,
            "source_url": "https://example.invalid/browser.dmg",
        }


if __name__ == "__main__":
    unittest.main()
