#!/usr/bin/env python3
"""Fail-closed notice tests for package_models.py.

Requires numpy/PIL (the conversion venv). Run with:

  Local/Scratch/media-enhancement/venv/bin/python -m unittest \
      discover -s FloeAgent/scripts/media-enhancement/tests -v

Covers the review requirements:
  * the packager refuses a missing/empty/unnoticed/mismatching license instead
    of succeeding with `licenseFile: null`;
  * `--provenance` proves the notice bytes came from the fetch staging;
  * `--reuse-compiled` regenerates only notices/manifests and preserves every
    model/fixture byte, with an old/new hash mapping report.
"""
from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
try:
    import numpy as np

    import package_models  # noqa: E402

    HAVE_DEPS = True
except Exception:  # pragma: no cover - exercised only without numpy/PIL
    HAVE_DEPS = False

RIFE_NOTICE = (
    "Third-party notices — floe-model-rife-v4\n\n"
    "Upstream project: Practical-RIFE\n"
    "License: MIT License\n\nMIT License\n\nCopyright (c) 2021 hzwer\n"
)
REALESRGAN_NOTICE = (
    "Third-party notices — floe-model-realesrgan-x4plus\n\n"
    "1) Real-ESRGAN (weights): BSD 3-Clause License\n"
    "2) BasicSR RRDBNet (architecture): Apache License Version 2.0\n\n"
    "BSD 3-Clause License\n\nApache License\nVersion 2.0\n"
)


def sha256_file(path: pathlib.Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


@unittest.skipUnless(HAVE_DEPS, "numpy/PIL and package_models are required")
class NoticeFailClosedTests(unittest.TestCase):
    def _spec(self, directory: str) -> dict:
        for spec in package_models.MODEL_SPECS:
            if spec["directory"] == directory:
                return spec
        raise AssertionError(directory)

    def test_missing_notice_refused(self):
        spec = self._spec("floe-model-rife-v4")
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(SystemExit) as context:
                package_models.required_notice(spec, pathlib.Path(temporary))
        self.assertIn("missing required notice", str(context.exception))

    def test_empty_notice_refused(self):
        spec = self._spec("floe-model-rife-v4")
        with tempfile.TemporaryDirectory() as temporary:
            (pathlib.Path(temporary) / "floe-model-rife-v4.LICENSE").write_text("  \n")
            with self.assertRaises(SystemExit) as context:
                package_models.required_notice(spec, pathlib.Path(temporary))
        self.assertIn("empty", str(context.exception))

    def test_notice_without_upstream_markers_refused(self):
        spec = self._spec("floe-model-realesrgan-x4plus")
        with tempfile.TemporaryDirectory() as temporary:
            (pathlib.Path(temporary) / "floe-model-realesrgan-x4plus.LICENSE").write_text("see website")
            with self.assertRaises(SystemExit) as context:
                package_models.required_notice(spec, pathlib.Path(temporary))
        self.assertIn("missing upstream markers", str(context.exception))

    def test_provenance_mismatch_refused(self):
        spec = self._spec("floe-model-rife-v4")
        with tempfile.TemporaryDirectory() as temporary:
            license_path = pathlib.Path(temporary) / "floe-model-rife-v4.LICENSE"
            license_path.write_text(RIFE_NOTICE)
            provenance = {"licenseFiles": {"floe-model-rife-v4.LICENSE": {"sha256": "0" * 64}}}
            with self.assertRaises(SystemExit) as context:
                package_models.verify_notice_provenance(spec, license_path, provenance)
        self.assertIn("does not match", str(context.exception))

    def test_provenance_verified(self):
        spec = self._spec("floe-model-rife-v4")
        with tempfile.TemporaryDirectory() as temporary:
            license_path = pathlib.Path(temporary) / "floe-model-rife-v4.LICENSE"
            license_path.write_text(RIFE_NOTICE)
            provenance = {"licenseFiles": {"floe-model-rife-v4.LICENSE": {"sha256": sha256_file(license_path)}}}
            result = package_models.verify_notice_provenance(spec, license_path, provenance)
        self.assertTrue(result["verified"])


@unittest.skipUnless(HAVE_DEPS, "numpy/PIL and package_models are required")
class ReuseCompiledPackagingTests(unittest.TestCase):
    def _write_contract(self, models: pathlib.Path, spec: dict) -> None:
        directory = models / spec["directory"]
        (directory / "reference").mkdir(parents=True)
        contract = {
            "id": f"floe/model-{spec['directory'].removeprefix('floe-model-')}",
            "version": "1.0.0-test",
            "capability": "video.interpolate" if "rife" in spec["directory"] else "video.superResolution",
            "tileSize": 4,
            "scaleFactor": 2,
            "license": "MIT" if "rife" in spec["directory"] else "BSD-3-Clause",
            "licenseEvidence": "https://example.invalid/LICENSE",
            "source": "https://example.invalid/source",
            "sourceCommit": "a" * 40,
            "weightsSha256": "b" * 64,
            "convertedBy": "test",
            "coremltools": "9.0",
            "torch": "2.8.0",
        }
        (directory / "contract.json").write_text(json.dumps(contract))
        for npy_name, _png in spec["fixtures"]:
            np.save(directory / "reference" / npy_name, np.full((4, 4, 3), 128, dtype=np.uint8))
        np.save(directory / "reference" / "coreml_output.npy", np.full((8, 8, 3), 200.0, dtype=np.float32))
        (directory / "reference" / "comparison.json").write_text(json.dumps({"maxAbsDiff": 0.0019, "psnr": 59.0}))

    def _write_licenses(self, licenses: pathlib.Path, provenance_path: pathlib.Path) -> dict:
        entries = {
            "floe-model-rife-v4.LICENSE": RIFE_NOTICE,
            "floe-model-realesrgan-x4plus.LICENSE": REALESRGAN_NOTICE,
            "floe-model-realesrgan-x2plus.LICENSE": REALESRGAN_NOTICE,
        }
        license_files = {}
        for name, text in entries.items():
            (licenses / name).write_text(text)
            license_files[name] = {"sha256": sha256_file(licenses / name)}
        provenance = {
            "basicr": {
                "repo": "XPixelGroup/BasicSR",
                "tag": "v1.4.2",
                "commit": "651835a1b9d38dbbdaf45750f56906be2364f01a",
                "license": "Apache-2.0",
                "files": {
                    "basicsr/archs/rrdbnet_arch.py": {"sha256": "c" * 64},
                    "basicsr/archs/arch_util.py": {"sha256": "d" * 64},
                    "LICENSE.txt": {"sha256": "e" * 64},
                },
            },
            "practicalRife": {
                "weightsLicense": "MIT",
                "weightsLicenseEvidence": {"statement": "MIT", "licenseSha256": "f" * 64},
            },
            "realesrgan": {
                "weightsLicense": "BSD-3-Clause (repository license only)",
                "weightsLicenseStatus": "no separate weights grant published upstream",
                "weightsLicenseEvidence": {"sha256": "1" * 64},
            },
            "licenseFiles": license_files,
        }
        provenance_path.write_text(json.dumps(provenance))
        return provenance

    def test_reuse_compiled_regenerates_notices_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            models = root / "models"
            bundles = root / "bundles"
            licenses = root / "licenses"
            for spec in package_models.MODEL_SPECS:
                self._write_contract(models, spec)
                compiled = bundles / spec["bundle"] / "model.mlmodelc"
                compiled.mkdir(parents=True)
                (compiled / "coremldata.bin").write_bytes(f"compiled::{spec['bundle']}".encode())
            licenses.mkdir(parents=True)
            provenance_path = root / "provenance.json"
            self._write_licenses(licenses, provenance_path)
            before = {
                spec["bundle"]: sha256_file(bundles / spec["bundle"] / "model.mlmodelc" / "coremldata.bin")
                for spec in package_models.MODEL_SPECS
            }
            report_path = root / "reuse-report.json"
            argv = [
                "package_models.py",
                "--models", str(models),
                "--bundles", str(bundles),
                "--licenses", str(licenses),
                "--provenance", str(provenance_path),
                "--reuse-compiled",
                "--reuse-report", str(report_path),
            ]
            with unittest.mock.patch.object(sys, "argv", argv):
                self.assertEqual(package_models.main(), 0)

            for spec in package_models.MODEL_SPECS:
                bundle = bundles / spec["bundle"]
                self.assertEqual(
                    sha256_file(bundle / "model.mlmodelc" / "coremldata.bin"), before[spec["bundle"]],
                    "compiled model bytes must be preserved",
                )
                self.assertTrue((bundle / "LICENSE.txt").exists())
                # LICENSE.txt carries the staged upstream notice, not a stub.
                self.assertEqual((bundle / "LICENSE.txt").read_text(),
                                 (licenses / f"{spec['directory']}.LICENSE").read_text())
                manifest = json.loads((bundle / "manifest.json").read_text())
                self.assertEqual(manifest["id"], spec["bundle"].replace("floe-model-", "floe/model-"))
                for entry in manifest["files"]:
                    self.assertEqual(sha256_file(bundle / entry["path"]), entry["sha256"], entry["path"])
                provenance = json.loads((bundle / "PROVENANCE.json").read_text())
                self.assertEqual(provenance["licenseFile"], "LICENSE.txt")
                self.assertTrue(provenance["noticeProvenance"]["verified"])
                if "realesrgan" in spec["directory"]:
                    self.assertEqual(provenance["weightsLicense"], "BSD-3-Clause (repository license only)")
                    self.assertEqual(provenance["architecture"]["commit"], "651835a1b9d38dbbdaf45750f56906be2364f01a")
                    self.assertIn("no separate weights grant", provenance["weightsLicenseStatus"])
                else:
                    self.assertEqual(provenance["weightsLicense"], "MIT")
            report = json.loads(report_path.read_text())
            for spec in package_models.MODEL_SPECS:
                comparison = report["bundles"][spec["bundle"]]
                self.assertTrue(comparison["modelAndFixtureBytesUnchanged"], spec["bundle"])
                # Only model.mlmodelc pre-existed; everything else is new and
                # no pre-existing model/fixture byte may have changed.
                self.assertTrue(all(not path.startswith(("model.mlmodelc/", "fixtures/"))
                                    for path in {entry["path"] for entry in comparison["changed"]}))
                self.assertIn("model.mlmodelc/coremldata.bin", comparison["unchanged"])

            # Second pass with a corrected notice: model and fixture bytes must
            # stay identical; only the notice/metadata files may change.
            corrected = RIFE_NOTICE + "\nAdditional attribution note added by the notice review.\n"
            (licenses / "floe-model-rife-v4.LICENSE").write_text(corrected)
            provenance_payload = json.loads(provenance_path.read_text())
            provenance_payload["licenseFiles"]["floe-model-rife-v4.LICENSE"]["sha256"] = sha256_file(
                licenses / "floe-model-rife-v4.LICENSE"
            )
            provenance_path.write_text(json.dumps(provenance_payload))
            with unittest.mock.patch.object(sys, "argv", argv):
                self.assertEqual(package_models.main(), 0)
            report = json.loads(report_path.read_text())
            comparison = report["bundles"]["floe-model-rife-v4"]
            self.assertTrue(comparison["modelAndFixtureBytesUnchanged"])
            changed = {entry["path"] for entry in comparison["changed"]}
            self.assertEqual(changed, {"LICENSE.txt", "manifest.json", "PROVENANCE.json"})
            self.assertTrue(all(not path.startswith(("model.mlmodelc/", "fixtures/")) for path in changed))
            self.assertIn("fixtures/expected.png", comparison["unchanged"])
            self.assertEqual(
                (bundles / "floe-model-rife-v4" / "model.mlmodelc" / "coremldata.bin").read_bytes(),
                f"compiled::floe-model-rife-v4".encode(),
            )

    def test_missing_notice_aborts_without_touching_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            models = root / "models"
            bundles = root / "bundles"
            licenses = root / "licenses"
            licenses.mkdir(parents=True)
            spec = package_models.MODEL_SPECS[0]
            self._write_contract(models, spec)
            compiled = bundles / spec["bundle"] / "model.mlmodelc"
            compiled.mkdir(parents=True)
            marker = compiled / "coremldata.bin"
            marker.write_bytes(b"must-survive")
            argv = [
                "package_models.py",
                "--models", str(models),
                "--bundles", str(bundles),
                "--licenses", str(licenses),
                "--reuse-compiled",
            ]
            with unittest.mock.patch.object(sys, "argv", argv):
                with self.assertRaises(SystemExit) as context:
                    package_models.main()
            self.assertIn("missing required notice", str(context.exception))
            self.assertTrue(marker.exists())
            self.assertEqual(marker.read_bytes(), b"must-survive")


if __name__ == "__main__":
    unittest.main()
