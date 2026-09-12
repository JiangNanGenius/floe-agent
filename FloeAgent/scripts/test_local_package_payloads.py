import importlib.util
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


if __name__ == '__main__':
    unittest.main()
