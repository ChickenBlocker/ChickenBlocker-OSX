#!/usr/bin/env python3
"""Generate Firefox policy delivery files from the canonical policies JSON.

Runs on the Mac at install time:

    gen-firefox-profile.py <policies.json> <out-dir>

Produces in <out-dir>:
  org.mozilla.firefox.plist
      The expected managed-preferences content, used for inspection and
      diagnostics. The configuration profile below is the live delivery
      channel; Firefox does not honor a bare file copied into
      /Library/Managed Preferences.
  org.mozilla.firefox.mobileconfig
      Required configuration profile for a one-time manual install via
      System Settings -> General -> Device Management (double-click first).
      This is the live Firefox policy channel.
"""
import json
import os
import plistlib
import sys

PROFILE_UUID = "6348c9a2-7a51-4b1b-9d2a-2cb000000001"
PAYLOAD_UUID = "6348c9a2-7a51-4b1b-9d2a-2cb000000002"
IDENTIFIER = "com.chickenblocker.firefox"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: gen-firefox-profile.py <policies.json> <out-dir>")
    src, outdir = sys.argv[1], sys.argv[2]
    with open(src, "r") as f:
        data = json.load(f)
    policies = data.get("policies")
    if not isinstance(policies, dict):
        sys.exit("ERROR: %s has no 'policies' object" % src)

    # Unlike policies.json, Firefox's macOS preferences channel must be
    # explicitly enabled before any of the other policy keys are read.
    mac_policies = dict(policies)
    mac_policies["EnterprisePoliciesEnabled"] = True

    plist_path = os.path.join(outdir, "org.mozilla.firefox.plist")
    with open(plist_path, "wb") as f:
        plistlib.dump(mac_policies, f)
    print("wrote %s (%d policy keys)" % (plist_path, len(mac_policies)))

    profile = {
        "PayloadContent": [
            {
                "PayloadType": "com.apple.ManagedClient.preferences",
                "PayloadIdentifier": IDENTIFIER + ".managedprefs",
                "PayloadUUID": PAYLOAD_UUID,
                "PayloadVersion": 1,
                "PayloadDisplayName": "ChickenBlocker Firefox Policies",
                "PayloadOrganization": "ChickenBlocker",
                "PayloadContent": {
                    "org.mozilla.firefox": {
                        "Forced": [
                            {"mcx_preference_settings": mac_policies}
                        ]
                    }
                },
            }
        ],
        "PayloadIdentifier": IDENTIFIER,
        "PayloadRemovalDisallowed": True,
        # User scope: system-scoped managed-preferences payloads from manual
        # profiles are not materialized into /Library/Managed Preferences on
        # macOS 27 (verified on-target); user-scoped ones are.
        "PayloadScope": "User",
        "PayloadType": "Configuration",
        "PayloadUUID": PROFILE_UUID,
        "PayloadVersion": 1,
        "PayloadDisplayName": "ChickenBlocker Firefox",
        "PayloadOrganization": "ChickenBlocker",
    }
    mc_path = os.path.join(outdir, "org.mozilla.firefox.mobileconfig")
    with open(mc_path, "wb") as f:
        plistlib.dump(profile, f)
    print("wrote %s (optional manual System Settings install)" % mc_path)


if __name__ == "__main__":
    main()
