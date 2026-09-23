import contextlib
import hashlib
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock as mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent  # FloeAgent/
REPO = ROOT.parent
sys.path.insert(0, str(SCRIPTS))

import license_inventory as li  # noqa: E402

MIT_TEXT = (
    "MIT License\n\n"
    "Copyright (c) 2026 Example\n\n"
    "Permission is hereby granted, free of charge, to any person obtaining a copy\n"
    "of this software and associated documentation files (the \"Software\"), to deal\n"
    "in the Software without restriction.\n"
)


def make_checkout(checkouts: Path, identity: str, license_text: str = MIT_TEXT) -> str:
    """Create a resolved-looking git checkout and return its real HEAD revision."""
    checkout = checkouts / identity
    checkout.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(checkout)], check=True, capture_output=True)
    (checkout / "LICENSE").write_text(license_text, encoding="utf-8")
    subprocess.run(["git", "-C", str(checkout), "add", "LICENSE"], check=True, capture_output=True)
    subprocess.run(
        [
            "git", "-C", str(checkout),
            "-c", "user.name=Floe Test",
            "-c", "user.email=floe@example.invalid",
            "commit", "-q", "-m", "license",
        ],
        check=True,
        capture_output=True,
    )
    return subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()


class LicenseInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = li.build()
        cls.manifest = cls.result["manifest"]

    def test_no_problems_in_the_generated_inventory(self):
        self.assertEqual(self.result["problems"], [])

    def test_every_component_license_is_recorded_not_guessed(self):
        unknown = [
            component["name"]
            for component in self.manifest["components"]
            if component["license"] == "UNKNOWN"
        ]
        self.assertEqual(unknown, [])

    def test_resolved_packages_are_backed_by_license_evidence(self):
        evidence = {row["identity"]: row for row in self.result["evidence"]["licenses"]}
        pins = [c for c in self.manifest["components"] if c["section"] == "swift"]
        self.assertEqual(len(pins), self.manifest["counts"]["pins"])
        for component in pins:
            row = evidence.get(component["name"])
            self.assertIsNotNone(row, component["name"])
            self.assertNotEqual(row["license"], "UNKNOWN")
            self.assertTrue(row["evidence"], component["name"])
            self.assertRegex(row["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(row["revision"], r"^[0-9a-f]{40}$", component["name"])
            self.assertTrue(row["source"], component["name"])
            path = ROOT / row["evidence"]
            if path.is_file():
                self.assertEqual(li.sha256_file(path), row["sha256"], row["evidence"])

    def test_libgit2_exception_is_explicit_and_text_is_bundled(self):
        component = next(c for c in self.manifest["components"] if c["name"] == "libgit2")
        self.assertEqual(component["license"], "GPL-2.0 WITH libgit2 linking exception")
        self.assertEqual(component["noteKey"], "settings.licenses.note.libgit2")
        document = next(d for d in self.manifest["documents"] if d["id"] == "libgit2")
        self.assertEqual(document["bundlePath"], li.LIBGIT2_COPYING_BUNDLE_PATH)
        self.assertTrue(document["required"])
        copy = ROOT / "FloeApp/Resources" / li.LIBGIT2_COPYING_BUNDLE_PATH
        self.assertTrue(copy.is_file())
        digest = hashlib.sha256(copy.read_bytes()).hexdigest()
        record = next(r for r in self.result["evidence"]["licenses"] if r["identity"] == "libgit2")
        self.assertEqual(digest, record["sha256"])

    def test_gpl_gate_rejects_unrecorded_copyleft(self):
        violations, _ = li.license_gate(
            [{"name": "x", "license": "GPL-3.0"}, {"name": "y", "license": "LGPL-2.1"}]
        )
        self.assertEqual(len(violations), 2)
        violations, notices = li.license_gate(
            [{"name": "libgit2", "license": "GPL-2.0 WITH libgit2 linking exception"}]
        )
        self.assertEqual(violations, [])
        self.assertEqual(len(notices), 1)

    def test_every_notice_maps_into_a_declared_bundle_resource(self):
        rules = li.bundle_rules(li.PROJECT_YML.read_text())
        for document in self.manifest["documents"]:
            mapped = li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"])
            self.assertEqual(mapped, document["bundlePath"], document["repositoryPath"])
        self.assertEqual(
            li.bundle_path_for(rules, "FloeAgent/FloeApp/Resources/Licenses/third-party-inventory.json"),
            li.MANIFEST_BUNDLE_PATH,
        )

    def test_manifest_localization_keys_are_complete(self):
        self.assertEqual(li.localization_problems(self.manifest, li.XSTRINGS), [])

    def test_document_titles_are_not_mixed_bilingual(self):
        for document in self.manifest["documents"]:
            self.assertNotIn(" / ", document["titleFallback"], document["id"])
        for section in self.manifest["sections"]:
            self.assertNotIn(" / ", section["fallback"], section["id"])

    def test_swift_view_reads_the_generated_manifest_only(self):
        view = (ROOT / "FloeApp/Settings/TinyEMULicensesView.swift").read_text()
        self.assertIn("Licenses/third-party-inventory.json", view)
        for hand_copied in ("LicenseInventory.groups", "BundledLicenseCatalog", "LicenseComponent("):
            self.assertNotIn(hand_copied, view)

    def test_check_mode_is_read_only(self):
        artifacts = [
            li.MARKDOWN,
            li.MANIFEST,
            li.EVIDENCE,
            ROOT / "FloeApp/Resources" / li.LIBGIT2_COPYING_BUNDLE_PATH,
        ]
        before = {path: (path.stat().st_mtime_ns, path.stat().st_size) for path in artifacts}
        completed = subprocess.run(
            [sys.executable, str(SCRIPTS / "license_inventory.py"), "--check"],
            cwd=REPO,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--check OK", completed.stdout)
        for path in artifacts:
            self.assertEqual(before[path], (path.stat().st_mtime_ns, path.stat().st_size), path)

    def test_generated_artifacts_are_current(self):
        self.assertEqual(li.MARKDOWN.read_text(encoding="utf-8"), self.result["markdown"])
        self.assertEqual(li.MANIFEST.read_text(encoding="utf-8"), self.result["manifest_text"])
        self.assertEqual(li.EVIDENCE.read_text(encoding="utf-8"), self.result["evidence_text"])
        if self.result["libgit2_bytes"] is not None:
            self.assertEqual(
                (ROOT / "FloeApp/Resources" / li.LIBGIT2_COPYING_BUNDLE_PATH).read_bytes(),
                self.result["libgit2_bytes"],
            )

    def test_packaged_manifest_counts_match_its_lists(self):
        counts = self.manifest["counts"]
        self.assertEqual(counts["components"], len(self.manifest["components"]))
        self.assertEqual(counts["documents"], len(self.manifest["documents"]))
        self.assertEqual(counts["pins"], sum(1 for c in self.manifest["components"] if c["section"] == "swift"))
        # The TinyEMU/slirp notice stays first and required; every other
        # previously bundled notice family is still declared.
        self.assertEqual(self.manifest["documents"][0]["id"], "tinyemu")
        self.assertTrue(self.manifest["documents"][0]["required"])
        ids = {document["id"] for document in self.manifest["documents"]}
        for required in ("occt", "occt-exception", "whisperkit", "royalvnc", "pdfium", "libarchive"):
            self.assertIn(required, ids)

    def test_pins_keep_the_revision_alongside_a_semver(self):
        pins = li.load_pins()
        versioned = [pin for pin in pins if re.match(r"^\d+\.", pin["version"])]
        self.assertTrue(versioned)
        for pin in versioned:
            self.assertRegex(pin["revision"], r"^[0-9a-f]{40}$", pin["identity"])
            self.assertNotEqual(pin["revision"], pin["version"], pin["identity"])

    def test_swiftpm_url_spelling_does_not_change_license_source(self):
        committed = json.loads(subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"], cwd=REPO, text=True
        ))
        swift_system = next(pin for pin in committed["pins"] if pin["identity"] == "swift-system")
        canonical_source = swift_system["location"]
        self.assertTrue(canonical_source.endswith(".git"))
        swift_system["location"] = canonical_source.removesuffix(".git")
        with tempfile.TemporaryDirectory() as folder:
            resolved = Path(folder) / "Package.resolved"
            resolved.write_text(json.dumps(committed), encoding="utf-8")
            with mock.patch.object(li, "PACKAGE_RESOLVED", resolved):
                pin = next(pin for pin in li.load_pins() if pin["identity"] == "swift-system")
        self.assertEqual(pin["location"], canonical_source)

    def test_committed_evidence_binds_every_pin_revision_and_source(self):
        pins = {pin["identity"]: pin for pin in li.load_pins()}
        evidence = li.load_evidence()
        self.assertEqual(set(pins), set(evidence))
        self.assertEqual(self.result["evidence"]["schemaVersion"], 2)
        for identity, pin in pins.items():
            self.assertEqual(evidence[identity]["revision"], pin["revision"], identity)
            self.assertEqual(evidence[identity]["source"], pin["location"], identity)


class EvidenceRevisionBindingTests(unittest.TestCase):
    """resolve_pins must bind evidence to the exact pin, never to an identity."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.checkouts = self.tmp / "checkouts"
        self.checkouts.mkdir()

    @staticmethod
    def pin(identity="alpha", revision="a" * 40, location="https://example.com/alpha.git"):
        return {
            "identity": identity,
            "location": location,
            "revision": revision,
            "version": "1.0.0",
        }

    @staticmethod
    def record(
        identity="alpha",
        revision="a" * 40,
        location="https://example.com/alpha.git",
        license_name="MIT",
        evidence=".build/checkouts/alpha/LICENSE",
        sha256="f" * 64,
    ):
        return {
            "identity": identity,
            "license": license_name,
            "evidence": evidence,
            "sha256": sha256,
            "revision": revision,
            "source": location,
        }

    def resolve(self, pins, recorded):
        problems = []
        rows, evidence, stats = li.resolve_pins(
            pins, recorded, problems, checkouts=self.checkouts, root=self.tmp
        )
        return problems, rows, evidence, stats

    def test_same_pin_offline_reuse_succeeds(self):
        problems, rows, evidence, stats = self.resolve([self.pin()], {"alpha": self.record()})
        self.assertEqual(problems, [])
        self.assertEqual(rows[0]["license"], "MIT")
        self.assertEqual(rows[0]["evidence"], ".build/checkouts/alpha/LICENSE")
        self.assertEqual(evidence[0]["revision"], "a" * 40)
        self.assertEqual(evidence[0]["source"], "https://example.com/alpha.git")
        self.assertEqual(stats["recorded"], 1)

    def test_changed_revision_without_checkout_is_rejected(self):
        recorded = {"alpha": self.record()}
        problems, _, evidence, stats = self.resolve([self.pin(revision="b" * 40)], recorded)
        self.assertEqual(len(problems), 1)
        self.assertIn("cannot verify revision", problems[0])
        self.assertEqual(evidence[0]["license"], "UNKNOWN")
        self.assertIsNone(evidence[0]["sha256"])
        self.assertNotEqual(evidence[0]["sha256"], recorded["alpha"]["sha256"])
        self.assertEqual(evidence[0]["revision"], "b" * 40)
        self.assertEqual(stats["unknown"], 1)

    def test_changed_source_without_checkout_is_rejected(self):
        recorded = {"alpha": self.record()}
        problems, _, evidence, _ = self.resolve(
            [self.pin(location="https://example.com/fork.git")], recorded
        )
        self.assertEqual(len(problems), 1)
        self.assertIn("cannot verify revision", problems[0])
        self.assertEqual(evidence[0]["license"], "UNKNOWN")

    def test_legacy_recorded_row_without_revision_is_rejected_offline(self):
        legacy = {
            "identity": "alpha",
            "license": "MIT",
            "evidence": ".build/checkouts/alpha/LICENSE",
            "sha256": "f" * 64,
        }
        problems, _, evidence, _ = self.resolve([self.pin()], {"alpha": legacy})
        self.assertEqual(len(problems), 1)
        self.assertIn("no revision", problems[0])
        self.assertEqual(evidence[0]["license"], "UNKNOWN")

    def test_verified_checkout_license_is_recorded_at_the_declared_revision(self):
        actual = make_checkout(self.checkouts, "alpha")
        problems, _, evidence, stats = self.resolve([self.pin(revision=actual)], {})
        self.assertEqual(problems, [])
        self.assertEqual(evidence[0]["license"], "MIT")
        self.assertEqual(evidence[0]["revision"], actual)
        self.assertEqual(evidence[0]["source"], "https://example.com/alpha.git")
        self.assertEqual(evidence[0]["evidence"], ".build/checkouts/alpha/LICENSE")
        self.assertEqual(
            evidence[0]["sha256"], li.sha256_file(self.checkouts / "alpha" / "LICENSE")
        )
        self.assertEqual(stats["checkout"], 1)

    def test_wrong_checkout_revision_is_rejected_and_never_read(self):
        make_checkout(self.checkouts, "alpha")
        problems, _, evidence, stats = self.resolve([self.pin(revision="b" * 40)], {})
        self.assertTrue(any("does not match the declared pin" in p for p in problems))
        self.assertEqual(evidence[0]["license"], "UNKNOWN")
        self.assertIsNone(evidence[0]["sha256"])
        self.assertNotEqual(
            evidence[0]["sha256"], li.sha256_file(self.checkouts / "alpha" / "LICENSE")
        )
        self.assertEqual(stats["unknown"], 1)

    def test_wrong_checkout_rejects_even_when_recorded_evidence_matches_the_pin(self):
        make_checkout(self.checkouts, "alpha")
        declared = "b" * 40
        recorded = {"alpha": self.record(revision=declared)}
        problems, _, evidence, _ = self.resolve([self.pin(revision=declared)], recorded)
        self.assertTrue(any("does not match the declared pin" in p for p in problems))
        # The declared-revision record is reused; the wrong checkout is not read.
        self.assertEqual(evidence[0]["sha256"], recorded["alpha"]["sha256"])
        self.assertNotEqual(
            evidence[0]["sha256"], li.sha256_file(self.checkouts / "alpha" / "LICENSE")
        )

    def test_checkout_with_unreadable_revision_is_rejected(self):
        (self.checkouts / "alpha").mkdir()
        problems, _, evidence, _ = self.resolve([self.pin()], {})
        self.assertTrue(any("could not be read" in p for p in problems))
        self.assertEqual(evidence[0]["license"], "UNKNOWN")

    def test_same_revision_license_change_is_flagged(self):
        actual = make_checkout(self.checkouts, "alpha")
        recorded = {"alpha": self.record(revision=actual)}
        problems, _, evidence, _ = self.resolve([self.pin(revision=actual)], recorded)
        self.assertEqual(len(problems), 1)
        self.assertIn("upstream license changed", problems[0])
        self.assertEqual(evidence[0]["license"], "MIT")

    def test_moved_pin_with_only_a_repository_notice_is_flagged(self):
        notice = self.tmp / "notice" / "LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text(MIT_TEXT, encoding="utf-8")
        digest = li.sha256_file(notice)
        recorded = {
            "alpha": self.record(
                revision="a" * 40, evidence="notice/LICENSE.txt", sha256=digest
            )
        }
        with mock.patch.dict(li.APP_ONLY_NOTICES, {"alpha": "notice/LICENSE.txt"}, clear=True):
            problems, _, evidence, _ = self.resolve([self.pin(revision="b" * 40)], recorded)
        self.assertEqual(len(problems), 1)
        self.assertIn("repository notice", problems[0])
        self.assertEqual(evidence[0]["revision"], "b" * 40)

    def test_same_pin_repository_notice_is_verified_and_tampering_is_flagged(self):
        notice = self.tmp / "notice" / "LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text(MIT_TEXT, encoding="utf-8")
        digest = li.sha256_file(notice)
        recorded = {
            "alpha": self.record(evidence="notice/LICENSE.txt", sha256=digest)
        }
        with mock.patch.dict(li.APP_ONLY_NOTICES, {"alpha": "notice/LICENSE.txt"}, clear=True):
            problems, _, evidence, stats = self.resolve([self.pin()], recorded)
            self.assertEqual(problems, [])
            self.assertEqual(evidence[0]["sha256"], digest)
            self.assertEqual(stats["notice"], 1)
            notice.write_text(MIT_TEXT + "\nmodified\n", encoding="utf-8")
            problems, _, _, _ = self.resolve([self.pin()], recorded)
        self.assertEqual(len(problems), 1)
        self.assertIn("upstream license changed", problems[0])

    def test_reused_repository_evidence_must_still_match_its_digest(self):
        notice = self.tmp / "notice" / "LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text(MIT_TEXT, encoding="utf-8")
        recorded = {"alpha": self.record(evidence="notice/LICENSE.txt", sha256="0" * 64)}
        with mock.patch.dict(li.APP_ONLY_NOTICES, {}, clear=True):
            problems, _, _, _ = self.resolve([self.pin()], recorded)
        self.assertEqual(len(problems), 1)
        self.assertIn("recorded evidence file changed", problems[0])

    def test_check_mode_succeeds_without_any_checkout(self):
        artifacts = [
            li.MARKDOWN,
            li.MANIFEST,
            li.EVIDENCE,
            ROOT / "FloeApp/Resources" / li.LIBGIT2_COPYING_BUNDLE_PATH,
        ]
        before = {path: (path.stat().st_mtime_ns, path.stat().st_size) for path in artifacts}
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(li, "CHECKOUTS", self.checkouts):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = li.main(["--check"])
        self.assertEqual(code, 0, stderr.getvalue())
        self.assertIn("--check OK", stdout.getvalue())
        self.assertIn("recorded reuse", stdout.getvalue())
        for path in artifacts:
            self.assertEqual(before[path], (path.stat().st_mtime_ns, path.stat().st_size), path)


if __name__ == "__main__":
    unittest.main()
