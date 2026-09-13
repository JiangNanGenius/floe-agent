import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from resolved_pins import resolved_pins


class ResolvedPinsTests(unittest.TestCase):
    def setUp(self):
        self.current = json.loads((Path(__file__).resolve().parents[2] / "Package.resolved").read_text())

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


if __name__ == "__main__":
    unittest.main()
