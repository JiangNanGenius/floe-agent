"""SimulationKit restricted input contract with synthetic local fixtures."""
import hashlib
import importlib.util
import json
import os
from unittest import mock
from pathlib import Path
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('simulation_transport', ROOT / '.github/scripts/simulation_transport.py')
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class SimulationTransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.vendor = self.root / 'vendor'
        self.vendor.mkdir()
        self.archive = self.root / 'input.zip'
        self.evidence = self.root / 'evidence.json'
        self.files = {}
        for component in module.COMPONENTS:
            entries = {}
            for i in range(13):
                name = 'slice/file%02d' % i
                content = (component + name).encode()
                entries[name] = hashlib.sha256(content).hexdigest()
                self.files[component + '.xcframework/' + name] = content
            (self.vendor / (component + '.manifest.json')).write_text(json.dumps({'files': entries}))

    def create_zip(self, files):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(self.archive, 'w') as z:
                for name, data in files:
                    z.writestr(name, data)
        return module.digest(self.archive)

    def test_install_and_verify_then_reject_tampering_and_extra(self):
        digest = self.create_zip(self.files.items())
        module.install(self.vendor, self.archive, digest, self.evidence)
        module.verify(self.vendor, self.evidence)
        path = self.vendor / next(iter(self.files))
        original = path.read_bytes()
        path.write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            module.verify(self.vendor, self.evidence)
        path.write_bytes(original)
        extra = self.vendor / (module.COMPONENTS[0] + '.xcframework') / 'extra'
        extra.write_bytes(b'extra')
        with self.assertRaises(ValueError):
            module.verify(self.vendor, self.evidence)

    def test_staging_and_destination_share_volume(self):
        digest = self.create_zip(self.files.items())
        real_rename = os.rename
        calls = []
        def check_then_rename(source, destination):
            src, dst = Path(source), Path(destination)
            self.assertEqual(src.parent, self.vendor / '.simulation-extracted')
            self.assertEqual(src.parent.stat().st_dev, dst.parent.stat().st_dev)
            calls.append(src.name)
            return real_rename(source, destination)
        with mock.patch.object(module.os, 'rename', side_effect=check_then_rename):
            module.install(self.vendor, self.archive, digest, self.evidence)
        self.assertEqual(len(calls), 3)
        self.assertFalse((self.vendor / '.simulation-extracted').exists())

    def test_tag_binding_handles_absent_lightweight_and_annotated(self):
        source = 'a' * 40
        release = {'draft': True, 'tag_name': 'v1.8.42-simulation-transport-fa252b61852d',
                   'target_commitish': source}
        self.assertEqual(module.verify_release_target(release, source, lambda *a, **k: None)['mode'], 'tag_absent')
        wrong = dict(release, target_commitish='b' * 40)
        with self.assertRaises(ValueError):
            module.verify_release_target(wrong, source, lambda *a, **k: None)
        def lightweight(path, missing_ok=False):
            return {'object': {'type': 'commit', 'sha': source}}
        self.assertEqual(module.verify_release_target(release, source, lightweight)['mode'], 'tag_resolved')
        def annotated(path, missing_ok=False):
            if path.startswith('git/ref/'):
                return {'object': {'type': 'tag', 'sha': 'b' * 40}}
            return {'object': {'type': 'commit', 'sha': source}}
        self.assertEqual(module.verify_release_target(release, source, annotated)['resolvedCommit'], source)
        def bad_tag(path, missing_ok=False):
            return {'object': {'type': 'commit', 'sha': 'c' * 40}}
        with self.assertRaises(ValueError):
            module.verify_release_target(release, source, bad_tag)
        def unexpected_error(path, missing_ok=False):
            raise ValueError('HTTP 403')
        with self.assertRaises(ValueError):
            module.verify_release_target(release, source, unexpected_error)

    def test_rejects_wrong_outer_digest_and_extra_member(self):
        self.create_zip(self.files.items())
        with self.assertRaises(ValueError):
            module.install(self.vendor, self.archive, '0' * 64, self.evidence)
        digest = self.create_zip(list(self.files.items()) + [('../escape', b'x')])
        with self.assertRaises(ValueError):
            module.install(self.vendor, self.archive, digest, self.evidence)
        self.assertFalse(self.evidence.exists())

    def test_rejects_duplicate_and_wrong_member_bytes(self):
        items = list(self.files.items())
        for rows in (items[:-1] + [items[0]], [(n, b'bad' if i == 0 else data) for i, (n, data) in enumerate(items)]):
            with self.subTest():
                digest = self.create_zip(rows)
                with self.assertRaises(ValueError):
                    module.install(self.vendor, self.archive, digest, self.evidence)
                self.assertFalse(self.evidence.exists())
                stage = self.vendor / '.simulation-extracted'
                if stage.exists():
                    import shutil
                    shutil.rmtree(stage)

    def test_rejects_symlinked_zip_entry(self):
        with zipfile.ZipFile(self.archive, 'w') as z:
            for i, (name, data) in enumerate(self.files.items()):
                item = zipfile.ZipInfo(name)
                item.create_system = 3
                item.external_attr = ((0o120777 if i == 0 else 0o100644) << 16)
                z.writestr(item, data)
        with self.assertRaises(ValueError):
            module.install(self.vendor, self.archive, module.digest(self.archive), self.evidence)


if __name__ == '__main__':
    unittest.main()
