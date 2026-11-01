#!/usr/bin/env python3
"""Validate the signing certificate against the profile and emit minimal entitlements.

The canary has no tunnel. Copying every entitlement from an Xcode-generated
NetworkExtension profile would grant unrelated capabilities, so this helper
emits only:
  - application-identifier (wildcard resolved to the concrete host bundle ID)
  - com.apple.developer.team-identifier
  - get-task-allow
No keychain group is included because the canary does not use Keychain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import ssl
import subprocess
import sys
from pathlib import Path


IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
CERT_BLOCK = re.compile(
    r"SHA-256 hash:\s*([0-9A-Fa-f]+)\s*\n"
    r"SHA-1 hash:\s*([0-9A-Fa-f]+)\s*\n"
    r"(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)",
    re.S,
)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def load_identities() -> list[dict[str, str]]:
    result = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"])
    if result.returncode != 0:
        fail("could not enumerate codesigning identities")
    identities = []
    for line in result.stdout.splitlines():
        match = IDENTITY_LINE.match(line)
        if match:
            identities.append({"sha1": match.group(1).upper(), "name": match.group(2)})
    return identities


def load_certificates() -> dict[str, dict[str, str]]:
    result = run(["/usr/bin/security", "find-certificate", "-Z", "-p", "-a"])
    if result.returncode != 0:
        fail("could not enumerate keychain certificates")
    certificates = {}
    for match in CERT_BLOCK.finditer(result.stdout):
        sha256 = match.group(1).upper()
        sha1 = match.group(2).upper()
        try:
            der = ssl.PEM_cert_to_DER_cert(match.group(3))
        except ValueError:
            continue
        certificates[sha1] = {
            "sha1": hashlib.sha1(der).hexdigest().upper(),
            "sha256": hashlib.sha256(der).hexdigest().upper(),
            "sourceSha256": sha256,
        }
    return certificates


def select_identity(reference: str, identities: list[dict[str, str]], certificates: dict[str, dict[str, str]]) -> dict[str, str]:
    reference_upper = reference.strip().upper()
    selected = None
    if re.fullmatch(r"[0-9A-F]{40}", reference_upper):
        matches = [item for item in identities if item["sha1"] == reference_upper]
        if len(matches) == 1:
            selected = matches[0]
    elif re.fullmatch(r"[0-9A-F]{64}", reference_upper):
        cert = next((item for item in certificates.values() if item["sha256"] == reference_upper), None)
        if cert is not None:
            matches = [item for item in identities if item["sha1"] == cert["sha1"]]
            if len(matches) == 1:
                selected = matches[0]
    else:
        exact = [item for item in identities if item["name"] == reference]
        if len(exact) == 1:
            selected = exact[0]
        elif len(exact) == 0:
            contains = [item for item in identities if reference.lower() in item["name"].lower()]
            if len(contains) == 1:
                selected = contains[0]

    if selected is None:
        fail("codesigning identity reference did not resolve to exactly one valid identity")
    cert = certificates.get(selected["sha1"])
    if cert is None:
        fail("valid identity certificate was not found in the keychain certificate list")
    if cert["sha1"] != selected["sha1"]:
        fail("keychain certificate hash does not match the selected identity")
    return {"id": selected, "cert": cert}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile-plist", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--output-entitlements", required=True)
    args = parser.parse_args()

    with open(args.profile_plist, "rb") as handle:
        profile = plistlib.load(handle)
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail("profile has no Entitlements dictionary")
    developer_certificates = profile.get("DeveloperCertificates")
    if not isinstance(developer_certificates, list) or not developer_certificates:
        fail("profile has no DeveloperCertificates")

    identities = load_identities()
    certificates = load_certificates()
    selected = select_identity(args.identity, identities, certificates)

    profile_sha1 = {
        hashlib.sha1(bytes(certificate)).hexdigest().upper()
        for certificate in developer_certificates
    }
    profile_sha256 = {
        hashlib.sha256(bytes(certificate)).hexdigest().upper()
        for certificate in developer_certificates
    }
    if selected["cert"]["sha1"] not in profile_sha1:
        fail("selected identity certificate SHA-1 is not authorized by the profile DeveloperCertificates")
    if selected["cert"]["sha256"] not in profile_sha256:
        fail("selected identity certificate SHA-256 is not authorized by the profile DeveloperCertificates")

    application_identifier = entitlements.get("application-identifier")
    if not isinstance(application_identifier, str) or "." not in application_identifier:
        fail("profile has no usable application-identifier")
    team_identifier, suffix = application_identifier.split(".", 1)
    if suffix not in (args.bundle_id, "*"):
        fail("profile application-identifier does not authorize the canary host bundle ID")
    profile_team = entitlements.get("com.apple.developer.team-identifier")
    if profile_team is not None and profile_team != team_identifier:
        fail("profile team identifier is inconsistent with application-identifier")
    if entitlements.get("get-task-allow") is not True:
        fail("profile is not a development profile with get-task-allow=true")

    wildcard = suffix == "*"
    canonical_application_identifier = f"{team_identifier}.{args.bundle_id}"
    minimal = {
        "application-identifier": canonical_application_identifier,
        "com.apple.developer.team-identifier": team_identifier,
        "get-task-allow": True,
    }
    output_path = Path(args.output_entitlements)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as handle:
        plistlib.dump(minimal, handle, fmt=plistlib.FMT_XML, sort_keys=True)

    print(json.dumps({
        "identityCertificateInProfile": True,
        "profileCertificateCount": len(developer_certificates),
        "applicationIdentifierWildcardResolved": wildcard,
        "entitlementKeys": sorted(minimal),
        "networkExtensionEntitlementsOmitted": True,
        "keychainGroupOmitted": True,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
