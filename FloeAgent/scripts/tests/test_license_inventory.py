import contextlib
import hashlib
import io
import json
import os
import re
import shutil
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
        ] + [ROOT / path for path in self.result["vendored_copies"]]
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
        for repository_path, expected in self.result["vendored_copies"].items():
            copied = ROOT / repository_path
            self.assertTrue(copied.is_file(), repository_path)
            self.assertEqual(copied.read_bytes(), expected, repository_path)

    def test_packaged_manifest_counts_match_its_lists(self):
        counts = self.manifest["counts"]
        self.assertEqual(counts["components"], len(self.manifest["components"]))
        self.assertEqual(counts["documents"], len(self.manifest["documents"]))
        self.assertEqual(counts["pins"], sum(1 for c in self.manifest["components"] if c["section"] == "swift"))
        # Notices are identified independently of display order: media
        # notices can precede the engine section without dropping TinyEMU.
        documents = {document["id"]: document for document in self.manifest["documents"]}
        self.assertEqual(len(documents), len(self.manifest["documents"]))
        tinyemu = documents["tinyemu"]
        self.assertTrue(tinyemu["required"])
        self.assertEqual(tinyemu["bundlePath"], "TinyEMU-LICENSES.txt")
        self.assertEqual(tinyemu["section"], "engines")
        for music in ("pip-ambient-meditation", "pip-ambient-expansion"):
            self.assertTrue(documents[music]["required"])
            self.assertEqual(documents[music]["license"], "CC0-1.0")
            self.assertEqual(documents[music]["section"], "media")
        ids = set(documents)
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
        # The tracked host lock is serialized by SwiftPM in either the v1
        # (object.pins/repositoryURL) or v2/v3 (pins/location) schema; the
        # committed spelling must win in both.
        if committed.get("version") in (2, 3):
            pins, url_key = committed["pins"], "location"
        else:
            pins, url_key = committed["object"]["pins"], "repositoryURL"
        swift_system = next(
            pin for pin in pins
            if (pin.get(url_key) or "").rstrip("/").endswith("swift-system.git")
        )
        canonical_source = swift_system[url_key]
        self.assertTrue(canonical_source.endswith(".git"))
        swift_system[url_key] = canonical_source.removesuffix(".git")
        with tempfile.TemporaryDirectory() as folder:
            resolved = Path(folder) / "Package.resolved"
            resolved.write_text(json.dumps(committed), encoding="utf-8")
            with mock.patch.object(li, "PACKAGE_RESOLVED", resolved):
                pin = next(pin for pin in li.load_pins() if pin["identity"] == "swift-system")
        self.assertEqual(pin["location"], canonical_source)

    def test_committed_evidence_binds_every_declared_dependency(self):
        resolved = li.load_pins()
        pins = {pin["identity"]: pin for pin in resolved}
        vendored = {
            row["identity"]: row
            for row in li.resolve_vendored_packages(resolved, [])["evidence"]
        }
        cad = {row["identity"]: row for row in li.resolve_cad_packages([])["evidence"]}
        openshape = {
            row["identity"]: row
            for row in li.resolve_openshape_attribution([])["evidence"]
        }
        evidence = li.load_evidence()
        self.assertEqual(set(evidence), set(pins) | set(vendored) | set(cad) | set(openshape))
        self.assertEqual(self.result["evidence"]["schemaVersion"], 2)
        for identity, pin in pins.items():
            self.assertEqual(evidence[identity]["revision"], pin["revision"], identity)
            self.assertEqual(evidence[identity]["source"], pin["location"], identity)
        for identity, row in vendored.items():
            self.assertEqual(evidence[identity]["revision"], row["revision"], identity)
            self.assertEqual(evidence[identity]["source"], row["source"], identity)
            self.assertEqual(evidence[identity]["evidence"], row["evidence"], identity)
            copied = ROOT / evidence[identity]["evidence"]
            self.assertTrue(copied.is_file(), evidence[identity]["evidence"])
            self.assertEqual(li.sha256_file(copied), evidence[identity]["sha256"], identity)
        for identity, row in cad.items():
            self.assertEqual(evidence[identity]["revision"], row["revision"], identity)
            self.assertEqual(evidence[identity]["source"], row["source"], identity)
            self.assertEqual(evidence[identity]["evidence"], row["evidence"], identity)
            copied = ROOT / evidence[identity]["evidence"]
            self.assertTrue(copied.is_file(), evidence[identity]["evidence"])
            self.assertEqual(li.sha256_file(copied), evidence[identity]["sha256"], identity)
        for identity, row in openshape.items():
            self.assertEqual(evidence[identity]["revision"], row["revision"], identity)
            self.assertEqual(evidence[identity]["source"], row["source"], identity)
            self.assertEqual(evidence[identity]["evidence"], row["evidence"], identity)
            copied = ROOT / evidence[identity]["evidence"]
            self.assertTrue(copied.is_file(), evidence[identity]["evidence"])
            self.assertEqual(li.sha256_file(copied), evidence[identity]["sha256"], identity)

    def test_generation_is_reproducible_byte_for_byte(self):
        second = li.build()
        self.assertEqual(second["manifest_text"], self.result["manifest_text"])
        self.assertEqual(second["evidence_text"], self.result["evidence_text"])
        self.assertEqual(second["markdown"], self.result["markdown"])

    def test_vendored_lock_switch_is_declared_consistently(self):
        resolved = li.load_pins()
        original = next(spec for spec in li.VENDORED_PACKAGES
                        if spec["identity"] == "mlx-swift-lm")
        vendored = li.resolve_vendored_packages(resolved, [])
        swift = [c for c in self.manifest["components"] if c["section"] == "swift"]
        if any(pin["identity"] == "mlx-swift-lm" for pin in resolved):
            # Remote pin still declared: the vendored copy must not appear twice.
            self.assertEqual(vendored["components"], [])
            self.assertFalse(any(c["name"] == "mlx-swift-lm" for c in swift))
            return
        self.assertEqual([c["name"] for c in vendored["components"]], ["mlx-swift-lm"])
        component = next(c for c in swift if c["name"] == "mlx-swift-lm")
        self.assertEqual(component["license"], "MIT")
        self.assertIn(original["revision"], component["source"])
        document = next(d for d in self.manifest["documents"] if d["id"] == "mlx-swift-lm")
        self.assertTrue(document["required"])
        self.assertEqual(document["bundlePath"], "Licenses/MLXSwiftLM-LICENSE.txt")
        vendored_license = ROOT / original["path"] / "LICENSE"
        copied = ROOT / "FloeApp/Resources" / "Licenses/MLXSwiftLM-LICENSE.txt"
        self.assertTrue(copied.is_file())
        self.assertEqual(copied.read_bytes(), vendored_license.read_bytes())
        row = next(r for r in self.result["evidence"]["licenses"]
                   if r["identity"] == "mlx-swift-lm")
        self.assertEqual(row["revision"], original["revision"])
        self.assertEqual(row["evidence"], f"{original['path']}/LICENSE")
        self.assertEqual(li.sha256_file(vendored_license), row["sha256"])


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

    def test_wrong_checkout_is_not_reported_as_a_verified_license_read(self):
        make_checkout(self.checkouts, "alpha")
        declared = "b" * 40
        recorded = {"alpha": self.record(revision=declared)}
        problems, _, _, _ = self.resolve([self.pin(revision=declared)], recorded)
        self.assertTrue(any("does not match the declared pin" in p for p in problems))
        self.assertFalse(any("no classifiable license file" in p for p in problems), problems)

    def test_verified_checkout_without_a_license_file_is_flagged(self):
        checkout = self.checkouts / "alpha"
        checkout.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(checkout)], check=True, capture_output=True)
        (checkout / "README").write_text("no license file here\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(checkout), "add", "README"], check=True, capture_output=True)
        subprocess.run(
            [
                "git", "-C", str(checkout),
                "-c", "user.name=Floe Test",
                "-c", "user.email=floe@example.invalid",
                "commit", "-q", "-m", "readme",
            ],
            check=True,
            capture_output=True,
        )
        actual = subprocess.check_output(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
        ).strip()
        recorded = {"alpha": self.record(revision=actual)}
        problems, _, evidence, _ = self.resolve([self.pin(revision=actual)], recorded)
        self.assertTrue(any("no classifiable license file" in p for p in problems), problems)
        self.assertEqual(evidence[0]["license"], "MIT")
        self.assertEqual(evidence[0]["sha256"], recorded["alpha"]["sha256"])

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

    def test_app_only_notice_wins_over_an_identical_checkout(self):
        """A same-revision Xcode checkout must not rewrite the tracked
        app-only evidence path to a build-cache string."""
        actual = make_checkout(self.checkouts, "alpha")
        notice = self.tmp / "notice" / "LICENSE.txt"
        notice.parent.mkdir(parents=True)
        notice.write_text(MIT_TEXT, encoding="utf-8")
        digest = li.sha256_file(notice)
        recorded = {
            "alpha": self.record(
                evidence="notice/LICENSE.txt", sha256=digest, revision=actual
            )
        }
        with mock.patch.dict(li.APP_ONLY_NOTICES, {"alpha": "notice/LICENSE.txt"}, clear=True):
            problems, _, evidence, stats = self.resolve([self.pin(revision=actual)], recorded)
        self.assertEqual(problems, [])
        self.assertEqual(evidence[0]["evidence"], "notice/LICENSE.txt")
        self.assertEqual(evidence[0]["sha256"], digest)
        self.assertEqual(stats["notice"], 1)

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
        vendored = li.resolve_vendored_packages(li.load_pins(), [])["copies"]
        artifacts = [
            li.MARKDOWN,
            li.MANIFEST,
            li.EVIDENCE,
            ROOT / "FloeApp/Resources" / li.LIBGIT2_COPYING_BUNDLE_PATH,
        ] + [ROOT / path for path in vendored]
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


class VendoredPackageTests(unittest.TestCase):
    """The vendored mlx-swift-lm copy must be stable across the lock switch.

    Fixture roots exercise both states directly, so these assertions hold before
    and after Package.resolved drops the remote pin.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.spec = next(spec for spec in li.VENDORED_PACKAGES
                         if spec["identity"] == "mlx-swift-lm")
        self.license_path = self.root / self.spec["path"] / li.VENDORED_LICENSE_NAME

    def write_license(self, text=MIT_TEXT):
        self.license_path.parent.mkdir(parents=True, exist_ok=True)
        self.license_path.write_text(text, encoding="utf-8")

    def pin(self):
        return {
            "identity": self.spec["identity"],
            "location": self.spec["upstream"],
            "revision": self.spec["revision"],
            "version": self.spec["revision"],
        }

    def test_remote_pin_stays_the_single_declaration(self):
        self.write_license()
        problems = []
        result = li.resolve_vendored_packages([self.pin()], problems, root=self.root)
        self.assertEqual(problems, [])
        self.assertEqual(result["components"], [])
        self.assertEqual(result["documents"], [])
        self.assertEqual(result["evidence"], [])
        self.assertEqual(result["copies"], {})
        self.assertEqual(result["notes"], [])

    def test_local_package_replaces_the_pin_with_the_full_license(self):
        self.write_license()
        problems = []
        result = li.resolve_vendored_packages([], problems, root=self.root)
        self.assertEqual(problems, [])
        component = result["components"][0]
        self.assertEqual(component["name"], "mlx-swift-lm")
        self.assertEqual(component["license"], "MIT")
        self.assertEqual(component["section"], "swift")
        self.assertEqual(component["noteKey"], "settings.licenses.note.mlx_vendor")
        self.assertIn(self.spec["revision"], component["source"])
        document = result["documents"][0]
        self.assertEqual(document["id"], self.spec["document"]["id"])
        self.assertEqual(document["bundlePath"], "Licenses/MLXSwiftLM-LICENSE.txt")
        self.assertEqual(document["kindKey"], li.KINDS["full_text"])
        self.assertTrue(document["required"])
        self.assertEqual(
            result["copies"][document["repositoryPath"]], self.license_path.read_bytes()
        )
        evidence = result["evidence"][0]
        self.assertEqual(evidence["identity"], "mlx-swift-lm")
        self.assertEqual(evidence["revision"], self.spec["revision"])
        self.assertEqual(evidence["source"], self.spec["upstream"])
        self.assertEqual(evidence["evidence"], f"{self.spec['path']}/{li.VENDORED_LICENSE_NAME}")
        self.assertEqual(evidence["sha256"], li.sha256_file(self.license_path))
        self.assertEqual([note[0] for note in result["notes"]], [self.spec["note"][0]])

    def test_document_bundle_path_is_declared_by_project_yml(self):
        # No project.yml edit: the Licenses folder resource already maps it.
        self.write_license()
        document = li.resolve_vendored_packages([], [], root=self.root)["documents"][0]
        rules = li.bundle_rules(li.PROJECT_YML.read_text())
        self.assertEqual(
            li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"]),
            document["bundlePath"],
        )

    def test_missing_vendored_copy_is_a_problem_not_a_silent_drop(self):
        problems = []
        result = li.resolve_vendored_packages([], problems, root=self.root)
        self.assertEqual(result["components"], [])
        self.assertEqual(result["copies"], {})
        self.assertEqual(len(problems), 1)
        self.assertIn("vendored", problems[0])
        self.assertIn(self.spec["path"], problems[0])

    def test_unexpected_vendored_license_is_flagged(self):
        self.write_license("Apache License\nVersion 2.0\n")
        problems = []
        li.resolve_vendored_packages([], problems, root=self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("expected MIT", problems[0])

    def test_check_detects_a_missing_or_changed_bundled_copy(self):
        relative = "FloeApp/Resources/Licenses/MLXSwiftLM-LICENSE.txt"
        copies = {relative: b"complete MIT license text\n"}
        drift = li.vendored_copy_drift(copies, self.root)
        self.assertEqual(len(drift), 1)
        self.assertIn("missing", drift[0][1])
        target = self.root / relative
        target.parent.mkdir(parents=True)
        target.write_bytes(b"stale text\n")
        drift = li.vendored_copy_drift(copies, self.root)
        self.assertEqual(len(drift), 1)
        self.assertIn("differs", drift[0][1])
        target.write_bytes(copies[relative])
        self.assertEqual(li.vendored_copy_drift(copies, self.root), [])

    def test_manifest_and_localization_accept_the_vendored_document(self):
        self.write_license()
        result = li.resolve_vendored_packages([], [], root=self.root)
        components = li.build_components([], [], [], result["components"])
        manifest = li.build_manifest(components, result["documents"], result["notes"])
        self.assertEqual(li.localization_problems(manifest, li.XSTRINGS), [])
        violations, _ = li.license_gate(manifest["components"])
        self.assertEqual(violations, [])
        self.assertIn("mlx_vendor", {note["id"] for note in manifest["notes"]})
        self.assertEqual(manifest["counts"]["pins"], 1)

    def test_catalog_value_matches_the_generated_note_and_title(self):
        catalog = json.loads(li.XSTRINGS.read_text(encoding="utf-8"))["strings"]
        note_id, note_text = self.spec["note"]
        note = catalog[f"settings.licenses.note.{note_id}"]["localizations"]
        self.assertEqual(note["en"]["stringUnit"]["value"], note_text)
        self.assertTrue(note["zh-Hans"]["stringUnit"]["value"].strip())
        document = self.spec["document"]
        title = catalog[document["titleKey"]]["localizations"]
        self.assertEqual(title["en"]["stringUnit"]["value"], document["titleFallback"])
        self.assertTrue(title["zh-Hans"]["stringUnit"]["value"].strip())


class BundledBootPairTests(unittest.TestCase):
    """The bundled Linux boot pair must be declared truthfully and bound to pins.

    The app ships the verified Linux 6.18.56 Image + OpenSBI 1.9 fw_jump as
    separate data resources, while the Debian rootfs stays a separately
    downloaded image with its own legacy kernel/bbl pair. These tests bind the
    rendered metadata to the canonical pair manifest and the tracked config so
    a new pair cannot silently keep stale hashes, sources or license text.
    """

    NOTE_KEY = "settings.licenses.note.linux_boot_pair"
    KERNEL_NAME = "Linux guest boot kernel (bundled 6.18.56 Image)"
    FIRMWARE_NAME = "Linux guest boot firmware (bundled OpenSBI v1.9 fw_jump)"
    LEGACY_NAME = (
        "Floe Linux guest component (Debian 13 riscv64 userland, kernel, bbl, static glibc)"
    )
    DOCUMENT_ID = "linux-boot-pair"
    NOTICE = ROOT / "FloeApp/Resources/Licenses/LinuxBootPair-LICENSES.txt"
    RECORD = ROOT / "ThirdParty/TinyEMU/guest-image/BOOT-PAIR-LICENSES.md"
    PAIR_MANIFEST = ROOT / "ThirdParty/TinyEMU/guest-image/boot-pair-v2.manifest.json"
    CONFIG = ROOT / "ThirdParty/TinyEMU/guest-image/config_linux_riscv64_6.18.56"

    @classmethod
    def setUpClass(cls):
        cls.result = li.build()
        cls.manifest = cls.result["manifest"]
        cls.pair = json.loads(cls.PAIR_MANIFEST.read_text())["pair"]

    def component(self, name: str) -> dict:
        return next(c for c in self.manifest["components"] if c["name"] == name)

    def test_bundled_pair_is_separate_from_the_downloaded_guest_image(self):
        kernel = self.component(self.KERNEL_NAME)
        firmware = self.component(self.FIRMWARE_NAME)
        for component in (kernel, firmware):
            self.assertEqual(component["section"], "engines")
            self.assertEqual(component["noteKey"], self.NOTE_KEY)
        self.assertIn("GPL-2.0", kernel["license"])
        self.assertIn("not linked into the app binary", kernel["license"])
        self.assertIn(self.pair["version"], kernel["version"])
        self.assertIn("linux-6.18.56.tar.xz", kernel["source"])
        self.assertEqual(firmware["license"], "BSD-2-Clause")
        self.assertIn("opensbi", firmware["source"])
        # The legacy row keeps describing the separately downloaded image and
        # its own note; it is not renamed away.
        legacy = self.component(self.LEGACY_NAME)
        self.assertIn("floe-linux-guest", legacy["source"])
        self.assertEqual(legacy["noteKey"], "settings.licenses.note.guest_image")

    def test_bundled_pair_notice_binds_the_pinned_pair_manifest(self):
        notice = self.NOTICE.read_text(encoding="utf-8")
        self.assertIn(self.pair["kernelSHA256"], notice)
        self.assertIn(self.pair["firmwareSHA256"], notice)
        self.assertIn(f'{self.pair["kernelBytes"]:,}', notice)
        self.assertIn(f'{self.pair["firmwareBytes"]:,}', notice)
        self.assertIn(li.sha256_file(self.CONFIG), notice)
        self.assertIn("GNU GENERAL PUBLIC LICENSE", notice)
        self.assertIn("Western Digital", notice)

    def test_tracked_record_binds_manifest_notice_and_config_bytes(self):
        record = self.RECORD.read_text(encoding="utf-8")
        self.assertIn(self.pair["kernelSHA256"], record)
        self.assertIn(self.pair["firmwareSHA256"], record)
        self.assertIn(self.pair["version"], record)
        self.assertIn(li.sha256_file(self.CONFIG), record)
        self.assertIn(li.sha256_file(self.NOTICE), record)
        self.assertIn("boot-pair-v2.manifest.json", record)

    def test_boot_pair_document_is_required_and_bundled(self):
        document = next(d for d in self.manifest["documents"] if d["id"] == self.DOCUMENT_ID)
        self.assertTrue(document["required"])
        self.assertEqual(document["bundlePath"], "Licenses/LinuxBootPair-LICENSES.txt")
        self.assertEqual(document["section"], "engines")
        self.assertEqual(document["noteKey"], None)
        self.assertTrue(self.NOTICE.is_file())
        rules = li.bundle_rules(li.PROJECT_YML.read_text())
        self.assertEqual(
            li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"]),
            document["bundlePath"],
        )

    def test_boot_pair_note_and_title_are_bilingual_and_aligned(self):
        catalog = json.loads(li.XSTRINGS.read_text(encoding="utf-8"))["strings"]
        note = next(n for n in self.manifest["notes"] if n["id"] == "linux_boot_pair")
        self.assertEqual(note["textKey"], self.NOTE_KEY)
        self.assertEqual(
            catalog[self.NOTE_KEY]["localizations"]["en"]["stringUnit"]["value"],
            note["fallback"],
        )
        for key in (self.NOTE_KEY, "settings.licenses.document.linux_boot_pair.title"):
            for locale in ("en", "zh-Hans"):
                value = catalog[key]["localizations"][locale]["stringUnit"]["value"]
                self.assertTrue(value.strip(), f"{key}:{locale}")
        title = next(d for d in self.manifest["documents"] if d["id"] == self.DOCUMENT_ID)
        self.assertEqual(
            catalog[title["titleKey"]]["localizations"]["en"]["stringUnit"]["value"],
            title["titleFallback"],
        )

    def test_kernel_exception_is_exact_and_the_gate_is_not_loosened(self):
        kernel_license = self.component(self.KERNEL_NAME)["license"]
        self.assertIn(kernel_license, li.EXCEPTIONS)
        explanation = li.EXCEPTIONS[kernel_license]
        self.assertIn("not linked", explanation)
        self.assertIn("corresponding source", explanation)
        violations, notices = li.license_gate([{"name": "kernel", "license": kernel_license}])
        self.assertEqual(violations, [])
        self.assertEqual(len(notices), 1)
        for near_miss in ("GPL-2.0", "GPL-2.0 (Linux kernel)", kernel_license + "."):
            violations, _ = li.license_gate([{"name": "kernel", "license": near_miss}])
            self.assertEqual(len(violations), 1, near_miss)

    def test_checkout_override_defaults_to_the_real_build_cache(self):
        script = (
            "import sys; sys.path.insert(0, 'scripts'); "
            "import license_inventory as li; print(li.CHECKOUTS)"
        )
        env = {key: value for key, value in os.environ.items()
               if key != "FLOE_LICENSE_CHECKOUTS"}
        completed = subprocess.run(
            [sys.executable, "-c", script], cwd=ROOT, capture_output=True, text=True, env=env
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), str(ROOT / ".build/checkouts"))
        env["FLOE_LICENSE_CHECKOUTS"] = "/nonexistent/read-only-checkouts"
        completed = subprocess.run(
            [sys.executable, "-c", script], cwd=ROOT, capture_output=True, text=True, env=env
        )
        self.assertEqual(completed.stdout.strip(), "/nonexistent/read-only-checkouts")


class CadPackageTests(unittest.TestCase):
    """The linked FloeCAD Swift packages must be declared from the CAD lock.

    ThirdParty/FloeCADKit/Package.resolved is the single pin authority; the
    reviewed rows bind each identity to the exact lock revision and to the
    digest of the complete upstream license text tracked under
    FloeApp/Resources/Licenses.
    """

    @classmethod
    def setUpClass(cls):
        cls.result = li.build()
        cls.manifest = cls.result["manifest"]
        cls.lock = json.loads((ROOT / "ThirdParty/FloeCADKit/Package.resolved").read_text())
        cls.pins = {pin["identity"]: pin for pin in li.resolved_pins(cls.lock)}

    def component(self, identity: str) -> dict:
        return next(c for c in self.manifest["components"] if c["name"] == identity)

    def test_four_linked_cad_packages_are_declared_with_bundled_copies(self):
        for spec in li.CAD_LINKED_PACKAGES:
            component = self.component(spec["identity"])
            pin = self.pins[spec["identity"]]
            self.assertEqual(component["license"], spec["license"])
            self.assertEqual(component["version"], spec["version"])
            self.assertEqual(component["source"], pin["location"])
            self.assertEqual(component["section"], "swift")
            self.assertEqual(component["noteKey"], li.CAD_NOTE_KEY)
            self.assertEqual(component["evidence"], spec["notice"])
            copy = ROOT / spec["notice"]
            self.assertTrue(copy.is_file(), spec["notice"])
            self.assertEqual(li.sha256_file(copy), spec["sha256"], spec["notice"])
            document = next(d for d in self.manifest["documents"] if d["id"] == spec["identity"])
            self.assertTrue(document["required"])
            self.assertEqual(document["section"], "swift")
            self.assertEqual(
                document["bundlePath"],
                "Licenses/" + spec["notice"].rsplit("/", 1)[-1],
            )
            rules = li.bundle_rules(li.PROJECT_YML.read_text())
            self.assertEqual(
                li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"]),
                document["bundlePath"],
            )

    def test_evidence_binds_each_reviewed_copy_to_the_lock_revision(self):
        evidence = {row["identity"]: row for row in self.result["evidence"]["licenses"]}
        for spec in li.CAD_LINKED_PACKAGES:
            row = evidence[spec["identity"]]
            pin = self.pins[spec["identity"]]
            self.assertEqual(row["license"], spec["license"])
            self.assertEqual(row["evidence"], spec["notice"])
            self.assertEqual(row["sha256"], spec["sha256"])
            self.assertEqual(row["revision"], spec["revision"])
            self.assertEqual(row["revision"], pin["state"]["revision"])
            self.assertEqual(row["source"], pin["location"])

    def test_build_only_cad_dependencies_are_not_claimed_as_shipped(self):
        names = {c["name"] for c in self.manifest["components"]}
        for identity in li.CAD_BUILD_ONLY_PACKAGES:
            self.assertNotIn(identity, names)
            self.assertIn(identity, self.pins)
        self.assertEqual(
            set(self.pins),
            {spec["identity"] for spec in li.CAD_LINKED_PACKAGES}
            | set(li.CAD_BUILD_ONLY_PACKAGES),
        )

    def test_cad_lock_stays_bound_to_the_floecadkit_manifest(self):
        manifest = (ROOT / "ThirdParty/FloeCADKit/Package.swift").read_bytes()
        self.assertEqual(self.lock["originHash"], hashlib.sha256(manifest).hexdigest())

    def test_available_pinned_checkouts_match_the_reviewed_copies(self):
        verified = 0
        for spec in li.CAD_LINKED_PACKAGES:
            state, revision = li.read_checkout_revision(spec["identity"], li.CHECKOUTS)
            if state != "ok" or revision != spec["revision"]:
                continue
            license_name, _path, digest = li.detect_pin_license(spec["identity"], li.CHECKOUTS)
            self.assertEqual(digest, spec["sha256"], spec["identity"])
            self.assertEqual(license_name, spec["license"], spec["identity"])
            verified += 1
        # No assertion on the count: a clean clone has no checkouts. A checkout
        # that is present but does not match the declared pin is already a
        # generator problem, not a skipped case.


class CadLockVerificationTests(unittest.TestCase):
    """resolve_cad_packages must fail closed on lock/copy/checkout drift."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.checkouts = self.root / "checkouts"
        self.checkouts.mkdir()
        self.package = self.root / "ThirdParty/FloeCADKit"
        self.package.mkdir(parents=True)
        (self.root / "FloeApp/Resources/Licenses").mkdir(parents=True)

    def make_spec(self, identity="euclid", title="Euclid", text=MIT_TEXT):
        notice = f"FloeApp/Resources/Licenses/{title}-LICENSE.txt"
        path = self.root / notice
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return {
            "identity": identity,
            "revision": "a" * 40,
            "version": "1.0.0",
            "title": title,
            "license": "MIT",
            "sha256": li.sha256_file(path),
            "notice": notice,
        }

    def write_lock(self, specs, revisions=None, extra_pins=()):
        manifest = self.package / "Package.swift"
        manifest.write_bytes(b"// fixture FloeCADKit manifest\n")
        revisions = revisions or {}
        pins = []
        for spec in specs:
            revision = revisions.get(spec["identity"], spec["revision"])
            if revision is None:
                continue
            pins.append(
                {
                    "identity": spec["identity"],
                    "kind": "remoteSourceControl",
                    "location": f"https://example.com/{spec['identity']}.git",
                    "state": {"revision": revision, "version": spec["version"]},
                }
            )
        pins.extend(extra_pins)
        lock = {
            "originHash": hashlib.sha256(manifest.read_bytes()).hexdigest(),
            "pins": pins,
            "version": 3,
        }
        (self.package / "Package.resolved").write_text(json.dumps(lock), encoding="utf-8")
        return lock

    def resolve(self, specs, revisions=None, extra_pins=()):
        self.write_lock(specs, revisions, extra_pins)
        problems = []
        with mock.patch.object(li, "CAD_LINKED_PACKAGES", tuple(specs)):
            result = li.resolve_cad_packages(problems, checkouts=self.checkouts, root=self.root)
        return problems, result

    def test_reviewed_row_is_declared_from_the_lock(self):
        spec = self.make_spec()
        problems, result = self.resolve([spec])
        self.assertEqual(problems, [])
        self.assertEqual([c["name"] for c in result["components"]], ["euclid"])
        self.assertEqual(result["components"][0]["noteKey"], li.CAD_NOTE_KEY)
        self.assertEqual(result["evidence"][0]["revision"], "a" * 40)
        self.assertEqual(result["evidence"][0]["evidence"], spec["notice"])
        self.assertEqual(result["documents"][0]["id"], "euclid")

    def test_moved_lock_revision_fails_closed(self):
        spec = self.make_spec()
        problems, result = self.resolve([spec], revisions={"euclid": "b" * 40})
        self.assertTrue(any("pin moved" in problem for problem in problems), problems)
        self.assertEqual(result["components"], [])
        self.assertEqual(result["documents"], [])
        self.assertEqual(result["evidence"], [])

    def test_missing_lock_pin_fails_closed(self):
        spec = self.make_spec()
        other = self.make_spec(identity="lrucache", title="LRUCache")
        problems, result = self.resolve([spec, other], revisions={"euclid": None})
        self.assertTrue(any("no longer declared" in problem for problem in problems), problems)
        self.assertEqual([c["name"] for c in result["components"]], ["lrucache"])

    def test_stale_lock_relative_to_the_manifest_fails_closed(self):
        spec = self.make_spec()
        self.write_lock([spec])
        (self.package / "Package.swift").write_bytes(b"// changed manifest\n")
        problems = []
        with mock.patch.object(li, "CAD_LINKED_PACKAGES", (spec,)):
            li.resolve_cad_packages(problems, checkouts=self.checkouts, root=self.root)
        self.assertTrue(any("stale" in problem for problem in problems), problems)

    def test_unreviewed_lock_identity_fails_closed(self):
        spec = self.make_spec()
        extra = {
            "identity": "newdep",
            "kind": "remoteSourceControl",
            "location": "https://example.com/newdep.git",
            "state": {"revision": "c" * 40, "version": "2.0.0"},
        }
        problems, _ = self.resolve([spec], extra_pins=[extra])
        self.assertTrue(any("unreviewed identity" in problem for problem in problems), problems)

    def test_missing_reviewed_copy_fails_closed(self):
        spec = self.make_spec()
        (self.root / spec["notice"]).unlink()
        problems, result = self.resolve([spec])
        self.assertTrue(any("reviewed license copy is missing" in p for p in problems), problems)
        self.assertEqual(result["components"], [])

    def test_edited_reviewed_copy_is_flagged_and_recorded(self):
        spec = self.make_spec()
        notice = self.root / spec["notice"]
        notice.write_text(MIT_TEXT + "\nmodified\n", encoding="utf-8")
        problems, result = self.resolve([spec])
        self.assertTrue(any("changed" in problem for problem in problems), problems)
        self.assertEqual(result["evidence"][0]["sha256"], li.sha256_file(notice))

    def test_wrong_checkout_revision_rejects_and_never_reads_the_license(self):
        spec = self.make_spec()
        make_checkout(self.checkouts, "euclid", "Apache License\nVersion 2.0\n")
        problems, result = self.resolve([spec])
        self.assertTrue(
            any("does not match the declared CAD pin" in p for p in problems), problems
        )
        self.assertEqual(result["evidence"][0]["sha256"], spec["sha256"])

    def test_same_revision_checkout_verifies_without_moving_the_evidence_path(self):
        notice_path = self.root / "FloeApp/Resources/Licenses/Euclid-LICENSE.txt"
        notice_path.parent.mkdir(parents=True, exist_ok=True)
        notice_path.write_text(MIT_TEXT, encoding="utf-8")
        actual = make_checkout(self.checkouts, "euclid", MIT_TEXT)
        spec = {
            "identity": "euclid",
            "revision": actual,
            "version": "1.0.0",
            "title": "Euclid",
            "license": "MIT",
            "sha256": li.sha256_file(notice_path),
            "notice": "FloeApp/Resources/Licenses/Euclid-LICENSE.txt",
        }
        problems, result = self.resolve([spec])
        self.assertEqual(problems, [])
        self.assertEqual(result["evidence"][0]["evidence"], spec["notice"])
        self.assertEqual(result["evidence"][0]["revision"], actual)

    def test_checkout_license_mismatch_is_flagged(self):
        notice_path = self.root / "FloeApp/Resources/Licenses/Euclid-LICENSE.txt"
        notice_path.parent.mkdir(parents=True, exist_ok=True)
        notice_path.write_text(MIT_TEXT, encoding="utf-8")
        actual = make_checkout(self.checkouts, "euclid", "Apache License\nVersion 2.0\n")
        spec = {
            "identity": "euclid",
            "revision": actual,
            "version": "1.0.0",
            "title": "Euclid",
            "license": "MIT",
            "sha256": li.sha256_file(notice_path),
            "notice": "FloeApp/Resources/Licenses/Euclid-LICENSE.txt",
        }
        problems, _ = self.resolve([spec])
        self.assertTrue(
            any("does not match the license file in the verified checkout" in p for p in problems),
            problems,
        )

    def test_unexpected_reviewed_license_text_is_flagged(self):
        spec = self.make_spec(text="Apache License\nVersion 2.0\n")
        problems, result = self.resolve([spec])
        self.assertTrue(any("reads as Apache-2.0" in p for p in problems), problems)
        self.assertEqual(result["components"][0]["license"], "Apache-2.0")


class NativeOCCTTests(unittest.TestCase):
    """Native OCCT (linked) and WASM OCCT (viewer) must be distinct declarations."""

    @classmethod
    def setUpClass(cls):
        cls.result = li.build()
        cls.manifest = cls.result["manifest"]
        cls.dependencies = json.loads(
            (ROOT / "ThirdParty/FloeCADKit/DEPENDENCIES.json").read_text()
        )

    def component(self, name: str) -> dict:
        return next(c for c in self.manifest["components"] if c["name"] == name)

    def test_native_occt_is_declared_separately_from_the_wasm_viewer(self):
        native = self.component(li.OCCT_NATIVE_NAME)
        self.assertEqual(native["section"], "engineering")
        self.assertEqual(native["version"], "7.8.1")
        self.assertEqual(native["license"], li.OCCT_NATIVE_LICENSE)
        self.assertEqual(native["noteKey"], "settings.licenses.note.occt_native")
        self.assertIn(
            self.dependencies["relink"]["occt"]["commit"], native["source"], native["source"]
        )
        wasm = self.component("Open CASCADE Technology (OCCT)")
        self.assertEqual(wasm["version"], "pinned by EngineeringViewers")
        self.assertEqual(wasm["license"], "LGPL-2.1 with OCCT exception")
        self.assertEqual(wasm["noteKey"], "settings.licenses.note.occt")
        self.assertNotEqual(native["license"], wasm["license"])
        self.assertNotEqual(native["name"], wasm["name"])

    def test_native_exception_is_exact_and_near_misses_are_rejected(self):
        self.assertIn(li.OCCT_NATIVE_LICENSE, li.EXCEPTIONS)
        violations, notices = li.license_gate(
            [{"name": "occt-native", "license": li.OCCT_NATIVE_LICENSE}]
        )
        self.assertEqual(violations, [])
        self.assertEqual(len(notices), 1)
        # The WebAssembly rows keep their own exact exception string.
        violations, _ = li.license_gate(
            [{"name": "occt-wasm", "license": "LGPL-2.1 with OCCT exception"}]
        )
        self.assertEqual(violations, [])
        for near_miss in (
            "LGPL-2.1",
            "LGPL-2.1-only with OCCT exception",
            li.OCCT_NATIVE_LICENSE + ".",
            "LGPL-2.1 with OCCT exception (native static libraries)",
            "LGPL-2.1 with OCCT exception (native static libraries linked via FloeCADKit "
            "OCCT binaryTarget)",
        ):
            violations, _ = li.license_gate([{"name": "x", "license": near_miss}])
            self.assertEqual(len(violations), 1, near_miss)

    def test_bundled_source_offer_records_the_pinned_facts(self):
        notice = (ROOT / li.OCCT_NATIVE_NOTICE).read_text(encoding="utf-8")
        occt = self.dependencies["relink"]["occt"]
        self.assertIn(occt["commit"], notice)
        self.assertIn(occt["tag"], notice)
        self.assertIn(occt["sourceArchive"], notice)
        self.assertIn("ThirdParty/FloeCADKit/OCCT_RELINK.md", notice)
        self.assertIn("relink/SOURCE_OFFER.md", notice)
        for artifact in self.dependencies["artifacts"]:
            self.assertIn(artifact["sha256"], notice, artifact["name"])
        for key, field in (("buildProgram", "sha256"), ("toolchain", "fileSha256")):
            self.assertIn(self.dependencies["relink"][key][field], notice, key)
        document = next(d for d in self.manifest["documents"] if d["id"] == "occt-native")
        self.assertTrue(document["required"])
        self.assertEqual(document["bundlePath"], "Licenses/OCCT-Native-SOURCE-OFFER.txt")
        self.assertEqual(document["section"], "engineering")
        rules = li.bundle_rules(li.PROJECT_YML.read_text())
        self.assertEqual(
            li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"]),
            document["bundlePath"],
        )

    def test_retained_relink_inputs_still_match_the_pinned_hashes(self):
        for key, field in (("buildProgram", "sha256"), ("toolchain", "fileSha256")):
            entry = self.dependencies["relink"][key]
            retained = ROOT / "ThirdParty/FloeCADKit" / entry["retainedCopy"]
            self.assertTrue(retained.is_file(), entry["retainedCopy"])
            self.assertEqual(li.sha256_file(retained), entry[field], entry["retainedCopy"])
        for relative in ("OCCT_RELINK.md", "relink/README.md", "relink/SOURCE_OFFER.md"):
            self.assertTrue((ROOT / "ThirdParty/FloeCADKit" / relative).is_file(), relative)

    def test_native_license_texts_are_the_linked_package_copies(self):
        for relative, bundled in (
            ("license.occt.txt", "FloeApp/Resources/EngineeringViewers/license.occt.txt"),
            (
                "OCCT_LGPL_EXCEPTION.txt",
                "FloeApp/Resources/EngineeringViewers/OCCT_LGPL_EXCEPTION.txt",
            ),
        ):
            package_copy = ROOT / "ThirdParty/FloeCADKit" / relative
            bundled_copy = ROOT / bundled
            self.assertTrue(package_copy.is_file(), relative)
            self.assertTrue(bundled_copy.is_file(), bundled)
            self.assertEqual(li.sha256_file(package_copy), li.sha256_file(bundled_copy), relative)

    def test_linked_slice_bytes_match_the_pins_when_present(self):
        if os.environ.get("FLOECAD_LOCAL_RELINK"):
            self.skipTest("deliberate local relink: official slice bytes are expected to differ")
        verified = 0
        for artifact in self.dependencies["artifacts"]:
            path = ROOT / "ThirdParty/FloeCADKit" / artifact["installPath"]
            if not path.is_file():
                continue
            self.assertEqual(path.stat().st_size, artifact["size"], artifact["name"])
            self.assertEqual(li.sha256_file(path), artifact["sha256"], artifact["name"])
            verified += 1
        # Slices are Git-ignored: a clean clone has none and verifies none.

    def test_occt_notes_and_titles_are_bilingual_and_aligned(self):
        catalog = json.loads(li.XSTRINGS.read_text(encoding="utf-8"))["strings"]
        for note_id in ("occt", "occt_native", "cad_packages"):
            note = next(n for n in self.manifest["notes"] if n["id"] == note_id)
            en = catalog[note["textKey"]]["localizations"]["en"]["stringUnit"]["value"]
            self.assertEqual(en, note["fallback"], note_id)
            self.assertTrue(
                catalog[note["textKey"]]["localizations"]["zh-Hans"]["stringUnit"]["value"].strip(),
                note_id,
            )
        for title_key, fallback in (
            ("settings.licenses.document.occt_native.title", "OCCT 7.8.1 native static libraries (source offer)"),
            ("settings.licenses.document.euclid.title", "Euclid"),
            ("settings.licenses.document.lrucache.title", "LRUCache"),
            ("settings.licenses.document.shapescript.title", "ShapeScript"),
            ("settings.licenses.document.svgpath.title", "SVGPath"),
        ):
            entry = catalog[title_key]["localizations"]
            self.assertEqual(entry["en"]["stringUnit"]["value"], fallback, title_key)
            self.assertTrue(entry["zh-Hans"]["stringUnit"]["value"].strip(), title_key)


class OCCTNativeRecordTests(unittest.TestCase):
    """The bundled OCCT record must fail closed when a pinned fact changes."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        package = self.root / "ThirdParty/FloeCADKit"
        (package / "relink").mkdir(parents=True)
        for relative in (
            "DEPENDENCIES.json",
            "OCCT_RELINK.md",
            "license.occt.txt",
            "OCCT_LGPL_EXCEPTION.txt",
            "relink/build_occt_ios.sh",
            "relink/ios.toolchain.cmake",
            "relink/README.md",
            "relink/SOURCE_OFFER.md",
        ):
            shutil.copy(ROOT / "ThirdParty/FloeCADKit" / relative, package / relative)
        (self.root / "FloeApp/Resources/Licenses").mkdir(parents=True)
        (self.root / "FloeApp/Resources/EngineeringViewers").mkdir(parents=True)
        shutil.copy(ROOT / li.OCCT_NATIVE_NOTICE, self.root / li.OCCT_NATIVE_NOTICE)
        for relative in ("license.occt.txt", "OCCT_LGPL_EXCEPTION.txt"):
            shutil.copy(
                ROOT / "FloeApp/Resources/EngineeringViewers" / relative,
                self.root / "FloeApp/Resources/EngineeringViewers" / relative,
            )
        self.notice = self.root / li.OCCT_NATIVE_NOTICE
        self.dependencies = json.loads(
            (self.root / "ThirdParty/FloeCADKit/DEPENDENCIES.json").read_text()
        )

    def problems(self):
        problems = []
        li.occt_native_problems(problems, root=self.root)
        return problems

    def test_complete_record_has_no_problems(self):
        self.assertEqual(self.problems(), [])

    def test_missing_slice_pin_in_the_notice_is_flagged(self):
        digest = self.dependencies["artifacts"][0]["sha256"]
        self.notice.write_text(
            self.notice.read_text(encoding="utf-8").replace(digest, "0" * 64),
            encoding="utf-8",
        )
        problems = self.problems()
        self.assertTrue(any("does not record the pinned slice" in p for p in problems), problems)

    def test_changed_retained_relink_input_is_flagged(self):
        script = self.root / "ThirdParty/FloeCADKit/relink/build_occt_ios.sh"
        script.write_bytes(script.read_bytes() + b"\n# modified\n")
        problems = self.problems()
        self.assertTrue(any("retained OCCT relink input changed" in p for p in problems), problems)

    def test_missing_bundled_record_is_flagged(self):
        self.notice.unlink()
        problems = self.problems()
        self.assertTrue(any("source offer is missing" in p for p in problems), problems)

    def test_changed_bundled_license_text_is_flagged(self):
        bundled = self.root / "FloeApp/Resources/EngineeringViewers/OCCT_LGPL_EXCEPTION.txt"
        bundled.write_bytes(bundled.read_bytes() + b"\nmodified\n")
        problems = self.problems()
        self.assertTrue(
            any("no longer matches the linked library's copy" in p for p in problems), problems
        )

    def test_missing_artifact_pins_are_flagged(self):
        (self.root / "ThirdParty/FloeCADKit/DEPENDENCIES.json").unlink()
        problems = self.problems()
        self.assertTrue(any("artifact pins are missing" in p for p in problems), problems)

    def test_notice_must_name_the_relink_records(self):
        self.notice.write_text(
            self.notice.read_text(encoding="utf-8").replace("OCCT_RELINK.md", "OTHER.md"),
            encoding="utf-8",
        )
        problems = self.problems()
        self.assertTrue(
            any("does not record the pinned relink record" in p for p in problems), problems
        )


class OpenShapeAttributionTests(unittest.TestCase):
    """FloeCADKit's OpenShape3D-derived MIT code must be declared and bound.

    OpenShape3D is not a resolved package (FloeCADKit is the modified
    extraction), so the reviewed row binds ThirdParty/FloeCADKit/DEPENDENCIES.json
    plus the tracked and bundled MIT copies instead of a lock pin, and the
    component must stay truthful about the local modifications.
    """

    @classmethod
    def setUpClass(cls):
        cls.result = li.build()
        cls.manifest = cls.result["manifest"]
        cls.dependencies = json.loads(
            (ROOT / "ThirdParty/FloeCADKit/DEPENDENCIES.json").read_text()
        )

    def test_derived_component_document_and_evidence_are_declared(self):
        spec = li.OPENSHAPE_COMPONENT
        record = self.dependencies["sources"][spec["identity"]]
        component = next(
            c for c in self.manifest["components"] if c["name"] == spec["identity"]
        )
        self.assertEqual(component["license"], "MIT")
        self.assertEqual(component["section"], "swift")
        self.assertEqual(component["noteKey"], li.OPENSHAPE_NOTE_KEY)
        self.assertEqual(component["version"], record["commit"])
        self.assertIn(record["commit"], component["source"])
        self.assertEqual(component["evidence"], spec["notice"])
        document = next(
            d for d in self.manifest["documents"] if d["id"] == spec["identity"]
        )
        self.assertTrue(document["required"])
        self.assertEqual(document["section"], "swift")
        self.assertEqual(document["bundlePath"], "Licenses/OpenShape3D-LICENSE.txt")
        self.assertEqual(document["titleFallback"], spec["title"])
        rules = li.bundle_rules(li.PROJECT_YML.read_text())
        self.assertEqual(
            li.bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"]),
            document["bundlePath"],
        )
        row = next(
            r
            for r in self.result["evidence"]["licenses"]
            if r["identity"] == spec["identity"]
        )
        self.assertEqual(row["license"], "MIT")
        self.assertEqual(row["revision"], record["commit"])
        self.assertEqual(row["source"], record["repositoryClone"])
        self.assertEqual(row["evidence"], spec["notice"])
        self.assertEqual(li.sha256_file(ROOT / row["evidence"]), row["sha256"])

    def test_bundled_notice_is_the_linked_packages_exact_mit_copy(self):
        spec = li.OPENSHAPE_COMPONENT
        package_copy = ROOT / spec["packageCopy"]
        bundled_copy = ROOT / spec["notice"]
        self.assertTrue(package_copy.is_file(), spec["packageCopy"])
        self.assertTrue(bundled_copy.is_file(), spec["notice"])
        self.assertEqual(package_copy.read_bytes(), bundled_copy.read_bytes())
        self.assertEqual(li.sha256_file(bundled_copy), spec["sha256"])
        text = bundled_copy.read_text(encoding="utf-8")
        self.assertIn("MIT License", text)
        self.assertIn("Copyright (c) 2026 Laan Labs and the openshape3d contributors", text)
        self.assertEqual(li.classify_license(text), "MIT")

    def test_note_declares_a_modified_derived_copy_not_an_unmodified_library(self):
        note = next(n for n in self.manifest["notes"] if n["id"] == "openshape3d")
        text = note["fallback"]
        self.assertIn("locally modified extraction", text)
        self.assertIn("not an unmodified upstream library", text)
        self.assertIn(li.OPENSHAPE_COMPONENT["revision"], text)
        self.assertIn("PATCHES.md", text)

    def test_openshape_note_and_title_are_bilingual_and_aligned(self):
        catalog = json.loads(li.XSTRINGS.read_text(encoding="utf-8"))["strings"]
        note = next(n for n in self.manifest["notes"] if n["id"] == "openshape3d")
        entry = catalog[note["textKey"]]["localizations"]
        self.assertEqual(entry["en"]["stringUnit"]["value"], note["fallback"])
        self.assertTrue(entry["zh-Hans"]["stringUnit"]["value"].strip())
        title_key = "settings.licenses.document.openshape3d.title"
        title = catalog[title_key]["localizations"]
        self.assertEqual(title["en"]["stringUnit"]["value"], li.OPENSHAPE_COMPONENT["title"])
        self.assertTrue(title["zh-Hans"]["stringUnit"]["value"].strip())


class OpenShapeRecordTests(unittest.TestCase):
    """resolve_openshape_attribution must fail closed on source/copy drift."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        package = self.root / "ThirdParty/FloeCADKit"
        package.mkdir(parents=True)
        shutil.copy(
            ROOT / li.OPENSHAPE_COMPONENT["dependencies"], package / "DEPENDENCIES.json"
        )
        shutil.copy(
            ROOT / li.OPENSHAPE_COMPONENT["packageCopy"],
            package / "LICENSE-OpenShape3D-MIT.txt",
        )
        (self.root / "FloeApp/Resources/Licenses").mkdir(parents=True)
        shutil.copy(
            ROOT / li.OPENSHAPE_COMPONENT["notice"],
            self.root / li.OPENSHAPE_COMPONENT["notice"],
        )
        self.dependencies_path = package / "DEPENDENCIES.json"
        self.package_copy = package / "LICENSE-OpenShape3D-MIT.txt"
        self.bundled_copy = self.root / li.OPENSHAPE_COMPONENT["notice"]

    def resolve(self):
        problems = []
        result = li.resolve_openshape_attribution(problems, root=self.root)
        return problems, result

    def rewrite_source(self, mutate):
        dependencies = json.loads(self.dependencies_path.read_text(encoding="utf-8"))
        mutate(dependencies["sources"]["openshape3d"])
        self.dependencies_path.write_text(json.dumps(dependencies), encoding="utf-8")

    def test_complete_record_declares_the_component_without_problems(self):
        problems, result = self.resolve()
        self.assertEqual(problems, [])
        self.assertEqual([c["name"] for c in result["components"]], ["openshape3d"])
        self.assertEqual([d["id"] for d in result["documents"]], ["openshape3d"])
        self.assertEqual([r["identity"] for r in result["evidence"]], ["openshape3d"])

    def test_missing_source_record_is_flagged(self):
        self.dependencies_path.unlink()
        problems, result = self.resolve()
        self.assertEqual(result["components"], [])
        self.assertTrue(any("source record is missing" in p for p in problems), problems)

    def test_unreadable_source_record_is_flagged(self):
        self.dependencies_path.write_text("{ not json", encoding="utf-8")
        problems, _ = self.resolve()
        self.assertTrue(any("cannot be read" in p for p in problems), problems)

    def test_moved_commit_is_flagged(self):
        self.rewrite_source(lambda source: source.update(commit="0" * 40))
        problems, _ = self.resolve()
        self.assertTrue(
            any("recorded source commit moved" in p for p in problems), problems
        )

    def test_moved_repository_is_flagged(self):
        self.rewrite_source(
            lambda source: source.update(repositoryClone="https://example.com/other.git")
        )
        problems, _ = self.resolve()
        self.assertTrue(
            any("recorded source repositoryClone moved" in p for p in problems), problems
        )

    def test_missing_linked_package_copy_is_flagged(self):
        self.package_copy.unlink()
        problems, result = self.resolve()
        self.assertEqual(result["components"], [])
        self.assertTrue(
            any("tracked upstream MIT notice is missing" in p for p in problems), problems
        )

    def test_edited_linked_package_copy_is_flagged(self):
        self.package_copy.write_bytes(self.package_copy.read_bytes() + b"\nmodified\n")
        problems, _ = self.resolve()
        self.assertTrue(
            any("tracked MIT notice" in p and "changed" in p for p in problems), problems
        )

    def test_missing_bundled_copy_is_flagged(self):
        self.bundled_copy.unlink()
        problems, result = self.resolve()
        self.assertEqual(result["components"], [])
        self.assertTrue(
            any("bundled MIT notice is missing" in p for p in problems), problems
        )

    def test_bundled_copy_that_differs_from_the_linked_copy_is_flagged(self):
        self.bundled_copy.write_bytes(b"different MIT text\n")
        problems, _ = self.resolve()
        self.assertTrue(
            any("no longer matches the linked package's copy" in p for p in problems),
            problems,
        )

    def test_non_mit_text_is_flagged(self):
        self.package_copy.write_text("Apache License\nVersion 2.0\n", encoding="utf-8")
        self.bundled_copy.write_text("Apache License\nVersion 2.0\n", encoding="utf-8")
        problems, _ = self.resolve()
        self.assertTrue(any("expected MIT" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
