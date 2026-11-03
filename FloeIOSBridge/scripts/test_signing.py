#!/usr/bin/env python3
"""Deterministic checks for the pure profile/entitlement validation logic."""

from __future__ import annotations

import hashlib
import plistlib
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_signing as ps  # noqa: E402


checks = 0
failures = 0


def expect(condition: bool, name: str, detail: str = "") -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name} {detail}")


def expect_exit(name: str, function) -> None:
    global checks, failures
    checks += 1
    try:
        function()
    except SystemExit:
        print(f"PASS {name}")
        return
    failures += 1
    print(f"FAIL {name} (expected SystemExit)")


FAKE_CERT = b"unit-test-certificate"
FAKE_SHA1 = hashlib.sha1(FAKE_CERT).hexdigest().upper()
FAKE_SHA256 = hashlib.sha256(FAKE_CERT).hexdigest().upper()
TEAM = "TEAM123456"


def host_profile() -> dict:
    return {
        "Entitlements": {
            "application-identifier": f"{TEAM}.org.floeagent.iosbridge",
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": True,
            "com.apple.developer.networking.vpn.api": ["allow-vpn"],
            "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
        },
        "DeveloperCertificates": [FAKE_CERT],
    }


def tunnel_profile() -> dict:
    return {
        "Entitlements": {
            "application-identifier": f"{TEAM}.org.floeagent.iosbridge.tunnel",
            "com.apple.developer.team-identifier": TEAM,
            "get-task-allow": True,
            "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
        },
        "DeveloperCertificates": [FAKE_CERT],
    }


expect(ps.validate_application_identifier(host_profile(), ps.HOST_ID) == TEAM, "host app id/team")
expect(ps.validate_application_identifier(tunnel_profile(), ps.TUNNEL_ID, TEAM) == TEAM, "tunnel app id/team")
ps.validate_capabilities(host_profile(), "host")
print("PASS host capabilities")
ps.validate_capabilities(tunnel_profile(), "tunnel")
print("PASS tunnel capabilities")
expect(ps.certificate_authorized(host_profile(), FAKE_SHA1, FAKE_SHA256), "host cert authorized")
expect(not ps.certificate_authorized(host_profile(), "0" * 40, "0" * 64), "unknown cert rejected")

host_entitlements = ps.minimal_host_entitlements(TEAM)
tunnel_entitlements = ps.minimal_tunnel_entitlements(TEAM)
expect(
    set(host_entitlements) == {
        "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
        "com.apple.developer.networking.vpn.api", "com.apple.developer.networking.networkextension",
    },
    "host entitlement keys minimal",
)
expect(
    set(tunnel_entitlements) == {
        "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
        "com.apple.developer.networking.networkextension",
    },
    "tunnel entitlement keys minimal",
)
expect(host_entitlements["com.apple.developer.networking.vpn.api"] == ["allow-vpn"], "host vpn value")
expect(
    host_entitlements["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"],
    "host NE value",
)
expect(
    tunnel_entitlements["com.apple.developer.networking.networkextension"] == ["packet-tunnel-provider"],
    "tunnel NE value",
)
expect("com.apple.developer.networking.vpn.api" not in tunnel_entitlements, "tunnel omits vpn.api")

wrong_bundle = host_profile()
wrong_bundle["Entitlements"]["application-identifier"] = f"{TEAM}.org.example.other"
expect_exit("wrong host bundle rejected",
             lambda: ps.validate_application_identifier(wrong_bundle, ps.HOST_ID))

no_vpn = host_profile()
no_vpn["Entitlements"].pop("com.apple.developer.networking.vpn.api")
expect_exit("host without vpn capability rejected", lambda: ps.validate_capabilities(no_vpn, "host"))

no_ne = tunnel_profile()
no_ne["Entitlements"]["com.apple.developer.networking.networkextension"] = ["app-proxy-provider"]
expect_exit("tunnel without packet capability rejected", lambda: ps.validate_capabilities(no_ne, "tunnel"))

no_task_allow = tunnel_profile()
no_task_allow["Entitlements"]["get-task-allow"] = False
expect_exit("non-development tunnel profile rejected",
             lambda: ps.validate_application_identifier(no_task_allow, ps.TUNNEL_ID, TEAM))

other_team = tunnel_profile()
other_team["Entitlements"]["application-identifier"] = "OTHERTEAM.org.floeagent.iosbridge.tunnel"
other_team["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM"
expect_exit("cross-team tunnel rejected",
             lambda: ps.validate_application_identifier(other_team, ps.TUNNEL_ID, TEAM))

with tempfile.TemporaryDirectory() as temporary:
    identity = {
        "id": {"sha1": FAKE_SHA1, "name": "Fake Development"},
        "cert": {"sha1": FAKE_SHA1, "sha256": FAKE_SHA256},
    }
    output = Path(temporary)
    plan = ps.write_plan(host_profile(), tunnel_profile(), identity, output)
    expect(plan["identityCertificateInHostProfile"], "plan host cert")
    expect(plan["identityCertificateInTunnelProfile"], "plan tunnel cert")
    host_out = plistlib.load((output / "host-entitlements.plist").open("rb"))
    tunnel_out = plistlib.load((output / "tunnel-entitlements.plist").open("rb"))
    expect(host_out == host_entitlements, "written host entitlements")
    expect(tunnel_out == tunnel_entitlements, "written tunnel entitlements")
    expect((output / "signing-plan.json").is_file(), "signing plan written")

print(f"SIGNING LOGIC {'PASS' if failures == 0 else 'FAIL'} checks={checks} failures={failures}")
sys.exit(0 if failures == 0 else 1)
