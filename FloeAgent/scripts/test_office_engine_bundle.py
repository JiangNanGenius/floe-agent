#!/usr/bin/env python3
import json
import difflib
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from package_office_engine import package, REQUIRED
from verify_office_engine import verify
from prepare_office_native_sources import prepare
from supplement_office_engine import supplement
from repair_office_embedding_bundle import repair


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

    def test_header_only_collection_does_not_ship_dangling_test_script_alias(self):
        scripts = self.source / "engine/workdir/UnpackedTarball/zstd/tests/cli-tests/bin"
        scripts.mkdir(parents=True)
        (scripts / "zstd").write_text("test runner, not an embedding header")
        (scripts / "unzstd").symlink_to("zstd")
        package(self.root)
        relocated = self.extract()
        self.assertFalse((relocated / scripts.relative_to(self.root) / "unzstd").is_symlink())
        self.assertEqual(verify(relocated)["archivesVerified"], 1)

    def broken_test_alias_archive(self, *, altered_target=False):
        manifest = package(self.root)
        archive_path = self.root / "office-engine-ios-arm64.tar.gz"
        with tarfile.open(archive_path) as archive:
            contents = [(m, archive.extractfile(m).read()) for m in archive.getmembers()]
        alias = "source/engine/workdir/UnpackedTarball/zstd/tests/cli-tests/bin/unzstd"
        target = "different" if altered_target else "zstd"
        manifest["files"].append({"path": alias, "symlink": target})
        with tarfile.open(archive_path, "w:gz") as archive:
            for member, data in contents:
                if member.name == "bundle-manifest.json":
                    data = json.dumps(manifest).encode()
                    member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            link = tarfile.TarInfo(alias)
            link.type = tarfile.SYMTYPE
            link.linkname = target
            archive.addfile(link)
        lock = self.root / "repair.lock.json"
        lock.write_text(json.dumps({"qualifiedEmbeddingArtifact": {
            "archiveSHA256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
            "omittedTestAliases": {alias: "zstd"}}}))
        return archive_path, lock

    def test_locked_repair_preserves_all_native_bytes_and_original_archive(self):
        archive, lock = self.broken_test_alias_archive()
        original = archive.read_bytes()
        destination = self.root / "repaired"
        report = repair(archive, destination, lock)
        self.assertEqual(report["verified"]["archivesVerified"], 1)
        self.assertEqual((destination / self.library.relative_to(self.root)).read_bytes(), self.library.read_bytes())
        self.assertEqual(len(report["removedUnusedTestAliases"]), 1)
        self.assertEqual(archive.read_bytes(), original)
        with self.assertRaisesRegex(ValueError, "new destination"):
            repair(archive, destination, lock)

    def test_locked_repair_rejects_unknown_archive_before_creating_output(self):
        archive, lock = self.broken_test_alias_archive()
        archive.write_bytes(archive.read_bytes() + b"changed")
        destination = self.root / "repaired"
        with self.assertRaisesRegex(ValueError, "differs from locked"):
            repair(archive, destination, lock)
        self.assertFalse(destination.exists())

    def test_locked_repair_rejects_a_different_alias_defect(self):
        archive, lock = self.broken_test_alias_archive(altered_target=True)
        with self.assertRaisesRegex(ValueError, "does not match"):
            repair(archive, self.root / "repaired", lock)

    def test_external_symlink_rejects_packaging(self):
        (self.source / "host-link").symlink_to(Path(self.directory.name))
        with self.assertRaisesRegex(ValueError, "escapes"):
            package(self.root)

    def test_explicit_linker_objects_are_preserved_in_order(self):
        obj = self.source / "engine/workdir/UnpackedTarball/nss/freebl/aes.o"
        obj.parent.mkdir(parents=True)
        obj.write_bytes(b"synthetic object")
        self.list.write_text(str(obj) + "\n" + str(self.library) + "\n")
        manifest = package(self.root)
        self.assertEqual(manifest["linkerInputs"], [str(obj.relative_to(self.root)), str(self.library.relative_to(self.root))])
        relocated = self.extract()
        result = verify(relocated, prepare=True)
        self.assertEqual(result["objectsVerified"], 1)
        self.assertEqual(result["archivesVerified"], 1)
        self.assertEqual((relocated / "prepared/ios-all-static-libs.list").read_text().splitlines(),
                         [str((relocated / path).resolve()) for path in manifest["linkerInputs"]])

    def test_missing_explicit_linker_object_rejects_packaging(self):
        self.list.write_text(str(self.library) + "\n" + str(self.source / "engine/missing.o") + "\n")
        with self.assertRaises(FileNotFoundError):
            package(self.root)

    def test_supplement_rejects_changed_artifact_before_checkout(self):
        archive = Path(self.directory.name) / "untrusted.tar.gz"
        archive.write_bytes(b"changed archive")
        lock = Path(self.directory.name) / "artifact-lock.json"
        lock.write_text(json.dumps({"qualifiedNativeArtifact": {"archiveSHA256": "incorrect"}}))
        output = Path(self.directory.name) / "new-build"
        with self.assertRaisesRegex(ValueError, "locked archive"):
            supplement(archive, output, lock)
        self.assertFalse(output.exists())

    def test_supplement_preserves_existing_build_root(self):
        archive = Path(self.directory.name) / "original.tar.gz"
        archive.write_bytes(b"verified input")
        lock = Path(self.directory.name) / "artifact-lock.json"
        lock.write_text(json.dumps({"qualifiedNativeArtifact": {"archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest()}}))
        with self.assertRaisesRegex(ValueError, "existing inputs must be preserved"):
            supplement(archive, self.root, lock)
        self.assertTrue(self.library.exists())

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

    def overlay_fixture(self):
        name = "ios/Mobile/DocumentViewController.mm"
        original = self.source / name
        original.write_text(original.read_text() + "\n")
        package(self.root)
        relocated = self.extract()
        old = (relocated / "source" / name).read_text()
        new = "public API input\n"
        patch_text = "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), fromfile="a/" + name, tofile="b/" + name))
        patch = Path(self.directory.name) / "overlay.patch"
        patch.write_text(patch_text)
        sha = lambda value: hashlib.sha256(value.encode()).hexdigest()
        lock = {"commit": "fixture", "embeddingOverlay": {
            "patch": patch.name, "sha256": sha(patch_text), "requiredFrameworks": ["GameController"],
            "files": {name: {"originalSHA256": sha(old), "preparedSHA256": sha(new)}}}}
        lock_path = Path(self.directory.name) / "lock.json"
        lock_path.write_text(json.dumps(lock))
        return relocated, lock_path, name, old, new

    def test_native_overlay_preserves_verified_inputs_and_replays(self):
        root, lock, name, old, new = self.overlay_fixture()
        result = prepare(root, lock)
        self.assertEqual((root / "source" / name).read_text(), old)
        self.assertEqual((root / "prepared/native" / name).read_text(), new)
        self.assertFalse(result["nativeCompilePassed"])
        self.assertEqual(prepare(root, lock), result)
        verify(root)

    def test_native_overlay_rejects_unpinned_source(self):
        root, lock, name, _, _ = self.overlay_fixture()
        data = json.loads(lock.read_text())
        data["embeddingOverlay"]["files"][name]["originalSHA256"] = "wrong"
        lock.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "pinned overlay"):
            prepare(root, lock)
        self.assertFalse((root / "prepared/native").exists())

    def test_native_overlay_does_not_overwrite_manual_edits(self):
        root, lock, name, _, _ = self.overlay_fixture()
        prepare(root, lock)
        target = root / "prepared/native" / name
        target.write_text("manual change")
        with self.assertRaisesRegex(ValueError, "was edited"):
            prepare(root, lock)
        self.assertEqual(target.read_text(), "manual change")

    def test_native_overlay_checks_patch_digest(self):
        root, lock, _, _, _ = self.overlay_fixture()
        (lock.parent / "overlay.patch").write_text("changed patch")
        with self.assertRaisesRegex(ValueError, "patch checksum"):
            prepare(root, lock)

    def test_unqualified_build_is_rejected(self):
        (self.root / "qualification.json").write_text('{"nativeBuildPassed": false}')
        with self.assertRaisesRegex(ValueError, "unqualified"):
            package(self.root)


if __name__ == "__main__":
    unittest.main()
