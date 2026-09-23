import hashlib
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent  # FloeAgent/
REPO = ROOT.parent
sys.path.insert(0, str(SCRIPTS))

import license_inventory as li  # noqa: E402


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
        for required in ("occt", "occt-exception", "whisperkit", "ide-notice", "royalvnc", "pdfium", "libarchive"):
            self.assertIn(required, ids)


if __name__ == "__main__":
    unittest.main()
