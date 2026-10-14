#!/usr/bin/env python3
"""Generate the Firefox configuration profile (mobileconfig) from the
canonical policies JSON.

Runs on the Mac at install time:

    gen-firefox-profile.py <policies.json> <out.mobileconfig>

The profile delivers the org.mozilla.firefox managed-preferences domain
(payload com.apple.managed.preferences), which Firefox reads as enterprise
policies. This channel replaces distribution/policies.json inside Firefox.app:
it survives Firefox updates (nothing is written into the app bundle, so no
App-Management TCC consent and no elevated updates).
"""
import json
import plistlib
import sys

PROFILE_UUID = "6348c9a2-7a51-4b1b-9d2a-2cb000000001"
PAYLOAD_UUID = "6348c9a2-7a51-4b1b-9d2a-2cb000000002"
IDENTIFIER = "com.chickenblocker.firefox"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen-firefox-profile.py <policies.json> <out.mobileconfig>")
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "r") as f:
        data = json.load(f)
    policies = data.get("policies")
    if not isinstance(policies, dict):
        sys.exit("ERROR: %s has no 'policies' object" % src)

    profile = {
        "PayloadContent": [
            {
                "PayloadType": "com.apple.managed.preferences",
                "PayloadIdentifier": IDENTIFIER + ".managedprefs",
                "PayloadUUID": PAYLOAD_UUID,
                "PayloadVersion": 1,
                "PayloadDisplayName": "ChickenBlocker Firefox Policies",
                "PayloadOrganization": "ChickenBlocker",
                "PayloadContent": {
                    "org.mozilla.firefox": {
                        "Forced": [
                            {"mcx_domain_settings": policies}
                        ]
                    }
                },
            }
        ],
        "PayloadIdentifier": IDENTIFIER,
        "PayloadRemovalDisallowed": True,
        "PayloadScope": "System",
        "PayloadType": "Configuration",
        "PayloadUUID": PROFILE_UUID,
        "PayloadVersion": 1,
        "PayloadDisplayName": "ChickenBlocker Firefox",
        "PayloadOrganization": "ChickenBlocker",
    }

    with open(dst, "wb") as f:
        plistlib.dump(profile, f)
    print("wrote %s (%d policy keys)" % (dst, len(policies)))


if __name__ == "__main__":
    main()
