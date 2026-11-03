#!/usr/bin/env python3
"""Validate host/tunnel development profiles and emit minimal entitlements.

The two bundle roles need different profiles and different minimal
entitlements. This helper never copies a broad Xcode profile entitlement set;
it requires the specific NetworkExtension capabilities the prototype uses and
then writes only those keys. It also proves that the selected signing
certificate is one of each profile's DeveloperCertificates.
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

HOST_ID = "org.floeagent.iosbridge"
TUNNEL_ID = "org.floeagent.iosbridge.tunnel"
DEFAULT_HOST_ID = HOST_ID
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")


def derive_bundle_ids(host_bundle_id: str = DEFAULT_HOST_ID) -> dict[str, str]:
    """Derive the single-app bundle IDs from one explicit host ID.

    The public/default value is the existing canonical ID, so current device
    upgrades are unchanged.  A developer self-signing a public build supplies
    one host ID; the tunnel, core and embedded test IDs are always derived.
    """
    host = (host_bundle_id or "").strip()
    if not BUNDLE_ID_RE.fullmatch(host):
        raise ValueError(
            "host bundle ID must be a reverse-DNS identifier using letters, "
            "digits and hyphens"
        )
    if host.endswith((".tunnel", ".core")):
        raise ValueError("host bundle ID must not end in .tunnel or .core")
    return {
        "host": host,
        "tunnel": host + ".tunnel",
        "core": host + ".core",
        "test": host,
    }


def canonical_bundle_ids() -> dict[str, str]:
    return derive_bundle_ids(DEFAULT_HOST_ID)

IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
CERT_BLOCK = re.compile(
    r"SHA-256 hash:\s*([0-9A-Fa-f]+)\s*\n"
    r"SHA-1 hash:\s*([0-9A-Fa-f]+)\s*\n"
    r"(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)",
    re.S,
)

HOST_REQUIRED_NE = "packet-tunnel-provider"
HOST_REQUIRED_VPN = "allow-vpn"


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


def select_identity(reference: str,
                    identities: list[dict[str, str]],
                    certificates: dict[str, dict[str, str]]) -> dict[str, str]:
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


def profile_entitlements(profile: dict) -> dict:
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail("profile has no Entitlements dictionary")
    return entitlements


def profile_certificate_hashes(profile: dict) -> tuple[set[str], set[str]]:
    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        fail("profile has no DeveloperCertificates")
    sha1 = {hashlib.sha1(bytes(item)).hexdigest().upper() for item in certificates}
    sha256 = {hashlib.sha256(bytes(item)).hexdigest().upper() for item in certificates}
    return sha1, sha256


def certificate_authorized(profile: dict, sha1: str, sha256: str) -> bool:
    authorized_sha1, authorized_sha256 = profile_certificate_hashes(profile)
    return sha1.upper() in authorized_sha1 and sha256.upper() in authorized_sha256


def validate_application_identifier(profile: dict, bundle_id: str,
                                    expected_team: str | None = None) -> str:
    entitlements = profile_entitlements(profile)
    application_identifier = entitlements.get("application-identifier")
    if not isinstance(application_identifier, str) or "." not in application_identifier:
        fail("profile has no usable application-identifier")
    team_identifier, suffix = application_identifier.split(".", 1)
    if suffix not in (bundle_id, "*"):
        fail(f"profile application-identifier {application_identifier!r} does not authorize {bundle_id!r}")
    profile_team = entitlements.get("com.apple.developer.team-identifier")
    if profile_team is not None and profile_team != team_identifier:
        fail("profile team identifier is inconsistent with application-identifier")
    if expected_team is not None and team_identifier != expected_team:
        fail("host and tunnel profiles have different teams")
    if entitlements.get("get-task-allow") is not True:
        fail("profile is not a development profile with get-task-allow=true")
    return team_identifier


def validate_capabilities(profile: dict, role: str, method: str = "validate") -> None:
    entitlements = profile_entitlements(profile)
    network_extension = entitlements.get("com.apple.developer.networking.networkextension")
    if not isinstance(network_extension, list) or HOST_REQUIRED_NE not in network_extension:
        fail(f"{role} profile does not authorize NetworkExtension {HOST_REQUIRED_NE}")

    vpn_api = entitlements.get("com.apple.developer.networking.vpn.api")
    if role == "host":
        if not isinstance(vpn_api, list) or HOST_REQUIRED_VPN not in vpn_api:
            fail(f"host profile does not authorize Personal VPN {HOST_REQUIRED_VPN}")
    else:
        # A tunnel extension may have a profile that also carries Personal VPN;
        # minimal entitlements still omit it, but a profile missing it is fine.
        if method == "verbose":
            print(json.dumps({"tunnelVpnApiPresent": isinstance(vpn_api, list)}))


def minimal_host_entitlements(team_identifier: str, bundle_id: str = HOST_ID) -> dict:
    return {
        "application-identifier": f"{team_identifier}.{bundle_id}",
        "com.apple.developer.team-identifier": team_identifier,
        "get-task-allow": True,
        "com.apple.developer.networking.vpn.api": [HOST_REQUIRED_VPN],
        "com.apple.developer.networking.networkextension": [HOST_REQUIRED_NE],
    }


def minimal_tunnel_entitlements(team_identifier: str, bundle_id: str = TUNNEL_ID) -> dict:
    return {
        "application-identifier": f"{team_identifier}.{bundle_id}",
        "com.apple.developer.team-identifier": team_identifier,
        "get-task-allow": True,
        "com.apple.developer.networking.networkextension": [HOST_REQUIRED_NE],
    }


def write_plan(host_profile: dict, tunnel_profile: dict, identity: dict,
               output_dir: Path, bundle_ids: dict[str, str] | None = None) -> dict:
    bundle_ids = bundle_ids or canonical_bundle_ids()
    host_team = validate_application_identifier(host_profile, bundle_ids["host"])
    tunnel_team = validate_application_identifier(
        tunnel_profile, bundle_ids["tunnel"], expected_team=host_team
    )
    validate_capabilities(host_profile, "host")
    validate_capabilities(tunnel_profile, "tunnel")

    if not certificate_authorized(host_profile, identity["cert"]["sha1"], identity["cert"]["sha256"]):
        fail("selected certificate is not authorized by the host profile")
    if not certificate_authorized(tunnel_profile, identity["cert"]["sha1"], identity["cert"]["sha256"]):
        fail("selected certificate is not authorized by the tunnel profile")

    host_entitlements = minimal_host_entitlements(host_team, bundle_ids["host"])
    tunnel_entitlements = minimal_tunnel_entitlements(tunnel_team, bundle_ids["tunnel"])

    output_dir.mkdir(parents=True, exist_ok=True)
    host_path = output_dir / "host-entitlements.plist"
    tunnel_path = output_dir / "tunnel-entitlements.plist"
    with host_path.open("wb") as handle:
        plistlib.dump(host_entitlements, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    with tunnel_path.open("wb") as handle:
        plistlib.dump(tunnel_entitlements, handle, fmt=plistlib.FMT_XML, sort_keys=True)

    plan = {
        "identitySHA1": identity["id"]["sha1"],
        "identityName": identity["id"]["name"],
        "identityCertificateInHostProfile": True,
        "identityCertificateInTunnelProfile": True,
        "teamIdentifier": host_team,
        "hostBundleIdentifier": bundle_ids["host"],
        "tunnelBundleIdentifier": bundle_ids["tunnel"],
        "coreBundleIdentifier": bundle_ids["core"],
        "testBundleIdentifier": bundle_ids["test"],
        "hostEntitlementKeys": sorted(host_entitlements),
        "tunnelEntitlementKeys": sorted(tunnel_entitlements),
        "hostProfileCapabilities": {
            "networkExtension": [HOST_REQUIRED_NE],
            "vpnAPI": [HOST_REQUIRED_VPN],
        },
        "tunnelProfileCapabilities": {"networkExtension": [HOST_REQUIRED_NE]},
        "hostEntitlements": str(host_path),
        "tunnelEntitlements": str(tunnel_path),
        "minimalOnly": True,
        "bundleIDSource": "explicit-host-id" if bundle_ids["host"] != DEFAULT_HOST_ID else "canonical-default",
    }
    (output_dir / "signing-plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    (output_dir / "bundle-ids.json").write_text(json.dumps(bundle_ids, indent=2, sort_keys=True) + "\n")
    return plan


def apply_bundle_ids(app: Path, bundle_ids: dict[str, str]) -> dict:
    """Rewrite all Bridge bundle identifiers before private signing.

    This changes only Info.plist metadata.  Executable bytes and source
    constants are untouched.  Every nested bundle with a CFBundleIdentifier
    must resolve to the explicit expected set; an unmodified old/canonical
    Core or an unknown nested bundle fails the whole operation before any
    plist is written.
    """
    app = Path(app)
    if not app.is_dir():
        raise ValueError(f"app bundle not found: {app}")
    known = [
        (app / "Info.plist", "host", bundle_ids["host"]),
        (app / "PlugIns" / "BridgeTunnel.appex" / "Info.plist", "appex", bundle_ids["tunnel"]),
        (
            app / "PlugIns" / "BridgeTunnel.appex" / "Frameworks" / "BridgeCore.framework"
            / "Info.plist",
            "appex-core",
            bundle_ids["core"],
        ),
        (
            app / "Frameworks" / "BridgeCore.framework" / "Info.plist",
            "host-core",
            bundle_ids["core"],
        ),
        (app / "PlugIns" / "BridgeTests.xctest" / "Info.plist", "test", bundle_ids["test"]),
    ]
    missing = [str(path.relative_to(app)) for path, _, _ in known if not path.is_file()]
    if missing:
        raise ValueError("missing expected bundle Info.plist: " + json.dumps(missing))

    expected = set(bundle_ids.values())
    known_by_path = {path.resolve(): (role, expected_id) for path, role, expected_id in known}
    nested = []
    for path in app.rglob("Info.plist"):
        if not path.is_file():
            continue
        try:
            payload = plistlib.loads(path.read_bytes())
        except (OSError, plistlib.InvalidFileException):
            raise ValueError(f"could not read plist: {path.relative_to(app)}")
        if "CFBundleIdentifier" not in payload:
            continue
        identifier = payload.get("CFBundleIdentifier")
        if path.resolve() in known_by_path:
            continue
        if not isinstance(identifier, str) or identifier not in expected:
            nested.append({
                "path": str(path.relative_to(app)),
                "bundleIdentifier": identifier,
                "expected": sorted(expected),
            })
    if nested:
        raise ValueError(
            "nested bundle identifier was not rewritten or is not expected: "
            + json.dumps(nested, sort_keys=True)
        )

    updated = []
    unchanged = []
    for path, role, expected_id in known:
        raw = path.read_bytes()
        fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
        payload = plistlib.loads(raw)
        current = payload.get("CFBundleIdentifier")
        if current == expected_id:
            unchanged.append({"role": role, "path": str(path.relative_to(app))})
            continue
        payload["CFBundleIdentifier"] = expected_id
        path.write_bytes(plistlib.dumps(payload, fmt=fmt, sort_keys=False))
        updated.append({
            "role": role,
            "path": str(path.relative_to(app)),
            "from": current,
            "to": expected_id,
        })
    return {
        "bundleIds": bundle_ids,
        "updated": updated,
        "unchanged": unchanged,
        "nestedChecked": len(list(app.rglob("Info.plist"))),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-profile-plist")
    parser.add_argument("--tunnel-profile-plist")
    parser.add_argument("--identity")
    parser.add_argument("--output-dir")
    parser.add_argument("--bundle-id", default=DEFAULT_HOST_ID)
    parser.add_argument("--derive-only", action="store_true",
                        help="print the derived host/tunnel/core/test IDs and exit")
    parser.add_argument("--apply-bundle-ids", action="store_true",
                        help="rewrite all Info.plist bundle IDs in an extracted app")
    parser.add_argument("--app")
    args = parser.parse_args()

    try:
        bundle_ids = derive_bundle_ids(args.bundle_id)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.derive_only:
        print(json.dumps(bundle_ids, indent=2, sort_keys=True))
        return 0

    if args.apply_bundle_ids:
        if not args.app:
            parser.error("--apply-bundle-ids requires --app")
        try:
            report = apply_bundle_ids(Path(args.app), bundle_ids)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    if not args.host_profile_plist or not args.tunnel_profile_plist or not args.identity or not args.output_dir:
        parser.error("--host-profile-plist, --tunnel-profile-plist, --identity and --output-dir are required")

    with open(args.host_profile_plist, "rb") as handle:
        host_profile = plistlib.load(handle)
    with open(args.tunnel_profile_plist, "rb") as handle:
        tunnel_profile = plistlib.load(handle)

    identities = load_identities()
    certificates = load_certificates()
    identity = select_identity(args.identity, identities, certificates)
    plan = write_plan(host_profile, tunnel_profile, identity, Path(args.output_dir), bundle_ids)
    print(json.dumps(plan, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
