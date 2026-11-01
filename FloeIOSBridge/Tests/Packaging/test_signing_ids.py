#!/usr/bin/env python3
"""Private re-signing bundle-ID validation and nested plist rewrite tests."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import support  # noqa: E402
import prepare_signing as ps  # noqa: E402
import verify_bridge as vb  # noqa: E402

FAKE_CERT = b"bundle-id-test-certificate"
FAKE_SHA1 = hashlib.sha1(FAKE_CERT).hexdigest().upper()
FAKE_SHA256 = hashlib.sha256(FAKE_CERT).hexdigest().upper()
TEAM = "TEAM123456"
CUSTOM_HOST = "com.example.floe.bridge"
CUSTOM_IDS = {
    "host": CUSTOM_HOST,
    "tunnel": CUSTOM_HOST + ".tunnel",
    "core": CUSTOM_HOST + ".core",
    "test": CUSTOM_HOST,
}


def profile(bundle_id: str, team: str = TEAM) -> dict:
    return {
        "Entitlements": {
            "application-identifier": f"{team}.{bundle_id}",
            "com.apple.developer.team-identifier": team,
            "get-task-allow": True,
            "com.apple.developer.networking.vpn.api": ["allow-vpn"],
            "com.apple.developer.networking.networkextension": ["packet-tunnel-provider"],
        },
        "DeveloperCertificates": [FAKE_CERT],
    }


def identity() -> dict:
    return {
        "id": {"sha1": FAKE_SHA1, "name": "Fake Development"},
        "cert": {"sha1": FAKE_SHA1, "sha256": FAKE_SHA256},
    }


class SigningIdentifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-sign-ids-")
        self.root = Path(self.temporary.name)
        self.source_root = support.write_source_root(
            self.root / "source", "1.0.0", "14", prototype=True
        )
        self.identity = support.identity_for(self.source_root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_derive_custom_bundle_ids(self) -> None:
        self.assertEqual(ps.derive_bundle_ids(CUSTOM_HOST), CUSTOM_IDS)
        self.assertEqual(vb.derive_bundle_ids(CUSTOM_HOST), CUSTOM_IDS)
        self.assertEqual(ps.derive_bundle_ids(), ps.canonical_bundle_ids())
        self.assertEqual(ps.canonical_bundle_ids()["host"], vb.HOST_ID)

    def test_invalid_host_bundle_ids_are_rejected(self) -> None:
        for value in (
            "", "com", "com..example", "com.example.tunnel", "com.example.core",
            "com.example bridge", "com.example_bridge", "-com.example", "com.example.",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    ps.derive_bundle_ids(value)
                with self.assertRaises(vb.IdentityError):
                    vb.derive_bundle_ids(value)

    def test_custom_profiles_match_derived_ids(self) -> None:
        host_profile = profile(CUSTOM_IDS["host"])
        tunnel_profile = profile(CUSTOM_IDS["tunnel"])
        self.assertEqual(
            ps.validate_application_identifier(host_profile, CUSTOM_IDS["host"]), TEAM
        )
        self.assertEqual(
            ps.validate_application_identifier(
                tunnel_profile, CUSTOM_IDS["tunnel"], expected_team=TEAM
            ),
            TEAM,
        )

    def test_profile_with_canonical_id_rejects_custom_host(self) -> None:
        with self.assertRaises(SystemExit):
            ps.validate_application_identifier(profile(ps.HOST_ID), CUSTOM_IDS["host"])

    def test_wrong_suffix_profile_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            ps.validate_application_identifier(
                profile(CUSTOM_IDS["host"]), CUSTOM_IDS["tunnel"]
            )
        with self.assertRaises(SystemExit):
            ps.validate_application_identifier(
                profile(CUSTOM_IDS["core"]), CUSTOM_IDS["tunnel"], expected_team=TEAM
            )

    def test_cross_team_custom_profiles_are_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            ps.validate_application_identifier(
                profile(CUSTOM_IDS["tunnel"], "OTHERTEAM"),
                CUSTOM_IDS["tunnel"],
                expected_team=TEAM,
            )

    def test_write_plan_emits_custom_ids_and_minimal_entitlements(self) -> None:
        output = self.root / "plan"
        plan = ps.write_plan(
            profile(CUSTOM_IDS["host"]),
            profile(CUSTOM_IDS["tunnel"]),
            identity(),
            output,
            CUSTOM_IDS,
        )
        self.assertEqual(plan["hostBundleIdentifier"], CUSTOM_IDS["host"])
        self.assertEqual(plan["tunnelBundleIdentifier"], CUSTOM_IDS["tunnel"])
        self.assertEqual(plan["coreBundleIdentifier"], CUSTOM_IDS["core"])
        self.assertEqual(plan["testBundleIdentifier"], CUSTOM_IDS["test"])
        host_entitlements = support.read_plist(output / "host-entitlements.plist")
        tunnel_entitlements = support.read_plist(output / "tunnel-entitlements.plist")
        self.assertEqual(
            host_entitlements["application-identifier"], f"{TEAM}.{CUSTOM_IDS['host']}"
        )
        self.assertEqual(
            tunnel_entitlements["application-identifier"], f"{TEAM}.{CUSTOM_IDS['tunnel']}"
        )
        self.assertEqual(json.loads((output / "bundle-ids.json").read_text()), CUSTOM_IDS)

    def test_apply_bundle_ids_updates_all_nested_plists_without_binary_changes(self) -> None:
        app = support.make_app(self.root / "custom-app", self.identity, bundle_ids=vb.canonical_bundle_ids())
        binaries = [
            app / "BridgeHost",
            app / "PlugIns/BridgeTunnel.appex/BridgeTunnel",
            app / "PlugIns/BridgeTests.xctest/BridgeTests",
            app / "Frameworks/BridgeCore.framework/BridgeCore",
            app / "PlugIns/BridgeTunnel.appex/Frameworks/BridgeCore.framework/BridgeCore",
        ]
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries}
        report = ps.apply_bundle_ids(app, CUSTOM_IDS)
        after = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries}
        self.assertEqual(before, after)
        self.assertEqual(len(report["updated"]), 5)
        self.assertEqual(report["unchanged"], [])
        self.assertEqual(
            support.read_plist(app / "Info.plist")["CFBundleIdentifier"],
            CUSTOM_IDS["host"],
        )
        self.assertEqual(
            support.read_plist(
                app / "PlugIns/BridgeTunnel.appex/Info.plist"
            )["CFBundleIdentifier"],
            CUSTOM_IDS["tunnel"],
        )
        self.assertEqual(
            support.read_plist(
                app / "Frameworks/BridgeCore.framework/Info.plist"
            )["CFBundleIdentifier"],
            CUSTOM_IDS["core"],
        )
        self.assertEqual(
            support.read_plist(
                app / "PlugIns/BridgeTunnel.appex/Frameworks/BridgeCore.framework/Info.plist"
            )["CFBundleIdentifier"],
            CUSTOM_IDS["core"],
        )
        self.assertEqual(
            support.read_plist(app / "PlugIns/BridgeTests.xctest/Info.plist")["CFBundleIdentifier"],
            CUSTOM_IDS["test"],
        )

    def test_apply_bundle_ids_canonical_is_idempotent(self) -> None:
        app = support.make_app(self.root / "canonical-app", self.identity)
        report = ps.apply_bundle_ids(app, vb.canonical_bundle_ids())
        self.assertEqual(report["updated"], [])
        self.assertEqual(len(report["unchanged"]), 5)

    def test_missing_nested_core_plist_fails_before_any_write(self) -> None:
        app = support.make_app(self.root / "missing-core", self.identity)
        (app / "PlugIns/BridgeTunnel.appex/Frameworks/BridgeCore.framework/Info.plist").unlink()
        before = support.read_plist(app / "Info.plist")["CFBundleIdentifier"]
        with self.assertRaises(ValueError):
            ps.apply_bundle_ids(app, CUSTOM_IDS)
        after = support.read_plist(app / "Info.plist")["CFBundleIdentifier"]
        self.assertEqual(before, after)

    def test_foreign_nested_bundle_fails_before_any_write(self) -> None:
        app = support.make_app(self.root / "foreign-nested", self.identity)
        extra = app / "Frameworks/Extra.framework/Info.plist"
        support.write_plist(extra, {"CFBundleIdentifier": vb.HOST_ID})
        before = support.read_plist(app / "Info.plist")["CFBundleIdentifier"]
        with self.assertRaises(ValueError):
            ps.apply_bundle_ids(app, CUSTOM_IDS)
        after = support.read_plist(app / "Info.plist")["CFBundleIdentifier"]
        self.assertEqual(before, after)

    def test_apply_bundle_ids_cli(self) -> None:
        app = support.make_app(self.root / "cli-apply", self.identity)
        script = Path(__file__).resolve().parents[2] / "scripts" / "prepare_signing.py"
        result = subprocess.run(
            [sys.executable, "-B", str(script), "--apply-bundle-ids",
             "--app", str(app), "--bundle-id", CUSTOM_HOST],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["bundleIds"], CUSTOM_IDS)
        self.assertEqual(
            support.read_plist(app / "Info.plist")["CFBundleIdentifier"], CUSTOM_HOST
        )

        bad = subprocess.run(
            [sys.executable, "-B", str(script), "--apply-bundle-ids",
             "--app", str(app), "--bundle-id", "not-a-bundle-id"],
            text=True, capture_output=True,
        )
        self.assertEqual(bad.returncode, 2)
        self.assertIn("reverse-DNS", bad.stderr)

    def test_signed_private_verifier_accepts_explicit_custom_ids(self) -> None:
        app = support.make_app(
            self.root / "signed-custom", self.identity,
            signed=True, bundle_ids=CUSTOM_IDS,
        )
        result = vb.check_app(
            app,
            require_unsigned=False,
            mode=vb.QUALIFICATION,
            identity=self.identity,
            bundle_ids=CUSTOM_IDS,
            probe=support.FakeMachOProbe(),
            source_root=self.source_root,
            project_yml=self.source_root / "project.yml",
        )
        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["bundleIds"], CUSTOM_IDS)
        self.assertEqual(result["metadataMode"], "resigned-explicit-ids")
        self.assertNotIn("host-bundle-id", result["failures"])

    def test_signed_custom_id_ipa_is_verified(self) -> None:
        app = support.make_app(
            self.root / "signed-custom-ipa", self.identity,
            signed=True, bundle_ids=CUSTOM_IDS,
        )
        ipa = support.make_ipa(self.root, app, "FloeBridge-custom-signed.ipa")
        result = vb.check_ipa(
            ipa,
            require_unsigned=False,
            mode=vb.QUALIFICATION,
            identity=self.identity,
            bundle_ids=CUSTOM_IDS,
            probe=support.FakeMachOProbe(),
            source_root=self.source_root,
            project_yml=self.source_root / "project.yml",
        )
        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["bundleIds"], CUSTOM_IDS)

    def test_public_release_rejects_custom_bundle_ids(self) -> None:
        release_source = support.write_source_root(
            self.root / "release-source", "1.0.0", "14", prototype=False
        )
        identity = support.identity_for(release_source)
        app = support.make_app(
            self.root / "release-custom", identity, vb.RELEASE, bundle_ids=CUSTOM_IDS
        )
        with self.assertRaises(vb.IdentityError):
            vb.check_app(
                app,
                require_unsigned=True,
                mode=vb.RELEASE,
                identity=identity,
                bundle_ids=CUSTOM_IDS,
                probe=support.FakeMachOProbe(),
                source_root=release_source,
                project_yml=release_source / "project.yml",
            )

    def test_cli_requires_allow_signed_for_explicit_ids(self) -> None:
        script = Path(__file__).resolve().parents[2] / "scripts" / "verify_bridge.py"
        app = support.make_app(self.root / "cli-app", self.identity)
        result = subprocess.run(
            [sys.executable, "-B", str(script), "--mode", "qualification",
             "--bundle-id", CUSTOM_HOST, "--app", str(app)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("--allow-signed", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
