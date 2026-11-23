#!/usr/bin/env python3
"""Embed the matching Apple Developer ID profile in a staged OTA app and sign it."""

import argparse
from datetime import datetime, timezone
from hashlib import sha1
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


RESOURCES = Path(__file__).resolve().parents[1] / "Resources"
ENTITLEMENTS = RESOURCES / "FloeMacHost-OTA-CloudKit.entitlements"
APPLICATION_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"
PUSH_ENVIRONMENT = "com.apple.developer.aps-environment"
CLOUD_CONTAINERS = "com.apple.developer.icloud-container-identifiers"
CLOUD_SERVICES = "com.apple.developer.icloud-services"
CLOUD_ENVIRONMENT = "com.apple.developer.icloud-container-environment"
KEYCHAIN_GROUPS = "keychain-access-groups"


def run(*command, **kwargs):
    return subprocess.run(command, check=True, timeout=60, **kwargs)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_claims(profile, requested, certificate, now):
    entitlements = profile.get("Entitlements", {})
    expires = profile.get("ExpirationDate")
    require(isinstance(expires, datetime) and expires.replace(tzinfo=timezone.utc) > now,
            "The provisioning profile has expired or lacks an expiration date.")
    require(profile.get("ProvisionsAllDevices") is True
            and entitlements.get("com.apple.developer.get-task-allow") is not True
            and entitlements.get("get-task-allow") is not True,
            "Use a Developer ID distribution profile for all Macs.")
    require("OSX" in profile.get("Platform", []), "The provisioning profile does not include macOS.")
    require(requested[TEAM_ID] in profile.get("TeamIdentifier", []),
            "The provisioning profile belongs to a different developer team.")
    require(certificate in profile.get("DeveloperCertificates", []),
            "The provisioning profile does not authorize the app's existing Developer ID certificate.")
    groups = requested[KEYCHAIN_GROUPS]
    allowed_groups = entitlements.get(KEYCHAIN_GROUPS, [])
    team = requested[TEAM_ID]
    require(groups[0] == requested[APPLICATION_ID] and isinstance(allowed_groups, list)
            and all(group.startswith(f"{team}.")
                    and (group in allowed_groups or f"{team}.*" in allowed_groups) for group in groups),
            "The provisioning profile does not grant the requested Keychain groups.")
    for key in (APPLICATION_ID, TEAM_ID, PUSH_ENVIRONMENT, CLOUD_CONTAINERS, CLOUD_SERVICES, CLOUD_ENVIRONMENT):
        expected = requested[key]
        allowed = entitlements.get(key)
        if key == CLOUD_SERVICES and allowed == "*":
            continue  # Apple's Developer ID profile wildcard for service names, not containers.
        if isinstance(expected, list):
            require(isinstance(allowed, list) and all(value in allowed for value in expected),
                    f"The provisioning profile does not grant the required values for {key}.")
        else:
            require(allowed == expected or isinstance(allowed, list) and expected in allowed,
                    f"The provisioning profile does not match {key}.")


def verify_signed_claims(app, requested):
    output = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(app), stdout=subprocess.PIPE).stdout
    signed = plistlib.loads(output)
    require(all(signed.get(key) == value for key, value in requested.items()),
            "The signed app does not contain the requested CloudKit and Keychain entitlements.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Staged Developer ID signed Floe Agent.app")
    parser.add_argument("profile", type=Path, help="Apple-issued Mac Developer ID .provisionprofile")
    parser.add_argument("--check", action="store_true", help="Validate the profile and app without changing them")
    args = parser.parse_args()

    contents = args.app / "Contents"
    requested = plistlib.loads(ENTITLEMENTS.read_bytes())
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    require(requested[APPLICATION_ID] == f"{requested[TEAM_ID]}.{info['CFBundleIdentifier']}",
            "The staged app does not use the existing Floe Bridge bundle identifier.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app))
    signature = run("/usr/bin/codesign", "-d", "--verbose=4", str(args.app), stderr=subprocess.PIPE).stderr
    require(b"Authority=Developer ID Application:" in signature,
            "The staged app must be signed with the existing Developer ID Application certificate.")
    profile = plistlib.loads(run("/usr/bin/security", "cms", "-D", "-i", str(args.profile),
                                stdout=subprocess.PIPE).stdout)
    with tempfile.TemporaryDirectory(prefix="floe-cloudkit-cert-") as temporary:
        prefix = str(Path(temporary) / "certificate")
        run("/usr/bin/codesign", "-d", "--extract-certificates=" + prefix, str(args.app))
        certificate = Path(prefix + "0").read_bytes()
    validate_claims(profile, requested, certificate, datetime.now(timezone.utc))
    if args.check:
        verify_signed_claims(args.app, requested)
        print("Floe Mac Developer ID provisioning profile matches the CloudKit signing configuration.")
        return

    embedded = contents / "embedded.provisionprofile"
    shutil.copyfile(args.profile, embedded)
    embedded.chmod(0o644)
    run("/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime", "--sign", sha1(certificate).hexdigest(),
        "--entitlements", str(ENTITLEMENTS), str(args.app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app))
    verify_signed_claims(args.app, requested)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from None
