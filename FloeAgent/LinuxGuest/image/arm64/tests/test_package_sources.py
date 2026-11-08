# SPDX-License-Identifier: MPL-2.0
"""Real file transactions; apt-config transport alone is scripted.

No guest, apt, pip, installation, host source switch or image repack runs.
Actual effective APT paths still require Root's later real-guest acceptance.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import shutil
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[4] / "Sources/FloeExecution/Resources"
SPEC = importlib.util.spec_from_file_location("sources", RESOURCES / "linux_package_sources.py")
SOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCES)
CATALOG = json.loads((RESOURCES / "LinuxPackageSources.json").read_text())


class PackageSourceTransactions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-package-sources-", dir=os.environ.get("FLOE_PACKAGE_SOURCE_FIXTURE_ROOT"))
        self.root = Path(self.temporary.name)
        for relative, data in {
            "etc/os-release": b'ID=debian\nVERSION_CODENAME=trixie\n',
            "usr/share/keyrings/debian-archive-keyring.gpg": b"opaque fixture; NOT a signature qualification",
            "etc/apt/sources.list": b"deb https://custom.example.invalid/debian trixie main\n",
            "etc/apt/sources.list.d/debian.sources": b'Types: deb\n# http://snapshot.debian.org/archive/debian/20261027T000000Z\nURIs: http://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n\nTypes: deb\n# http://snapshot.debian.org/archive/debian-security/20261027T000000Z\nURIs: http://deb.debian.org/debian-security\nSuites: trixie-security\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n',
        }.items():
            f = self.root / relative
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(data)
        self.originals = self.tree()

    def tearDown(self):
        self.temporary.cleanup()

    def tree(self):
        return {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in self.root.rglob("*") if p.is_file() and not p.is_symlink()}

    def probe(self, selection):
        return lambda: ("/etc/apt/sources.list", "/etc/apt/sources.list.d/", False)

    def originals_unchanged(self):
        now = self.tree()
        self.assertEqual({name: now[name] for name in self.originals}, self.originals)

    def test_inspection_does_not_seed_or_change_existing_environment(self):
        state = SOURCES.inspect(self.root, CATALOG, probe=self.probe("system"))
        self.assertEqual(state["selection"], "system")
        self.assertTrue(state["verified"])
        self.assertEqual(self.tree(), self.originals)

    def test_tuna_switch_keeps_standard_paths_and_cli_repository_then_restores_originals(self):
        result = SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertEqual(result["uri"], "https://mirrors.tuna.tsinghua.edu.cn/debian")
        self.assertEqual(result["sourceList"], "/etc/apt/sources.list")
        self.assertEqual(result["sourceParts"], "/etc/apt/sources.list.d/")
        self.assertFalse((self.root / SOURCES.CONF).exists())
        text = (self.root / SOURCES.MANAGED_SOURCE).read_text()
        self.assertIn("Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg", text)
        self.assertIn("URIs: https://security.debian.org/debian-security", text)
        self.assertIn("URIs: https://mirrors.tuna.tsinghua.edu.cn/debian", text)
        custom = self.root / "etc/apt/sources.list.d/model-added.list"
        custom.write_text("deb https://deb.debian.org/debian trixie-backports main\n")
        before = custom.read_bytes()
        self.assertEqual(SOURCES.inspect(self.root, CATALOG, probe=self.probe("tuna"))["sourceParts"], "/etc/apt/sources.list.d/")
        SOURCES.select(self.root, CATALOG, "official", probe=self.probe("official"))
        state = SOURCES.select(self.root, CATALOG, "system", probe=self.probe("system"))
        self.assertEqual(state["selection"], "system")
        self.assertEqual(custom.read_bytes(), before)
        self.assertFalse((self.root / SOURCES.STATE).exists())
        self.originals_unchanged()

    def test_effective_path_mismatch_rolls_back_single_commit_fragment(self):
        SOURCES.select(self.root, CATALOG, "official", probe=self.probe("official"))
        old = (self.root / SOURCES.MANAGED_SOURCE).read_bytes()
        with self.assertRaisesRegex(SOURCES.SourceError, "verificationFailed"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=lambda: ("/wrong.list", "/wrong.d", False))
        self.assertEqual((self.root / SOURCES.MANAGED_SOURCE).read_bytes(), old)

    def test_cancel_after_verified_write_rolls_back_and_keeps_custom_sources(self):
        calls = []
        def cancellation():
            calls.append(1)
            if len(calls) == 3:
                raise SOURCES.SourceError("cancelled")
        with self.assertRaisesRegex(SOURCES.SourceError, "cancelled"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"), check_cancelled=cancellation)
        self.assertFalse((self.root / SOURCES.CONF).exists())
        self.originals_unchanged()

    def test_cancel_immediately_after_atomic_replace_still_restores_old_fragment(self):
        SOURCES.select(self.root, CATALOG, "official", probe=self.probe("official"))
        old = (self.root / SOURCES.MANAGED_SOURCE).read_bytes()
        real_write = SOURCES.atomic_write
        fired = False
        def interrupted(root, relative, data):
            nonlocal fired
            real_write(root, relative, data)
            if relative == SOURCES.MANAGED_SOURCE and not fired:
                fired = True
                raise SOURCES.SourceError("cancelled")
        with patch.object(SOURCES, "atomic_write", side_effect=interrupted):
            with self.assertRaisesRegex(SOURCES.SourceError, "cancelled"):
                SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertEqual((self.root / SOURCES.MANAGED_SOURCE).read_bytes(), old)

    def test_modified_floe_fragment_and_symlink_or_hardlink_are_never_overwritten(self):
        target = self.root / SOURCES.CONF
        target.parent.mkdir(parents=True, exist_ok=True)
        custom = b'// user-edited source override\nDir::Etc::sourcelist "custom.list";\n'
        target.write_bytes(custom)
        with self.assertRaisesRegex(SOURCES.SourceError, "configurationChanged"):
            SOURCES.select(self.root, CATALOG, "system", probe=self.probe("system"))
        self.assertEqual(target.read_bytes(), custom)
        target.unlink()
        external = self.root / "outside-original"
        external.write_bytes(b"preserved")
        for kind in ("symlink", "hardlink"):
            if kind == "symlink": target.symlink_to(external)
            else: os.link(external, target)
            with self.assertRaisesRegex(SOURCES.SourceError, "unsafePath"):
                SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
            self.assertEqual(external.read_bytes(), b"preserved")
            target.unlink()

    def test_unknown_preset_insecure_catalog_or_missing_keyring_does_not_change_active_config(self):
        with self.assertRaisesRegex(SOURCES.SourceError, "unknownPreset"):
            SOURCES.select(self.root, CATALOG, "not-reviewed", probe=self.probe("tuna"))
        bad = copy.deepcopy(CATALOG)
        bad["apt"][1]["uri"] = "http://mirrors.tuna.tsinghua.edu.cn/debian"
        with self.assertRaisesRegex(SOURCES.SourceError, "invalidCatalog"):
            SOURCES.select(self.root, bad, "tuna", probe=self.probe("tuna"))
        (self.root / SOURCES.KEYRING.lstrip("/")).unlink()
        with self.assertRaisesRegex(SOURCES.SourceError, "missingKeyring"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertFalse((self.root / SOURCES.CONF).exists())

    def test_new_image_seeds_both_presets_and_read_only_check_is_idempotent(self):
        # Debian uses a relative /etc/os-release symlink on normal images.
        release = self.root / "usr/lib/os-release"
        release.parent.mkdir(parents=True, exist_ok=True)
        (self.root / "etc/os-release").rename(release)
        (self.root / "etc/os-release").symlink_to("../usr/lib/os-release")
        SOURCES.prepare_image(self.root, CATALOG)
        before = self.tree()
        SOURCES.prepare_image(self.root, CATALOG, check=True)
        SOURCES.prepare_image(self.root, CATALOG)
        self.assertEqual(self.tree(), before)
        self.assertEqual(SOURCES.inspect(self.root, CATALOG, probe=self.probe("official"))["selection"], "official")
        self.assertFalse((self.root / SOURCES.CONF).exists())
        for preset in CATALOG["python"]:
            self.assertEqual((self.root / SOURCES.PROFILE_DIR / ("pypi-" + preset["id"] + ".conf")).read_text(), "[global]\nindex-url = " + preset["indexURL"] + "\n")
        stored = json.loads((self.root / SOURCES.CATALOG_FILE).read_text())
        self.assertEqual(stored, CATALOG)
        self.assertEqual({p["id"] for p in stored["python"]}, {"official", "tuna"})
        for name in ["etc/apt/sources.list"]:
            self.assertEqual(self.tree()[name], self.originals[name])

    def test_apt_config_query_keeps_normal_directories_and_does_not_block_added_sources(self):
        result = subprocess_result(b"FLOE_LIST='/etc/apt/sources.list'\nFLOE_PARTS='/etc/apt/sources.list.d/'\n")
        with patch.object(SOURCES.subprocess, "run", return_value=result) as run:
            self.assertEqual(SOURCES.apt_probe(), self.probe("system")())
            self.assertEqual(run.call_count, 1)
            argv = run.call_args.args[0]
            self.assertEqual(argv[:2], ["/usr/bin/apt-config", "shell"])
            self.assertNotIn("apt-get", argv)
            self.assertNotIn("dump", argv)
        result.stdout += b"FLOE_OVERRIDE_apt_get_sourcelist='user.list'\n"
        with patch.object(SOURCES.subprocess, "run", return_value=result):
            self.assertTrue(SOURCES.apt_probe()[2])

    def test_custom_apt_overrides_are_preserved_and_system_restore_remains_available(self):
        system_with_override = lambda: ("/etc/apt/sources.list", "/etc/apt/sources.list.d/", True)
        self.assertEqual(SOURCES.inspect(self.root, CATALOG, probe=system_with_override)["selection"], "system")
        with self.assertRaisesRegex(SOURCES.SourceError, "customOverride"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=lambda: self.probe("tuna")()[:2] + (True,))
        self.assertFalse((self.root / SOURCES.CONF).exists())
        SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        restored = SOURCES.select(self.root, CATALOG, "system", probe=system_with_override)
        self.assertEqual(restored["selection"], "system")
        self.assertFalse((self.root / SOURCES.CONF).exists())
        self.originals_unchanged()

    def test_image_check_requires_keyring_and_preparation_never_accepts_host_root(self):
        with self.assertRaisesRegex(SOURCES.SourceError, "unsafeImageRoot"):
            SOURCES.prepare_image(Path("/"), CATALOG)
        SOURCES.prepare_image(self.root, CATALOG)
        (self.root / SOURCES.KEYRING.lstrip("/")).unlink()
        before = self.tree()
        with self.assertRaisesRegex(SOURCES.SourceError, "missingKeyring"):
            SOURCES.prepare_image(self.root, CATALOG, check=True)
        self.assertEqual(self.tree(), before)

    def test_standard_debian_readonly_keyring_symlink_supports_select_and_clean_recipe(self):
        keyring = self.root / SOURCES.KEYRING.lstrip("/")
        target = keyring.with_suffix(".pgp")
        keyring.rename(target)
        actual = os.environ.get("FLOE_DEBIAN_KEYRING_FIXTURE")
        if actual:
            shutil.copyfile(actual, target)
        keyring.symlink_to("debian-archive-keyring.pgp")
        before = target.read_bytes()
        state = SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertEqual(state["selection"], "tuna")
        SOURCES.prepare_image(self.root, CATALOG)
        SOURCES.prepare_image(self.root, CATALOG, check=True)
        self.assertTrue(keyring.is_symlink())
        self.assertEqual(os.readlink(keyring), "debian-archive-keyring.pgp")
        self.assertEqual(target.read_bytes(), before)

    def test_other_keyring_links_are_refused_without_relaxing_config_write_guards(self):
        keyring = self.root / SOURCES.KEYRING.lstrip("/")
        keyring.unlink()
        outside = self.root / "unrelated-public-key"
        outside.write_bytes(b"preserved")
        keyring.symlink_to(outside)
        with self.assertRaisesRegex(SOURCES.SourceError, "unsafePath"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertEqual(outside.read_bytes(), b"preserved")
        self.assertFalse((self.root / SOURCES.CONF).exists())

    def test_legacy_read_is_nonmutating_and_explicit_selection_removes_only_own_override(self):
        SOURCES.seed_profiles(self.root, CATALOG)
        (self.root / SOURCES.EMPTY_DIR).mkdir()
        conf = self.root / SOURCES.CONF
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_bytes(SOURCES.conf_text("tuna"))
        before = self.tree()
        legacy = lambda: ("/etc/floe/package-sources/tuna.sources", "/etc/floe/package-sources/empty.d/", False)
        self.assertTrue(SOURCES.inspect(self.root, CATALOG, probe=legacy)["legacyOverride"])
        self.assertEqual(self.tree(), before)
        state = SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertFalse(state["legacyOverride"])
        self.assertFalse(conf.exists())
        SOURCES.select(self.root, CATALOG, "system", probe=self.probe("system"))
        self.originals_unchanged()

    def test_restore_record_and_cli_modified_distribution_are_preserved(self):
        source = self.root / SOURCES.MANAGED_SOURCE
        original = source.read_bytes()
        source.write_bytes(original + b"\nTypes: deb\nURIs: https://other.example.invalid/debian\nSuites: stable\nComponents: main\n")
        modified = source.read_bytes()
        with self.assertRaisesRegex(SOURCES.SourceError, "configurationChanged"):
            SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        self.assertEqual(source.read_bytes(), modified)
        source.write_bytes(original)
        SOURCES.select(self.root, CATALOG, "tuna", probe=self.probe("tuna"))
        record = self.root / SOURCES.STATE
        value = json.loads(record.read_text())
        value["managedFile"] = "etc/unrelated"
        record.write_text(json.dumps(value))
        before = self.tree()
        with self.assertRaisesRegex(SOURCES.SourceError, "configurationChanged"):
            SOURCES.select(self.root, CATALOG, "system", probe=self.probe("system"))
        self.assertEqual(self.tree(), before)


def subprocess_result(stdout):
    from types import SimpleNamespace
    return SimpleNamespace(stdout=stdout, returncode=0)


if __name__ == "__main__":
    unittest.main()
