import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import resolved_pins as rp


RETIRED_PINS = [
    {"identity": "libgit2", "location": "https://github.com/ibrahimcetin/libgit2.git",
     "state": {"revision": "52287b0914f300f916b58fec80e13d8dd8f6824f", "version": "1.9.2"}},
    {"identity": "swiftgitx", "location": "https://github.com/ibrahimcetin/SwiftGitX.git",
     "state": {"revision": "fcfb71e3dcbbaa70d120b98b7477ce173074aec3", "version": "0.4.0"}},
    {"identity": "swift-crypto", "location": "https://github.com/apple/swift-crypto.git",
     "state": {"revision": "95ba0316a9b733e92bb6b071255ff46263bbe7dc", "version": "3.15.1"}},
]
CITADEL_PIN = {"identity": "citadel", "location": "https://github.com/orlandos-nl/Citadel.git",
               "state": {"revision": "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"}}


class HostGraphAdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "FloeAgent"
        self.root.mkdir()
        self.source = Path(os.environ.get("FLOE_LICENSE_TEST_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
        self.host = {"identity": "eventsource", "location": "https://github.com/mattt/EventSource.git",
                     "state": {"revision": "86b5096ac59ab46e66bd1f6377c604bc1dab0bc2", "version": "1.5.1"}}
        self.standalone = {**self.host, "state": {"revision": "bb4b61273b5a976bb571859c17f903ebc3439df1", "version": "1.6.0"}}
        self.write_lock(self.root / "Package.resolved", [self.host])
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            directory = self.root / policy["path"]
            directory.mkdir(parents=True)
            manifest = (self.source / policy["path"] / "Package.swift").read_bytes()
            self.assertEqual(hashlib.sha256(manifest).hexdigest(), policy["manifestSHA256"])
            (directory / "Package.swift").write_bytes(manifest)
            self.write_lock(directory / "Package.resolved", [self.standalone])

    def write_lock(self, path, pins):
        path.write_text(json.dumps({"version": 3, "pins": pins}))

    def project(self, name=None, path=None):
        names = [name] if name else list(rp.HOST_GRAPH_ADAPTERS)
        return "packages:\n" + "".join("  " + key + ":\n    path: " + (path or rp.HOST_GRAPH_ADAPTERS[key]["path"]) + "\n" for key in names)

    def install_vendored_proofs(self):
        # Copy real reviewed manifests/provenance, without resolving packages
        # or copying/hashing their full source trees.
        (self.root / "Package.swift").write_bytes((self.source / "Package.swift").read_bytes())
        for policy in rp.RETIRED_HOST_GRAPH_PINS.values():
            directory = self.root / policy["path"]
            directory.mkdir(parents=True, exist_ok=True)
            for filename, key in (("Package.swift", "manifestSHA256"),
                                  (policy["provenance"], "provenanceSHA256")):
                source = self.source / policy["path"] / filename
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), policy[key])
                shutil.copyfile(source, directory / filename)

    def install_media_exchange(self, pins):
        policy = rp.LOCAL_LOCK_RETIRED_REFERENCES["FloeMediaExchange"]
        directory = self.root / policy["path"]
        directory.mkdir(parents=True, exist_ok=True)
        manifest = (self.source / policy["path"] / "Package.swift").read_bytes()
        self.assertEqual(hashlib.sha256(manifest).hexdigest(), policy["manifestSHA256"])
        (directory / "Package.swift").write_bytes(manifest)
        self.write_lock(directory / "Package.resolved", pins)
        return "packages:\n  FloeMediaExchange:\n    path: " + policy["path"] + "\n"

    def test_both_reviewed_standalone_versions_are_not_app_authorities(self):
        self.assertEqual(rp.application_local_pins(self.project(), self.root), [])
        self.assertEqual(rp.verify_resolution([self.host], [self.host], [], []), [self.host])
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            no_suffix = {**self.standalone, "location": self.host["location"].removesuffix(".git")}
            self.write_lock(self.root / policy["path"] / "Package.resolved", [no_suffix])
            self.assertEqual(rp.application_local_pins(self.project(name), self.root), [])

    def test_manifest_change_and_new_direct_remote_fail(self):
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            path = self.root / policy["path"] / "Package.swift"
            original = path.read_bytes()
            for changed in [original + b"\n// changed\n", original.replace(b"dependencies:[", b'dependencies:[.package(url:"https://example.invalid/new",from:"1.0.0"),', 1)]:
                self.assertNotEqual(changed, original)
                path.write_bytes(changed)
                with self.assertRaisesRegex(ValueError, "manifest differs"):
                    rp.application_local_pins(self.project(name), self.root)
            path.write_bytes(original)

    def test_unknown_identity_and_source_still_fail(self):
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            lock = self.root / policy["path"] / "Package.resolved"
            for changed in [{**self.standalone, "identity": "unknown"},
                            {**self.standalone, "location": "https://mirror.invalid/EventSource.git"}]:
                self.write_lock(lock, [changed])
                with self.assertRaisesRegex(ValueError, "unknown identity or source"):
                    rp.application_local_pins(self.project(name), self.root)
            self.write_lock(lock, [self.standalone])

    def test_changed_path_and_aliased_directory_fail(self):
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            with self.assertRaisesRegex(ValueError, "reviewed non-aliased path"):
                rp.application_local_pins(self.project(name, "../outside"), self.root)
            directory = self.root / policy["path"]
            saved = directory.with_name(directory.name + "-real")
            directory.rename(saved); directory.symlink_to(saved, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "reviewed non-aliased path"):
                rp.application_local_pins(self.project(name), self.root)
            directory.unlink(); saved.rename(directory)

    def test_unknown_actual_root_dependency_remains_rejected(self):
        unknown = {**self.host, "identity": "unknown", "location": "https://example.invalid/unknown"}
        with self.assertRaisesRegex(ValueError, "differs from any committed lock"):
            rp.verify_resolution([self.host, unknown], [self.host], [], [])

    def test_three_exact_vendored_references_are_not_active_app_pins(self):
        self.install_vendored_proofs()
        self.assertEqual(set(rp.RETIRED_HOST_GRAPH_PINS), {p["identity"] for p in [*RETIRED_PINS, CITADEL_PIN]})
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            self.write_lock(self.root / policy["path"] / "Package.resolved", [self.standalone, *RETIRED_PINS])
        self.assertEqual(rp.application_local_pins(self.project(), self.root), [])
        self.assertEqual(rp.verify_resolution([self.host], [self.host], [], []), [self.host])
        # Accepting a historical standalone reference must never authorize the
        # same remote dependency in the actual App graph.
        for pin in RETIRED_PINS:
            with self.assertRaisesRegex(ValueError, "differs from any committed lock"):
                rp.verify_resolution([self.host, pin], [self.host], [], [])

    def test_retired_reference_source_revision_version_and_extra_state_must_match(self):
        self.install_vendored_proofs()
        for original in RETIRED_PINS:
            for changed in (
                {**original, "location": "https://mirror.invalid/" + original["identity"]},
                {**original, "state": {**original["state"], "revision": "0" * 40}},
                {**original, "state": {**original["state"], "version": "99.0.0"}},
                {**original, "state": {**original["state"], "branch": "main"}},
            ):
                for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
                    self.write_lock(self.root / policy["path"] / "Package.resolved", [self.standalone, changed])
                    with self.assertRaisesRegex(ValueError, "unknown identity or source"):
                        rp.application_local_pins(self.project(name), self.root)

    def test_vendored_reference_requires_frozen_manifest_provenance_and_live_path(self):
        self.install_vendored_proofs()
        for pin in RETIRED_PINS:
            policy = rp.RETIRED_HOST_GRAPH_PINS[pin["identity"]]
            directory = self.root / policy["path"]
            for filename in ("Package.swift", policy["provenance"]):
                path = directory / filename
                original = path.read_bytes()
                path.write_bytes(original + b"\n")
                self.assertFalse(rp._retired_host_graph_pin_matches(self.root, pin))
                path.write_bytes(original)
            host_manifest = self.root / "Package.swift"
            original = host_manifest.read_text()
            host_manifest.write_text(original.replace('path: "' + policy["path"] + '"', 'path: "ThirdParty/Other"'))
            self.assertFalse(rp._retired_host_graph_pin_matches(self.root, pin))
            host_manifest.write_text(original)
            saved = directory.with_name(directory.name + "-real")
            directory.rename(saved)
            directory.symlink_to(saved, target_is_directory=True)
            self.assertFalse(rp._retired_host_graph_pin_matches(self.root, pin))
            directory.unlink()
            saved.rename(directory)

    def test_active_whisperkit_cannot_be_treated_as_a_retired_reference(self):
        self.install_vendored_proofs()
        whisper = {"identity": "whisperkit", "location": "https://github.com/argmaxinc/WhisperKit.git",
                   "state": {"revision": "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d"}}
        for name, policy in rp.HOST_GRAPH_ADAPTERS.items():
            self.write_lock(self.root / policy["path"] / "Package.resolved", [self.standalone, whisper])
            with self.assertRaisesRegex(ValueError, "unknown identity or source"):
                rp.application_local_pins(self.project(name), self.root)

    def test_actual_graph_still_requires_every_committed_pin_and_exact_state(self):
        other = {"identity": "other", "location": "https://example.invalid/other",
                 "state": {"revision": "a" * 40, "version": "1.0.0"}}
        with self.assertRaisesRegex(ValueError, "Committed host dependency missing"):
            rp.verify_resolution([other], [self.host, other], [], [])
        for changed in (
            {**self.host, "location": "https://mirror.invalid/EventSource.git"},
            {**self.host, "state": self.standalone["state"]},
        ):
            with self.assertRaisesRegex(ValueError, "differs from committed lock"):
                rp.verify_resolution([changed], [self.host], [], [])

    def test_citadel_revision_only_reference_requires_its_exact_source_and_proof(self):
        self.install_vendored_proofs()
        project = self.install_media_exchange([self.host, CITADEL_PIN])
        self.assertEqual(rp.application_local_pins(project, self.root), [self.host])
        for changed in (
            {**CITADEL_PIN, "location": "https://mirror.invalid/Citadel.git"},
            {**CITADEL_PIN, "state": {"revision": "0" * 40}},
            {**CITADEL_PIN, "state": {**CITADEL_PIN["state"], "version": "1.0.0"}},
            {**CITADEL_PIN, "state": {**CITADEL_PIN["state"], "branch": "main"}},
        ):
            self.install_media_exchange([self.host, changed])
            with self.assertRaisesRegex(ValueError, "differs from reviewed vendored proof"):
                rp.application_local_pins(project, self.root)
        self.install_media_exchange([self.host, CITADEL_PIN])
        policy = rp.RETIRED_HOST_GRAPH_PINS["citadel"]
        for filename in ("Package.swift", policy["provenance"]):
            path = self.root / policy["path"] / filename
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            with self.assertRaisesRegex(ValueError, "differs from reviewed vendored proof"):
                rp.application_local_pins(project, self.root)
            path.write_bytes(original)
        directory = self.root / policy["path"]
        saved = directory.with_name(directory.name + "-real")
        directory.rename(saved)
        directory.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "differs from reviewed vendored proof"):
            rp.application_local_pins(project, self.root)
        directory.unlink()
        saved.rename(directory)

    def test_media_exchange_retires_only_four_proven_references_and_keeps_other_pins(self):
        self.install_vendored_proofs()
        project = self.install_media_exchange([self.host, *RETIRED_PINS, CITADEL_PIN])
        local = rp.application_local_pins(project, self.root)
        self.assertEqual(local, [self.host])
        self.assertEqual(rp.verify_resolution([self.host], [self.host], [], local), [self.host])
        for pin in [*RETIRED_PINS, CITADEL_PIN]:
            with self.assertRaisesRegex(ValueError, "differs from any committed lock"):
                rp.verify_resolution([self.host, pin], [self.host], [], local)
        unknown = {"identity": "unknown", "location": "https://example.invalid/unknown",
                   "state": {"revision": "a" * 40}}
        self.install_media_exchange([self.host, *RETIRED_PINS, CITADEL_PIN, unknown])
        local = rp.application_local_pins(project, self.root)
        self.assertIn(unknown, local, "unreviewed identities must not be silently retired")
        combined = rp.verify_resolution([self.host], [self.host], [], local)
        self.assertEqual({p["identity"] for p in combined} - {self.host["identity"]}, {"unknown"})
        changed = {**unknown, "location": "https://mirror.invalid/unknown"}
        with self.assertRaisesRegex(ValueError, "differs from committed lock"):
            rp.verify_resolution([self.host, changed], [self.host], [], local)

    def test_media_exchange_manifest_path_and_lock_alias_remain_rejected(self):
        self.install_vendored_proofs()
        project = self.install_media_exchange([self.host, *RETIRED_PINS, CITADEL_PIN])
        policy = rp.LOCAL_LOCK_RETIRED_REFERENCES["FloeMediaExchange"]
        directory = self.root / policy["path"]
        manifest = directory / "Package.swift"
        original = manifest.read_bytes()
        manifest.write_bytes(original + b"\n")
        with self.assertRaisesRegex(ValueError, "reviewed path or manifest"):
            rp.application_local_pins(project, self.root)
        manifest.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "reviewed path or manifest"):
            rp.application_local_pins(project.replace(policy["path"], "../other"), self.root)
        saved = directory.with_name(directory.name + "-real")
        directory.rename(saved)
        directory.symlink_to(saved, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "reviewed path or manifest"):
            rp.application_local_pins(project, self.root)
        directory.unlink()
        saved.rename(directory)
        lock = directory / "Package.resolved"
        saved_lock = self.root / "saved-lock.json"
        lock.rename(saved_lock)
        lock.symlink_to(saved_lock)
        with self.assertRaisesRegex(ValueError, "lock must not be an alias"):
            rp.application_local_pins(project, self.root)


if __name__ == "__main__":
    unittest.main()
