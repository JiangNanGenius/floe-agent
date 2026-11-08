import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import resolved_pins as rp


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


if __name__ == "__main__":
    unittest.main()
