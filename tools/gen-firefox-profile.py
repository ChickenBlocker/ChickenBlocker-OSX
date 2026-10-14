#!/usr/bin/env python3
"""Generate Firefox policy delivery files from the canonical policies JSON.

Runs on the Mac at install time:

    gen-firefox-profile.py <policies.json> <out-dir>

Produces in <out-dir>:
  org.mozilla.firefox.plist
      The managed-preferences file installed to
      /Library/Managed Preferences/org.mozilla.firefox.plist — the same file
      a configuration profile would deliver, enforced directly by the
      verifier (root-owned, outside any app bundle: no App-Management TCC,
      survives Firefox updates; `profiles install` no longer exists on
      macOS 27).
  org.mozilla.firefox.mobileconfig
      Optional configuration profile for a one-time manual install via
      System Settings -> Profiles (double-click). Adds UI-removal friction
      on top of the plist channel.
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

    plist_path = os.path.join(outdir, "org.mozilla.firefox.plist")
    with open(plist_path, "wb") as f:
        plistlib.dump(policies, f)
    print("wrote %s (%d policy keys)" % (plist_path, len(policies)))

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
    mc_path = os.path.join(outdir, "org.mozilla.firefox.mobileconfig")
    with open(mc_path, "wb") as f:
        plistlib.dump(profile, f)
    print("wrote %s (optional manual System Settings install)" % mc_path)


if __name__ == "__main__":
    main()
