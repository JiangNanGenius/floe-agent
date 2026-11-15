import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import strip_device_main as strip


@unittest.skipUnless(sys.platform == "darwin", "requires Apple's iOS SDK and Mach-O tools")
class DeviceMainStripTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        root = Path(scratch.name)
        cls.template = root / "products"
        cls.template.mkdir()
        cls.name = "Fixture App"
        app = cls.template / (cls.name + ".app")
        app.mkdir()
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        sdk_version = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], text=True).strip()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": cls.name, "CFBundleIdentifier": "org.floeagent.ios",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "101",
            "DTSDKName": "iphoneos" + sdk_version, "DTXcodeBuild": "fixture", "MinimumOSVersion": "26.0",
        }))
        source = root / "strip_fixture.c"
        source.write_text(
            'extern int puts(const char *);\n'
            'static __attribute__((noinline)) int fixture_local_step(int x) { return x + STEP; }\n'
            'int fixture_export(int x) { return fixture_local_step(x); }\n'
            'int main(int argc, char **argv) { puts("fixture-runtime-marker"); return fixture_export(argc); }\n'
        )
        clang = ["xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios26.0", "-isysroot", sdk]
        for tag, binary in [(17, app / cls.name), (18, root / cls.name)]:
            obj = root / (str(tag) + ".o")
            subprocess.run([*clang, "-g", "-O0", f"-DSTEP={tag}", "-c", source, "-o", obj], check=True)
            subprocess.run([*clang, obj, "-Wl,-no_adhoc_codesign", "-Wl,-export_dynamic", "-o", binary], check=True)
            dsym = cls.template / (app.name + ".dSYM") if tag == 17 else root / "other.dSYM"
            subprocess.run(["xcrun", "dsymutil", binary, "-o", dsym], check=True)
        (app / cls.name).chmod(0o751)
        extension = app / "PlugIns/Widget.appex"
        extension.mkdir(parents=True)
        extension_info = plistlib.loads((app / "Info.plist").read_bytes())
        extension_info.update(CFBundleExecutable="Widget", CFBundleIdentifier="org.floeagent.ios.widget",
                              CFBundlePackageType="XPC!")
        (extension / "Info.plist").write_bytes(plistlib.dumps(extension_info))
        shutil.copy2(app / cls.name, extension / "Widget")
        cls.other_dsym = root / "other.dSYM"

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.products = self.root / "products"
        shutil.copytree(self.template, self.products)
        self.app = self.products / (self.name + ".app")
        self.binary = self.app / self.name
        self.dsym = self.products / (self.app.name + ".dSYM")
        self.dwarf = self.dsym / "Contents/Resources/DWARF" / self.name
        self.original = self.binary.read_bytes()
        self.staged_app = self.root / "staged" / self.app.name
        shutil.copytree(self.app, self.staged_app)

    def run_packager(self, **environment_overrides):
        # A private checkout drives the actual CLI, its clean-commit guard, bundle
        # normalization and ditto archives without touching the user's Git or packages.
        repo = self.root / "repo"
        scripts = repo / "FloeAgent/scripts"
        scripts.mkdir(parents=True)
        for name in ("package_local_device", "strip_device_main", "prepare_app_store_bundle",
                     "normalize_simulator_runpaths", "verify_github_release_publication", "verify_direct_unsigned_artifact"):
            shutil.copyfile(SCRIPTS / (name + ".py"), scripts / (name + ".py"))
        (repo / "Local/Artifacts").mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@invalid",
               "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        for args in (["init", "-q"], ["add", "FloeAgent"], ["commit", "-qm", "Fixture"]):
            subprocess.run([*git, *args], check=True)
        sha = subprocess.check_output([*git, "rev-parse", "HEAD"], text=True).strip()
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        environment.update(environment_overrides)
        environment.pop("FLOE_PRIVACY_REBUILT_FRAMEWORKS", None)
        return subprocess.run(
            [sys.executable, "-B", scripts / "package_local_device.py", "--products", str(self.products),
             "--source", sha, "--qualification", "Mach-O fixture"],
            cwd=repo, env=environment, capture_output=True, text=True,
        )

    def test_packager_strips_only_transport_and_preserved_dsym_resolves_local_source(self):
        result = self.run_packager()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.root / "repo/Local/Artifacts/build101"
        with zipfile.ZipFile(out / "raw-device-app.zip") as raw:
            self.assertEqual(raw.read(self.app.name + "/" + self.name), self.original)
        with zipfile.ZipFile(out / "local-device.zip") as transport:
            member = "Payload/" + self.app.name + "/" + self.name
            executable = self.root / "shipped-main"
            executable.write_bytes(transport.read(member))
            self.assertEqual(stat.S_IMODE(transport.getinfo(member).external_attr >> 16), 0o751)
            self.assertEqual(transport.read("Payload/" + self.app.name + "/PlugIns/Widget.appex/Widget"), self.original)
            dwarf = self.root / "shipped-dwarf"
            dwarf.write_bytes(transport.read("symbols/" + self.dsym.name + "/Contents/Resources/DWARF/" + self.name))
            self.assertEqual(dwarf.read_bytes(), self.dwarf.read_bytes())
            meta = json.loads(transport.read("provenance.json"))
        self.assertEqual(self.binary.read_bytes(), self.original)
        self.assertEqual(meta["app_uuid"], strip.arm64_uuid(executable))
        self.assertEqual(meta["dsym_uuid"], strip.arm64_uuid(dwarf))
        self.assertEqual(meta["main_executable_strip"]["stripped_sha256"], strip.digest_file(executable))
        self.assertLess(executable.stat().st_size, len(self.original))
        original_names = subprocess.check_output(["xcrun", "nm", self.binary], text=True)
        shipped_names = subprocess.check_output(["xcrun", "nm", executable], text=True)
        address = re.search(r"(?m)^([0-9a-fA-F]+) t _fixture_local_step$", original_names).group(1)
        self.assertNotIn("_fixture_local_step", shipped_names)
        self.assertIn("_fixture_export", shipped_names)
        self.assertIn("_puts", shipped_names)
        lookup = subprocess.check_output(["xcrun", "dwarfdump", "--lookup", "0x" + address, dwarf], text=True)
        self.assertIn("fixture_local_step", lookup)
        self.assertIn("strip_fixture.c", lookup)

    def test_stale_dsym_blocks_transport_and_preserves_raw_archive_and_staging(self):
        wrong = self.other_dsym / "Contents/Resources/DWARF" / self.name
        shutil.copyfile(wrong, self.dwarf)
        result = self.run_packager()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dSYM UUIDs differ", result.stderr)
        out = self.root / "repo/Local/Artifacts/build101"
        self.assertFalse((out / "local-device.zip").exists())
        self.assertFalse((out / "provenance.json").exists())
        with zipfile.ZipFile(out / "raw-device-app.zip") as raw:
            self.assertEqual(raw.read(self.app.name + "/" + self.name), self.original)
        staged = self.root / "repo/Local/Scratch/build101-transfer/Payload" / self.app.name
        self.assertEqual((staged / self.name).read_bytes(), self.original)
        self.assertEqual(self.binary.read_bytes(), self.original)
        self.assertEqual(self.dwarf.read_bytes(), wrong.read_bytes())
        raw_zip = out / "raw-device-app.zip"
        before = strip.file_state(raw_zip)
        retry = subprocess.run(result.args, cwd=self.root / "repo", capture_output=True)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual(strip.file_state(raw_zip), before)

    def test_existing_recovery_zip_survives_without_a_staging_directory(self):
        out = self.root / "repo/Local/Artifacts/build101"
        out.mkdir(parents=True)
        archive = out / "raw-device-app.zip"
        with zipfile.ZipFile(archive, "x") as retained:
            retained.writestr(self.app.name + "/" + self.name, b"previous device executable")
        archive.chmod(0o640)
        original = archive.read_bytes()
        before = strip.file_state(archive)

        result = self.run_packager()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Existing raw device archive", result.stderr)
        self.assertEqual(strip.file_state(archive), before)
        self.assertEqual(archive.read_bytes(), original)
        self.assertEqual(list(out.iterdir()), [archive])
        self.assertFalse((self.root / "repo/Local/Scratch/build101-transfer").exists())

    def test_concurrently_created_recovery_zip_wins_atomic_publication(self):
        out = self.root / "repo/Local/Artifacts/build101"
        target = out / "raw-device-app.zip"
        other = self.root / "other-recovery.zip"
        with zipfile.ZipFile(other, "x") as retained:
            retained.writestr("source", "concurrent owner's recovery archive")
        other.chmod(0o640)
        original = other.read_bytes()
        commands = self.root / "commands"
        commands.mkdir()
        ditto = commands / "ditto"
        # A separate process claims the canonical name after the initial check.
        # The real macOS archiver still performs the producer's entire write.
        ditto.write_text(
            '#!/bin/sh\nset -eu\n'
            'if [ "$1" = "-c" ] && [ "$3" = "--keepParent" ]; then\n'
            '  /bin/ln "$OTHER_RECOVERY" "$RECOVERY_TARGET"\n'
            'fi\n'
            'exec /usr/bin/ditto "$@"\n'
        )
        ditto.chmod(0o755)

        result = self.run_packager(PATH=str(commands) + os.pathsep + os.environ["PATH"],
                                   OTHER_RECOVERY=str(other), RECOVERY_TARGET=str(target))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Existing raw device archive", result.stderr)
        self.assertTrue(other.samefile(target))
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
        self.assertEqual(list(out.iterdir()), [target])
        self.assertFalse((self.root / "repo/Local/Scratch/build101-transfer").exists())

    def test_candidate_corruption_or_strip_failure_leaves_staged_app_untouched(self):
        actual_run = subprocess.run
        for needle, expected in [(b"_fixture_export\0", "external symbols"),
                                 (b"fixture-runtime-marker\0", "runtime contents"),
                                 (None, "returned non-zero")]:
            with self.subTest(needle=needle):
                def corrupt(command, **kwargs):
                    result = actual_run(command, **kwargs)
                    if command[:2] == ["xcrun", "strip"]:
                        candidate = Path(command[command.index("-o") + 1])
                        if needle is None:
                            raise subprocess.CalledProcessError(1, command)
                        image = bytearray(candidate.read_bytes())
                        position = image.rindex(needle)
                        image[position + 2] ^= 1
                        candidate.write_bytes(image)
                    return result

                with mock.patch.object(subprocess, "run", corrupt):
                    with self.assertRaisesRegex((ValueError, subprocess.CalledProcessError), expected):
                        strip.strip_staged_main(self.app, self.staged_app, self.dsym)
                self.assertEqual((self.staged_app / self.name).read_bytes(), self.original)
                self.assertEqual(self.binary.read_bytes(), self.original)
                self.assertFalse(list(self.staged_app.glob(".floe-strip-*")))

    def test_rejects_missing_dsym_or_a_shared_raw_executable(self):
        with self.assertRaisesRegex(ValueError, "separate staged"):
            strip.strip_staged_main(self.app, self.app, self.dsym)
        shutil.copyfile(self.binary, self.dwarf)
        with self.assertRaisesRegex(ValueError, "DWARF debug-symbol companion"):
            strip.strip_staged_main(self.app, self.staged_app, self.dsym)
        self.dwarf.unlink()
        with self.assertRaises(FileNotFoundError):
            strip.strip_staged_main(self.app, self.staged_app, self.dsym)
        self.assertEqual(self.binary.read_bytes(), self.original)
        self.assertEqual((self.staged_app / self.name).read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
