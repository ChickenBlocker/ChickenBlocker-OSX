#!/usr/bin/env python3
"""Validate Santa rules and generate deterministic configuration profiles."""

import argparse
import json
import os
import plistlib
import re
import sys


PRODUCTION_IDENTIFIER = "com.chickenblocker.santa"
PROBE_IDENTIFIER = "com.chickenblocker.santa.probe"
PRODUCTION_PROFILE_UUID = "A77657D1-39E8-5B3A-A0C5-6F9CBFD93A61"
PRODUCTION_PAYLOAD_UUID = "82C48E4A-EE6E-5EC3-B79B-FD3076CD2DBB"
PROBE_PROFILE_UUID = "B7709707-23C6-5967-8BF5-F2F710CD2127"
PROBE_PAYLOAD_UUID = "795A99A7-40E6-5070-878F-121AFDAD86D7"
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
SIGNING_ID_RE = re.compile(
    r"^(?:platform:[A-Za-z0-9][A-Za-z0-9.-]*|[A-Z0-9]{10}:[A-Za-z0-9][A-Za-z0-9.-]*)$"
)
ALLOWED_CATALOG_KEYS = {
    "name", "rule_type", "identifier", "policy", "custom_msg", "enabled",
    "verified_version", "artifact_sha256", "source_url",
}
ALLOWED_RULE_TYPES = {"SIGNINGID"}
ALLOWED_POLICIES = {"BLOCKLIST"}
FORBIDDEN_EXACT_IDENTIFIERS = {
    "platform:com.apple.launchd",
    "platform:com.apple.sh",
    "platform:com.apple.bash",
    "platform:com.apple.zsh",
    "43aq936h96:org.mozilla.firefox",
}


class ValidationError(ValueError):
    """Raised when a catalog or probe rule is unsafe or malformed."""


def _nonempty_string(value, field, index):
    if not isinstance(value, str) or not value.strip():
        raise ValidationError("rule %d has invalid %s" % (index, field))
    return value


def _forbidden_identifier(identifier):
    lowered = identifier.lower()
    if lowered in FORBIDDEN_EXACT_IDENTIFIERS:
        return True
    return any(token in lowered for token in ("santa", "com.apple.webkit."))


def validate_catalog(data):
    if not isinstance(data, dict) or set(data) != {"rules"}:
        raise ValidationError("catalog must contain only a 'rules' array")
    if not isinstance(data["rules"], list):
        raise ValidationError("catalog 'rules' must be an array")

    enabled_rules = []
    identifiers = set()
    for index, rule in enumerate(data["rules"], 1):
        if not isinstance(rule, dict):
            raise ValidationError("rule %d must be an object" % index)
        unknown = set(rule) - ALLOWED_CATALOG_KEYS
        required = {"name", "rule_type", "identifier", "policy", "enabled"}
        if unknown or not required.issubset(rule):
            raise ValidationError("rule %d has missing or unknown fields" % index)

        _nonempty_string(rule["name"], "name", index)
        rule_type = _nonempty_string(rule["rule_type"], "rule_type", index)
        identifier = _nonempty_string(rule["identifier"], "identifier", index)
        policy = _nonempty_string(rule["policy"], "policy", index)
        if rule_type not in ALLOWED_RULE_TYPES:
            raise ValidationError("rule %d uses disallowed rule_type %s" % (index, rule_type))
        if policy not in ALLOWED_POLICIES:
            raise ValidationError("rule %d uses disallowed policy %s" % (index, policy))
        if not isinstance(rule["enabled"], bool):
            raise ValidationError("rule %d enabled must be boolean" % index)
        if not SIGNING_ID_RE.fullmatch(identifier):
            raise ValidationError(
                "rule %d identifier must be platform:bundle-id or TEAMID:bundle-id" % index
            )
        if identifier in identifiers:
            raise ValidationError("duplicate rule identifier: %s" % identifier)
        if _forbidden_identifier(identifier):
            raise ValidationError("forbidden block target: %s" % identifier)
        identifiers.add(identifier)

        custom_msg = rule.get("custom_msg")
        if custom_msg is not None and not isinstance(custom_msg, str):
            raise ValidationError("rule %d custom_msg must be a string" % index)
        evidence = (
            rule.get("verified_version"), rule.get("artifact_sha256"),
            rule.get("source_url"))
        if not identifier.startswith("platform:") and not all(evidence):
            raise ValidationError(
                "rule %d third-party SigningID requires verification evidence" % index
            )
        if any(value is not None for value in evidence):
            if not all(isinstance(value, str) and value for value in evidence):
                raise ValidationError("rule %d verification evidence must be complete" % index)
            if not SHA256_RE.fullmatch(rule["artifact_sha256"]):
                raise ValidationError("rule %d has invalid artifact_sha256" % index)
            if not rule["source_url"].startswith("https://"):
                raise ValidationError("rule %d source_url must use HTTPS" % index)
        if rule["enabled"]:
            output = {
                "identifier": identifier,
                "policy": policy,
                "rule_type": rule_type,
            }
            if custom_msg:
                output["custom_msg"] = custom_msg
            enabled_rules.append(output)
    return enabled_rules


def load_catalog(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return validate_catalog(json.load(handle))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError("cannot read catalog %s: %s" % (path, error)) from error


def probe_rule(identifier):
    if not isinstance(identifier, str) or not SHA256_RE.fullmatch(identifier):
        raise ValidationError("probe identifier must be exactly 64 hexadecimal characters")
    return [{
        "identifier": identifier.lower(),
        "policy": "BLOCKLIST",
        "rule_type": "BINARY",
        "custom_msg": "ChickenBlocker disposable Santa probe was blocked.",
    }]


def santa_payload(rules, mode):
    identifier = PROBE_IDENTIFIER if mode == "probe" else PRODUCTION_IDENTIFIER
    payload_uuid = PROBE_PAYLOAD_UUID if mode == "probe" else PRODUCTION_PAYLOAD_UUID
    return {
        "ClientMode": 1,
        "EnableNotificationSilences": False,
        "EnableSilentMode": False,
        "EnableSilentTTYMode": False,
        "PayloadDisplayName": "ChickenBlocker Santa Configuration",
        "PayloadIdentifier": identifier + ".config",
        "PayloadOrganization": "ChickenBlocker",
        "PayloadType": "com.northpolesec.santa",
        "PayloadUUID": payload_uuid,
        "PayloadVersion": 1,
        "StaticRules": rules,
    }


def build_profile(rules, mode):
    if mode == "production" and not rules:
        raise ValidationError("production profile must contain at least one enabled rule")
    if mode == "probe":
        if (len(rules) != 1 or rules[0].get("rule_type") != "BINARY" or
                rules[0].get("identifier") == "platform:com.apple.Safari"):
            raise ValidationError("probe profile must contain exactly one SHA-256 BINARY rule")
    if mode == "rollback" and rules:
        raise ValidationError("rollback profile must not contain rules")

    identifier = PROBE_IDENTIFIER if mode == "probe" else PRODUCTION_IDENTIFIER
    profile_uuid = PROBE_PROFILE_UUID if mode == "probe" else PRODUCTION_PROFILE_UUID
    display_suffix = {"production": "Safari Denial", "probe": "Probe", "rollback": "Rollback"}[mode]
    return {
        "PayloadContent": [santa_payload(rules, mode)],
        "PayloadDescription": "Santa Monitor mode with ChickenBlocker-reviewed static rules.",
        "PayloadDisplayName": "ChickenBlocker Santa %s" % display_suffix,
        "PayloadIdentifier": identifier,
        "PayloadOrganization": "ChickenBlocker",
        "PayloadRemovalDisallowed": True,
        "PayloadScope": "System",
        "PayloadType": "Configuration",
        "PayloadUUID": profile_uuid,
        "PayloadVersion": 1,
    }


def profile_bytes(profile):
    return plistlib.dumps(profile, fmt=plistlib.FMT_XML, sort_keys=True)


def write_outputs(profile, output_dir, basename):
    os.makedirs(output_dir, exist_ok=True)
    payload_path = os.path.join(output_dir, basename + ".plist")
    profile_path = os.path.join(output_dir, basename + ".mobileconfig")
    with open(payload_path, "wb") as handle:
        plistlib.dump(profile["PayloadContent"][0], handle, sort_keys=True)
    with open(profile_path, "wb") as handle:
        handle.write(profile_bytes(profile))
    return payload_path, profile_path


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("production", "probe", "rollback"))
    parser.add_argument("--catalog", help="production Santa rule catalog")
    parser.add_argument("--probe-sha256", help="disposable probe SHA-256")
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.mode == "production":
            if not args.catalog or args.probe_sha256:
                raise ValidationError("production mode requires --catalog only")
            rules = load_catalog(args.catalog)
            basename = PRODUCTION_IDENTIFIER
        elif args.mode == "probe":
            if not args.probe_sha256 or args.catalog:
                raise ValidationError("probe mode requires --probe-sha256 only")
            rules = probe_rule(args.probe_sha256)
            basename = PROBE_IDENTIFIER
        else:
            if args.catalog or args.probe_sha256:
                raise ValidationError("rollback mode accepts no rule input")
            rules = []
            basename = PRODUCTION_IDENTIFIER + ".rollback"
        paths = write_outputs(build_profile(rules, args.mode), args.output_dir, basename)
    except ValidationError as error:
        sys.exit("ERROR: %s" % error)
    for path in paths:
        print("wrote %s" % path)


if __name__ == "__main__":
    main()
