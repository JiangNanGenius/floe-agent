#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused regressions for the ccs-lineage review copy of the corresponding-
source producer (v1.1.1-ccslineage-rc1).

Two changed boundaries, each proven positive AND negative:

1. Apple/APSL content scan now mirrors the frozen bootstrap producer
   (build-bootstrap.sh lines 396-403): compat/config/cross prose attestation
   records (*.patch) that merely *describe* the rejected Apple header pass,
   while actual Apple/APSL text in any compiled input (compat headers,
   config/*, cross/*) is still rejected fail-closed.
2. The public manifest/offer binds and lists exactly the two shipped
   executable payloads (lib/libproot.so, lib/libproot_loader.so). An extra
   recorded provenance output (the qualification-only lib/libfloeprobe.so)
   keeps checks passing but must never appear on the public archive surface;
   a provenance missing either shipped binding fails closed.

Stdlib only, synthetic bytes, temp directories. No build, network, Git or
repository writes. Run directly::

    PYTHONDONTWRITEBYTECODE=1 python3 \
        tests/test_ccslineage_patch_regressions.py -v
"""

import io
import tarfile
import unittest
from pathlib import Path

import importlib.util

_spec = importlib.util.spec_from_file_location(
    "ccslineage_base", str(Path(__file__).resolve().parent / "test_produce_corresponding_source.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

ccs = base.ccs
Fixture = base.Fixture
sha = base.sha
BSD_QUEUE_TEXT = base.BSD_QUEUE_TEXT

# The exact negative attestation from the real recipe tree
# (FloeAndroid/core/linuxruntime/native-build/compat/queue.h.cdefs-adapt.patch).
PROSE_ATTESTATION = (
    "--- a/compat/queue.h.orig\n+++ b/compat/queue.h\n"
    "@@\n-#include <sys/cdefs.h>\n+#include <stddef.h>\n"
    "# Adaptation: bionic sys/queue.h is BSD-3-Clause; the adapted file keeps\n"
    "# the full notice preserved. No Apple/APSL text involved.\n")


def load_report(fx, extra=()):
    return ccs.load_and_validate(base.parse(fx.argv("check", extra)))


def manifest_of(report):
    import json
    return json.loads(report["_manifest_bytes"].decode("utf-8"))


def member_text(report, name):
    with tarfile.open(fileobj=io.BytesIO(report["_tar_bytes"]), mode="r:gz") as tar:
        for m in tar.getmembers():
            if m.name.endswith(name):
                f = tar.extractfile(m)
                return f.read().decode("utf-8")
    raise AssertionError(f"member {name} missing from archive")


class ApslScanScope(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self.tmp.name))
        self.addCleanup(self.tmp.cleanup)

    def test_prose_attestation_patch_passes(self):
        (self.fx.recipe / "compat" / "queue.h.cdefs-adapt.patch").write_text(
            PROSE_ATTESTATION)
        self.fx.write_provenance()  # rebind recipe hash with the new file
        report = load_report(self.fx)
        names = {c["id"] for c in report["checks"] if c["ok"]}
        self.assertIn("recipe-tree-binds-provenance", names)
        self.assertIn("no-apple-apsl-in-recipe", names)
        # the attestation file still ships inside native-build/
        self.assertIn("native-build/compat/queue.h.cdefs-adapt.patch",
                      [f["path"] for f in manifest_of(report)["files"]])

    def test_apsl_in_compiled_queue_header_still_rejected(self):
        (self.fx.recipe / "compat" / "queue.h").write_text(
            BSD_QUEUE_TEXT + "\n * Copyright (c) 2023 Apple Inc. — APSL-2.0\n")
        self.fx.write_provenance()
        with self.assertRaises(ccs.ProduceError) as ctx:
            load_report(self.fx)
        self.assertIn("queue.h", str(ctx.exception))
        self.assertIn("APSL", str(ctx.exception))

    def test_apsl_in_cross_shim_still_rejected(self):
        shim = self.fx.recipe / "cross" / "aarch64-linux-musl-gcc"
        shim.write_text("#!/bin/sh\n# Apache-licensed? Apple Inc. APSL header here\nexec zig cc \"$@\"\n")
        self.fx.write_provenance()
        with self.assertRaises(ccs.ProduceError):
            load_report(self.fx)

    def test_deny_and_text_checks_still_cover_patch_files(self):
        p = self.fx.recipe / "compat" / "queue.h.cdefs-adapt.patch"
        p.write_bytes(b"\x00\x01binary is never a recipe input")
        self.fx.write_provenance()
        with self.assertRaises(ccs.ProduceError):
            load_report(self.fx)


class ShippedPayloadSelection(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self.tmp.name))
        self.addCleanup(self.tmp.cleanup)

    def _with_probe_output(self):
        import json
        prov = json.loads(self.fx.provenance.read_text())
        prov["outputs_sha256"]["lib/libfloeprobe.so"] = sha(b"qualification probe")
        self.fx.provenance.write_text(json.dumps(prov, indent=1))

    def test_extra_output_passes_but_is_never_publicly_listed(self):
        self._with_probe_output()
        report = load_report(self.fx, extra=["--relink-evidence", str(self.fx.relink)])
        man = manifest_of(report)
        self.assertEqual(man["offer"]["binaries"],
                         ["lib/libproot.so", "lib/libproot_loader.so"])
        self.assertEqual(sorted(man["provenance"]["payloadsSha256"]),
                         ["lib/libproot.so", "lib/libproot_loader.so"])
        self.assertNotIn("libfloeprobe", man["provenance"]["payloadsSha256"])
        self.assertNotIn(b"libfloeprobe", report["_manifest_bytes"])
        offer = member_text(report, "CORRESPONDING-SOURCE.md")
        self.assertNotIn("libfloeprobe", offer)
        self.assertIn("`lib/libproot.so`", offer)
        self.assertIn("`lib/libproot_loader.so`", offer)

    def test_missing_shipped_binding_rejected(self):
        import json
        prov = json.loads(self.fx.provenance.read_text())
        del prov["outputs_sha256"]["lib/libproot_loader.so"]
        self.fx.provenance.write_text(json.dumps(prov, indent=1))
        with self.assertRaises(ccs.ProduceError) as ctx:
            load_report(self.fx)
        self.assertIn("lib/libproot_loader.so", str(ctx.exception))

    def test_garbage_shipped_binding_rejected(self):
        import json
        prov = json.loads(self.fx.provenance.read_text())
        prov["outputs_sha256"]["lib/libproot.so"] = "not-a-hash"
        self.fx.provenance.write_text(json.dumps(prov, indent=1))
        with self.assertRaises(ccs.ProduceError):
            load_report(self.fx)


class UnchangedBindings(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self.tmp.name))
        self.addCleanup(self.tmp.cleanup)

    def test_recipe_drift_still_rejected(self):
        (self.fx.recipe / "PINS.md").write_text("# pins\ndrifted\n")
        with self.assertRaises(ccs.ProduceError) as ctx:
            load_report(self.fx)
        self.assertIn("recipe_tree_sha256", str(ctx.exception))

    def test_determinism_preserved_with_probe_output(self):
        import json
        self._prov = json.loads(self.fx.provenance.read_text())
        self._prov["outputs_sha256"]["lib/libfloeprobe.so"] = sha(b"qualification probe")
        self.fx.provenance.write_text(json.dumps(self._prov, indent=1))
        r1 = load_report(self.fx)
        r2 = load_report(self.fx)
        self.assertEqual(r1["archiveSha256"], r2["archiveSha256"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
