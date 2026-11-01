#!/usr/bin/env python3
"""Argument-array and response-boundary tests for the gh transport."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import publication_support as support  # noqa: F401
import publish_bridge_release as pub


def include_response(status: str, body: dict | bytes, *, extra_headers: str = "") -> bytes:
    raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    headers = f"HTTP/2.0 {status}\r\nContent-Type: application/json\r\n{extra_headers}\r\n"
    return headers.encode("ascii") + raw


class RecordingRunner:
    def __init__(self, response):
        self.response = response
        self.calls: list[tuple[list[str], bytes | None, Path | None]] = []

    def __call__(self, argv, input_bytes, input_path):
        self.calls.append((list(argv), input_bytes, input_path))
        if isinstance(self.response, Exception):
            raise self.response
        return pub.CommandResult(0, self.response, b"")


class GhTransportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-gh-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_get_argv_and_include_parsing(self) -> None:
        runner = RecordingRunner(include_response("200 OK", {"tag_name": "v1.7.65"}))
        transport = pub.GhTransport(runner=runner)
        status, payload = transport.api_json(
            "GET", "repos/JiangNanGenius/floe-agent/releases/latest"
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"tag_name": "v1.7.65"})
        self.assertEqual(runner.calls[0][0], [
            "gh",
            "api",
            "--hostname",
            "github.com",
            "--method",
            "GET",
            "--include",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            "repos/JiangNanGenius/floe-agent/releases/latest",
        ])
        self.assertIsInstance(runner.calls[0][0], list)
        self.assertIsNone(runner.calls[0][1])
        self.assertIsNone(runner.calls[0][2])

    def test_post_uses_json_stdin_and_no_shell(self) -> None:
        runner = RecordingRunner(include_response("201 Created", {"id": 123}))
        transport = pub.GhTransport(runner=runner)
        payload = {
            "tag_name": "floe-ios-bridge-v1.0.0",
            "target_commitish": "a" * 40,
            "name": "Floe iOS Bridge 1.0.0",
            "body": "notes",
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
            "generate_release_notes": False,
        }
        status, body = transport.api_json(
            "POST", "repos/JiangNanGenius/floe-agent/releases", payload
        )
        self.assertEqual(status, 201)
        self.assertEqual(body, {"id": 123})
        argv, input_bytes, input_path = runner.calls[0]
        self.assertIsNone(input_path)
        self.assertEqual(json.loads(input_bytes), payload)
        self.assertEqual(input_bytes, json.dumps(payload, sort_keys=True).encode("utf-8"))
        self.assertIn("--input", argv)
        self.assertEqual(argv[argv.index("--input") + 1], "-")
        self.assertIn("Content-Type: application/json", argv)
        self.assertNotIn("shell", argv)

    def test_upload_uses_exact_file_and_query_name(self) -> None:
        asset = self.root / "Floe-iOS-Bridge-1.0.0-unsigned.ipa"
        asset.write_bytes(b"ipa bytes")
        runner = RecordingRunner(include_response("201 Created", {"name": asset.name}))
        transport = pub.GhTransport(runner=runner)
        status, body = transport.upload(
            "https://uploads.github.com/repos/JiangNanGenius/floe-agent/releases/1/assets{?name,label}",
            asset.name,
            asset,
        )
        self.assertEqual(status, 201)
        argv, input_bytes, input_path = runner.calls[0]
        self.assertIsNone(input_bytes)
        self.assertEqual(input_path, asset)
        self.assertIn("--input", argv)
        self.assertEqual(argv[argv.index("--input") + 1], str(asset))
        self.assertIn("Content-Type: application/octet-stream", argv)
        self.assertIn(
            "https://uploads.github.com/repos/JiangNanGenius/floe-agent/releases/1/assets?name="
            + asset.name,
            argv,
        )
        self.assertNotIn("--clobber", argv)

    def test_404_is_not_found(self) -> None:
        runner = RecordingRunner(include_response("404 Not Found", {"message": "Not Found"}))
        transport = pub.GhTransport(runner=runner)
        with self.assertRaises(pub.NotFound) as caught:
            transport.api_json("GET", "repos/x/y/releases/tags/nope")
        self.assertEqual(caught.exception.status, 404)

    def test_write_timeout_is_ambiguous(self) -> None:
        runner = RecordingRunner(subprocess.TimeoutExpired(["gh"], 1))
        transport = pub.GhTransport(runner=runner)
        with self.assertRaises(pub.AmbiguousWrite):
            transport.api_json("POST", "repos/x/y/releases", {"draft": True})

    def test_error_redacts_token_material(self) -> None:
        secret = "github_pat_11AAAAAAAAAAAAAAAAAAAA"
        def failing(argv, input_bytes, input_path):
            return pub.CommandResult(
                1,
                include_response("403 Forbidden", {"message": "bad token"}),
                f"gh: rejected {secret}".encode("utf-8"),
            )
        transport = pub.GhTransport(runner=failing)
        with self.assertRaises(pub.GitHubError) as caught:
            transport.api_json("GET", "repos/x/y/releases/latest")
        message = str(caught.exception)
        self.assertNotIn(secret, message)
        self.assertIn("<redacted>", message)

    def test_real_verifier_command_is_exact_and_read_only(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"ok": True, "sourceRef": "a" * 40}),
            stderr="",
        )
        with mock.patch.object(pub.subprocess, "run", return_value=completed) as run:
            payload = pub.run_public_verifier(
                ipa="/tmp/asset.ipa",
                sidecar="/tmp/asset.ipa.sha256",
                summary="/tmp/asset-public.json",
                version="1.0.0",
                build="14",
                source_ref="a" * 40,
                tag="floe-ios-bridge-v1.0.0",
                repo_root="/tmp/repo",
                project="/tmp/repo/FloeIOSBridge/project.yml",
                latest_json="/tmp/latest.json",
                expect_latest_tag="v1.7.65",
                strict=True,
            )
        self.assertTrue(payload["ok"])
        argv = run.call_args[0][0]
        self.assertEqual(argv[0:2], [sys.executable, "-B"])
        self.assertTrue(argv[2].endswith("verify_public_release.py"))
        self.assertEqual(argv[3:], [
            "--ipa", "/tmp/asset.ipa",
            "--sha256", "/tmp/asset.ipa.sha256",
            "--public-summary", "/tmp/asset-public.json",
            "--version", "1.0.0",
            "--build", "14",
            "--source-ref", "a" * 40,
            "--tag", "floe-ios-bridge-v1.0.0",
            "--repo-root", "/tmp/repo",
            "--project", "/tmp/repo/FloeIOSBridge/project.yml",
            "--latest-json", "/tmp/latest.json",
            "--expect-latest-tag", "v1.7.65",
            "--strict",
            "--json",
        ])

    def test_real_verifier_nonzero_exit_is_a_failure(self) -> None:
        completed = subprocess.CompletedProcess(
            args=[], returncode=1, stdout=json.dumps({"ok": True}), stderr="failed"
        )
        with mock.patch.object(pub.subprocess, "run", return_value=completed):
            payload = pub.run_public_verifier(
                ipa="/tmp/asset.ipa",
                sidecar="/tmp/asset.ipa.sha256",
                summary="/tmp/asset-public.json",
                version="1.0.0",
                build="14",
                source_ref="a" * 40,
                tag="floe-ios-bridge-v1.0.0",
                repo_root="/tmp/repo",
                project="/tmp/repo/FloeIOSBridge/project.yml",
                latest_json="/tmp/latest.json",
                expect_latest_tag="v1.7.65",
                strict=True,
            )
        self.assertFalse(payload["ok"])

    def test_client_paths_are_the_expected_rest_endpoints(self) -> None:
        runner = RecordingRunner(include_response(
            "200 OK",
            {"ref": "refs/tags/floe-ios-bridge-v1.0.0", "object": {"type": "tag", "sha": "a" * 40}},
        ))
        transport = pub.GhTransport(runner=runner)
        client = pub.GitHubClient(transport=transport)
        client.get_tag_ref("floe-ios-bridge-v1.0.0")
        self.assertEqual(
            runner.calls[-1][0][-1],
            "repos/JiangNanGenius/floe-agent/git/ref/tags/floe-ios-bridge-v1.0.0",
        )


if __name__ == "__main__":
    unittest.main()
