#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused offline tests for the corresponding-source archive producer.

Stdlib only, synthetic bytes, temporary directories. No build, no Gradle, no
network, no signing, no repository writes outside temp. The tests assert the
deterministic positive path AND the fail-closed negative paths (recipe drift,
pin drift, tampered upstream bytes, Apple/APSL text, credential-named license
files, incomplete relink evidence, refusal to overwrite a destination).

Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_produce_corresponding_source.py -v
"""

import argparse
import hashlib
import importlib.util
import json
import tempfile
import tarfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "produce-corresponding-source.py"
_spec = importlib.util.spec_from_file_location("produce_ccs", SCRIPT)
ccs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ccs)

PROOT_URL = "https://example.invalid/proot/archive/v5.1.107.98.zip"
TALLOC_URL = "https://example.invalid/pub/talloc/talloc-2.4.2.tar.gz"
BSD_QUEUE_TEXT = (
    "/*\n"
    " * Copyright (c) 1991, 1993 The Regents of the University of California.\n"
    " * All rights reserved. (BSD-3-Clause)\n"
    " */\n"
    "#define QUEUE_HEAD(name, type) struct name\n"
)


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.recipe = root / "native-build"
        self.cache = root / "dl"
        self.licenses = root / "lic"
        self.relink = root / "build"
        self.provenance = root / "provenance.json"
        self.third_party = root / "THIRD_PARTY.md"
        self.build()

    def build(self):
        self.proot_bytes = b"PK\x03\x04 synthetic proot archive bytes " * 16
        self.talloc_bytes = b"\x1f\x8b synthetic talloc tarball bytes " * 16
        self.cache.mkdir(parents=True, exist_ok=True)
        (self.cache / "proot-v5.1.107.98.zip").write_bytes(self.proot_bytes)
        (self.cache / "talloc-2.4.2.tar.gz").write_bytes(self.talloc_bytes)

        d = self.recipe
        (d / "compat").mkdir(parents=True, exist_ok=True)
        (d / "config").mkdir(parents=True, exist_ok=True)
        (d / "cross").mkdir(parents=True, exist_ok=True)
        (d / "patches").mkdir(parents=True, exist_ok=True)
        (d / "build-bootstrap.sh").write_text(
            "#!/usr/bin/env bash\n"
            f'PROOT_URL="{PROOT_URL}"\n'
            f'PROOT_SHA="{sha(self.proot_bytes)}"\n'
            'PROOT_FILENAME="proot-v5.1.107.98.zip"\n'
            f'TALLOC_URL="{TALLOC_URL}"\n'
            f'TALLOC_SHA="{sha(self.talloc_bytes)}"\n'
            "echo recipe\n"
        )
        (d / "PINS.md").write_text("# pins\nhuman record\n")
        (d / "compat" / "musl-compat.h").write_text(
            "/* MPL-2.0 Floe */\n#define TEMP_FAILURE_RETRY(exp) 1\n")
        (d / "compat" / "queue.h").write_text(BSD_QUEUE_TEXT)
        (d / "config" / "talloc-config.h").write_text(
            "/* reviewed cross config */\n#define HAVE_STRLCPY 1\n")
        shim = d / "cross" / "aarch64-linux-musl-gcc"
        shim.write_text("#!/bin/sh\nexec zig cc \"$@\"\n")
        shim.chmod(0o755)
        self.patch_bytes = (b"--- a/src/tracee/event.c\n"
                            b"+++ b/src/tracee/event.c\n+PTRACE_O_EXITKILL\n")
        (d / "patches" / "tracee-event-exitkill.patch").write_bytes(self.patch_bytes)

        self.licenses.mkdir(parents=True, exist_ok=True)
        (self.licenses / "Zig-LICENSE").write_text("MIT\nzig\n")
        (self.licenses / "xz-0BSD-LICENSE").write_text("0BSD\n")

        self.third_party.write_text("# Third-party components\nMPL/PRoot obligations table\n")

        r = self.relink
        (r / "talloc-install" / "lib").mkdir(parents=True, exist_ok=True)
        (r / "talloc.o").write_bytes(b"\x7fELF synthetic talloc object")
        (r / "replace.o").write_bytes(b"\x7fELF synthetic replace object")
        (r / "libtalloc.members.txt").write_text("talloc.o\nreplace.o\n")
        (r / "talloc-install" / "lib" / "libtalloc.a").write_bytes(b"!<arch>\nsynthetic archive")

        self.write_provenance()

    def refresh_recipe_hash(self):
        entries = ccs.collect_recipe_tree(self.recipe)
        return ccs.recipe_tree_sha256(self.recipe, entries)

    def write_provenance(self):
        self.provenance.write_text(json.dumps({
            "generated_utc": "2026-10-22T00:00:00Z",
            "producer": "FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh",
            "recipe_tree_sha256": self.refresh_recipe_hash(),
            "outputs_sha256": {"lib/libproot.so": sha(b"libproot"),
                               "lib/libproot_loader.so": sha(b"loader")},
            "pins": {
                "proot": {"url": PROOT_URL, "tarball_sha256": sha(self.proot_bytes)},
                "talloc": {"url": TALLOC_URL, "tarball_sha256": sha(self.talloc_bytes)},
            },
            "patches": {"tracee-event-exitkill": {
                "file": "patches/tracee-event-exitkill.patch",
                "sha256": sha(self.patch_bytes),
                "before_sha256": sha(b"before"), "after_sha256": sha(b"after"),
            }},
        }, indent=1))

    def argv(self, command, extra=()):
        return [command,
                "--recipe-dir", str(self.recipe),
                "--provenance", str(self.provenance),
                "--upstream-cache", str(self.cache),
                "--third-party-doc", str(self.third_party),
                "--license-dir", f"linuxruntime={self.licenses}",
                "--release-version", "0.1.0-alpha.8",
                "--source-commit", "a" * 40, *extra]

    # ---- guest-resolver module fixture (optional boundary; composes onto
    #      the base recipe without changing the original proot/talloc pins) --
    GUEST_FILES = {
        "PROTOCOL.json": b'{"id":"floe-guest-dns-v1"}\n',
        "build-guest-resolver.sh": b"#!/usr/bin/env bash\n# pinned producer\n",
        "libnss_floe.c": (b"/* SPDX-License-Identifier: MPL-2.0 */\n"
                          b"int _nss_floe_gethostbyname2_r(void) { return 0; }\n"),
        "nss-floe.map": (b"{\n global:\n  _nss_floe_gethostbyname_r;\n"
                         b"  _nss_floe_gethostbyname2_r;\n"
                         b"  _nss_floe_gethostbyname3_r;\n"
                         b"  _nss_floe_gethostbyname4_r;\n local: *;\n};\n"),
    }

    def with_guest(self, **override):
        # The guest toolchain binding reads the Zig pins from the recipe's
        # build-bootstrap.sh; the real script carries them, so the fixture
        # script must too. Re-bind the provenance recipe hash afterwards.
        script = (self.recipe / "build-bootstrap.sh").read_text()
        self.zig_archive_bytes = b"synthetic pinned zig archive"
        (self.recipe / "build-bootstrap.sh").write_text(
            script
            + 'ZIG_URL="https://example.invalid/zig-aarch64-macos-0.14.1.tar.xz"\n'
            + f'ZIG_SHA="{sha(self.zig_archive_bytes)}"\n'
            + 'ZIG_DIRNAME="zig-aarch64-macos-0.14.1"\n')
        self.write_provenance()

        g = self.root / "guest-resolver"
        g.mkdir(parents=True, exist_ok=True)
        for name, data in self.GUEST_FILES.items():
            (g / name).write_bytes(data)
        order = sorted(self.GUEST_FILES, key=lambda s: s.encode("utf-8"))
        lines = "".join(f"{sha(self.GUEST_FILES[n])}  {n}\n" for n in order)
        sources = [{"path": n, "sha256": sha(self.GUEST_FILES[n]),
                    "bytes": len(self.GUEST_FILES[n])} for n in order]
        manifest = {
            "schemaVersion": 1,
            "protocol": "floe-guest-dns-v1",
            "library": "libnss_floe.so.2",
            "target": "aarch64-linux-gnu",
            "glibcFloor": "2.28",
            "soname": "libnss_floe.so.2",
            "sourceTreeSha256": sha(lines.encode("utf-8")),
            "sources": sources,
            "toolchain": {"name": "zig", "version": "0.14.1",
                          "archiveSha256": sha(self.zig_archive_bytes)},
            "binary": {"name": "libnss_floe.so.2", "sha256": sha(b"synthetic .so"),
                       "bytes": 26472},
            "minimumLoadAlignment": 16384,
            "exports": ["_nss_floe_gethostbyname2_r", "_nss_floe_gethostbyname3_r",
                        "_nss_floe_gethostbyname4_r", "_nss_floe_gethostbyname_r"],
        }
        manifest.update(override)
        self.guest_dir = g
        self.guest_manifest = self.root / "guest-manifest.json"
        self.guest_manifest.write_text(json.dumps(manifest, indent=1, sort_keys=True))
        return self

    def guest_argv_extra(self):
        return ("--guest-resolver-dir", str(self.guest_dir),
                "--guest-resolver-manifest", str(self.guest_manifest))


def parse(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("command")
    parser.add_argument("--recipe-dir")
    parser.add_argument("--provenance")
    parser.add_argument("--upstream-cache")
    parser.add_argument("--third-party-doc")
    parser.add_argument("--license-dir", action="append", default=[])
    parser.add_argument("--mpl-license")
    parser.add_argument("--relink-evidence")
    parser.add_argument("--guest-resolver-dir")
    parser.add_argument("--guest-resolver-manifest")
    parser.add_argument("--release-version")
    parser.add_argument("--source-commit")
    parser.add_argument("--out")
    return parser.parse_args(argv)


def load(argv):
    return ccs.load_and_validate(parse(argv))


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.fx = Fixture(self.tmp)

    def run_cli(self, argv):
        return ccs.main(argv)


class PositiveTests(Base):
    def test_check_reports_and_is_deterministic(self):
        first = load(self.fx.argv("check"))
        second = load(self.fx.argv("check"))
        self.assertEqual(first["archiveSha256"], second["archiveSha256"])
        self.assertEqual(first["_tar_bytes"], second["_tar_bytes"])
        self.assertGreaterEqual(len(first["checks"]), 10)
        self.assertTrue(all(c["ok"] for c in first["checks"]))

    def test_produce_writes_expected_files_and_contents(self):
        out = self.tmp / "out"
        self.assertEqual(self.run_cli(self.fx.argv("produce", ["--out", str(out)])), 0)
        names = sorted(p.name for p in out.iterdir())
        self.assertEqual(names, ["MANIFEST.json", "SHA256SUMS",
                                 "floe-linuxruntime-corresponding-source-0.1.0-alpha.8.tar.gz"])
        archive = out / names[2]
        root = "floe-linuxruntime-corresponding-source-0.1.0-alpha.8"
        with tarfile.open(archive, "r:gz") as tar:
            entries = tar.getnames()
            member = tar.extractfile(f"{root}/upstream/proot-v5.1.107.98.zip").read()
        self.assertEqual(member, self.fx.proot_bytes)
        self.assertIn(f"{root}/upstream/talloc-2.4.2.tar.gz", entries)
        self.assertIn(f"{root}/native-build/build-bootstrap.sh", entries)
        self.assertIn(f"{root}/native-build/patches/tracee-event-exitkill.patch", entries)
        self.assertIn(f"{root}/third-party/THIRD_PARTY.md", entries)
        self.assertIn(f"{root}/third-party-licenses/linuxruntime/xz-0BSD-LICENSE", entries)
        self.assertIn(f"{root}/CORRESPONDING-SOURCE.md", entries)
        self.assertIn(f"{root}/MANIFEST.json", entries)
        self.assertFalse(any("/relink/" in e for e in entries))
        with tarfile.open(archive, "r:gz") as tar:
            listing = [(m.name, m.mode, m.uid, m.gid, m.mtime) for m in tar.getmembers()]
        self.assertEqual([n for n, *_ in listing],
                         sorted([n for n, *_ in listing], key=lambda s: s.encode()))
        for _, _, uid, gid, mtime in listing:
            self.assertEqual((uid, gid, mtime), (0, 0, 0))
        shim = next(m for m in listing if m[0].endswith("cross/aarch64-linux-musl-gcc"))
        self.assertEqual(shim[1], 0o755)
        sums = (out / "SHA256SUMS").read_text()
        self.assertIn(sha(archive.read_bytes()), sums)
        manifest = json.loads((out / "MANIFEST.json").read_text())
        self.assertEqual(manifest["recipeTreeSha256"], self.fx.refresh_recipe_hash())
        self.assertEqual(manifest["sourceCommit"], "a" * 40)

    def test_relink_evidence_opt_in(self):
        out = self.tmp / "out2"
        self.assertEqual(self.run_cli(self.fx.argv(
            "produce", ["--out", str(out), "--relink-evidence", str(self.fx.relink)])), 0)
        with tarfile.open(out / "floe-linuxruntime-corresponding-source-0.1.0-alpha.8.tar.gz",
                          "r:gz") as tar:
            names = tar.getnames()
        self.assertTrue(any(n.endswith("relink/talloc.o") for n in names))
        self.assertTrue(any(n.endswith("relink/talloc-install/lib/libtalloc.a") for n in names))
        self.assertTrue(any(n.endswith("relink/libtalloc.members.txt") for n in names))

    def test_mpl_license_included(self):
        mpl = self.tmp / "LICENSE"
        mpl.write_text("Mozilla Public License Version 2.0\n=====\n")
        out = self.tmp / "out3"
        self.assertEqual(self.run_cli(self.fx.argv(
            "produce", ["--out", str(out), "--mpl-license", str(mpl)])), 0)
        with tarfile.open(out / "floe-linuxruntime-corresponding-source-0.1.0-alpha.8.tar.gz",
                          "r:gz") as tar:
            self.assertTrue(any(n.endswith("LICENSE-MPL-2.0.txt") for n in tar.getnames()))


class NegativeTests(Base):
    def test_recipe_drift_rejected(self):
        (self.fx.recipe / "PINS.md").write_text("# pins\nhuman record CHANGED\n")
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(self.fx.argv("check"))
        self.assertIn("recipe_tree_sha256", str(ctx.exception))

    def test_provenance_unusable_rejected(self):
        self.fx.provenance.write_text(json.dumps({"pins": {}}))
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_producer_pin_drift_rejected(self):
        script = (self.fx.recipe / "build-bootstrap.sh").read_text()
        (self.fx.recipe / "build-bootstrap.sh").write_text(
            script.replace(sha(self.fx.proot_bytes), sha(b"rotten")))
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_tampered_upstream_rejected(self):
        (self.fx.cache / "proot-v5.1.107.98.zip").write_bytes(b"tampered")
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_missing_upstream_rejected(self):
        (self.fx.cache / "proot-v5.1.107.98.zip").unlink()
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(self.fx.argv("check"))
        self.assertIn("never fetches", str(ctx.exception))

    def test_apsl_text_rejected(self):
        (self.fx.recipe / "compat" / "queue.h").write_text(
            BSD_QUEUE_TEXT + "\n * Copyright (c) 2023 Apple Inc. — APSL-2.0\n")
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_credential_named_license_rejected(self):
        (self.fx.licenses / "id_rsa").write_text("private\n")
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_binary_license_rejected(self):
        (self.fx.licenses / "junk").write_bytes(b"\x00\x01\x02")
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check"))

    def test_incomplete_relink_evidence_rejected(self):
        (self.fx.relink / "talloc-install" / "lib" / "libtalloc.a").unlink()
        with self.assertRaises(ccs.ProduceError):
            load(self.fx.argv("check", ["--relink-evidence", str(self.fx.relink)]))

    def test_version_grammar_rejected(self):
        argv = self.fx.argv("check")
        argv[argv.index("--release-version") + 1] = "0.1.0 alpha 8"
        with self.assertRaises(ccs.ProduceError):
            load(argv)

    def test_check_writes_nothing(self):
        before = sorted(p.name for p in self.tmp.iterdir())
        load(self.fx.argv("check"))
        after = sorted(p.name for p in self.tmp.iterdir())
        self.assertEqual(before, after)

    def test_produce_refuses_nonempty_and_existing(self):
        out = self.tmp / "out4"
        out.mkdir()
        (out / "junk.txt").write_text("x")
        self.assertEqual(self.run_cli(self.fx.argv("produce", ["--out", str(out)])), 1)
        self.assertEqual((out / "junk.txt").read_text(), "x")  # untouched
        self.assertEqual(sorted(p.name for p in out.iterdir()), ["junk.txt"])
        good = self.tmp / "out5"
        self.assertEqual(self.run_cli(self.fx.argv("produce", ["--out", str(good)])), 0)
        self.assertEqual(self.run_cli(self.fx.argv("produce", ["--out", str(good)])), 1)
        names = sorted(p.name for p in good.iterdir())
        self.assertEqual(names, ["MANIFEST.json", "SHA256SUMS",
                                 "floe-linuxruntime-corresponding-source-0.1.0-alpha.8.tar.gz"])


class GuestResolverTests(Base):
    """Changed-boundary SOURCE tests for the optional guest-resolver module:
    truthful deterministic inclusion plus the fail-closed negatives (partial
    input, missing/tampered helper source, tampered tree hash, toolchain pin
    drift, manifest bounds/extra keys)."""

    def test_guest_resolver_included_and_deterministic(self):
        fx = self.fx.with_guest()
        argv = fx.argv("check", fx.guest_argv_extra())
        first = load(argv)
        second = load(argv)
        self.assertEqual(first["archiveSha256"], second["archiveSha256"])
        self.assertEqual(first["_tar_bytes"], second["_tar_bytes"])
        out = self.tmp / "out-guest"
        self.assertEqual(self.run_cli(fx.argv("produce",
                                              ["--out", str(out),
                                               *fx.guest_argv_extra()])), 0)
        with tarfile.open(out / "floe-linuxruntime-corresponding-source-0.1.0-alpha.8.tar.gz",
                          "r:gz") as tar:
            names = tar.getnames()
        root = "floe-linuxruntime-corresponding-source-0.1.0-alpha.8"
        for rel in ("libnss_floe.c", "nss-floe.map", "build-guest-resolver.sh",
                    "PROTOCOL.json"):
            self.assertIn(f"{root}/guest-resolver/{rel}", names)
        self.assertIn(f"{root}/guest-resolver-manifest.json", names)
        manifest = json.loads((out / "MANIFEST.json").read_text())
        self.assertEqual(manifest["guestResolver"]["protocol"], "floe-guest-dns-v1")
        self.assertEqual(manifest["guestResolver"]["binary"]["bytes"], 26472)
        self.assertEqual(manifest["recipeTreeSha256"], self.fx.refresh_recipe_hash())

    def test_guest_resolver_without_provenance_change_when_absent(self):
        base = load(self.fx.argv("check"))
        self.assertNotIn("guestResolver",
                         json.loads(base["_manifest_bytes"].decode("utf-8")))
        self.assertFalse(any(c["id"] == "guest-resolver-bound" for c in base["checks"]))

    def test_guest_resolver_partial_input_rejected(self):
        fx = self.fx.with_guest()
        argv = fx.argv("check", ("--guest-resolver-dir", str(fx.guest_dir)))
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(argv)
        self.assertIn("all-or-none", str(ctx.exception))

    def test_guest_resolver_missing_source_rejected(self):
        fx = self.fx.with_guest()
        (fx.guest_dir / "libnss_floe.c").unlink()
        with self.assertRaises(ccs.ProduceError):
            load(fx.argv("check", fx.guest_argv_extra()))

    def test_guest_resolver_tampered_source_rejected(self):
        fx = self.fx.with_guest()
        (fx.guest_dir / "libnss_floe.c").write_bytes(b"/* tampered */\n")
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(fx.argv("check", fx.guest_argv_extra()))
        self.assertIn("libnss_floe.c", str(ctx.exception))

    def test_guest_resolver_tree_hash_mismatch_rejected(self):
        fx = self.fx.with_guest(sourceTreeSha256="0" * 64)
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(fx.argv("check", fx.guest_argv_extra()))
        self.assertIn("sourceTreeSha256", str(ctx.exception))

    def test_guest_resolver_toolchain_drift_rejected(self):
        fx = self.fx.with_guest(toolchain={"name": "zig", "version": "9.9.9",
                                           "archiveSha256": "f" * 64})
        with self.assertRaises(ccs.ProduceError):
            load(fx.argv("check", fx.guest_argv_extra()))

    def test_guest_resolver_binary_bound_rejected(self):
        fx = self.fx.with_guest(binary={"name": "libnss_floe.so.2",
                                        "sha256": sha(b"x"), "bytes": 5000000})
        with self.assertRaises(ccs.ProduceError):
            load(fx.argv("check", fx.guest_argv_extra()))

    def test_guest_resolver_extra_key_rejected(self):
        fx = self.fx.with_guest(buildHostPath="/Users/private/nope")
        with self.assertRaises(ccs.ProduceError) as ctx:
            load(fx.argv("check", fx.guest_argv_extra()))
        self.assertIn("manifestSchema", str(ctx.exception))


class RecipeHashMirror(unittest.TestCase):
    def test_mirror_matches_shasum_stream_semantics(self):
        # shasum-style 'hash␠␠path' stream over byte-sorted relative paths
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / "PINS.md").write_text("a")
            (root / "build-bootstrap.sh").write_text("b")
            (root / "compat").mkdir()
            (root / "compat" / "h.h").write_text("c")
            for extra in ("config", "cross", "patches"):
                (root / extra).mkdir()
            entries = ccs.collect_recipe_tree(root)
            self.assertEqual(entries, ["PINS.md", "build-bootstrap.sh", "compat/h.h"])
            expected_stream = "".join(
                f"{sha((root / p).read_bytes())}  {p}\n" for p in entries)
            self.assertEqual(hashlib.sha256(expected_stream.encode()).hexdigest(),
                             ccs.recipe_tree_sha256(root, entries))


if __name__ == "__main__":
    unittest.main(verbosity=2)
