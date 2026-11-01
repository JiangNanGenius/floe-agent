#!/usr/bin/env python3
"""Deterministic offline checks for the Bridge package verifier."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import support  # noqa: E402
import verify_bridge as vb  # noqa: E402


class VerifyBridgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-verify-tests-")
        self.root = Path(self.temporary.name)
        self.source_root = support.write_source_root(
            self.root / "source", "1.0.0", "14", prototype=True
        )
        self.identity = support.identity_for(self.source_root)
        self.release_source = support.write_source_root(
            self.root / "release-source", "1.0.0", "14", prototype=False
        )
        self.release_identity = support.identity_for(self.release_source)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def app(self, mode: str = vb.QUALIFICATION, **kwargs) -> Path:
        source = self.source_root if mode == vb.QUALIFICATION else self.release_source
        app = support.make_app(self.root / f"app-{len(kwargs)}-{mode}", self.identity, mode, **kwargs)
        return app

    def check(self, app: Path, mode: str = vb.QUALIFICATION, probe=None, **kwargs):
        if probe is None:
            probe = support.FakeMachOProbe(kwargs.pop("overrides", None))
        source = self.source_root if mode == vb.QUALIFICATION else self.release_source
        identity = self.identity if mode == vb.QUALIFICATION else self.release_identity
        return vb.check_app(
            app,
            require_unsigned=True,
            mode=mode,
            identity=identity,
            probe=probe,
            source_root=source,
            project_yml=source / "project.yml",
        )

    def assert_ok(self, result: dict) -> None:
        self.assertTrue(result["ok"], json.dumps(result.get("failures", []), indent=2))

    def assert_fails(self, result: dict, name: str) -> None:
        self.assertIn(name, result["failures"], json.dumps(result["failures"], indent=2))

    def test_qualification_package_passes(self) -> None:
        result = self.check(self.app())
        self.assert_ok(result)
        self.assertEqual(result["identity"]["buildNumber"], "14")
        self.assertGreater(len(result["checks"]), 60)
        self.assertEqual(result["uuids"]["host"], support.DEFAULT_UUIDS["host"])

    def test_release_package_passes(self) -> None:
        app = support.make_app(self.root / "release-app", self.identity, vb.RELEASE)
        result = self.check(app, mode=vb.RELEASE)
        self.assert_ok(result)

    def test_release_rejects_prototype_flags(self) -> None:
        app = self.app(mode=vb.QUALIFICATION)
        result = self.check(app, mode=vb.RELEASE)
        self.assert_fails(result, "release-no-prototype-flags")
        self.assert_fails(result, "release-no-prototype-local-network-copy")

    def test_release_rejects_unknown_truthy_prototype_key(self) -> None:
        app = support.make_app(self.root / "unknown-prototype", self.identity, vb.RELEASE)
        plist = app / "Info.plist"
        with plist.open("rb") as handle:
            payload = plistlib.load(handle)
        payload["FloePrototypeFutureSurface"] = True
        support.write_plist(plist, payload)
        result = self.check(app, mode=vb.RELEASE)
        self.assert_fails(result, "release-no-prototype-flags")

    def test_release_rejects_legacy_file_channel_marker(self) -> None:
        app = support.make_app(self.root / "marker-app", self.identity, vb.RELEASE)
        probe = support.FakeMachOProbe({"host": {"strings": ["BridgeFileChannel", "safe"]}})
        result = self.check(app, mode=vb.RELEASE, probe=probe)
        self.assert_fails(result, "release-no-legacy-surface-markers")

    def test_release_rejects_legacy_bearer_marker_in_appex(self) -> None:
        app = support.make_app(self.root / "marker-appex", self.identity, vb.RELEASE)
        probe = support.FakeMachOProbe({"appex": {"strings": ["prototypeToken"]}})
        result = self.check(app, mode=vb.RELEASE, probe=probe)
        self.assert_fails(result, "release-no-legacy-surface-markers")

    def test_each_role_version_must_match(self) -> None:
        for role, expected in (
            ("host", "host-version"),
            ("appex", "appex-version"),
            ("test", "test-version"),
            ("core", "host-core-version"),
            ("appex-core", "appex-core-version"),
        ):
            with self.subTest(role=role):
                app = support.make_app(
                    self.root / f"wrong-{role}", self.identity, vb.QUALIFICATION,
                    versions={role: {"marketing": "0.9.0"}},
                )
                result = self.check(app)
                self.assert_fails(result, expected)

    def test_each_role_build_must_match(self) -> None:
        for role, expected in (
            ("host", "host-build"),
            ("appex", "appex-build"),
            ("test", "test-build"),
            ("core", "host-core-build"),
            ("appex-core", "appex-core-build"),
        ):
            with self.subTest(role=role):
                app = support.make_app(
                    self.root / f"wrong-build-{role}", self.identity, vb.QUALIFICATION,
                    versions={role: {"build": "99"}},
                )
                result = self.check(app)
                self.assert_fails(result, expected)

    def test_caller_supplied_wrong_version_is_rejected(self) -> None:
        with self.assertRaises(vb.IdentityError):
            vb.apply_identity_overrides(self.identity, "9.9.9", None)
        with self.assertRaises(vb.IdentityError):
            vb.apply_identity_overrides(self.identity, None, "99")

    def test_host_xctest_load_is_rejected(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({
            "host": {"loads": [
                "@rpath/BridgeCore.framework/BridgeCore",
                "@rpath/XCTest.framework/XCTest",
            ]}
        })
        result = self.check(app, probe=probe)
        self.assert_fails(result, "host-no-xctest-load")
        self.assert_fails(result, "host-load-allowlist")

    def test_unexpected_nested_framework_is_rejected(self) -> None:
        app = self.app()
        (app / "Frameworks" / "Extra.framework").mkdir()
        result = self.check(app)
        self.assert_fails(result, "host-embedded-frameworks-exact")

    def test_unexpected_nested_dylib_is_rejected(self) -> None:
        app = self.app()
        (app / "Frameworks" / "libExtra.dylib").write_bytes(b"dylib")
        result = self.check(app)
        self.assert_fails(result, "host-no-embedded-dylibs")

    def test_escaping_app_symlink_is_rejected(self) -> None:
        app = self.app()
        outside = self.root / "outside"
        outside.write_text("outside")
        os.symlink(outside, app / "escape")
        result = self.check(app)
        self.assert_fails(result, "no-escaping-symlinks")

    def test_missing_uuid_is_rejected(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({"test": {"uuid": ""}})
        result = self.check(app, probe=probe)
        self.assert_fails(result, "test-uuid")
        self.assert_fails(result, "role-uuids-distinct")

    def test_duplicate_role_uuid_is_rejected(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({"test": {"uuid": support.DEFAULT_UUIDS["host"]}})
        result = self.check(app, probe=probe)
        self.assert_fails(result, "role-uuids-distinct")

    def test_simulator_macho_platform_is_rejected(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({"host": {"platform": 7}})
        result = self.check(app, probe=probe)
        self.assert_fails(result, "host-macho-platform")

    def test_wrong_macho_filetype_is_rejected(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({"host": {"filetype": "BUNDLE"}})
        result = self.check(app, probe=probe)
        self.assert_fails(result, "host-macho-filetype")

    def test_minimum_ios_version_is_enforced(self) -> None:
        app = self.app()
        probe = support.FakeMachOProbe({"host": {"minos": "25.0"}})
        result = self.check(app, probe=probe)
        self.assert_fails(result, "host-minos-minimum")

    def test_appex_package_type_is_checked(self) -> None:
        app = self.app()
        plist = app / "PlugIns" / vb.APPEX_NAME / "Info.plist"
        with plist.open("rb") as handle:
            payload = plistlib.load(handle)
        payload["CFBundlePackageType"] = "APPL"
        support.write_plist(plist, payload)
        result = self.check(app)
        self.assert_fails(result, "appex-package-type")

    def test_ddi_artifact_is_rejected(self) -> None:
        app = self.app()
        (app / "Image.dmg").write_bytes(b"not a ddi")
        result = self.check(app)
        self.assert_fails(result, "no-bundled-ddi-or-test-frameworks")

    def test_source_bridgebuild_must_match(self) -> None:
        app = self.app()
        bridge = self.source_root / "Sources" / "BridgeCore" / "BridgeBuild.swift"
        bridge.write_text(bridge.read_text().replace('"14"', '"12"'))
        result = self.check(app)
        self.assert_fails(result, "bridgebuild-build-number")

    def test_qualification_source_must_keep_prototype_true(self) -> None:
        app = self.app()
        bridge = self.source_root / "Sources" / "BridgeCore" / "BridgeBuild.swift"
        bridge.write_text(bridge.read_text().replace("prototypeDiagnostics = true", "prototypeDiagnostics = false"))
        result = self.check(app)
        self.assert_fails(result, "bridgebuild-prototype-diagnostics")

    def test_ipa_topology_and_unsigned_boundary(self) -> None:
        app = self.app()
        ipa = support.make_ipa(self.root, app, "Bridge.ipa")
        source = self.source_root
        result = vb.check_ipa(
            ipa, require_unsigned=True, mode=vb.QUALIFICATION, identity=self.identity,
            probe=support.FakeMachOProbe(), source_root=source, project_yml=source / "project.yml",
        )
        self.assert_ok(result)
        self.assertEqual(result["ipa"], str(ipa))

    def test_ipa_with_profile_is_rejected_when_unsigned(self) -> None:
        app = self.app()
        ipa = support.make_ipa(
            self.root, app, "Bridge-profile.ipa",
            extra={"Payload/BridgeHost.app/embedded.mobileprovision": b"profile"},
        )
        source = self.source_root
        result = vb.check_ipa(
            ipa, require_unsigned=True, mode=vb.QUALIFICATION, identity=self.identity,
            probe=support.FakeMachOProbe(), source_root=source, project_yml=source / "project.yml",
        )
        self.assert_fails(result, "ipa-no-embedded-profile")

    def test_private_signed_ipa_can_be_verified(self) -> None:
        app = support.make_app(self.root / "signed-app", self.identity, vb.QUALIFICATION, signed=True)
        ipa = support.make_ipa(self.root, app, "Bridge-signed.ipa")
        source = self.source_root
        result = vb.check_ipa(
            ipa, require_unsigned=False, mode=vb.QUALIFICATION, identity=self.identity,
            probe=support.FakeMachOProbe(), source_root=source, project_yml=source / "project.yml",
        )
        self.assert_ok(result)

    def test_dsym_uuid_matching(self) -> None:
        app = self.app()
        result = self.check(app)
        dsyms = support.make_dsyms(self.root / "dsyms")
        dsym_result = vb.check_dsyms(result, dsyms, mode=vb.QUALIFICATION, probe=support.FakeMachOProbe())
        self.assert_ok(dsym_result)
        self.assertEqual(dsym_result["uuids"]["host"], support.DEFAULT_UUIDS["host"])

    def test_dsym_uuid_mismatch_is_rejected(self) -> None:
        app = self.app()
        result = self.check(app)
        dsyms = support.make_dsyms(self.root / "dsyms-mismatch")
        probe = support.FakeMachOProbe({
            "host": {"uuid": support.DEFAULT_UUIDS["appex"]},
        })
        dsym_result = vb.check_dsyms(result, dsyms, mode=vb.QUALIFICATION, probe=probe)
        # The probe remaps the binary UUID only when it is re-read; the app
        # result remains the authoritative binary UUID.  Force a bad dSYM by
        # changing the expected UUID instead.
        result["uuids"]["host"] = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        dsym_result = vb.check_dsyms(result, dsyms, mode=vb.QUALIFICATION, probe=probe)
        self.assert_fails(dsym_result, "dsym-host-uuid-matches-binary")

    def test_release_requires_complete_dsym_set(self) -> None:
        app = support.make_app(self.root / "release-dsym-app", self.identity, vb.RELEASE)
        result = self.check(app, mode=vb.RELEASE)
        dsyms = support.make_dsyms(self.root / "release-dsyms")[:1]
        dsym_result = vb.check_dsyms(result, dsyms, mode=vb.RELEASE, probe=support.FakeMachOProbe())
        self.assert_fails(dsym_result, "dsym-complete-set")

    def test_release_rejects_signing_mode_on_cli(self) -> None:
        script = Path(__file__).resolve().parents[2] / "scripts" / "verify_bridge.py"
        result = subprocess.run(
            [sys.executable, "-B", str(script), "--mode", "release", "--allow-signed",
             "--app", str(self.app())],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("qualification-only", result.stderr)

    def test_read_only_check_never_rewrites_lock(self) -> None:
        lock_dir = self.source_root / "Vendor"
        lock_dir.mkdir(exist_ok=True)
        lock = {
            "component": "idevice",
            "release": "v0.1.68",
            "commit": "d32c8189c51c2789496b0768039419c3705498c3",
            "assetSHA256": "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7",
        }
        lock_path = lock_dir / "idevice.lock.json"
        lock_path.write_text(json.dumps(lock))
        scripts = self.source_root / "scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "fetch_idevice.sh").write_text(
            'VERSION="v0.1.68"\nASSET_SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"\n'
        )
        before = hashlib.sha256(lock_path.read_bytes()).hexdigest()
        result = vb.check_project(
            self.source_root / "project.yml", self.source_root.parent, vb.QUALIFICATION,
            None, "1.0.0", "14",
        )
        self.assertTrue(result["ok"], result["failures"])
        after = hashlib.sha256(lock_path.read_bytes()).hexdigest()
        self.assertEqual(before, after)
        self.assertEqual(json.loads(lock_path.read_text()), lock)


if __name__ == "__main__":
    unittest.main(verbosity=2)
