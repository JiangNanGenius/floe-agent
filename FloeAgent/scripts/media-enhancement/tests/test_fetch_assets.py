#!/usr/bin/env python3
"""Deterministic offline tests for fetch_assets.py.

These run without network, torch or numpy (stdlib only):

  python3 -m unittest discover -s FloeAgent/scripts/media-enhancement/tests -v

They cover the reproducibility-review requirements:
  * every reviewed input carries a pinned 64-hex sha256 (no `None` first-fetch
    path is accepted);
  * a fresh download whose hash does not match is refused and removed;
  * an existing file with the wrong hash is refused without being deleted;
  * a mocked transport produces a deterministic provenance/license staging run;
  * `--check` is read-only and reports missing/mismatching files.

Real-network verification of the small upstream sources is a separate command
(see README): `fetch_assets.py --sources-only` plus
`verify_rrdbnet_source.py --fetch-dir`.
"""
from __future__ import annotations

import hashlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import fetch_assets  # noqa: E402


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FetchVerifiedTests(unittest.TestCase):
    def test_fresh_download_hash_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "asset.bin"
            payload = b"pinned-bytes"
            with unittest.mock.patch.object(fetch_assets, "download", lambda url, dest: dest.write_bytes(payload)):
                result = fetch_assets.fetch_verified("https://example.invalid/asset", target, digest(payload))
            self.assertEqual(result, digest(payload))
            self.assertEqual(target.read_bytes(), payload)

    def test_cached_file_is_not_redownloaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "asset.bin"
            payload = b"cached-bytes"
            target.write_bytes(payload)

            def explode(url, dest):  # pragma: no cover - must not run
                raise AssertionError("cached file must not be re-downloaded")

            with unittest.mock.patch.object(fetch_assets, "download", explode):
                self.assertEqual(fetch_assets.fetch_verified("https://example.invalid/asset", target, digest(payload)),
                                 digest(payload))

    def test_fresh_download_corruption_removed_and_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "asset.bin"
            with unittest.mock.patch.object(fetch_assets, "download", lambda url, dest: dest.write_bytes(b"corrupted")):
                with self.assertRaises(SystemExit) as context:
                    fetch_assets.fetch_verified("https://example.invalid/asset", target, digest(b"expected"))
            self.assertIn("mismatch", str(context.exception))
            self.assertFalse(target.exists(), "a freshly downloaded corrupt file must be removed")

    def test_existing_corruption_is_refused_but_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "asset.bin"
            target.write_bytes(b"evidence-that-must-not-be-deleted")
            with unittest.mock.patch.object(fetch_assets, "download", lambda url, dest: dest.write_bytes(b"expected")):
                with self.assertRaises(SystemExit) as context:
                    fetch_assets.fetch_verified("https://example.invalid/asset", target, digest(b"expected"))
            self.assertIn("refusing to continue", str(context.exception))
            self.assertTrue(target.exists())
            self.assertEqual(target.read_bytes(), b"evidence-that-must-not-be-deleted")

    def test_missing_or_malformed_hash_is_refused_before_transport(self):
        def explode(url, dest):  # pragma: no cover - must not run
            raise AssertionError("unpinned input must not be downloaded")

        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "asset.bin"
            with unittest.mock.patch.object(fetch_assets, "download", explode):
                for expected in (None, "", "not-a-hash", "6aa8eb3f"):
                    with self.assertRaises(SystemExit):
                        fetch_assets.fetch_verified("https://example.invalid/asset", target, expected)
            self.assertFalse(target.exists())

    def test_all_reviewed_inputs_are_pinned(self):
        for table_name in ("BASICSR_FILES", "PRACTICAL_RIFE_FILES", "REALESRGAN_FILES"):
            table = getattr(fetch_assets, table_name)
            for name, expected in table.items():
                self.assertRegex(expected, fetch_assets.SHA256_RE, f"{table_name}[{name}]")
        for name, spec in fetch_assets.REALESRGAN_WEIGHTS.items():
            self.assertRegex(spec["sha256"], fetch_assets.SHA256_RE, name)
        self.assertRegex(fetch_assets.RIFE_WEIGHTS_SHA256, fetch_assets.SHA256_RE)
        self.assertRegex(fetch_assets.RIFE_FLOWNET_SHA256, fetch_assets.SHA256_RE)
        # `--check` never has an unpinned expectation.
        with tempfile.TemporaryDirectory() as temporary:
            paths = fetch_assets.expected_paths(pathlib.Path(temporary), pathlib.Path(temporary))
        self.assertTrue(paths)
        for label, _path, expected, _small in paths:
            self.assertIsNotNone(expected, label)
            self.assertRegex(expected, fetch_assets.SHA256_RE, label)


class OfflineRunTests(unittest.TestCase):
    """Mocked transport: a full deterministic sources-only run.

    The transport content is synthetic, so the pinned hash tables are patched
    to the hashes of exactly that synthetic content. The run still exercises
    the real fetch/verify/stage/check paths and would fail if any input were
    accepted without a matching pinned hash.
    """

    def _setup_patches(self, requests: list[str]) -> tuple[object, dict]:
        def fake_download(url: str, destination: pathlib.Path) -> None:
            requests.append(url)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(f"payload-for::{url}".encode())

        def expected_for(repo: str, commit: str, relative: str) -> str:
            url = fetch_assets.RAW_URL.format(repo=repo, commit=commit, path=relative)
            return digest(f"payload-for::{url}".encode())

        patches = {
            "BASICSR_FILES": {
                relative: expected_for(fetch_assets.BASICSR_REPO, fetch_assets.BASICSR_COMMIT, relative)
                for relative in fetch_assets.BASICSR_FILES
            },
            "PRACTICAL_RIFE_FILES": {
                relative: expected_for("hzwer/Practical-RIFE", fetch_assets.PRACTICAL_RIFE_COMMIT, relative)
                for relative in fetch_assets.PRACTICAL_RIFE_FILES
            },
            "REALESRGAN_FILES": {
                relative: expected_for("xinntao/Real-ESRGAN", fetch_assets.REALESRGAN_COMMIT, relative)
                for relative in fetch_assets.REALESRGAN_FILES
            },
        }
        return fake_download, patches

    def _run(self, arguments: list[str]) -> tuple[int, pathlib.Path, list[str]]:
        requests: list[str] = []
        fake_download, patches = self._setup_patches(requests)
        with unittest.mock.patch.object(fetch_assets, "download", fake_download), \
                unittest.mock.patch.multiple(fetch_assets, **patches), \
                unittest.mock.patch.object(sys, "argv", ["fetch_assets.py", *arguments]):
            code = fetch_assets.main()
        return code, pathlib.Path(arguments[1]), requests

    def _check(self, arguments: list[str]) -> tuple[int, str]:
        requests: list[str] = []
        fake_download, patches = self._setup_patches(requests)
        buffer = io.StringIO()
        with unittest.mock.patch.object(fetch_assets, "download", fake_download), \
                unittest.mock.patch.multiple(fetch_assets, **patches), \
                unittest.mock.patch.object(sys, "stdout", buffer), \
                unittest.mock.patch.object(sys, "argv", ["fetch_assets.py", *arguments, "--check"]):
            code = fetch_assets.main()
        self.assertEqual(requests, [], "check mode must not download")
        return code, buffer.getvalue()

    def test_mocked_sources_only_run_is_deterministic_and_staged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            arguments = [
                "--destination", str(root / "downloads"),
                "--work", str(root / "work"),
                "--licenses", str(root / "licenses"),
                "--sources-only",
            ]
            code, _, requests = self._run(arguments)
            self.assertEqual(code, 0)
            self.assertEqual(len(requests), len(set(requests)), "each source fetched exactly once")
            provenance_path = root / "downloads" / "provenance.json"
            first = provenance_path.read_bytes()
            provenance = json.loads(first)
            self.assertEqual(provenance["schema"], 2)
            self.assertEqual(provenance["mode"], "sources-only")
            licenses = provenance["licenseFiles"]
            self.assertEqual(set(licenses), {
                "floe-model-rife-v4.LICENSE",
                "floe-model-realesrgan-x4plus.LICENSE",
                "floe-model-realesrgan-x2plus.LICENSE",
            })
            for name, entry in licenses.items():
                staged = root / "licenses" / name
                self.assertTrue(staged.exists(), name)
                self.assertEqual(entry["sha256"], digest(staged.read_bytes()), name)
                text = staged.read_text()
                if name == "floe-model-rife-v4.LICENSE":
                    self.assertIn("Practical-RIFE", text)
                    self.assertIn("License: MIT", text)
                else:
                    # The synthetic transport body is not the real license text;
                    # the composed header must still attribute both licenses.
                    for marker in ("BSD-3-Clause", "Apache-2.0", "BasicSR", "Real-ESRGAN"):
                        self.assertIn(marker, text, f"{name}: {marker}")
            # Second run reuses every cached file (no transport at all) and
            # produces byte-identical provenance.
            code, _, second_requests = self._run(arguments)
            self.assertEqual(code, 0)
            self.assertEqual(second_requests, [])
            self.assertEqual(provenance_path.read_bytes(), first)
            # A read-only check passes and writes nothing new.
            before = sorted(path.relative_to(root).as_posix() for path in root.rglob("*"))
            code, _, check_requests = self._run([*arguments, "--check"])
            self.assertEqual(code, 0)
            self.assertEqual(check_requests, [])
            after = sorted(path.relative_to(root).as_posix() for path in root.rglob("*"))
            self.assertEqual(after, before)

    def test_check_detects_corruption_and_missing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            arguments = [
                "--destination", str(root / "downloads"),
                "--work", str(root / "work"),
                "--licenses", str(root / "licenses"),
                "--sources-only",
            ]
            self.assertEqual(self._run(arguments)[0], 0)
            target = root / "work" / "basicsr" / "VERSION"
            target.write_bytes(b"corrupted")
            code, output = self._check(arguments)
            self.assertEqual(code, 1)
            report = json.loads(output)
            self.assertFalse(report["ok"])
            self.assertTrue(any("VERSION" in problem and "mismatch" in problem for problem in report["problems"]))
            (root / "work" / "realesrgan" / "LICENSE").unlink()
            code, output = self._check(arguments)
            self.assertEqual(code, 1)
            report = json.loads(output)
            self.assertTrue(any("missing" in problem and "LICENSE" in problem for problem in report["problems"]))

    def test_license_composition_requires_source_texts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            work = root / "work"
            (work / "upstream-practical-rife").mkdir(parents=True)
            (work / "basicsr").mkdir()
            (work / "realesrgan").mkdir()
            (work / "upstream-practical-rife" / "LICENSE").write_text("MIT License\n\ncopyright\n")
            (work / "basicsr" / "LICENSE.txt").write_text("Apache License\nVersion 2.0\n")
            (work / "realesrgan" / "LICENSE").write_text("BSD 3-Clause License\n\nBSD-3\n")
            sources = {
                "practicalRife": {"files": {"README.md": {"sha256": "a" * 64}, "LICENSE": {"sha256": "b" * 64}}},
            }
            staged = fetch_assets.compose_licenses(root / "licenses", work, sources)
            self.assertEqual(len(staged), 3)
            rife = (root / "licenses" / "floe-model-rife-v4.LICENSE").read_text()
            self.assertIn("The content of these links is under the same MIT license as this project.", rife)
            self.assertIn("MIT License", rife)


if __name__ == "__main__":
    unittest.main()
