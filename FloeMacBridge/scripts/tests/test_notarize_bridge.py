import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("bridge_notary", Path(__file__).parents[1] / "notarize_bridge.py")
notary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notary)


class FrameworkArchiveTests(unittest.TestCase):
    def archive(self, root, entries):
        path = Path(root) / "app.zip"
        with zipfile.ZipFile(path, "w") as archive:
            for name, data, mode in entries:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, data)
        return path

    def test_pinned_framework_links_survive_extraction(self):
        with tempfile.TemporaryDirectory() as root:
            prefix = notary.SPARKLE_PREFIX
            entries = [(prefix + "Versions/B/Sparkle", b"Mach-O fixture", stat.S_IFREG | 0o755)]
            entries += [(name, target.encode(), stat.S_IFLNK | 0o777) for name, target in notary.SPARKLE_LINKS.items()]
            archive = self.archive(root, entries)
            destination = Path(root) / "out"
            notary.extract_zip(archive, destination)
            binary = destination / prefix / "Sparkle"
            self.assertTrue(binary.is_symlink())
            self.assertEqual(binary.read_bytes(), b"Mach-O fixture")
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)

    def test_framework_link_cannot_escape(self):
        with tempfile.TemporaryDirectory() as root:
            archive = self.archive(root, [(notary.SPARKLE_PREFIX + "Versions/Current", b"../../../../outside", stat.S_IFLNK | 0o777)])
            with self.assertRaises(notary.HelperError):
                notary.validate_zip(archive)

    def test_unknown_links_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            archive = self.archive(root, [("Floe Bridge.app/Contents/Resources/link", b"inside", stat.S_IFLNK | 0o777)])
            with self.assertRaises(notary.HelperError):
                notary.validate_zip(archive)

    def test_member_cannot_write_through_allowed_link(self):
        with tempfile.TemporaryDirectory() as root:
            entries = [(notary.SPARKLE_PREFIX + "Resources", b"Versions/Current/Resources", stat.S_IFLNK | 0o777),
                       (notary.SPARKLE_PREFIX + "Resources/injected", b"bad", stat.S_IFREG | 0o644)]
            with self.assertRaises(notary.HelperError):
                notary.extract_zip(self.archive(root, entries), Path(root) / "out")
            self.assertFalse((Path(root) / "out").exists())

    def test_duplicate_and_traversal_members_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            for entries in [
                [("Floe Bridge.app/Contents/file", b"a", stat.S_IFREG | 0o644)] * 2,
                [("Floe Bridge.app/../outside", b"a", stat.S_IFREG | 0o644)],
            ]:
                with self.assertRaises(notary.HelperError):
                    notary.validate_zip(self.archive(root, entries))

    def test_original_link_free_archive_remains_supported(self):
        with tempfile.TemporaryDirectory() as root:
            name = "Floe Bridge.app/Contents/Resources/source-commit.txt"
            archive = self.archive(root, [(name, b"a" * 40, stat.S_IFREG | 0o644)])
            destination = Path(root) / "out"
            notary.extract_zip(archive, destination)
            self.assertEqual((destination / name).read_bytes(), b"a" * 40)


if __name__ == "__main__":
    unittest.main()
