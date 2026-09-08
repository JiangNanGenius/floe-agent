#!/usr/bin/env python3
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from package_office_engine import package, REQUIRED
from verify_office_engine import verify


class OfficeEngineBundleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="Floe Office bundle ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "build"
        self.root.mkdir()
        self.source = self.root / "source"
        for name in REQUIRED:
            path = self.source / name
            if path.suffix:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic input")
            else:
                path.mkdir(parents=True, exist_ok=True)
                (path / "fixture.h").write_text("synthetic header")
        self.library = self.source / "engine/workdir/LinkTarget/StaticLibrary/libfixture.a"
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"!<arch>\nfixture")
        self.list = self.source / "engine/workdir/CustomTarget/ios/ios-all-static-libs.list"
        self.list.write_text(str(self.library) + "\n")
        (self.root / "qualification.json").write_text(json.dumps({"nativeBuildPassed": True, "commit": "fixture"}))

    def extract(self):
        relocated = Path(self.directory.name) / "relocated bundle"
        relocated.mkdir()
        with tarfile.open(self.root / "office-engine-ios-arm64.tar.gz") as archive:
            archive.extractall(relocated, filter="data")
        return relocated

    def test_relocation_preserves_native_sources_headers_and_link_order(self):
        header = self.source / "engine/workdir/UnpackedTarball/poco/Foundation/include/Poco.h"
        header.parent.mkdir(parents=True)
        header.write_text("poco")
        (self.source / "pocoinclude-symlink").symlink_to(header.parent)
        (self.source / "lobuilddir-symlink").symlink_to(self.source / "engine")
        ignored = self.source / "browser/node_modules/dependency/private.js"
        ignored.parent.mkdir(parents=True)
        ignored.write_text("excluded")
        package(self.root)
        relocated = self.extract()
        result = verify(relocated, prepare=True)
        self.assertFalse(result["embeddingVerified"])
        self.assertEqual(result["archivesVerified"], 1)
        self.assertEqual((relocated / "source/pocoinclude-symlink/Poco.h").read_text(), "poco")
        self.assertFalse((relocated / "source/browser/node_modules").exists())
        self.assertEqual((relocated / "prepared/ios-all-static-libs.list").read_text().strip(), str((relocated / self.library.relative_to(self.root)).resolve()))
        self.assertEqual(verify(relocated), result)

    def test_missing_native_headers_reject_packaging(self):
        (self.source / "engine/config_host/fixture.h").unlink()
        (self.source / "engine/config_host").rmdir()
        with self.assertRaisesRegex(ValueError, "Missing editor"):
            package(self.root)

    def test_external_symlink_rejects_packaging(self):
        (self.source / "host-link").symlink_to(Path(self.directory.name))
        with self.assertRaisesRegex(ValueError, "escapes"):
            package(self.root)

    def test_missing_archive_rejects_packaging(self):
        self.library.unlink()
        with self.assertRaises(FileNotFoundError):
            package(self.root)

    def test_modified_archive_cannot_prepare_a_linker_list(self):
        package(self.root)
        relocated = self.extract()
        (relocated / self.library.relative_to(self.root)).write_bytes(b"!<arch>\nchanged")
        with self.assertRaisesRegex(ValueError, "Changed or missing"):
            verify(relocated, prepare=True)
        self.assertFalse((relocated / "prepared").exists())

    def test_modified_native_source_is_rejected(self):
        package(self.root)
        relocated = self.extract()
        (relocated / "source/ios/Mobile/DocumentViewController.mm").write_text("changed source")
        with self.assertRaisesRegex(ValueError, "Changed or missing"):
            verify(relocated)

    def test_relocated_symlink_cannot_escape(self):
        header = self.source / "common/fixture.h"
        (self.source / "native-header").symlink_to(header)
        package(self.root)
        relocated = self.extract()
        link = relocated / "source/native-header"
        link.unlink()
        link.symlink_to(header)
        with self.assertRaisesRegex(ValueError, "escapes"):
            verify(relocated)

    def test_unqualified_build_is_rejected(self):
        (self.root / "qualification.json").write_text('{"nativeBuildPassed": false}')
        with self.assertRaisesRegex(ValueError, "unqualified"):
            package(self.root)


if __name__ == "__main__":
    unittest.main()
