#!/usr/bin/env python3
"""Read-only public asset verifier tests (no GitHub or network calls)."""

from __future__ import annotations

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
import verify_bridge as vb  # noqa: E402
import verify_public_release as vp  # noqa: E402


def git(repo: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments], text=True, capture_output=True
    )
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(arguments)} failed: {result.stderr}")
    return result.stdout


def init_repo(root: Path) -> tuple[Path, Path]:
    repo = root / "repo"
    repo.mkdir(parents=True)
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "bridge-tests@example.invalid")
    git(repo, "config", "user.name", "Bridge Tests")
    project = repo / "FloeIOSBridge"
    support.write_source_root(project, "1.0.0", "14", prototype=False)
    (repo / "README.md").write_text("root\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "fixture")
    return repo, project


class PublicReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-public-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_canonical_name(self) -> None:
        self.assertEqual(
            vp.canonical_ipa_name("1.0.0"),
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
        )

    def test_tag_binding_passes(self) -> None:
        repo, _ = init_repo(self.root)
        git(repo, "tag", "-a", "floe-ios-bridge-v1.0.0", "-m", "bridge 1.0.0")
        checks = vp.check_tag(repo, "floe-ios-bridge-v1.0.0", "HEAD", "1.0.0")
        self.assertTrue(all(item["ok"] for item in checks), checks)
        commit = git(repo, "rev-parse", "HEAD").strip()
        self.assertTrue(any(item["detail"] == commit for item in checks))

    def test_wrong_tag_name_is_rejected(self) -> None:
        repo, _ = init_repo(self.root)
        checks = vp.check_tag(repo, "floe-bridge-v1.0.0", "HEAD", "1.0.0")
        self.assertFalse(all(item["ok"] for item in checks))
        self.assertIn("tag-name-canonical", {item["name"] for item in checks if not item["ok"]})
        self.assertIn("tag-not-macos-bridge", {item["name"] for item in checks if not item["ok"]})

    def test_moved_or_unrelated_tag_is_rejected(self) -> None:
        repo, _ = init_repo(self.root)
        git(repo, "tag", "floe-ios-bridge-v1.0.0")
        (repo / "README.md").write_text("second commit\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-q", "-m", "second")
        checks = vp.check_tag(repo, "floe-ios-bridge-v1.0.0", "HEAD", "1.0.0")
        failures = {item["name"] for item in checks if not item["ok"]}
        self.assertIn("tag-commit-equals-source-ref", failures)

    def test_missing_tag_can_only_be_allowed_explicitly(self) -> None:
        repo, _ = init_repo(self.root)
        strict = vp.check_tag(repo, "floe-ios-bridge-v1.0.0", "HEAD", "1.0.0")
        self.assertIn("tag-exists", {item["name"] for item in strict if not item["ok"]})
        allowed = vp.check_tag(
            repo, "floe-ios-bridge-v1.0.0", "HEAD", "1.0.0", allow_missing=True
        )
        self.assertTrue(all(item["ok"] for item in allowed), allowed)

    def test_latest_pointer_must_not_become_bridge(self) -> None:
        latest = self.root / "latest.json"
        latest.write_text(json.dumps({"tag_name": "floe-bridge-v0.1.0"}))
        checks = vp.check_latest(latest, "floe-ios-bridge-v1.0.0", "floe-bridge-v0.1.0", strict=True)
        self.assertTrue(all(item["ok"] for item in checks), checks)

        latest.write_text(json.dumps({"tag_name": "floe-ios-bridge-v1.0.0"}))
        checks = vp.check_latest(latest, "floe-ios-bridge-v1.0.0", None, strict=True)
        failures = {item["name"] for item in checks if not item["ok"]}
        self.assertIn("latest-not-bridge-tag", failures)

    def test_latest_pointer_expected_unchanged(self) -> None:
        latest = self.root / "latest.json"
        latest.write_text(json.dumps({"tag_name": "something-else"}))
        checks = vp.check_latest(latest, "floe-ios-bridge-v1.0.0", "floe-bridge-v0.1.0", strict=True)
        failures = {item["name"] for item in checks if not item["ok"]}
        self.assertIn("latest-pointer-unchanged", failures)

    def test_latest_json_requires_expected_tag_in_strict_mode(self) -> None:
        latest = self.root / "latest.json"
        latest.write_text(json.dumps({"tag_name": "floe-bridge-v0.1.0"}))
        strict = vp.check_latest(latest, "floe-ios-bridge-v1.0.0", None, strict=True)
        self.assertIn(
            "latest-pointer-unchanged",
            {item["name"] for item in strict if not item["ok"]},
        )
        relaxed = vp.check_latest(latest, "floe-ios-bridge-v1.0.0", None, strict=False)
        self.assertTrue(all(item["ok"] for item in relaxed), relaxed)

    def test_latest_unchecked_in_non_strict_mode(self) -> None:
        checks = vp.check_latest(None, "floe-ios-bridge-v1.0.0", None, strict=False)
        self.assertTrue(all(item["ok"] for item in checks), checks)
        checks = vp.check_latest(None, "floe-ios-bridge-v1.0.0", None, strict=True)
        self.assertFalse(all(item["ok"] for item in checks))

    def test_sha256_sidecar(self) -> None:
        ipa = self.root / "Floe-iOS-Bridge-1.0.0-unsigned.ipa"
        ipa.write_bytes(b"ipa bytes")
        digest = pb.sha256(ipa)
        sidecar = Path(str(ipa) + ".sha256")
        sidecar.write_text(f"{digest}  {ipa.name}\n")
        checks = vp.check_sidecar(ipa, sidecar)
        self.assertTrue(all(item["ok"] for item in checks), checks)

        sidecar.write_text(f"{'0' * 64}  {ipa.name}\n")
        checks = vp.check_sidecar(ipa, sidecar)
        self.assertIn("sidecar-hash-matches", {item["name"] for item in checks if not item["ok"]})

        sidecar.write_text(f"{digest}  other.ipa\n")
        checks = vp.check_sidecar(ipa, sidecar)
        self.assertIn("sidecar-filename-matches", {item["name"] for item in checks if not item["ok"]})

    def test_public_summary_binds_source_and_artifact(self) -> None:
        repo, project = init_repo(self.root)
        identity = vb.load_project_identity(project / "project.yml")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        self.assertTrue(provenance["ok"], provenance["strictDeviations"])
        ipa = self.root / vp.canonical_ipa_name(identity.marketing_version)
        ipa.write_bytes(b"public ipa")
        summary = pb.build_public_summary(
            identity, ipa, provenance,
            {"checks": [{"ok": True}]},
            {"checks": [{"ok": True}]},
            {"ok": True},
        )
        summary_path = self.root / "summary.json"
        summary_path.write_text(json.dumps(summary))
        checks = vp.check_public_summary(summary_path, identity, provenance, ipa)
        self.assertTrue(all(item["ok"] for item in checks), checks)

        wrong = dict(summary)
        wrong["sourceTreeSHA256"] = "0" * 64
        summary_path.write_text(json.dumps(wrong))
        checks = vp.check_public_summary(summary_path, identity, provenance, ipa)
        self.assertIn(
            "public-summary-source-tree-sha256",
            {item["name"] for item in checks if not item["ok"]},
        )

    def test_public_summary_rejects_custom_bundle_ids(self) -> None:
        repo, project = init_repo(self.root)
        identity = vb.load_project_identity(project / "project.yml")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        ipa = self.root / vp.canonical_ipa_name(identity.marketing_version)
        ipa.write_bytes(b"public ipa")
        summary = pb.build_public_summary(
            identity, ipa, provenance,
            {"checks": [{"ok": True}]},
            {"checks": [{"ok": True}]},
            {"ok": True},
        )
        summary["bundleIdentifier"] = "com.example.floe.bridge"
        summary_path = self.root / "summary-custom-id.json"
        summary_path.write_text(json.dumps(summary))
        checks = vp.check_public_summary(summary_path, identity, provenance, ipa)
        self.assertIn(
            "public-summary-canonical-bundle-ids",
            {item["name"] for item in checks if not item["ok"]},
        )

    def test_public_summary_rejects_private_paths(self) -> None:
        repo, project = init_repo(self.root)
        identity = vb.load_project_identity(project / "project.yml")
        provenance = pb.compute_provenance(repo, project, vb.RELEASE, "HEAD")
        ipa = self.root / vp.canonical_ipa_name(identity.marketing_version)
        ipa.write_bytes(b"public ipa")
        summary = pb.build_public_summary(
            identity, ipa, provenance,
            {"checks": [{"ok": True}]},
            {"checks": [{"ok": True}]},
            {"ok": True},
        )
        summary["notes"] = "/Users/example/private"
        summary_path = self.root / "summary.json"
        summary_path.write_text(json.dumps(summary))
        checks = vp.check_public_summary(summary_path, identity, provenance, ipa)
        self.assertIn(
            "public-summary-safe",
            {item["name"] for item in checks if not item["ok"]},
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
