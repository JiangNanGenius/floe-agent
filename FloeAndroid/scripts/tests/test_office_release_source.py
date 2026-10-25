#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused offline tests for the Office-generation corresponding-source tool
and the Office pins gate added to the stage-release checker.

Stdlib only, synthetic bytes, temporary directories. No build, no Gradle, no
network, no signing, no device, no repository writes outside temp. The tests
assert the deterministic positive path (embedding the Linux/IDE generation
byte-exact, adding the Office group, sanitized public renderings) AND the
fail-closed negative paths (stale-generation combined offers, producer pin
drift, overlay/manifest/notice cross-binding drift, missing MPL notices,
release-tag binding, private-path leakage, credential names, symlinks, the
exact build-id waiver semantics in prepare-stage-release, and refusal to
overwrite a destination).

Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        FloeAndroid/scripts/tests/test_office_release_source.py -v
"""

import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import struct
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
SCRIPT_OFC = HERE / "produce-office-corresponding-source.py"
SCRIPT_PSR = HERE / "prepare-stage-release.py"


def _load(name, script):
    spec = importlib.util.spec_from_file_location(name, script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {script}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


ofc = _load("floe_office_ccs_under_test", SCRIPT_OFC)
psr = _load("floe_stage_release_under_test", SCRIPT_PSR)


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def j(obj) -> bytes:
    return (json.dumps(obj, indent=1, ensure_ascii=False) + "\n").encode("utf-8")


# ---------------------------------------------------------------------------
# synthetic Office module tree + synthetic Linux/IDE combined generation
# ---------------------------------------------------------------------------

class OfficeFixture:
    """Builds a small, internally consistent officeengine tree and matching
    combined CCS directory. Values mirror the REAL identity constants (the
    tool pins those by design); the payload content is synthetic."""

    VERSION = "0.1.0-alpha.12"
    COMMIT = "d" * 40
    REPO = "JiangNanGenius/floe-agent"

    def __init__(self, root: Path):
        self.root = root
        self.base = root / "officeengine"
        self.combined = root / "combined-ccs"
        self.build()

    # -- payload-shaped synthetic bytes -------------------------------------
    def build(self):
        self.apk_sha = sha(b"SYNTHETIC-FINAL-SIGNED-APK-PRE-SET")
        R = ofc.UPSTREAM_REVISION
        self.lib_blobs = {}
        lib_names = list(ofc.OFFICE_PINNED_LIBRARIES) + [ofc.LIBCXX_NAME]
        for name in lib_names:
            self.lib_blobs[name] = f"ELF-SYNTH-{name}".encode() + bytes(range(64))
        official_libcxx_sha = sha(self.lib_blobs[ofc.LIBCXX_NAME])
        self.app_own_libcxx_sha = sha(b"Floe pinned NDK runtime copy")

        # asset originals (producer payload side)
        self.asset_originals = {
            "dist/branding.js": b"ARR brand script original bytes",
            "dist/cool.html": b"upstream cool.html original bytes %UI_RTL_SETTINGS%",
            "dist/images/old-brand.svg": b"<svg>brand art</svg>",
            "share/theme_definitions/online/one.svg": b"<svg>brand theme art</svg>",
            "dexopt/baseline.prof": b"upstream dex profile",
            "license.html": b"generated upstream licence html",
            "notice.txt": b"Apache-2.0 NOTICE byte-identical",
        }
        # Floe overlay new bytes (on disk under overlays/)
        spdx = "SPDX-License-Identifier: MPL-2.0\n"
        self.overlay_blobs = {
            "dist/branding.js": (spdx + "Floe neutral branding globals only\n").encode(),
            "dist/cool.html": (spdx + "Floe-adapted mobile page %UI_RTL_SETTINGS%\n").encode(),
            "share/theme_definitions/online/one.svg":
                (b'<?xml version="1.0" encoding="UTF-8"?>\n<!-- '
                 + spdx.encode()
                 + b'; Floe neutral widget artwork. -->\n<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18"><rect/></svg>\n'),
            "share/registry/floe-preview-policy.xcd":
                (b'<?xml version="1.0"?>\n<!-- ' + spdx.encode()
                 + b' -->\n<oor:component-schema/>\n'),
            "notices/index.html": self_notice_html(R),
        }
        self.notice_index = self.build_notice_index()
        self.overlay_blobs["notices/source-index.json"] = self.notice_index

        # producer-manifest.json (5291-record shape, synthetic content)
        files = {}
        for name in lib_names:
            files[f"lib/arm64-v8a/{name}"] = {
                "bytes": len(self.lib_blobs[name]),
                "sha256": sha(self.lib_blobs[name]),
            }
        for rel, blob in self.asset_originals.items():
            files[f"assets/{rel}"] = {"bytes": len(blob), "sha256": sha(blob)}
        files["assets/unpack/etc/fonts/fonts.conf"] = {"bytes": 0, "sha256": sha(b"")}
        self.manifest_obj = {
            "schema": ofc.MANIFEST_SCHEMA,
            "source": {"repository": ofc.UPSTREAM_REPOSITORY, "revision": R,
                       "version": ofc.PRODUCER_VERSION_NAME,
                       "binding": "synthetic for tests"},
            "artifact": {"url": ofc.PRODUCER_APK_URL,
                         "sha256": ofc.PRODUCER_APK_SHA256,
                         "signerSha256": ofc.PRODUCER_SIGNER_CERT_SHA256},
            "selectedFiles": len(files),
            "selectedBytes": sum(v["bytes"] for v in files.values()),
            "nativeLibraries": len(lib_names),
            "actualArm64And16K": True,
            "files": files,
        }
        self.manifest_bytes = j(self.manifest_obj)

        # asset-overlays entries (records are rebuilt in finalize_index)
        entries = []
        for rel, blob in sorted(self.overlay_blobs.items()):
            if rel == "notices/source-index.json":
                continue  # bound via its own add entry after the index is final
            op = "add" if (rel == "notices/index.html"
                           or rel.startswith("share/registry/")) else "replace"
            entry = {"operation": op, "destination": rel, "source": rel,
                     "sha256": sha(blob),
                     "originalSha256": None if op == "add"
                     else self.manifest_obj["files"][f"assets/{rel}"]["sha256"],
                     "reason": "synthetic " + op, "license": "MPL-2.0"}
            entries.append(entry)
        for rel in ("dist/images/old-brand.svg", "dexopt/baseline.prof"):
            entries.append({"operation": "remove", "destination": rel,
                            "originalSha256":
                                self.manifest_obj["files"][f"assets/{rel}"]["sha256"],
                            "reason": "synthetic remove"})
        self.index_self_sha = sha(self.notice_index)
        entries.append({"operation": "add", "destination": "notices/source-index.json",
                        "source": "notices/source-index.json",
                        "sha256": self.index_self_sha, "originalSha256": None,
                        "reason": "synthetic public source index add",
                        "license": "MPL-2.0"})
        self.overlays_obj = {
            "schema": ofc.OVERLAYS_SCHEMA,
            "producerSource": R,
            "entries": entries,
            "sourceAccess": {
                "tag": f"android/v{self.VERSION}",
                "archiveUrl": ofc.RELEASE_URL_FMT.format(
                    repo=self.REPO, version=self.VERSION,
                    archive=ofc.ARCHIVE_NAME_FMT.format(version=self.VERSION)),
                "nativeSource": ofc.UPSTREAM_COMMIT_TREE_URL,
                "privatePathsExcluded": True,
            },
        }
        self.overlays_bytes = j(self.overlays_obj)

        # payload-pins.json (with the real-world host staging reference)
        self.pins_obj = {
            "schema": ofc.PINS_SCHEMA,
            "recorded": "2026-10-26",
            "source": {"repository": ofc.UPSTREAM_REPOSITORY,
                       "branch": "Collabora Online 26.04 mobile release line",
                       "revision": R,
                       "apkVersion": ofc.PRODUCER_VERSION_NAME,
                       "apkCode": ofc.PRODUCER_VERSION_CODE,
                       "embeddedBuildId": ofc.EMBEDDED_BUILD_ID,
                       "bindingLimit": "synthetic"},
            "artifact": {"url": ofc.PRODUCER_APK_URL,
                         "sha256": ofc.PRODUCER_APK_SHA256,
                         "signerCertSha256": ofc.PRODUCER_SIGNER_CERT_SHA256,
                         "signature": "apksigner v2/v3 synthetic"},
            "payload": {"stagedBy": "Local/Private/somewhere/prepare_office_payload.py --stage",
                        "manifestFile": "producer-manifest.json",
                        "manifestSha256": sha(self.manifest_bytes),
                        "files": len(self.manifest_obj["files"]),
                        "selectedBytes": self.manifest_obj["selectedBytes"],
                        "nativeLibraries": 15,
                        "arm64And16KiBAligned": True,
                        "consumedSelection": "5276 asset files + 14 selected native libraries"},
            "libcxxPolicy": {"packaged": False,
                             "officialSha256": official_libcxx_sha,
                             "appOwnSha256": self.app_own_libcxx_sha,
                             "evidence": "257 symbol name-level match synthetic"},
            "libraries": {n: self.manifest_obj["files"][f"lib/arm64-v8a/{n}"]["sha256"]
                          for n in ofc.OFFICE_PINNED_LIBRARIES},
            "anchorAssets": {
                "dist/cool.html": self.manifest_obj["files"]["assets/dist/cool.html"]["sha256"],
                "license.html": self.manifest_obj["files"]["assets/license.html"]["sha256"],
                "notice.txt": self.manifest_obj["files"]["assets/notice.txt"]["sha256"],
            },
        }

        self.write_tree()
        self.write_combined()

    def build_notice_index(self):
        R = ofc.UPSTREAM_REVISION
        obj = {
            "schema": ofc.SOURCE_INDEX_SCHEMA,
            "license": "MPL-2.0",
            "status": "synthetic",
            "payloadIdentity": {
                "publisher": "Collabora Productivity Ltd.",
                "product": "Collabora Office for Android (mobile)",
                "versionName": ofc.PRODUCER_VERSION_NAME,
                "versionCode": ofc.PRODUCER_VERSION_CODE,
                "abi": ofc.PRODUCER_ABI,
                "apkFile": ofc.PRODUCER_APK_FILE,
                "apkUrl": ofc.PRODUCER_APK_URL,
                "apkSha256": ofc.PRODUCER_APK_SHA256,
                "signerCertSha256": ofc.PRODUCER_SIGNER_CERT_SHA256,
            },
            "sourceBinding": {
                "primaryRepository": ofc.UPSTREAM_REPOSITORY,
                "officialMirror": ofc.UPSTREAM_MIRROR,
                "revision": R,
                "monorepo": True,
            },
            "floeOverlay": {"manifest": "core/officeengine/asset-overlays.json",
                            "operationCount": 0, "sourceFileRecords": []},
            "noticePage": {"path": "notices/index.html", "sha256": ""},
            "bundledOriginalNotices": {
                "license.html": {"path": "assets/license.html", "bytes": 0,
                                 "sha256": "", "modified": False},
                "notice.txt": {"path": "assets/notice.txt", "bytes": 0,
                               "sha256": "", "modified": False},
            },
            "floeCorrespondingSource": {
                "status": "release-source-links",
                "tag": f"android/v{self.VERSION}",
                "archiveUrl": ofc.RELEASE_URL_FMT.format(
                    repo=self.REPO, version=self.VERSION,
                    archive=ofc.ARCHIVE_NAME_FMT.format(version=self.VERSION)),
                "sourceRoot": "FloeAndroid/core/officeengine",
            },
            "externalPins": {
                "recipe": "engine/download.lst",
                "recipeUrl": ofc.UPSTREAM_DOWNLOAD_LST_URL,
                "recipeSha256": "ab" * 32,
                "fetchRecipe": "engine/Makefile.fetch",
                "fetchRecipeUrl": f"{ofc.UPSTREAM_MIRROR}/blob/{R}/engine/Makefile.fetch",
                "tarballs": [],
            },
            "selfEntry": "Own digest excluded to avoid circular hash",
        }
        return j(obj)

    def finalize_index(self):
        """Re-embed records/notice/self digests and rewrite the index + the
        overlay self-entry + overlays document so everything stays
        consistent. Call again after mutating overlay/pins inputs."""
        index = json.loads(self.notice_index.decode("utf-8"))
        entries = [e for e in self.overlays_obj["entries"]
                   if e["destination"] != "notices/source-index.json"]
        index["floeOverlay"]["operationCount"] = len(entries) + 1
        index["floeOverlay"]["sourceFileRecords"] = [
            {"path": e["destination"], "operation": e["operation"],
             "originalSha256": e.get("originalSha256"),
             "newSha256": e.get("sha256")} for e in entries]
        index["noticePage"]["sha256"] = sha(self.overlay_blobs["notices/index.html"])
        index["bundledOriginalNotices"]["license.html"]["sha256"] = \
            self.manifest_obj["files"]["assets/license.html"]["sha256"]
        index["bundledOriginalNotices"]["license.html"]["bytes"] = \
            self.manifest_obj["files"]["assets/license.html"]["bytes"]
        index["bundledOriginalNotices"]["notice.txt"]["sha256"] = \
            self.manifest_obj["files"]["assets/notice.txt"]["sha256"]
        index["bundledOriginalNotices"]["notice.txt"]["bytes"] = \
            self.manifest_obj["files"]["assets/notice.txt"]["bytes"]
        self.notice_index = j(index)
        self.index_self_sha = sha(self.notice_index)
        self.overlay_blobs["notices/source-index.json"] = self.notice_index
        for e in self.overlays_obj["entries"]:
            if e["destination"] == "notices/source-index.json":
                e["sha256"] = self.index_self_sha
        self.overlays_bytes = j(self.overlays_obj)
        self.manifest_bytes = j(self.manifest_obj)
        self.pins_obj["payload"]["manifestSha256"] = sha(self.manifest_bytes)

    def write_tree(self):
        self.finalize_index()
        base = self.base
        def put(rel, blob):
            p = base / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(blob)
        put("PROVENANCE.md", b"# Embedded Office producer, source and delivery boundaries\n\nsynthetic public provenance document\n")
        put("build.gradle.kts", b"// synthetic module build source\nval pins = file(\"payload-pins.json\")\n")
        put("consumer-rules.pro", b"-keep class org.libreoffice.androidlib.LOActivity { *; }\n")
        put("asset-overlays.json", self.overlays_bytes)
        put("producer-manifest.json", self.manifest_bytes)
        put("payload-pins.json", (json.dumps(self.pins_obj, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
        put("README.md", b"# module notes\nrun with -Pfloe.office.payloadDir=\"/Volumes/TECLAST-512/IOS AI AGENT/Local/Private/x\"\n")
        put("tools/README.md",
            (b"# Office engine payload producer inputs\nsee "
             + ofc.README_REDACTIONS[0][0].encode()
             + b" for apksigner discovery\n"))
        put("tools/prepare_payload.py", b"#!/usr/bin/env python3\n# synthetic stager tool\n")
        put("tools/test_renderer_witness.js",
            b"// synthetic harness for main-render-integration/READINESS_PROTOCOL.md\n")
        for rel, blob in self.overlay_blobs.items():
            put(f"overlays/{rel}", blob)
        mpl = (b"/*\n * This Source Code Form is subject to the terms of the\n"
               b" * Mozilla Public License, v. 2.0.\n */\n")
        for f in ("COWebView.kt", "COWebViewClient.kt", "LOActivity.kt", "MobileSocket.kt"):
            put(f"src/main/java/org/libreoffice/androidlib/{f}",
                mpl + b"package org.libreoffice.androidlib\n")
        put("src/main/java/org/libreoffice/androidlib/lok/LokClipboardData.kt",
            b"package org.libreoffice.androidlib.lok\n")
        put("src/main/java/com/floe/android/core/officeengine/OfficeEngine.kt",
            b"package com.floe.android.core.officeengine\n")
        put("src/main/java/com/floe/android/core/officeengine/OfficeNoticesActivity.kt",
            b"// SPDX-License-Identifier: MPL-2.0\npackage com.floe.android.core.officeengine\n")
        put("src/main/AndroidManifest.xml", b"<manifest/>\n")
        put("src/main/assets/floe-office/renderer-witness.js",
            b"// SPDX-License-Identifier: MPL-2.0\n")
        put("src/main/res/values/strings.xml", b"<resources/>\n")
        put("src/test/java/com/floe/android/core/officeengine/OfficeReadOnlyProtocolTest.kt",
            b"// SPDX-License-Identifier: MPL-2.0\n")

    def write_combined(self, tar_sha=None, **man_over):
        self.combined.mkdir(parents=True, exist_ok=True)
        inner_files = {
            "README.md": (b"linux-ide offer\n", 0o644),
            "linuxruntime/MANIFEST.json": (b"{}\n", 0o644),
            "third-party/sora-editor/SOURCE.md": (b"x\n", 0o644),
        }
        tar_bytes = ofc.build_archive(self.VERSION, inner_files)
        man = {
            "schemaVersion": 1,
            "tool": {"name": "assemble-android-corresponding-source", "version": "1.0.0"},
            "offer": {"purpose": "combined", "releaseApk": {
                "name": ofc.APK_NAME_FMT.format(version=self.VERSION),
                "sha256": self.apk_sha}},
            "releaseVersion": self.VERSION,
            "sourceCommit": self.COMMIT,
            "linuxRuntime": {"embeddedArchive": "linuxruntime/x.tar.gz",
                             "payloadsSha256": {}},
            "soraEditor": {"coordinate": "io.github.rosemoe:editor:0.24.4"},
            "files": [{"path": k, "sha256": sha(v[0]), "bytes": len(v[0])}
                      for k, v in sorted(inner_files.items())],
        }
        man.update(man_over)
        mb = j(man)
        self.combined_manifest = mb
        name = ofc.INNER_TAR_FMT.format(version=self.VERSION)
        for p in self.combined.iterdir():
            p.unlink()
        (self.combined / name).write_bytes(tar_bytes)
        (self.combined / "MANIFEST.json").write_bytes(mb)
        (self.combined / "SHA256SUMS").write_bytes(
            (f"{sha(tar_bytes)}  {name}\n{sha(mb)}  MANIFEST.json\n").encode())
        self.combined_tar_bytes = tar_bytes

    def argv(self, command, **over):
        version = over.get("release-version", self.VERSION)
        apk_sha = over.get("apk-sha256", self.apk_sha)
        argv = [command,
                "--combined-ccs-dir", str(self.combined),
                "--office-source-dir", str(self.base),
                "--release-version", version,
                "--source-commit", over.get("source-commit", self.COMMIT),
                "--source-repository", over.get("source-repository", self.REPO),
                "--apk-name", over.get("apk-name",
                                       ofc.APK_NAME_FMT.format(version=version)),
                "--apk-sha256", apk_sha]
        if command == "produce":
            argv += ["--out", over.get("out", str(self.root / "out"))]
        return argv

    def run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = ofc.main(argv)
        return rc, out.getvalue(), err.getvalue()

    def check(self, **over):
        return self.run(self.argv("check", **over))

    def snapshot_dirs(self):
        digests = {}
        for start in (self.base, self.combined):
            for dirpath, _dirnames, filenames in os.walk(start):
                for fn in filenames:
                    p = Path(dirpath) / fn
                    digests[str(p)] = sha(p.read_bytes())
        return digests

    def set_overlay_blob(self, rel: str, blob: bytes):
        """Mutate an overlay file and re-derive every dependent digest so the
        ONLY remaining violation is the one under test."""
        self.overlay_blobs[rel] = blob
        for e in self.overlays_obj["entries"]:
            if e.get("source") == rel:
                e["sha256"] = sha(blob)
        self.finalize_index()
        self.write_tree()


def self_notice_html(revision: str) -> bytes:
    return ("""<!doctype html><html lang="en"><head><meta charset="utf-8">"""
            """<title>Floe notices</title></head><body>"""
            f"""<p>Upstream source <code>{revision}</code></p>"""
            """<p lang="zh-CN">本地静态页面</p></body></html>""").encode("utf-8")


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="floe-office-ccs-test-")
        self.tmp = Path(self._tmp.name)
        self.fx = OfficeFixture(self.tmp)
        self.fx.apk_sha = sha(b"SYNTHETIC-FINAL-SIGNED-APK")
        self.fx.write_combined()

    def tearDown(self):
        self._tmp.cleanup()


class PositiveTests(Base):
    def test_check_passes_and_is_deterministic(self):
        rc, out, err = self.fx.check()
        self.assertEqual(rc, 0, err)
        rep = json.loads(out)
        self.assertEqual(rep["officeGroup"],
                         {"embedded": 25, "overlayFiles": 6, "sourceFiles": 11})
        ids = {c["id"] for c in rep["checks"]}
        for must in ("linux-ide-embedded", "office-group-embedded", "pins-sanitized",
                     "recipe-sanitized", "notice-index-self-hash",
                     "overlay-file-set-equality", "overlays-release-tag",
                     "notice-original-notices"):
            self.assertIn(must, ids)
        rc2, out2, _ = self.fx.check()
        self.assertEqual(json.loads(out)["archiveSha256"],
                         json.loads(out2)["archiveSha256"])

    def test_check_writes_nothing(self):
        before = self.fx.snapshot_dirs()
        rc, _, err = self.fx.check()
        self.assertEqual(rc, 0, err)
        self.assertEqual(before, self.fx.snapshot_dirs())
        self.assertFalse((self.tmp / "out").exists())

    def test_produce_writes_three_files_and_reverifies(self):
        rc, out, err = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc, 0, err)
        out_dir = self.tmp / "out"
        names = sorted(p.name for p in out_dir.iterdir())
        self.assertEqual(names, [
            "MANIFEST.json", "SHA256SUMS",
            ofc.ARCHIVE_NAME_FMT.format(version=self.fx.VERSION)])
        sums = (out_dir / "SHA256SUMS").read_text()
        for line in sums.splitlines():
            digest, fname = line.split()
            self.assertEqual(digest, sha((out_dir / fname).read_bytes()))

    def test_embedded_combined_bytes_preserved_exact(self):
        rc, out, err = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc, 0, err)
        arc = self.tmp / "out" / ofc.ARCHIVE_NAME_FMT.format(version=self.fx.VERSION)
        with tarfile.open(arc, "r:gz") as tar:
            member = tar.extractfile(
                f"{ofc.ARCHIVE_ROOT_FMT.format(version=self.fx.VERSION)}/"
                f"linux-ide/{ofc.INNER_TAR_FMT.format(version=self.fx.VERSION)}")
            self.assertEqual(member.read(), self.fx.combined_tar_bytes)

    def test_office_group_members_and_sanitization(self):
        rc, out, err = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc, 0, err)
        rep = json.loads(out)
        out_dir = self.tmp / "out"
        with tarfile.open(out_dir / rep["archiveName"], "r:gz") as tar:
            names = {m.name.split("/", 1)[1] for m in tar.getmembers() if m.isfile()}
        self.assertIn("office/payload-pins.json", names)
        self.assertIn("office/producer-manifest.json", names)
        self.assertIn("office/overlays/share/theme_definitions/online/one.svg", names)
        self.assertIn("office/src/main/java/org/libreoffice/androidlib/MobileSocket.kt", names)
        self.assertIn("office/tools/README.md", names)
        self.assertIn("linux-ide/MANIFEST.json", names)
        self.assertNotIn("office/README.md", names)
        self.assertNotIn("office/tools/test_renderer_witness.js", names)
        with tarfile.open(out_dir / rep["archiveName"], "r:gz") as tar:
            pins_blob = tar.extractfile(
                f"{ofc.ARCHIVE_ROOT_FMT.format(version=self.fx.VERSION)}/"
                "office/payload-pins.json").read()
            recipe_blob = tar.extractfile(
                f"{ofc.ARCHIVE_ROOT_FMT.format(version=self.fx.VERSION)}/"
                "office/tools/README.md").read()
        for frag in ofc.LEAK_FORBIDDEN:
            self.assertNotIn(frag, pins_blob.decode())
            self.assertNotIn(frag, recipe_blob.decode())
        pins_in = json.loads((self.fx.base / "payload-pins.json").read_text())
        pins_out = json.loads(pins_blob.decode())
        self.assertNotIn("stagedBy", pins_out["payload"])
        del pins_in["payload"]["stagedBy"]
        self.assertEqual(pins_out, pins_in)
        self.assertIn("the local Android SDK build-tools directory",
                      recipe_blob.decode())
        manifest = json.loads((out_dir / "MANIFEST.json").read_text())
        self.assertEqual(manifest["officeEngine"]["pinsRendering"]["droppedKeys"],
                         ["payload.stagedBy"])
        self.assertEqual(len(manifest["officeEngine"]["recipeRendering"]["appliedRedactions"]), 1)
        self.assertEqual(manifest["linuxIdeCombined"]["embeddedArchiveSha256"],
                         sha(self.fx.combined_tar_bytes))

    def test_already_clean_inputs_pass(self):
        pins = json.loads((self.fx.base / "payload-pins.json").read_text())
        del pins["payload"]["stagedBy"]
        (self.fx.base / "payload-pins.json").write_text(
            json.dumps(pins, indent=2, ensure_ascii=False) + "\n")
        (self.fx.base / "tools" / "README.md").write_text(
            "# clean recipe\nsee the local build-tools directory\n")
        rc, out, err = self.fx.check()
        self.assertEqual(rc, 0, err)
        rep = json.loads(out)
        recipe = [c for c in rep["checks"] if c["id"] == "recipe-sanitized"][0]
        self.assertTrue(recipe["detail"]["alreadyClean"])
        pinsmeta = [c for c in rep["checks"] if c["id"] == "pins-sanitized"][0]
        self.assertEqual(pinsmeta["detail"]["droppedKeys"], [])


class NegativeBindingTests(Base):
    def assert_fail(self, rc, err, *fragments):
        self.assertEqual(rc, 1)
        for frag in fragments:
            self.assertIn(frag, err)

    def test_apk_name_must_match_version(self):
        rc, _, err = self.fx.check(**{"apk-name": "wrong.apk"})
        self.assert_fail(rc, err, "canonical stage-release name")

    def test_version_grammar(self):
        rc, _, err = self.fx.check(**{"release-version": "../bad"})
        self.assert_fail(rc, err, "stage-release grammar")

    def test_commit_grammar(self):
        rc, _, err = self.fx.check(**{"source-commit": "xyz"})
        self.assert_fail(rc, err, "40 or 64 lowercase hex")

    def test_apk_sha_grammar(self):
        rc, _, err = self.fx.check(**{"apk-sha256": "not-hex"})
        self.assert_fail(rc, err, "64 lowercase hex")

    def test_repository_grammar(self):
        rc, _, err = self.fx.check(**{"source-repository": "oops path"})
        self.assert_fail(rc, err, "OWNER/REPO")


class NegativeCombinedTests(Base):
    def test_stale_generation_commit(self):
        rc, _, err = self.fx.check(**{"source-commit": "e" * 40})
        self.assertIn("sourceCommit", err)
        self.assertEqual(rc, 1)

    def test_stale_generation_apk_binding(self):
        rc, _, err = self.fx.check(**{"apk-sha256": "11" * 32})
        self.assertIn("ONE final signed APK", err)

    def test_tampered_combined_sums(self):
        p = self.fx.combined / "SHA256SUMS"
        lines = p.read_text().splitlines()
        lines[0] = "ff" * 32 + lines[0][64:]
        p.write_text("\n".join(lines) + "\n")
        rc, _, err = self.fx.check()
        self.assertIn("SHA256SUMS", err)

    def test_combined_missing_sora_block(self):
        self.fx.write_combined(soraEditor=None)
        rc, _, err = self.fx.check()
        self.assertIn("soraEditor", err)

    def test_combined_stray_file(self):
        (self.fx.combined / "extra.bin").write_bytes(b"x")
        rc, _, err = self.fx.check()
        self.assertIn("unexpected files", err)

    def test_combined_escape_member_rejected(self):
        files = {"../../escape": (b"bad\n", 0o644)}
        # build_archive writes the prefix anyway; craft a raw tar instead
        import gzip, io as _io
        buf = _io.BytesIO()
        gz = gzip.GzipFile(fileobj=buf, mode="wb", mtime=0, filename="")
        with tarfile.open(fileobj=gz, mode="w") as tar:
            info = tarfile.TarInfo("../evil")
            info.size = 4
            tar.addfile(info, _io.BytesIO(b"evil"))
        gz.close()
        (self.fx.combined / ofc.INNER_TAR_FMT.format(version=self.fx.VERSION)).write_bytes(buf.getvalue())
        mb = self.fx.combined_manifest
        (self.fx.combined / "SHA256SUMS").write_text(
            f"{sha(buf.getvalue())}  {ofc.INNER_TAR_FMT.format(version=self.fx.VERSION)}\n"
            f"{sha(mb)}  MANIFEST.json\n")
        rc, _, err = self.fx.check()
        self.assertIn("escapes the expected root prefix", err)


class NegativeOfficeTests(Base):
    def test_pins_manifest_digest_drift(self):
        p = self.fx.base / "producer-manifest.json"
        p.write_bytes(p.read_bytes() + b"\n")  # trailing newline breaks the digest
        # pins manifestSha256 no longer matches the bytes
        rc, _, err = self.fx.check()
        self.assertIn("manifestSha256", err)

    def test_pins_library_drift(self):
        pins = json.loads((self.fx.base / "payload-pins.json").read_text())
        pins["libraries"]["libnss3.so"] = "99" * 32
        (self.fx.base / "payload-pins.json").write_text(
            json.dumps(pins, indent=2, ensure_ascii=False) + "\n")
        rc, _, err = self.fx.check()
        self.assertIn("producer-manifest record", err)

    def test_pinned_upstream_constants_required(self):
        pins = json.loads((self.fx.base / "payload-pins.json").read_text())
        pins["artifact"]["sha256"] = "88" * 32
        (self.fx.base / "payload-pins.json").write_text(
            json.dumps(pins, indent=2, ensure_ascii=False) + "\n")
        rc, _, err = self.fx.check()
        self.assertIn("pinned official producer APK/signer constants", err)

    def test_libcxx_packaged_policy_drift(self):
        pins = json.loads((self.fx.base / "payload-pins.json").read_text())
        pins["libcxxPolicy"]["packaged"] = True
        (self.fx.base / "payload-pins.json").write_text(
            json.dumps(pins, indent=2, ensure_ascii=False) + "\n")
        rc, _, err = self.fx.check()
        self.assertIn("packaged=false", err)

    def test_overlay_tree_drift(self):
        p = self.fx.base / "overlays/dist/branding.js"
        p.write_bytes(b"tampered bytes without license marker")
        rc, _, err = self.fx.check()
        self.assertIn("overlay replace dist/branding.js", err)

    def test_overlay_original_drift(self):
        entries = json.loads((self.fx.base / "asset-overlays.json").read_text())["entries"]
        for e in entries:
            if e["destination"] == "dist/cool.html":
                e["originalSha256"] = "77" * 32
        (self.fx.base / "asset-overlays.json").write_bytes(
            j({"schema": ofc.OVERLAYS_SCHEMA,
               "producerSource": ofc.UPSTREAM_REVISION,
               "entries": entries,
               "sourceAccess": self.fx.overlays_obj["sourceAccess"]}))
        rc, _, err = self.fx.check()
        self.assertIn("does not match the producer manifest record", err)

    def test_overlay_missing_file(self):
        (self.fx.base / "overlays/share/theme_definitions/online/one.svg").unlink()
        rc, _, err = self.fx.check()
        self.assertIn("overlay replace share/theme_definitions/online/one.svg", err)

    def test_extra_file_in_tree_rejected(self):
        (self.fx.base / "notes.txt").write_bytes(b"unexpected\n")
        rc, _, err = self.fx.check()
        self.assertIn("unexpected files at the office module root", err)

    def test_missing_required_doc_rejected(self):
        (self.fx.base / "PROVENANCE.md").unlink()
        rc, _, err = self.fx.check()
        self.assertIn("missing required public files", err)

    def test_binary_extension_rejected(self):
        (self.fx.base / "src/main/java/com/floe/android/core/officeengine/evil.so").write_bytes(b"\x7fELF")
        rc, _, err = self.fx.check()
        self.assertIn("unexpected type", err)

    def test_symlink_rejected(self):
        os.symlink(str(self.fx.base / "PROVENANCE.md"),
                   str(self.fx.base / "PROVENANCE.link.md"))
        rc, _, err = self.fx.check()
        self.assertIn("symlink", err)

    def test_leak_in_src_rejected(self):
        p = self.fx.base / "src/main/java/com/floe/android/core/officeengine/OfficeEngine.kt"
        p.write_bytes(b"// staged at /Users/someone/secret.kt\npackage x\n")
        rc, _, err = self.fx.check()
        self.assertIn("private operational path fragment", err)

    def test_credential_named_file_rejected(self):
        (self.fx.base / "src/main/java/com/floe/android/core/officeengine/private.kt"
         ).write_bytes(b"package x\n")
        rc, _, err = self.fx.check()
        self.assertIn("credential/evidence deny list", err)

    def test_private_key_content_rejected(self):
        p = self.fx.base / "consumer-rules.pro"
        p.write_bytes(b"-----BEGIN PRIVATE KEY-----\n")
        rc, _, err = self.fx.check()
        self.assertIn("rejected key material", err)

    def test_mpl_notice_must_be_preserved(self):
        p = self.fx.base / "src/main/java/org/libreoffice/androidlib/MobileSocket.kt"
        p.write_bytes(b"package org.libreoffice.androidlib\n")
        rc, _, err = self.fx.check()
        self.assertIn("lost the MPL notice", err)

    def test_release_tag_binding_stale_offer_rejected(self):
        overlays = json.loads((self.fx.base / "asset-overlays.json").read_text())
        overlays["sourceAccess"]["tag"] = "android/v0.1.0-alpha.11"
        (self.fx.base / "asset-overlays.json").write_bytes(j(overlays))
        rc, _, err = self.fx.check()
        self.assertIn("must name THIS release", err)

    def test_archive_url_binding(self):
        overlays = json.loads((self.fx.base / "asset-overlays.json").read_text())
        overlays["sourceAccess"]["archiveUrl"] = "https://example.invalid/x"
        (self.fx.base / "asset-overlays.json").write_bytes(j(overlays))
        rc, _, err = self.fx.check()
        self.assertIn("public release archive URL", err)

    def set_index(self, mutate):
        """Mutate the source index while keeping its overlay add-entry digest
        consistent, so the records-level gate is what fires."""
        idx_path = self.fx.base / "overlays/notices/source-index.json"
        idx = json.loads(idx_path.read_text(encoding="utf-8"))
        mutate(idx)
        blob = j(idx)
        idx_path.write_bytes(blob)
        overlays_path = self.fx.base / "asset-overlays.json"
        overlays = json.loads(overlays_path.read_text(encoding="utf-8"))
        for e in overlays["entries"]:
            if e["destination"] == "notices/source-index.json":
                e["sha256"] = sha(blob)
        overlays_path.write_bytes(j(overlays))

    def test_notice_index_record_dropped(self):
        self.set_index(lambda idx: idx["floeOverlay"]["sourceFileRecords"].pop())
        rc, _, err = self.fx.check()
        self.assertEqual(rc, 1)
        self.assertIn("records", err)

    def test_notice_index_record_field_drift(self):
        def drift(idx):
            idx["floeOverlay"]["sourceFileRecords"][0]["newSha256"] = "9" * 64
        self.set_index(drift)
        rc, _, err = self.fx.check()
        self.assertEqual(rc, 1)
        self.assertIn("does not match the overlay entry", err)

    def test_notice_page_script_rejected(self):
        self.fx.set_overlay_blob(
            "notices/index.html",
            self.fx.overlay_blobs["notices/index.html"].replace(
                b"</body>", b"<script src='x'></script></body>"))
        rc, _, err = self.fx.check()
        self.assertIn("no script", err)

    def test_arr_marker_in_theme_rejected(self):
        rel = "share/theme_definitions/online/one.svg"
        blob = self.fx.overlay_blobs[rel].replace(
            b"<rect/>", b'<rect/><!-- Copyright Collabora, All Rights Reserved -->')
        self.fx.set_overlay_blob(rel, blob)
        rc, _, err = self.fx.check()
        self.assertIn("All-Rights-Reserved", err)

    def test_spdx_marker_required_on_artwork(self):
        self.fx.set_overlay_blob("share/registry/floe-preview-policy.xcd",
                                 b'<?xml version="1.0"?>\n<oor:component-schema/>\n')
        rc, _, err = self.fx.check()
        self.assertIn("MPL-2.0 SPDX marker", err)

    def test_unexpected_producer_revision_rejected(self):
        pins = json.loads((self.fx.base / "payload-pins.json").read_text())
        pins["source"]["revision"] = "f" * 40
        pins["source"]["embeddedBuildId"] = "f" * 10
        (self.fx.base / "payload-pins.json").write_text(
            json.dumps(pins, indent=2, ensure_ascii=False) + "\n")
        rc, _, err = self.fx.check()
        self.assertIn("pinned upstream monorepo revision", err)

    def test_overlay_source_destination_pairing(self):
        overlays = json.loads((self.fx.base / "asset-overlays.json").read_text())
        for e in overlays["entries"]:
            if e["destination"] == "dist/cool.html":
                e["source"] = "dist/other.html"
        (self.fx.base / "asset-overlays.json").write_bytes(j(overlays))
        rc, _, err = self.fx.check()
        self.assertIn("source == destination", err)

    def test_overlay_extra_entry_without_file_rejected(self):
        overlays = json.loads((self.fx.base / "asset-overlays.json").read_text())
        overlays["entries"].append({"operation": "add",
                                    "destination": "share/extra.xcd",
                                    "source": "share/extra.xcd",
                                    "sha256": sha(b"x"), "originalSha256": None,
                                    "reason": "bogus extra"})
        (self.fx.base / "asset-overlays.json").write_bytes(j(overlays))
        rc, _, err = self.fx.check()
        self.assertEqual(rc, 1)
        self.assertIn("overlay add share/extra.xcd", err)


class ProduceWriteTests(Base):
    def test_refuses_nonempty_out(self):
        out = self.tmp / "out"
        out.mkdir()
        (out / "junk").write_bytes(b"x")
        rc, _, err = self.fx.run(self.fx.argv("produce", out=str(out)))
        self.assertIn("must be absent or empty", err)

    def test_twice_refuses_replace(self):
        rc, _, err = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc, 0, err)
        rc2, _, err2 = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc2, 1)
        self.assertIn("must be absent or empty", err2)

    def test_produce_report_matches_check_digest(self):
        rc, out, _ = self.fx.check()
        self.assertEqual(rc, 0)
        expected = json.loads(out)["archiveSha256"]
        rc, out2, err = self.fx.run(self.fx.argv("produce"))
        self.assertEqual(rc, 0, err)
        self.assertEqual(json.loads(out2)["archiveSha256"], expected)


# ---------------------------------------------------------------------------
# prepare-stage-release Office pins gate
# ---------------------------------------------------------------------------

def minimal_elf():
    """A minimal valid AArch64 ELF: ELF64 header + one 16 KiB-aligned PT_LOAD
    segment and NO build-id note (the shape of the producer's prebuilt
    libraries)."""
    ident = b"\x7fELF\x02\x01\x01\x00" + b"\x00" * 8
    header = ident + struct.pack(
        "<HHIQQQIHHHHHH",
        3,            # e_type ET_DYN
        183,          # e_machine AArch64
        1,            # e_version
        0,            # e_entry
        64,           # e_phoff
        0,            # e_shoff (no section headers)
        0,            # e_flags
        64,           # e_ehsize
        56,           # e_phentsize
        1,            # e_phnum
        64,           # e_shentsize
        0,            # e_shnum
        0,            # e_shstrndx
    )
    phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, 0, 0, 0x4000)
    return header + phdr + b"\x00" * 0x100


class StageOfficePinsTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="floe-stage-office-")
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def make_pins_file(self, lib_hashes, native_libraries=15, packaged=False,
                       include_libcxx=False):
        libs = dict(lib_hashes)
        if include_libcxx:
            libs[ofc.LIBCXX_NAME] = "00" * 32
        pins = {
            "schema": psr.OFFICE_PINS_SCHEMA,
            "source": {"revision": "a" * 40, "embeddedBuildId": "a" * 10},
            "artifact": {"url": "https://collabora.invalid/apk",
                         "sha256": "b" * 64, "signerCertSha256": "c" * 64},
            "payload": {"manifestSha256": "d" * 64, "files": 7,
                        "selectedBytes": 1234,
                        "nativeLibraries": native_libraries,
                        "arm64And16KiBAligned": True,
                        "consumedSelection": "x"},
            "libraries": libs,
            "libcxxPolicy": {"packaged": packaged, "officialSha256": "e" * 64,
                             "appOwnSha256": "f" * 64, "evidence": "synth"},
            "anchorAssets": {"license.html": "1" * 64},
        }
        p = self.tmp / "payload-pins.json"
        p.write_text(json.dumps(pins, indent=2) + "\n")
        return p

    def test_load_valid(self):
        p = self.make_pins_file({f"lib{i}.so": "%064x" % i for i in range(14)})
        data = psr.load_office_pins(str(p))
        self.assertEqual(len(data["libraries"]), 14)

    def test_load_rejects_bad_schema(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(14)})
        data = json.loads(p.read_text())
        data["schema"] = "wrong"
        p.write_text(json.dumps(data))
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.schema")

    def test_load_rejects_libcxx_in_libraries(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(13)},
                                include_libcxx=True)
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.libraries")

    def test_load_rejects_count_mismatch(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(12)})
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.libraries")

    def test_load_rejects_packaged_libcxx(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(14)},
                                packaged=True)
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.libcxx")

    def test_load_rejects_buildid_drift(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(14)})
        data = json.loads(p.read_text())
        data["source"]["embeddedBuildId"] = "b" * 10
        p.write_text(json.dumps(data))
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.buildid")

    def test_load_rejects_unsafe_anchor(self):
        p = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(14)})
        data = json.loads(p.read_text())
        data["anchorAssets"]["../secret.html"] = "0" * 64
        p.write_text(json.dumps(data))
        with self.assertRaises(psr.StageReleaseError) as caught:
            psr.load_office_pins(str(p))
        self.assertEqual(caught.exception.code, "office.pins.anchors")

    def make_apk_with_libs(self, blobs):
        path = self.tmp / "app.apk"
        with zipfile.ZipFile(path, "w") as zf:
            for name, blob in blobs.items():
                zf.writestr(f"lib/arm64-v8a/{name}", blob,
                            compress_type=zipfile.ZIP_STORED)
        return path

    def test_native_facts_waiver_only_for_pinned_exact_bytes(self):
        nss_blob = minimal_elf()
        nss_sha = sha(nss_blob)
        other_blob = minimal_elf()
        path = self.make_apk_with_libs({
            "libFloeAndroidCore.so": other_blob,   # no build id -> must still fail
            "libfloe_jni.so": other_blob,
            "libnss3.so": nss_blob,
        })
        pins = self.make_pins_file({"libnss3.so": nss_sha}, native_libraries=2)
        data = psr.load_office_pins(str(pins))
        facts = psr.native_facts(path, data)
        by_id = [p for p in facts["problems"] if "libnss3.so" in p["message"]]
        self.assertFalse(any(p["id"] == "native.build-id" for p in by_id))
        floe_problems = [p for p in facts["problems"]
                         if p["id"] == "native.build-id"]
        self.assertTrue(any("libFloeAndroidCore" in p["message"] for p in floe_problems))
        self.assertEqual(facts["office"]["buildIdWaived"], ["libnss3.so"])
        self.assertEqual(facts["office"]["packagedCount"], 1)
        self.assertEqual(facts["office"]["missing"], [])

    def test_native_facts_without_pins_requires_build_id_everywhere(self):
        path = self.make_apk_with_libs({"libFloeAndroidCore.so": minimal_elf(),
                                        "libfloe_jni.so": minimal_elf(),
                                        "libnss3.so": minimal_elf()})
        facts = psr.native_facts(path)
        ids = [p["id"] for p in facts["problems"]]
        self.assertGreaterEqual(ids.count("native.build-id"), 3)
        self.assertIsNone(facts["office"])

    def test_native_facts_pin_drift_not_waived(self):
        tampered = minimal_elf() + b"extra"
        path = self.make_apk_with_libs({"libFloeAndroidCore.so": minimal_elf(),
                                        "libfloe_jni.so": minimal_elf(),
                                        "libnss3.so": tampered})
        pins = self.make_pins_file({"libnss3.so": sha(minimal_elf())},
                                   native_libraries=2)
        facts = psr.native_facts(path, psr.load_office_pins(str(pins)))
        ids = [p["id"] for p in facts["problems"]]
        self.assertIn("office.pin-drift", ids)
        self.assertIn("native.build-id", ids)  # drift removes the waiver
        self.assertEqual(facts["office"]["pinDrift"], ["libnss3.so"])

    def test_native_facts_missing_pinned_library(self):
        path = self.make_apk_with_libs({"libFloeAndroidCore.so": minimal_elf(),
                                        "libfloe_jni.so": minimal_elf()})
        pins = self.make_pins_file({"libnss3.so": sha(minimal_elf())},
                                   native_libraries=2)
        facts = psr.native_facts(path, psr.load_office_pins(str(pins)))
        self.assertIn("office.library-missing", [p["id"] for p in facts["problems"]])
        self.assertEqual(facts["office"]["missing"], ["libnss3.so"])

    def test_native_facts_official_libcxx_packaged_rejected(self):
        libcxx = minimal_elf()
        pins_file = self.make_pins_file({"libnss3.so": sha(minimal_elf())},
                                        native_libraries=2)
        pins = json.loads(pins_file.read_text())
        pins["libcxxPolicy"]["officialSha256"] = sha(libcxx)
        pins_file.write_text(json.dumps(pins, indent=2))
        path = self.make_apk_with_libs({"libFloeAndroidCore.so": minimal_elf(),
                                        "libfloe_jni.so": minimal_elf(),
                                        "libnss3.so": minimal_elf(),
                                        "libc++_shared.so": libcxx})
        facts = psr.native_facts(path, psr.load_office_pins(str(pins_file)))
        self.assertIn("office.libcxx-official-packaged",
                      [p["id"] for p in facts["problems"]])

    def test_policy_from_args_loads_office_pins(self):
        pins = self.make_pins_file({f"lib{i}.so": "0" * 64 for i in range(14)})
        apk = self.tmp / "app-full-release.apk"
        apk.write_bytes(b"SYNTH")
        ns = argparse.Namespace(
            apk=str(apk), apksigner=None, aapt2=None,
            expected_sha256="0" * 64, package="com.floe.agent.full",
            version_code=14, version_name="0.1.0-alpha.12",
            tag="android/v0.1.0-alpha.12", cert_sha256="1" * 64,
            source_commit="a" * 40, source_repository=None, min_sdk=28,
            target_sdk=37, maturity="prerelease", stage_label="G05",
            previous_version_code=None, previous_cert_sha256=None,
            previous_package=None, previous_release_tag=None,
            native_manifest=None, native_manifest_role="canonical",
            office_pins=str(pins), output=None, body_out=None)
        policy = psr.policy_from_args(ns)
        self.assertEqual(policy.office_pins["schema"], psr.OFFICE_PINS_SCHEMA)
        self.assertEqual(policy.office_pins_sha256, sha(pins.read_bytes()))

    def test_cli_parser_accepts_office_pins(self):
        parser = psr.build_parser()
        base = ["check", "--apk", "x.apk", "--expected-sha256", "0" * 64,
                "--package", "com.floe.agent.full", "--version-code", "14",
                "--version-name", "0.1.0-alpha.12",
                "--tag", "android/v0.1.0-alpha.12", "--cert-sha256", "1" * 64,
                "--source-commit", "a" * 40, "--min-sdk", "28",
                "--target-sdk", "37", "--maturity", "prerelease"]
        args = parser.parse_args(base + ["--office-pins", "pins.json"])
        self.assertEqual(args.office_pins, "pins.json")
        args2 = parser.parse_args(base)
        self.assertIsNone(args2.office_pins)

    def test_evaluate_requires_office_facts_when_pins_set(self):
        policy = psr.ReleasePolicy(
            apk=Path("x.apk"), expected_sha256="0" * 64,
            package="com.floe.agent.full", version_code=14,
            version_name="0.1.0-alpha.12", tag="android/v0.1.0-alpha.12",
            cert_sha256="1" * 64, source_commit="a" * 40, min_sdk=28,
            target_sdk=37, maturity="prerelease",
            office_pins={"schema": psr.OFFICE_PINS_SCHEMA},
            office_pins_sha256="2" * 64)
        facts = minimal_stage_facts()
        report = psr.evaluate(policy, facts, "0" * 64, 10)
        self.assertIn("office.facts-missing",
                      [f["id"] for f in report["failures"]])

    def test_evaluate_records_waiver_limitation(self):
        policy = psr.ReleasePolicy(
            apk=Path("x.apk"), expected_sha256="0" * 64,
            package="com.floe.agent.full", version_code=14,
            version_name="0.1.0-alpha.12", tag="android/v0.1.0-alpha.12",
            cert_sha256="1" * 64, source_commit="a" * 40, min_sdk=28,
            target_sdk=37, maturity="prerelease",
            office_pins={"schema": psr.OFFICE_PINS_SCHEMA},
            office_pins_sha256="2" * 64)
        facts = minimal_stage_facts()
        facts["native"]["office"] = {"buildIdWaived": ["libnss3.so"],
                                     "missing": [], "pinDrift": [],
                                     "packagedCount": 14}
        report = psr.evaluate(policy, facts, "0" * 64, 10)
        notes = [x for x in report["limitations"] if "Office pins gate active" in x]
        self.assertEqual(len(notes), 1)
        self.assertIn("libnss3.so", notes[0])
        self.assertEqual(report["native"]["officePinsFileSha256"], "2" * 64)


def minimal_stage_facts():
    lib = {"name": "lib/arm64-v8a/libFloeAndroidCore.so", "bytes": 1,
           "sha256": "1" * 64, "stored": True, "zipDataOffset": 16384,
           "zipAligned": True, "minLoadAlignment": 16384,
           "loadAlignments": [16384], "buildId": "2" * 20,
           "debugSectionBytes": 0, "debugSections": {},
           "needed": ["libc.so"], "exportCount": 1, "jniExportCount": 0,
           "sectionHeaders": True}
    jni = dict(lib, name="lib/arm64-v8a/libfloe_jni.so", jniExportCount=2)
    return {
        "zip": {"entryCount": 4, "uncompressedBytes": 4, "abis": ["arm64-v8a"],
                "nativeEntries": [lib["name"], jni["name"]],
                "dexEntries": ["classes.dex"], "licenseEntries": [],
                "hasManifest": True, "problems": [],
                "nestedPackageEntries": []},
        "manifest": {"package": "com.floe.agent.full", "versionCode": 14,
                     "versionName": "0.1.0-alpha.12", "minSdk": 28, "targetSdk": 37,
                     "debuggable": False, "testOnly": False, "split": None,
                     "extractNativeLibs": False, "hasInstrumentation": False,
                     "applicationLabel": "@0x1"},
        "badging": {"package": "com.floe.agent.full", "versionCode": "14",
                    "versionName": "0.1.0-alpha.12", "abis": ["arm64-v8a"]},
        "signing": {"verified": True, "schemes": {"v2": True}, "modernScheme": True,
                    "signerCount": 1, "certSha256": "1" * 64,
                    "dn": "CN=Formal", "debugCertificate": False, "problems": []},
        "dex": {"dexFiles": ["classes.dex"], "classCount": 1,
                "markers": {m: True for m in psr.FULL_ONLY_MARKERS},
                "fullOnlyClassCount": 2},
        "native": {"abi": "arm64-v8a", "libraries": [lib, jni], "problems": [],
                   "debugSectionBytes": 0, "maxDebugSectionBytes": 0,
                   "testOnlyLibraries": [], "stripped": True},
        "toolVersions": {},
    }


if __name__ == "__main__":
    unittest.main(verbosity=2)
