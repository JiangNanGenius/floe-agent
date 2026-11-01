#!/usr/bin/env python3
"""Product-content private qualification mode and background policy checks."""

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
import package_bridge as pb  # noqa: E402
import prepare_signing as ps  # noqa: E402
import verify_bridge as vb  # noqa: E402

CUSTOM = vb.derive_bundle_ids("com.example.floe.bridge")
SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments], text=True, capture_output=True
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(arguments)} failed: {result.stderr}")
    return result.stdout


class ProductQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-product-")
        self.root = Path(self.temporary.name)
        self.product_source = support.write_source_root(
            self.root / "product-source", "1.0.0", "14", prototype=False
        )
        self.product_identity = support.identity_for(self.product_source)
        self.prototype_source = support.write_source_root(
            self.root / "prototype-source", "0.1.0", "13", prototype=True
        )
        self.prototype_identity = support.identity_for(self.prototype_source)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def product_app(self, name: str = "product-app", **kwargs) -> Path:
        return support.make_app(
            self.root / name,
            self.product_identity,
            vb.PRODUCT_QUALIFICATION,
            **kwargs,
        )

    def check(self, app: Path, mode: str = vb.PRODUCT_QUALIFICATION, **kwargs):
        source = kwargs.pop("source", self.product_source)
        identity = kwargs.pop("identity", self.product_identity)
        probe = kwargs.pop("probe", None) or support.FakeMachOProbe()
        return vb.check_app(
            app,
            mode=mode,
            identity=identity,
            probe=probe,
            source_root=source,
            project_yml=source / "project.yml",
            **kwargs,
        )

    def check_ipa(self, ipa: Path, mode: str = vb.PRODUCT_QUALIFICATION, **kwargs):
        source = kwargs.pop("source", self.product_source)
        identity = kwargs.pop("identity", self.product_identity)
        probe = kwargs.pop("probe", None) or support.FakeMachOProbe()
        return vb.check_ipa(
            ipa,
            mode=mode,
            identity=identity,
            probe=probe,
            source_root=source,
            project_yml=source / "project.yml",
            **kwargs,
        )

    def assert_ok(self, result: dict) -> None:
        self.assertTrue(result["ok"], json.dumps(result.get("failures", []), indent=2))

    def assert_fails(self, result: dict, name: str) -> None:
        self.assertIn(name, result["failures"], json.dumps(result["failures"], indent=2))

    def assert_named_checks_ok(self, result: dict, names: tuple[str, ...]) -> None:
        values = {item["name"]: item for item in result["checks"]}
        for name in names:
            self.assertIn(name, values)
            self.assertTrue(values[name]["ok"], values[name])

    # --- cross-mode boundary -------------------------------------------------

    def test_legacy_qualification_rejects_product_content(self) -> None:
        """The original defect is preserved as an explicit negative."""
        app = self.product_app(bundle_ids=CUSTOM)
        result = self.check(
            app,
            mode=vb.QUALIFICATION,
            require_unsigned=False,
            bundle_ids=CUSTOM,
            identity=self.product_identity,
        )
        self.assert_fails(result, "host-prototype-channels")
        self.assert_fails(result, "host-prototype-diagnostics")
        self.assert_fails(result, "bridgebuild-prototype-diagnostics")
        self.assertEqual(result["contentPolicy"], "legacy-prototype")

    def test_product_mode_rejects_prototype_app_surfaces(self) -> None:
        app = support.make_app(
            self.root / "prototype-surfaces",
            self.product_identity,
            vb.QUALIFICATION,
        )
        result = self.check(app)
        self.assert_fails(result, "release-no-prototype-flags")
        self.assert_fails(result, "release-no-prototype-local-network-copy")
        self.assert_fails(result, "product-background-continuous-absent")
        self.assert_fails(result, "product-background-modes-documented")

    def test_product_mode_rejects_prototype_compilation_source(self) -> None:
        source = support.write_source_root(
            self.root / "prototype-compilation",
            "1.0.0",
            "14",
            prototype=False,
            project_text=support.project_yml_text(
                "1.0.0", "14", prototype_compilation=True
            ),
        )
        identity = support.identity_for(source)
        app = support.make_app(
            self.root / "prototype-compilation-app",
            identity,
            vb.PRODUCT_QUALIFICATION,
        )
        result = self.check(app, source=source, identity=identity)
        self.assert_fails(result, "release-project-no-prototype-compilation")

    def test_product_mode_rejects_old_file_and_bearer_markers(self) -> None:
        app = self.product_app()
        probe = support.FakeMachOProbe({
            "host": {"strings": ["BridgeFileChannel", "controlKey"]},
            "appex": {"strings": ["prototypeToken"]},
        })
        result = self.check(app, probe=probe)
        self.assert_fails(result, "release-no-legacy-surface-markers")

    # --- positive product qualification -------------------------------------

    def test_unsigned_product_package_passes(self) -> None:
        app = self.product_app()
        result = self.check(app, require_unsigned=True)
        self.assert_ok(result)
        self.assertEqual(result["mode"], vb.PRODUCT_QUALIFICATION)
        self.assertEqual(result["contentPolicy"], "product")
        self.assertEqual(result["identity"]["marketingVersion"], "1.0.0")
        self.assertEqual(result["identity"]["buildNumber"], "14")
        self.assertEqual(result["uuids"]["host"], support.DEFAULT_UUIDS["host"])

    def test_signed_canonical_product_ipa_passes(self) -> None:
        app = self.product_app(signed=True)
        ipa = support.make_ipa(self.root, app, "FloeBridge-product-signed.ipa")
        result = self.check_ipa(ipa, require_unsigned=False)
        self.assert_ok(result)
        self.assertEqual(result["metadataMode"], "canonical")
        self.assertEqual(result["identity"]["marketingVersion"], "1.0.0")

    def test_signed_custom_id_product_ipa_full_nested_plists(self) -> None:
        app = self.product_app(name="signed-custom", signed=True, bundle_ids=CUSTOM)
        ipa = support.make_ipa(self.root, app, "FloeBridge-product-custom-signed.ipa")
        result = self.check_ipa(
            ipa, require_unsigned=False, bundle_ids=CUSTOM
        )
        self.assert_ok(result)
        self.assertEqual(result["metadataMode"], "resigned-explicit-ids")
        self.assertEqual(result["bundleIds"], CUSTOM)
        self.assertEqual(
            support.read_plist(app / "Info.plist")["CFBundleIdentifier"],
            CUSTOM["host"],
        )
        self.assertEqual(
            support.read_plist(
                app / "PlugIns" / vb.APPEX_NAME / "Info.plist"
            )["CFBundleIdentifier"],
            CUSTOM["tunnel"],
        )
        self.assertEqual(
            support.read_plist(
                app / "PlugIns" / vb.TEST_NAME / "Info.plist"
            )["CFBundleIdentifier"],
            CUSTOM["test"],
        )
        for plist in (
            app / "Frameworks" / "BridgeCore.framework" / "Info.plist",
            app / "PlugIns" / vb.APPEX_NAME / "Frameworks" / "BridgeCore.framework" / "Info.plist",
        ):
            self.assertEqual(
                support.read_plist(plist)["CFBundleIdentifier"], CUSTOM["core"]
            )
        self.assert_named_checks_ok(result, (
            "host-version",
            "appex-version",
            "test-version",
            "host-core-version",
            "appex-core-version",
            "bridgebuild-marketing-version",
            "bridgebuild-build-number",
            "bridgebuild-prototype-diagnostics",
            "host-macho-platform",
            "appex-macho-platform",
            "test-macho-platform",
            "role-uuids-distinct",
        ))
        dsyms = support.make_dsyms(self.root / "product-dsyms")
        dsym_result = vb.check_dsyms(
            result["appResult"], dsyms, mode=vb.PRODUCT_QUALIFICATION,
            probe=support.FakeMachOProbe(),
        )
        self.assert_ok(dsym_result)
        self.assertEqual(dsym_result["uuids"]["host"], support.DEFAULT_UUIDS["host"])

    def test_custom_id_rewrite_preserves_binaries_and_verifies(self) -> None:
        app = self.product_app(name="rewrite")
        binaries = [
            app / "BridgeHost",
            app / "PlugIns" / vb.APPEX_NAME / "BridgeTunnel",
            app / "PlugIns" / vb.TEST_NAME / "BridgeTests",
            app / "Frameworks" / "BridgeCore.framework" / "BridgeCore",
            app / "PlugIns" / vb.APPEX_NAME / "Frameworks" / "BridgeCore.framework" / "BridgeCore",
        ]
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries}
        report = ps.apply_bundle_ids(app, CUSTOM)
        after = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in binaries}
        self.assertEqual(before, after)
        self.assertEqual(len(report["updated"]), 5)
        result = self.check(
            app, require_unsigned=False, bundle_ids=CUSTOM
        )
        self.assert_ok(result)
        self.assertEqual(result["metadataMode"], "resigned-explicit-ids")

    # --- public release boundary --------------------------------------------

    def test_public_release_unsigned_ipa_passes(self) -> None:
        source = support.write_source_root(
            self.root / "release-source", "1.0.0", "14", prototype=False
        )
        identity = support.identity_for(source)
        app = support.make_app(self.root / "release-app", identity, vb.RELEASE)
        ipa = support.make_ipa(self.root, app, "Floe-iOS-Bridge-1.0.0-unsigned.ipa")
        result = vb.check_ipa(
            ipa, require_unsigned=True, mode=vb.RELEASE, identity=identity,
            probe=support.FakeMachOProbe(), source_root=source,
            project_yml=source / "project.yml",
        )
        self.assert_ok(result)

    def test_public_release_rejects_signed_ipa(self) -> None:
        source = support.write_source_root(
            self.root / "signed-release-source", "1.0.0", "14", prototype=False
        )
        identity = support.identity_for(source)
        app = support.make_app(
            self.root / "signed-release-app", identity, vb.RELEASE, signed=True
        )
        ipa = support.make_ipa(self.root, app, "signed-release.ipa")
        result = vb.check_ipa(
            ipa, require_unsigned=True, mode=vb.RELEASE, identity=identity,
            probe=support.FakeMachOProbe(), source_root=source,
            project_yml=source / "project.yml",
        )
        self.assert_fails(result, "ipa-no-signature-dir")
        self.assert_fails(result, "ipa-no-embedded-profile")

    def test_public_release_rejects_custom_ids(self) -> None:
        app = support.make_app(
            self.root / "release-custom", self.product_identity, vb.RELEASE,
            bundle_ids=CUSTOM,
        )
        with self.assertRaises(vb.IdentityError):
            self.check(app, mode=vb.RELEASE, require_unsigned=True, bundle_ids=CUSTOM)

    # --- background mode policy ---------------------------------------------

    def test_product_mode_accepts_no_background_modes(self) -> None:
        app = self.product_app(background_modes=[])
        result = self.check(app)
        self.assert_ok(result)
        self.assert_named_checks_ok(result, ("product-background-modes-documented",))

    def test_product_mode_accepts_documented_background_mode(self) -> None:
        app = self.product_app(background_modes=["audio", "processing"])
        result = self.check(app)
        self.assert_ok(result)

    def test_product_mode_rejects_continuous_background_mode(self) -> None:
        app = self.product_app(background_modes=["continuous"])
        result = self.check(app)
        self.assert_fails(result, "product-background-modes-documented")
        self.assert_fails(result, "product-background-continuous-absent")

    def test_release_rejects_continuous_background_mode(self) -> None:
        source = support.write_source_root(
            self.root / "continuous-release-source", "1.0.0", "14", prototype=False
        )
        identity = support.identity_for(source)
        app = support.make_app(
            self.root / "continuous-release-app", identity, vb.RELEASE,
            background_modes=["continuous"],
        )
        result = self.check(
            app, mode=vb.RELEASE, require_unsigned=True, source=source,
            identity=identity,
        )
        self.assert_fails(result, "product-background-modes-documented")
        self.assert_fails(result, "product-background-continuous-absent")

    def test_legacy_qualification_retains_continuous_assertion(self) -> None:
        app = support.make_app(
            self.root / "legacy-no-background",
            self.prototype_identity,
            vb.QUALIFICATION,
            background_modes=[],
        )
        result = self.check(
            app, mode=vb.QUALIFICATION, require_unsigned=True,
            source=self.prototype_source, identity=self.prototype_identity,
        )
        self.assert_fails(result, "host-background-continuous")

    # --- trusted mode derivation --------------------------------------------

    def test_derive_mode_from_project_source(self) -> None:
        self.assertEqual(
            vb.derive_verification_mode(self.product_source / "project.yml"),
            vb.PRODUCT_QUALIFICATION,
        )
        self.assertEqual(
            vb.derive_verification_mode(self.prototype_source / "project.yml"),
            vb.QUALIFICATION,
        )

    def test_derive_mode_prefers_committed_source_ref(self) -> None:
        repo = self.root / "derive-repo"
        project = repo / "FloeIOSBridge"
        support.write_source_root(project, "1.0.0", "14", prototype=False)
        git(repo, "init", "-q")
        git(repo, "config", "user.email", "bridge-tests@example.invalid")
        git(repo, "config", "user.name", "Bridge Tests")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "product source")
        bridge = project / "Sources" / "BridgeCore" / "BridgeBuild.swift"
        bridge.write_text(bridge.read_text().replace(
            "prototypeDiagnostics = false", "prototypeDiagnostics = true"
        ))
        self.assertEqual(
            vb.derive_verification_mode(project / "project.yml"),
            vb.QUALIFICATION,
        )
        self.assertEqual(
            vb.derive_verification_mode(project / "project.yml", repo, "HEAD"),
            vb.PRODUCT_QUALIFICATION,
        )

    def test_derive_mode_cli(self) -> None:
        script = SCRIPTS / "verify_bridge.py"
        product = subprocess.run(
            [sys.executable, "-B", str(script), "--derive-mode",
             "--project", str(self.product_source / "project.yml")],
            text=True, capture_output=True,
        )
        self.assertEqual(product.returncode, 0, product.stderr)
        self.assertEqual(product.stdout.strip(), vb.PRODUCT_QUALIFICATION)
        prototype = subprocess.run(
            [sys.executable, "-B", str(script), "--derive-mode",
             "--project", str(self.prototype_source / "project.yml")],
            text=True, capture_output=True,
        )
        self.assertEqual(prototype.returncode, 0, prototype.stderr)
        self.assertEqual(prototype.stdout.strip(), vb.QUALIFICATION)

    # --- packaging/signing helper policy ------------------------------------

    def test_product_ipa_name_policy(self) -> None:
        self.assertEqual(
            pb.resolve_ipa_name(vb.PRODUCT_QUALIFICATION, self.product_identity, None),
            "FloeBridge-product-unsigned.ipa",
        )
        self.assertEqual(
            pb.resolve_ipa_name(
                vb.PRODUCT_QUALIFICATION, self.product_identity, "candidate.ipa"
            ),
            "candidate.ipa",
        )
        self.assertEqual(
            pb.resolve_ipa_name(vb.QUALIFICATION, self.product_identity, None),
            "FloeBridge-unsigned.ipa",
        )

    def test_product_package_requires_source_ref(self) -> None:
        script = SCRIPTS / "package_bridge.py"
        result = subprocess.run(
            [sys.executable, "-B", str(script), "--check",
             "--mode", "product-qualification",
             "--project", str(self.product_source / "project.yml"),
             "--repo-root", str(self.root)],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("requires an explicit --source-ref", result.stderr)

    def test_build_script_product_mode_requires_source_ref(self) -> None:
        result = subprocess.run(
            ["bash", str(SCRIPTS / "build_bridge.sh"),
             "--mode", "product-qualification", "--check"],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("requires an explicit --source-ref", result.stderr)

    def test_sign_script_rejects_public_mode_and_public_filename(self) -> None:
        script = SCRIPTS / "sign_bridge_ipa.sh"
        release = subprocess.run(
            ["bash", str(script), "--mode", "release"],
            text=True, capture_output=True,
        )
        self.assertEqual(release.returncode, 1)
        self.assertIn("must remain unsigned", release.stderr)
        public_name = subprocess.run(
            ["bash", str(script), "--mode", "qualification",
             "--output", str(self.root / "Floe-iOS-Bridge-1.0.0-unsigned.ipa")],
            text=True, capture_output=True,
        )
        self.assertEqual(public_name.returncode, 1)
        self.assertIn("public release filename", public_name.stderr)

    def test_sign_script_derives_and_accepts_product_mode(self) -> None:
        system = subprocess.run(
            ["bash", str(SCRIPTS / "sign_bridge_ipa.sh"),
             "--project", str(self.product_source / "project.yml")],
            text=True, capture_output=True,
        )
        self.assertEqual(system.returncode, 1)
        self.assertIn(
            "derived signing mode from trusted source: product-qualification",
            system.stdout,
        )
        self.assertIn("--ipa is required", system.stderr)
        explicit = subprocess.run(
            ["bash", str(SCRIPTS / "sign_bridge_ipa.sh"),
             "--mode", "product-qualification",
             "--project", str(self.product_source / "project.yml")],
            text=True, capture_output=True,
        )
        self.assertEqual(explicit.returncode, 1)
        self.assertIn("--ipa is required", explicit.stderr)
        self.assertNotIn("source-ref", explicit.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
