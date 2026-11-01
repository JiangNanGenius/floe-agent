#!/usr/bin/env python3
"""Provenance and public-summary checks for Bridge packaging."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import support  # noqa: E402
import package_bridge as pb  # noqa: E402
import verify_bridge as vb  # noqa: E402


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        text=True, capture_output=True,
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(arguments)} failed: {result.stderr}")
    return result.stdout


def init_repo(root: Path, with_project: bool = True) -> tuple[Path, Path]:
    repo = root / "repo"
    repo.mkdir(parents=True)
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "bridge-tests@example.invalid")
    git(repo, "config", "user.name", "Bridge Tests")
    project = repo / "FloeIOSBridge"
    if with_project:
        support.write_source_root(project, "1.0.0", "14", prototype=False)
        (project / "Sources" / "BridgeHost").mkdir(parents=True, exist_ok=True)
        (project / "Sources" / "BridgeHost" / "Host.swift").write_text("// host\n")
        (project / "NOTES.md").write_text("bridge source\n")
    (repo / "README.md").write_text("root repository\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "fixture")
    return repo, project


class ProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-provenance-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_clean_source_tree_binds_to_ref(self) -> None:
        repo, project = init_repo(self.root)
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertTrue(provenance["ok"], provenance["strictDeviations"])
        self.assertEqual(provenance["sourceFileCount"], 7)
        self.assertTrue(all(item["path"].startswith("FloeIOSBridge/") for item in provenance["files"]))
        self.assertRegex(provenance["sourceTreeSHA256"], r"^[0-9a-f]{64}$")
        self.assertEqual(provenance["sourceRef"], git(repo, "rev-parse", "HEAD").strip())

    def test_modified_tracked_file_is_rejected(self) -> None:
        repo, project = init_repo(self.root)
        (project / "NOTES.md").write_text("changed\n")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertFalse(provenance["ok"])
        self.assertIn("modified", {item["kind"] for item in provenance["strictDeviations"]})

    def test_untracked_file_is_rejected(self) -> None:
        repo, project = init_repo(self.root)
        (project / "EXTRA.md").write_text("extra\n")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertFalse(provenance["ok"])
        self.assertIn("untracked", {item["kind"] for item in provenance["strictDeviations"]})

    def test_missing_tracked_file_is_rejected(self) -> None:
        repo, project = init_repo(self.root)
        (project / "NOTES.md").unlink()
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertFalse(provenance["ok"])
        self.assertIn("missing", {item["kind"] for item in provenance["strictDeviations"]})

    def test_escaping_tracked_symlink_is_rejected(self) -> None:
        repo, project = init_repo(self.root)
        os.symlink("../../outside.txt", project / "escape.txt")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "escaping symlink")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertFalse(provenance["ok"])
        kinds = {item["kind"] for item in provenance["strictDeviations"]}
        self.assertIn("escaping-symlink", kinds)

    def test_contained_symlink_is_accepted(self) -> None:
        repo, project = init_repo(self.root)
        os.symlink("NOTES.md", project / "link.md")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "contained symlink")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertTrue(provenance["ok"], provenance["strictDeviations"])
        kinds = {item["kind"] for item in provenance["files"]}
        self.assertIn("symlink", kinds)

    def test_root_dirty_changes_outside_source_are_ignored(self) -> None:
        repo, project = init_repo(self.root)
        (repo / "README.md").write_text("dirty outside source\n")
        (repo / "outside.txt").write_text("untracked outside source\n")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertTrue(provenance["ok"], provenance["strictDeviations"])
        self.assertTrue(all(item["path"].startswith("FloeIOSBridge/") for item in provenance["files"]))
        self.assertNotIn("outside.txt", json.dumps(provenance["files"]))

    def test_unexpected_ignored_file_is_rejected_in_release(self) -> None:
        repo, project = init_repo(self.root)
        (project / ".gitignore").write_text("ignored.txt\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "ignore file")
        (project / "ignored.txt").write_text("ignored but unexpected\n")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertFalse(provenance["ok"])
        self.assertIn("ignored-unexpected", {item["kind"] for item in provenance["strictDeviations"]})

    def test_known_generated_idevice_symlink_is_allowed(self) -> None:
        repo, project = init_repo(self.root)
        (project / ".gitignore").write_text("/Frameworks/IDevice.xcframework\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "ignore generated framework")
        (project / "Frameworks").mkdir()
        os.symlink("../../outside-cache/IDevice.xcframework", project / "Frameworks/IDevice.xcframework")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertTrue(provenance["ok"], provenance["strictDeviations"])
        self.assertIn(
            "FloeIOSBridge/Frameworks/IDevice.xcframework",
            provenance["ignoredPaths"],
        )

    def test_qualification_records_but_allows_dirty_source(self) -> None:
        repo, project = init_repo(self.root)
        (project / "NOTES.md").write_text("dirty private candidate\n")
        provenance = pb.compute_provenance(repo, project, vb.QUALIFICATION, "HEAD")
        self.assertTrue(provenance["ok"])
        self.assertIn("modified", {item["kind"] for item in provenance["strictDeviations"]})

    def test_source_tree_hash_changes_with_content(self) -> None:
        repo, project = init_repo(self.root)
        before = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        (project / "NOTES.md").write_text("changed\n")
        after = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertNotEqual(before["sourceTreeSHA256"], after["sourceTreeSHA256"])

    def test_no_head_fallback_when_project_is_untracked(self) -> None:
        repo, project = init_repo(self.root, with_project=False)
        support.write_source_root(project, "1.0.0", "14", prototype=False)
        with self.assertRaises(RuntimeError):
            pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        with self.assertRaises(vb.IdentityError):
            vb.load_identity_for_source(project / "project.yml", repo, "HEAD")

    def test_explicit_ref_identity_does_not_use_worktree(self) -> None:
        repo, project = init_repo(self.root)
        (project / "project.yml").write_text(
            support.project_yml_text("2.0.0", "20", prototype_compilation=False)
        )
        worktree_identity = vb.load_project_identity(project / "project.yml")
        self.assertEqual(worktree_identity.marketing_version, "2.0.0")
        ref_identity, commit = vb.load_identity_for_source(project / "project.yml", repo, "HEAD")
        self.assertEqual(ref_identity.marketing_version, "1.0.0")
        self.assertEqual(ref_identity.build_number, "14")
        self.assertEqual(commit, git(repo, "rev-parse", "HEAD").strip())
        vb.apply_identity_overrides(ref_identity, "1.0.0", "14")
        with self.assertRaises(vb.IdentityError):
            vb.apply_identity_overrides(ref_identity, "2.0.0", "20")

    def test_release_requires_source_ref(self) -> None:
        repo, project = init_repo(self.root)
        with self.assertRaises(vb.IdentityError):
            vb.resolve_ref(repo, "-bad-ref")

    def test_public_summary_safety(self) -> None:
        safe = {
            "schema": pb.PUBLIC_SCHEMA,
            "mode": vb.RELEASE,
            "marketingVersion": "1.0.0",
            "buildNumber": "14",
            "bundleIdentifier": vb.HOST_ID,
            "sourceRef": "a" * 40,
            "sourceTreeSHA256": "b" * 64,
            "sourceFileCount": 135,
            "artifact": {"filename": "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
                         "sha256": "c" * 64, "bytes": 1},
        }
        self.assertEqual(pb.public_summary_failures(safe), [])
        unsafe_path = dict(safe)
        unsafe_path["artifact"] = {"filename": "/Users/example/Floe.ipa", "sha256": "c" * 64, "bytes": 1}
        self.assertTrue(pb.public_summary_failures(unsafe_path))
        unsafe_key = dict(safe)
        unsafe_key["buildCommand"] = "xcodebuild"
        self.assertTrue(pb.public_summary_failures(unsafe_key))
        unsafe_udid = dict(safe)
        unsafe_udid["device"] = "UDID 00008110-000000000000001E"
        self.assertTrue(pb.public_summary_failures(unsafe_udid))
        unsafe_profile = dict(safe)
        unsafe_profile["notes"] = "embedded.mobileprovision"
        self.assertTrue(pb.public_summary_failures(unsafe_profile))

    def test_canonical_name(self) -> None:
        self.assertEqual(
            pb.canonical_ipa_name("1.0.0"),
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
        )
        with self.assertRaises(ValueError):
            pb.validate_ipa_name("../Floe.ipa")
        with self.assertRaises(ValueError):
            pb.validate_ipa_name("Floe.exe")

    def test_resolve_ipa_name_modes(self) -> None:
        identity = vb.BuildIdentity(
            "1.0.0", "14", "fixture",
            {role: {"marketingVersion": "1.0.0", "buildNumber": "14"}
             for role in ("host", "appex", "core", "test")},
        )
        self.assertEqual(
            pb.resolve_ipa_name(vb.RELEASE, identity, None),
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
        )
        self.assertEqual(
            pb.resolve_ipa_name(vb.RELEASE, identity, "Floe-iOS-Bridge-1.0.0-unsigned.ipa"),
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
        )
        with self.assertRaises(ValueError):
            pb.resolve_ipa_name(vb.RELEASE, identity, "FloeBridge-unsigned.ipa")
        self.assertEqual(
            pb.resolve_ipa_name(vb.QUALIFICATION, identity, None),
            "FloeBridge-unsigned.ipa",
        )
        self.assertEqual(
            pb.resolve_ipa_name(vb.QUALIFICATION, identity, "candidate.ipa"),
            "candidate.ipa",
        )

    def _write_pins(self, project: Path) -> None:
        lock = project / "Vendor" / "idevice.lock.json"
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(json.dumps({
            "component": "idevice",
            "release": "v0.1.68",
            "commit": "d32c8189c51c2789496b0768039419c3705498c3",
            "assetSHA256": "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7",
        }))
        script = project / "scripts" / "fetch_idevice.sh"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(
            'VERSION="v0.1.68"\n'
            'ASSET_SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"\n'
        )

    def _preflight(self, repo: Path, project: Path, mode: str = "release",
                   source_ref: str | None = "HEAD"):
        script = Path(__file__).resolve().parents[2] / "scripts" / "package_bridge.py"
        arguments = [
            sys.executable, "-B", str(script), "--check", "--mode", mode,
            "--repo-root", str(repo), "--project", str(project / "project.yml"),
        ]
        if source_ref is not None:
            arguments += ["--source-ref", source_ref]
        return subprocess.run(arguments, text=True, capture_output=True)

    def _release_preflight(self, repo: Path, project: Path):
        return self._preflight(repo, project, "release", "HEAD")

    def test_release_preflight_accepts_clean_1_0_source(self) -> None:
        repo, project = init_repo(self.root)
        (project / "project.yml").write_text(
            support.project_yml_text("1.0.0", "14", prototype_compilation=False)
        )
        bridge = project / "Sources" / "BridgeCore" / "BridgeBuild.swift"
        bridge.write_text(
            'public enum BridgeBuild {\n'
            '    public static let marketingVersion = "1.0.0"\n'
            '    public static let buildNumber = "14"\n'
            '    public static let prototypeDiagnostics = false\n'
            '}\n'
        )
        self._write_pins(project)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "release-shaped source")
        result = self._release_preflight(repo, project)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"], payload["failures"])
        self.assertEqual(payload["identity"]["marketingVersion"], "1.0.0")
        self.assertEqual(payload["sourceFileCount"], 9)

    def test_release_preflight_rejects_dirty_source(self) -> None:
        repo, project = init_repo(self.root)
        (project / "project.yml").write_text(
            support.project_yml_text("1.0.0", "14", prototype_compilation=False)
        )
        bridge = project / "Sources" / "BridgeCore" / "BridgeBuild.swift"
        bridge.write_text(
            'public enum BridgeBuild {\n'
            '    public static let marketingVersion = "1.0.0"\n'
            '    public static let buildNumber = "14"\n'
            '    public static let prototypeDiagnostics = false\n'
            '}\n'
        )
        self._write_pins(project)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "release-shaped source")
        (project / "NOTES.md").write_text("dirty\n")
        result = self._release_preflight(repo, project)
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertIn("provenance", {item["name"] for item in payload["checks"] if not item["ok"]})
        self.assertTrue(payload["provenanceDeviations"])

    def _product_repo(self) -> tuple[Path, Path]:
        repo, project = init_repo(self.root)
        (project / "project.yml").write_text(
            support.project_yml_text("1.0.0", "14", prototype_compilation=False)
        )
        (project / "Sources" / "BridgeCore" / "BridgeBuild.swift").write_text(
            'public enum BridgeBuild {\n'
            '    public static let marketingVersion = "1.0.0"\n'
            '    public static let buildNumber = "14"\n'
            '    public static let prototypeDiagnostics = false\n'
            '}\n'
        )
        self._write_pins(project)
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "product source")
        return repo, project

    def test_product_qualification_preflight_accepts_clean_1_0_source(self) -> None:
        repo, project = self._product_repo()
        result = self._preflight(repo, project, "product-qualification", "HEAD")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["ok"], payload["failures"])
        self.assertEqual(payload["mode"], vb.PRODUCT_QUALIFICATION)
        self.assertEqual(payload["identity"]["marketingVersion"], "1.0.0")
        self.assertEqual(payload["sourceFileCount"], 9)

    def test_product_qualification_preflight_requires_source_ref(self) -> None:
        repo, project = self._product_repo()
        result = self._preflight(repo, project, "product-qualification", None)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("requires an explicit --source-ref", result.stderr)

    def test_product_qualification_preflight_rejects_dirty_source(self) -> None:
        repo, project = self._product_repo()
        (project / "NOTES.md").write_text("dirty\n")
        result = self._preflight(repo, project, "product-qualification", "HEAD")
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertIn(
            "provenance",
            {item["name"] for item in payload["checks"] if not item["ok"]},
        )
        self.assertTrue(payload["provenanceDeviations"])

    def test_validate_lock_is_read_only(self) -> None:
        repo, project = init_repo(self.root)
        lock = project / "Vendor" / "idevice.lock.json"
        lock.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "component": "idevice",
            "release": "v0.1.68",
            "commit": "d32c8189c51c2789496b0768039419c3705498c3",
            "assetSHA256": "c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7",
        }
        lock.write_text(json.dumps(payload))
        script = project / "scripts" / "fetch_idevice.sh"
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(
            'VERSION="v0.1.68"\n'
            'ASSET_SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"\n'
        )
        before = hashlib.sha256(lock.read_bytes()).hexdigest()
        checks = vb.validate_lock(project)
        after = hashlib.sha256(lock.read_bytes()).hexdigest()
        self.assertTrue(all(item["ok"] for item in checks), checks)
        self.assertEqual(before, after)
        self.assertEqual(json.loads(lock.read_text()), payload)


if __name__ == "__main__":
    unittest.main(verbosity=2)
