import json
from pathlib import Path
import sys
import subprocess
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from resolved_pins import resolved_pins, application_pins, verify_resolution


class ResolvedPinsTests(unittest.TestCase):
    def setUp(self):
        # swift package resolve intentionally removes the Xcode-only Whisper
        # pin from the working host lock. Expected distribution fixtures must
        # come from the immutable source, just like the production checker.
        self.current = json.loads(subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"],
            cwd=Path(__file__).resolve().parents[2], text=True))

    def test_legacy_schema_preserves_every_committed_dependency(self):
        legacy = {"version": 1, "object": {"pins": [
            {"package": "Display Name", "repositoryURL": p["location"],
             "state": {"branch": None, "version": None, **p["state"]}}
            for p in self.current["pins"]]}}
        self.assertEqual(resolved_pins(legacy), resolved_pins(self.current))

    def test_version_two_and_three_are_equivalent(self):
        self.assertEqual(resolved_pins({**self.current, "version": 2}),
                         resolved_pins({**self.current, "version": 3}))

    def test_missing_empty_and_unknown_schemas_fail(self):
        for document in ({}, {"version": 4, "pins": self.current["pins"]},
                         {"version": 3}, {"version": 3, "pins": []},
                         {"version": 1, "object": {}}):
            with self.subTest(document=document), self.assertRaises(ValueError):
                resolved_pins(document)

    def test_invalid_or_mutable_pin_fails(self):
        pin = self.current["pins"][0]
        for replacement in ({"state": {}}, {"state": {"branch": "main"}},
                            {"location": ""}, {"identity": ""}):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                resolved_pins({"version": 3, "pins": [{**pin, **replacement}]})

    def test_duplicate_identity_fails(self):
        with self.assertRaises(ValueError):
            resolved_pins({"version": 3, "pins": [self.current["pins"][0]] * 2})

    def test_host_resolution_keeps_app_only_pin_in_distribution_inventory(self):
        project = (Path(__file__).resolve().parents[2] / "project.yml").read_text()
        app = application_pins(project)
        expected = resolved_pins(self.current)
        host = [p for p in expected if p["identity"] not in {p["identity"] for p in app}]
        self.assertEqual(verify_resolution(host, expected, app), expected)
        self.assertEqual(verify_resolution(expected, expected, app), expected)

    def test_host_missing_or_changed_pin_and_app_drift_fail(self):
        expected = resolved_pins(self.current)
        app = application_pins((Path(__file__).resolve().parents[2] / "project.yml").read_text())
        host = [p for p in expected if p["identity"] not in {p["identity"] for p in app}]
        changed = [{**host[0], "state": {"revision": "0" * 40}}, *host[1:]]
        wrong_app = [{**app[0], "state": {"revision": "0" * 40}}]
        for current, application in ((host[1:], app), (changed, app), (host, wrong_app)):
            with self.subTest(current=current), self.assertRaises(ValueError):
                verify_resolution(current, expected, application)

    def test_mutable_application_declaration_fails(self):
        with self.assertRaises(ValueError):
            application_pins("packages:\n  Test:\n    url: https://example.org/Test.git\n    branch: main\n")


if __name__ == "__main__":
    unittest.main()
