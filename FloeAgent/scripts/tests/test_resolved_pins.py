import hashlib
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from resolved_pins import (
    resolved_pins,
    application_local_pins,
    application_pins,
    app_pin_matches,
    verify_resolution,
    same_pin,
)


def pin(identity, location, *, revision="a" * 40, version=None, branch=None):
    state = {"revision": revision}
    if version is not None:
        state["version"] = version
    if branch is not None:
        state["branch"] = branch
    return {"identity": identity, "location": location, "state": state}


def lock_v3(pins):
    return json.dumps({"version": 3, "pins": pins})


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ResolvedPinsTests(unittest.TestCase):
    def test_revision_only_app_pin_keeps_committed_display_state(self):
        # XcodeGen cannot express a semver next to a revision, so a revision-only
        # app declaration is the immutable form. The repository and revision must
        # match the committed lock exactly, the declaration must not smuggle in
        # another revision, and the committed state (with its display version)
        # stays in the distribution inventory.
        pin = {
            "identity": "zipfoundation",
            "location": "https://github.com/weichsel/ZIPFoundation.git",
            "state": {"revision": "2" * 40, "version": "0.9.20"},
        }
        declared = {**pin, "state": {"revision": "2" * 40}}
        self.assertTrue(app_pin_matches(pin, declared))
        self.assertEqual(verify_resolution([], [pin], [declared]), [pin])
        self.assertEqual(verify_resolution([pin], [pin], [declared]), [pin])
        for changed in (
            {**declared, "state": {"revision": "3" * 40}},
            {**declared, "identity": "other"},
            {**declared, "location": "https://github.com/other/ZIPFoundation.git"},
        ):
            self.assertFalse(app_pin_matches(pin, changed))
            with self.assertRaises(ValueError):
                verify_resolution([], [pin], [changed])
        self.assertFalse(app_pin_matches(None, declared))
        self.assertFalse(app_pin_matches(pin, None))

    def test_github_git_suffix_does_not_change_a_pin(self):
        pin = {"identity": "swift-system", "location": "https://github.com/apple/swift-system.git",
               "state": {"revision": "a" * 40, "version": "1.8.0"}}
        alias = {**pin, "location": pin["location"].removesuffix(".git")}
        self.assertTrue(same_pin(pin, alias))
        self.assertEqual(verify_resolution([alias], [pin], []), [alias])
        for changed in (
            {**alias, "state": {"revision": "b" * 40, "version": "1.8.0"}},
            {**alias, "location": "https://github.com/other/swift-system"},
            {**alias, "location": "https://example.com/apple/swift-system"},
            {**alias, "identity": "other"},
        ):
            self.assertFalse(same_pin(pin, changed))
        self.assertFalse(same_pin({**pin, "location": "https://example.com/repo.git"},
                                  {**pin, "location": "https://example.com/repo"}))

    def setUp(self):
        # swift package resolve intentionally removes the Xcode-only Whisper
        # pin from the working host lock. Expected distribution fixtures must
        # come from the immutable source, just like the production checker.
        document = json.loads(subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"],
            cwd=Path(__file__).resolve().parents[2], text=True))
        # The tracked host lock is serialized by SwiftPM in either the v1
        # (object.pins/repositoryURL) or the v2/v3 (pins/location) schema.
        # Normalize to the v2/v3 shape the tests below exercise.
        if document.get("version") in (2, 3):
            pins = document["pins"]
        else:
            pins = [
                {"identity": p["identity"], "location": p["location"], "state": p["state"]}
                for p in resolved_pins(document)
            ]
        self.current = {"version": 3, "pins": pins}

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


class ApplicationLocalPinTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "FloeAgent"
        self.root.mkdir()
        self.cad = self.root / "ThirdParty" / "FloeCADKit"
        self.cad.mkdir(parents=True)
        self.legacy = self.root / "ThirdParty" / "Legacy"
        self.legacy.mkdir(parents=True)
        self.plain = self.root / "ThirdParty" / "Plain"
        self.plain.mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def project(self, *entries):
        return "packages:\n" + "".join(
            f"  {name}:\n{body}" for name, body in entries
        ) + "targets:\n  App:\n    type: application\n"

    def write_lock(self, path, pins):
        path.write_text(lock_v3(pins), encoding="utf-8")

    def local_project(self):
        return self.project(
            ("Root", "    path: .  # the committed host lock\n"),
            ("FloeCADKit", "    path: ThirdParty/FloeCADKit\n"),
            ("Legacy", "    path: ThirdParty/Legacy  # v1 lock\n"),
            ("Plain", "    path: ThirdParty/Plain\n"),
        )

    def test_reads_only_declared_direct_local_locks(self):
        # The root path is the committed host lock, not an App-local source.
        self.write_lock(self.root / "Package.resolved", [
            pin("root-only", "https://example.org/root-only.git")])
        self.write_lock(self.cad / "Package.resolved", [
            pin("euclid", "https://github.com/nicklockwood/Euclid.git",
                revision="a" * 40, version="0.9.6")])
        # A nested package lock is not a direct dependency of the declared
        # package and must never be pulled into the App closure.
        nested = self.cad / "Nested"
        nested.mkdir()
        self.write_lock(nested / "Package.resolved", [
            pin("nested-only", "https://example.org/nested-only.git")])
        # A v1 lock derives its identity from the repository URL exactly like
        # the existing host lock reader; the package display name is irrelevant.
        (self.legacy / "Package.resolved").write_text(json.dumps({
            "version": 1,
            "object": {"pins": [{
                "package": "Legacy Display Name",
                "repositoryURL": "https://github.com/example/LegacyCAD.git",
                "state": {"branch": None, "revision": "b" * 40,
                          "version": "1.2.3"},
            }]},
        }), encoding="utf-8")
        # A declared local package without a lock contributes nothing.
        self.assertEqual(
            application_local_pins(self.local_project(), self.root),
            [
                pin("euclid", "https://github.com/nicklockwood/Euclid.git",
                    revision="a" * 40, version="0.9.6"),
                pin("legacycad", "https://github.com/example/LegacyCAD.git",
                    revision="b" * 40, version="1.2.3"),
            ],
        )

    def test_duplicate_across_local_locks_must_agree(self):
        shared = pin("shared", "https://example.org/shared.git")
        self.write_lock(self.cad / "Package.resolved", [shared])
        self.write_lock(self.legacy / "Package.resolved", [shared])
        self.assertEqual(
            application_local_pins(self.local_project(), self.root), [shared])
        conflicting = {**shared, "state": {"revision": "b" * 40}}
        self.write_lock(self.legacy / "Package.resolved", [conflicting])
        with self.assertRaisesRegex(ValueError, "Conflicting resolved dependency"):
            application_local_pins(self.local_project(), self.root)

    def test_invalid_local_lock_fails(self):
        (self.cad / "Package.resolved").write_text(
            '{"version": 3, "pins": []}', encoding="utf-8")
        with self.assertRaises(ValueError):
            application_local_pins(self.local_project(), self.root)
        (self.cad / "Package.resolved").write_text(
            '{"version": 3, "pins": [{"identity": "x", '
            '"location": "https://example.org/x.git", "state": {"branch": "main"}}]}',
            encoding="utf-8")
        with self.assertRaises(ValueError):
            application_local_pins(self.local_project(), self.root)

    def test_path_escape_and_ambiguous_declarations_fail(self):
        outside = Path(self._tmp.name) / "Outside"
        outside.mkdir()
        self.write_lock(outside / "Package.resolved", [
            pin("outside", "https://example.org/outside.git")])
        for body in (
            "    path: ../Outside\n",
            f"    path: {outside}\n",
            "    path: ../../Outside\n",
        ):
            project = self.project(("Escape", body))
            with self.subTest(body=body), self.assertRaisesRegex(
                    ValueError, "escapes the project directory"):
                application_local_pins(project, self.root)

        link = self.root / "ThirdParty" / "Linked"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")
        project = self.project(("Linked", "    path: ThirdParty/Linked\n"))
        with self.assertRaisesRegex(ValueError, "escapes the project directory"):
            application_local_pins(project, self.root)

        ambiguous = self.project(
            ("Mixed", "    path: ThirdParty/FloeCADKit\n"
                      "    url: https://example.org/Mixed.git\n"
                      "    revision: %s\n" % ("c" * 40)))
        with self.assertRaisesRegex(ValueError, "mixes a local path"):
            application_local_pins(ambiguous, self.root)

    def test_local_pin_cannot_replace_a_committed_pin(self):
        host = pin("shared", "https://example.org/shared.git",
                   revision="a" * 40, version="1.0.0")
        conflicting = {**host, "state": {"revision": "b" * 40,
                                         "version": "1.0.0"}}
        with self.assertRaisesRegex(ValueError, "conflicts with committed lock"):
            verify_resolution([], [host], [], [conflicting])

    def test_local_pin_may_agree_with_a_direct_declaration(self):
        host = pin("zipfoundation",
                   "https://github.com/weichsel/ZIPFoundation.git",
                   revision="2" * 40, version="0.9.20")
        declared = {**host, "state": {"revision": "2" * 40}}
        self.assertEqual(
            verify_resolution([host], [host], [declared], [host]),
            [host])
        conflicting = {**host, "state": {"revision": "3" * 40,
                                         "version": "0.9.20"}}
        with self.assertRaises(ValueError):
            verify_resolution([], [host], [declared], [conflicting])

    def test_unknown_missing_changed_branch_and_semver_pins_fail(self):
        host = pin("shared", "https://example.org/shared.git",
                   revision="a" * 40, version="1.0.0")
        unknown = pin("unknown", "https://example.org/unknown.git")
        for actual in (
            [host, unknown],
            [],
            [{**host, "state": {"revision": "b" * 40, "version": "1.0.0"}}],
            [{**host, "state": {"revision": "a" * 40, "version": "1.0.1"}}],
            [{**host, "state": {"revision": "a" * 40, "branch": "main"}}],
            [{**host,
              "location": "https://example.org/other.git"}],
        ):
            with self.subTest(actual=actual), self.assertRaises(ValueError):
                verify_resolution(actual, [host], [], [])

    def test_missing_local_pin_is_allowed_for_a_host_seed(self):
        host = pin("shared", "https://example.org/shared.git",
                   revision="a" * 40, version="1.0.0")
        local = pin("cad", "https://example.org/cad.git",
                    revision="b" * 40, version="2.0.0")
        merged = verify_resolution([host], [host], [], [local])
        self.assertEqual(merged, [local, host])
        # Once the pin is present it must match the local lock exactly.
        changed = {**local, "state": {"revision": "c" * 40,
                                      "version": "2.0.0"}}
        with self.assertRaises(ValueError):
            verify_resolution([host, changed], [host], [], [local])


class DirectRevisionMetadataTests(unittest.TestCase):
    def setUp(self):
        self.host = pin(
            "zipfoundation", "https://github.com/weichsel/ZIPFoundation.git",
            revision="2" * 40, version="0.9.20")
        self.declared = {
            **self.host,
            "state": {"revision": self.host["state"]["revision"]},
        }

    def test_revision_only_actual_keeps_committed_display_version(self):
        actual = {**self.host, "state": {"revision": "2" * 40}}
        self.assertEqual(
            verify_resolution([actual], [self.host], [self.declared]),
            [self.host])
        # A revision-only actual state is only accepted for the exact directly
        # declared pin, never for an ordinary host dependency.
        with self.assertRaises(ValueError):
            verify_resolution([actual], [self.host], [])

    def test_any_other_metadata_change_is_rejected(self):
        revision = self.host["state"]["revision"]
        cases = (
            {**self.host, "state": {"revision": revision, "version": "9.9.9"}},
            {**self.host, "state": {"revision": revision, "branch": "main"}},
            {**self.host, "state": {"revision": revision, "version": "0.9.20",
                                    "unknown": "value"}},
            {**self.host, "state": {"revision": "3" * 40}},
            {**self.host,
             "location": "https://github.com/other/ZIPFoundation.git",
             "state": {"revision": revision}},
        )
        for actual in cases:
            with self.subTest(actual=actual), self.assertRaises(ValueError):
                verify_resolution([actual], [self.host], [self.declared])
        # A declaration that itself carries extra state does not authorize the
        # display-version omission.
        declared_with_version = {**self.host}
        with self.assertRaises(ValueError):
            verify_resolution([{**self.host, "state": {"revision": revision}}],
                              [self.host], [declared_with_version])
        # An expected pin with a branch is not the immutable pair the narrow
        # normalization covers, even when its revision matches.
        branched_host = {**self.host,
                         "state": {"revision": revision, "version": "0.9.20",
                                   "branch": "main"}}
        with self.assertRaises(ValueError):
            verify_resolution([{**self.host, "state": {"revision": revision}}],
                              [branched_host], [self.declared])

    def test_actual_with_exact_version_still_matches(self):
        actual = {**self.host, "state": {"revision": "2" * 40,
                                         "version": "0.9.20"}}
        self.assertEqual(
            verify_resolution([actual], [self.host], [self.declared]),
            [self.host])


class RealApplicationGraphTests(unittest.TestCase):
    """Exercise the committed root lock and the real FloeCADKit local lock."""

    def setUp(self):
        self.root = Path(__file__).resolve().parents[2]
        self.project_path = self.root / "project.yml"
        self.project = self.project_path.read_text(encoding="utf-8")
        document = json.loads(subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"],
            cwd=self.root, text=True))
        self.committed = resolved_pins(document)
        self.app = application_pins(self.project)
        self.local = application_local_pins(self.project, self.root)
        self.local_lock = self.root / "ThirdParty" / "FloeCADKit" / "Package.resolved"
        self.host_lock = self.root / "Package.resolved"

    def test_complete_graph_with_local_closure_and_revision_only_zip(self):
        self.assertEqual(len(self.local), 6)
        committed_by_identity = {p["identity"]: p for p in self.committed}
        zip_pin = committed_by_identity["zipfoundation"]
        self.assertEqual(zip_pin["state"]["version"], "0.9.20")
        actual = [p for p in self.committed if p["identity"] != "zipfoundation"]
        actual.append({**zip_pin, "state": {"revision": zip_pin["state"]["revision"]}})
        actual += self.local
        before = {path: sha256(path) for path in
                  (self.project_path, self.host_lock, self.local_lock)}
        combined = verify_resolution(actual, self.committed, self.app, self.local)
        after = {path: sha256(path) for path in
                 (self.project_path, self.host_lock, self.local_lock)}
        self.assertEqual(before, after, "verification must be read-only")
        self.assertEqual(len(combined), len(self.committed) + len(self.local))
        by_identity = {p["identity"]: p for p in combined}
        self.assertEqual(by_identity["zipfoundation"]["state"], zip_pin["state"])
        self.assertEqual(set(by_identity), set(committed_by_identity) | {
            p["identity"] for p in self.local})

    def test_incomplete_host_lock_is_a_valid_seed_and_completes_locally(self):
        seed = verify_resolution(self.committed, self.committed, self.app, self.local)
        self.assertEqual(len(seed), len(self.committed) + len(self.local))
        self.assertEqual(
            {p["identity"] for p in seed},
            {p["identity"] for p in self.committed} |
            {p["identity"] for p in self.local})

    def test_changed_local_revision_fails_against_the_real_graph(self):
        changed_local = [
            {**self.local[0],
             "state": {**self.local[0]["state"], "revision": "0" * 40}},
            *self.local[1:],
        ]
        actual = self.committed + changed_local
        with self.assertRaises(ValueError):
            verify_resolution(actual, self.committed, self.app, self.local)


if __name__ == "__main__":
    unittest.main()
