import base64
import importlib.util
import os
import runpy
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deb = load('deb', ROOT / 'Sources/FloeExecution/Resources/deb_extract.py')
install = load('install', ROOT / 'Sources/FloeExecution/Resources/managed_package_install.py')
remove = load('remove', ROOT / 'Sources/FloeExecution/Resources/managed_package_remove.py')
wheels = load('wheels', ROOT / 'scripts/install_python_bundled_packages.py')


def tar_payload(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz') as archive:
        for name, data in entries:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return out.getvalue()


class PayloadTests(unittest.TestCase):
    def test_deb_success_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / 'output'
            payload = tar_payload([('share/data.txt', b'hello')])
            self.assertEqual(deb.extract_payload(payload, 'data.tar.gz', target), (1, 0))
            self.assertEqual((target / 'share/data.txt').read_bytes(), b'hello')
            with self.assertRaises(ValueError):
                deb.extract_payload(payload, 'data.tar.gz', target)

    def test_deb_entrypoint_accepts_native_decoded_input(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / 'output'
            request = {'payloadBase64': base64.b64encode(tar_payload([('data.txt', b'payload')])).decode(),
                       'name': 'data.tar.gz', 'destination': str(target), 'maxEntries': 10, 'maxExpandedBytes': 4096}
            runpy.run_path(str(ROOT / 'Sources/FloeExecution/Resources/deb_extract.py'),
                           init_globals={'input': request}, run_name='__main__')
            self.assertEqual((target / 'data.txt').read_bytes(), b'payload')

    def test_deb_rejection_leaves_no_partial_output(self):
        for name, data in [('later', b'\x7fELF'), ('../escape', b'bad')]:
            with tempfile.TemporaryDirectory() as directory:
                target = Path(directory).resolve() / 'output'
                with self.assertRaises(ValueError):
                    deb.extract_payload(tar_payload([('first', b'ok'), (name, data)]), 'data.tar.gz', target)
                self.assertEqual(list(Path(directory).resolve().iterdir()), [])

    def test_deb_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            for limits in [dict(max_entries=1), dict(max_bytes=3)]:
                with self.assertRaises(ValueError):
                    deb.extract_payload(tar_payload([('a', b'ab'), ('b', b'cd')]), 'data.tar.gz', Path(directory).resolve() / 'out', **limits)
            self.assertEqual(list(Path(directory).resolve().iterdir()), [])

    def test_wheel_preflight_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            wheel = Path(directory).resolve() / 'bad.whl'
            with zipfile.ZipFile(wheel, 'w') as archive:
                archive.writestr('valid.py', 'pass')
                archive.writestr('../escaped', 'bad')
            with self.assertRaises(SystemExit):
                wheels.install(wheel, Path(directory).resolve() / 'site')
            self.assertFalse((Path(directory).resolve() / 'site').exists())

    def make_distribution(self, root, name, records):
        info = root / (name + '-1.0.dist-info')
        info.mkdir()
        (info / 'METADATA').write_text('Name: ' + name + '\nVersion: 1.0\n')
        (info / 'RECORD').write_text('\n'.join(x + ',,' for x in records + [info.name + '/METADATA', info.name + '/RECORD']))

    def test_remove_resolves_distribution_name_and_preserves_shared_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'shared.py').write_text('shared')
            (root / 'only.py').write_text('only')
            self.make_distribution(root, 'my_package', ['shared.py', 'only.py'])
            self.make_distribution(root, 'other', ['shared.py'])
            remove.remove_distribution(root, 'my-package')
            self.assertTrue((root / 'shared.py').exists())
            self.assertFalse((root / 'only.py').exists())
            self.assertFalse((root / 'my_package-1.0.dist-info/METADATA').exists())

    def test_remove_entrypoint_uses_selected_environment_and_decoded_input(self):
        with tempfile.TemporaryDirectory() as directory:
            layer = Path(directory).resolve()
            root = layer / 'usr/lib/floe-python/site-packages'
            root.mkdir(parents=True)
            (root / 'owned.py').write_text('owned')
            self.make_distribution(root, 'selected', ['owned.py'])
            with patch.dict(os.environ, {'FLOE_PYTHON_PACKAGE_TARGET': str(root), 'FLOE_PYTHON_WRITABLE_LAYER': str(layer)}):
                runpy.run_path(str(ROOT / 'Sources/FloeExecution/Resources/managed_package_remove.py'),
                               init_globals={'input': {'distribution': 'selected'}}, run_name='__main__')
            self.assertFalse((root / 'owned.py').exists())

    def test_remove_rolls_back_failed_move(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'a.py').write_text('a')
            (root / 'b.py').write_text('b')
            self.make_distribution(root, 'pkg', ['a.py', 'b.py'])
            replace = remove.os.replace
            def fail_second(source, destination):
                if Path(source) == root / 'b.py':
                    raise OSError('injected move failure')
                replace(source, destination)
            with patch.object(remove.os, 'replace', side_effect=fail_second):
                with self.assertRaises(OSError):
                    remove.remove_distribution(root, 'pkg')
            self.assertEqual((root / 'a.py').read_text(), 'a')
            self.assertTrue((root / 'pkg-1.0.dist-info/METADATA').exists())

    def test_remove_rejects_record_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            self.make_distribution(root, 'pkg', ['../outside'])
            with self.assertRaises(ValueError):
                remove.remove_distribution(root, 'pkg')
            self.assertTrue((root / 'pkg-1.0.dist-info/METADATA').exists())

    def test_python_upgrade_removes_old_metadata_and_retains_namespace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, incoming, merged = [root / x for x in ('target', 'incoming', 'merged')]
            target.mkdir(); incoming.mkdir()
            (target / 'namespace').mkdir(); (incoming / 'namespace').mkdir()
            (target / 'namespace/owned.py').write_text('old')
            (target / 'namespace/other.py').write_text('other')
            self.make_distribution(target, 'pkg', ['namespace/owned.py'])
            self.make_distribution(target, 'other', ['namespace/other.py'])
            (incoming / 'namespace/owned.py').write_text('new')
            self.make_distribution(incoming, 'pkg', ['namespace/owned.py'])
            info = incoming / 'pkg-1.0.dist-info'
            (info / 'METADATA').write_text('Name: pkg\nVersion: 2.0\n')
            (info / 'RECORD').write_text((info / 'RECORD').read_text().replace('pkg-1.0', 'pkg-2.0'))
            info.rename(incoming / 'pkg-2.0.dist-info')
            install.merge(target, incoming, merged)
            self.assertEqual((merged / 'namespace/owned.py').read_text(), 'new')
            self.assertEqual((merged / 'namespace/other.py').read_text(), 'other')
            self.assertFalse((merged / 'pkg-1.0.dist-info').exists())
            self.assertEqual(install.distributions(merged)['pkg'].version, '2.0')

    def test_python_conflict_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target, incoming, merged = [root / x for x in ('target', 'incoming', 'merged')]
            target.mkdir(); incoming.mkdir()
            (target / 'shared.py').write_text('old')
            self.make_distribution(target, 'existing', ['shared.py'])
            (incoming / 'shared.py').write_text('new')
            self.make_distribution(incoming, 'incoming', ['shared.py'])
            with self.assertRaises(ValueError): install.merge(target, incoming, merged)
            self.assertEqual((target / 'shared.py').read_text(), 'old')

    def test_python_process_interruption_restores_previous_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'site-packages'
            target.mkdir(); (target / 'new.py').write_text('new')
            transaction = root / '.floe-python-transaction'
            backup = transaction / 'backup'
            backup.mkdir(parents=True); (backup / 'old.py').write_text('old')
            install.write_journal(transaction, {'phase': 'committing', 'had_original': True})
            install.recover(target)
            self.assertEqual((target / 'old.py').read_text(), 'old')
            self.assertFalse((target / 'new.py').exists())
            self.assertFalse(transaction.exists())

    def test_python_native_rejection_can_recover_staging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def fake_pip(args):
                incoming = Path(args[args.index('--target') + 1]); incoming.mkdir()
                (incoming / 'bad.so').write_bytes(b'bad')
                return 0
            with self.assertRaises(ValueError): install.install(['bad'], root / 'site-packages', fake_pip)
            self.assertFalse((root / '.floe-python-transaction').exists())
            self.assertFalse((root / 'site-packages').exists())


if __name__ == '__main__':
    unittest.main()
