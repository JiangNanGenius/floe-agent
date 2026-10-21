#!/usr/bin/env python3
"""Validate and sign every embedded, source-declared Floe extension.

Profiles stay in the runner's private temporary directory. Nothing prints
profile contents, certificate identities or entitlement payloads. All profiles
and bundles are checked before the first signature is changed.
"""

import argparse
import base64
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import shutil
import subprocess
import os


TEAM = "QYL72C43K6"
APP_ID = "org.floeagent.ios"
EXTENSIONS = {
    APP_ID + ".screenshare": ("FloeScreenShare", "FloeScreenShare", "APPLE_SCREENSHARE_PROVISIONING_PROFILE_BASE64"),
    APP_ID + ".share": ("FloeShare", "FloeShare", "APPLE_SHARE_PROVISIONING_PROFILE_BASE64"),
    APP_ID + ".widgets": ("FloeWidgets", "FloeWidgets", "APPLE_WIDGETS_PROVISIONING_PROFILE_BASE64"),
    APP_ID + ".fileprovider": ("FloeFileProvider", "FloeFileProvider", "APPLE_FILEPROVIDER_PROVISIONING_PROFILE_BASE64"),
}


class SigningInputError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise SigningInputError(message)


def read_plist(path):
    require(path.is_file() and not path.is_symlink(), "Missing or unsafe signing input")
    with path.open("rb") as stream:
        result = plistlib.load(stream)
    require(isinstance(result, dict), "Invalid signing input")
    return result


def allows(granted, requested):
    """Capabilities are subsets; no wildcard substitutes for exact identities."""
    if isinstance(requested, bool):
        return isinstance(granted, bool) and granted == requested
    if isinstance(requested, list):
        return isinstance(granted, list) and all(value in granted for value in requested)
    if isinstance(requested, dict):
        return isinstance(granted, dict) and all(
            key in granted and allows(granted[key], value) for key, value in requested.items()
        )
    return type(granted) is type(requested) and granted == requested


def validated_entitlements(profile, declared, bundle_id, now=None):
    now = now or datetime.now(timezone.utc)
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, datetime), "Profile has no expiration")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    require(expiration > now, "Profile expired")
    require(profile.get("TeamIdentifier") == [TEAM], "Profile team mismatch")
    require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
            "App Store distribution profile required")
    entitlements = profile.get("Entitlements", {})
    identifier = TEAM + "." + bundle_id
    require(entitlements.get("application-identifier") == identifier, "Profile application mismatch")
    require(entitlements.get("get-task-allow") is False, "Development profile refused")
    require(entitlements.get("beta-reports-active") is True, "TestFlight profile required")
    require(declared.get("com.apple.security.application-groups") == ["group." + APP_ID],
            "Source App Group mismatch")
    for key, value in declared.items():
        require(key in entitlements and allows(entitlements[key], value),
                "Profile does not grant a declared capability")
    signed = dict(declared)
    signed.update({
        "application-identifier": identifier,
        "com.apple.developer.team-identifier": TEAM,
        "get-task-allow": False,
        "beta-reports-active": True,
        "keychain-access-groups": [identifier],
    })
    groups = entitlements.get("keychain-access-groups", [])
    require(identifier in groups or TEAM + ".*" in groups, "Profile keychain scope mismatch")
    return signed


def inventory(app):
    host = read_plist(app / "Info.plist")
    require(host.get("CFBundleIdentifier") == APP_ID, "Host application mismatch")
    plugins = app / "PlugIns"
    require(plugins.is_dir() and not plugins.is_symlink(), "Embedded extensions missing")
    found = {}
    for extension in plugins.iterdir():
        require(extension.suffix == ".appex" and extension.is_dir() and not extension.is_symlink(),
                "Unexpected embedded extension input")
        info = read_plist(extension / "Info.plist")
        identifier = info.get("CFBundleIdentifier")
        require(identifier in EXTENSIONS and identifier not in found, "Unknown or duplicate embedded extension")
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            require(isinstance(host.get(key), str) and info.get(key) == host[key], "Extension version mismatch")
        found[identifier] = extension
    require(set(found) == set(EXTENSIONS), "Required embedded extension missing")
    return found


def decode_profile(path):
    require(path.is_file() and not path.is_symlink(), "Required profile missing")
    result = subprocess.run(["security", "cms", "-D", "-i", str(path)],
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    profile = plistlib.loads(result.stdout)
    require(isinstance(profile, dict), "Invalid profile")
    return profile


def install_profile_inputs(directory):
    directory.mkdir(parents=True, exist_ok=True)
    # Existing Screen Share input is installed by the established workflow.
    for _, (stem, _, key) in EXTENSIONS.items():
        path = directory / (stem + ".mobileprovision")
        if path.exists():
            require(path.is_file() and not path.is_symlink(), "Unsafe profile input")
            continue
        encoded = os.environ.get(key)
        require(bool(encoded), "Required extension profile is not configured")
        data = base64.b64decode(encoded, validate=True)
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            stream.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--profiles-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path("."))
    args = parser.parse_args()
    identity = os.environ.get("SIGN_IDENTITY")
    require(bool(identity), "Distribution identity missing")
    bundles = inventory(args.app)
    install_profile_inputs(args.profiles_dir)
    # Validate the newly requested host capabilities (HealthKit, NFC, etc.)
    # as well as extensions, before changing any bundle or signature.
    validated_entitlements(
        decode_profile(args.profiles_dir / "Floe.mobileprovision"),
        read_plist(args.source_root / "FloeApp/Entitlements/Floe.entitlements"), APP_ID
    )
    prepared = []
    for identifier, (stem, folder, _) in EXTENSIONS.items():
        profile = args.profiles_dir / (stem + ".mobileprovision")
        entitlement_path = args.profiles_dir / (stem + ".entitlements")
        signed = validated_entitlements(
            decode_profile(profile),
            read_plist(args.source_root / folder / (stem + ".entitlements")), identifier
        )
        # Generated signing input stays outside the source/bundle trees.
        entitlement_path.write_bytes(plistlib.dumps(signed))
        entitlement_path.chmod(0o600)
        prepared.append((bundles[identifier], profile, entitlement_path))
    for bundle, profile, entitlements in prepared:
        shutil.copyfile(profile, bundle / "embedded.mobileprovision")
        subprocess.run(["codesign", "--force", "--sign", identity, "--entitlements", str(entitlements),
                        "--generate-entitlement-der", str(bundle)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    print("Validated and signed all required embedded extensions")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        # Suppress subprocess/profile payloads, paths and signing identities.
        raise SystemExit("Extension signing failed: " + (
            str(error) if isinstance(error, SigningInputError) else type(error).__name__
        ))
