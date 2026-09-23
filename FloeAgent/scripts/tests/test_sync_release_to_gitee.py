#!/usr/bin/env python3
"""Mock/contract tests for scripts/sync_release_to_gitee.py.

Everything runs against a local HTTP server that implements the subset of the
GitHub and Gitee v5 APIs the tool uses, including Gitee's single-attachment
size cap, duplicate names, transient 5xx responses and mid-run failures. No
network access and no real credentials are used.

Run:  python3 FloeAgent/scripts/tests/test_sync_release_to_gitee.py -v
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.abspath(os.path.join(HERE, "..", "sync_release_to_gitee.py"))
TOKEN = "TESTTOKEN"

GITHUB_TOKEN = "test-github-token"


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def sha512_hex(data):
    return hashlib.sha512(data).hexdigest()


class MockState:
    def __init__(self, max_upload=262144):
        self.max_upload = max_upload
        self.github_releases = {}          # tag -> release dict
        self.github_assets = {}            # release id -> [asset dict]
        self.github_asset_bytes = {}       # asset id -> bytes
        self.github_asset_override = {}    # asset id -> bytes served (digest mismatch test)
        self.gitee_releases = {}           # id -> release dict
        self.gitee_attach = {}             # fid -> dict(id, name, size, release_id, data)
        self.next_release_id = 700
        self.next_attach_id = 5000
        self.fail_upload_names = {}        # name -> remaining failures (persistent when large)
        self.fail_after_create_names = {}  # name -> remaining "response lost" failures
        self.fail_list_once = 0
        self.requests = []                 # (method, path)
        self.serve_requests = 0

    def add_github_release(self, tag, name, body, prerelease=True, target="main"):
        release_id = 1000 + len(self.github_releases)
        assets = []
        self.github_releases[tag] = {
            "id": release_id,
            "tag_name": tag,
            "name": name,
            "body": body,
            "prerelease": prerelease,
            "draft": False,
            "target_commitish": target,
            "html_url": "https://github.com/example/%s/releases/tag/%s" % ("repo", tag),
            "assets": assets,
        }
        self.github_assets[release_id] = assets
        return release_id

    def add_github_asset(self, release_id, name, data, content_type="application/octet-stream", digest=True):
        assets = self.github_assets[release_id]
        asset_id = 9000 + sum(len(a) for a in self.github_assets.values()) + len(assets)
        asset = {
            "id": asset_id,
            "name": name,
            "size": len(data),
            "content_type": content_type,
            "digest": ("sha256:%s" % sha256_hex(data)) if digest else None,
            "browser_download_url": "https://github.com/example/repo/releases/download/tag/%s" % name,
        }
        assets.append(asset)
        self.github_asset_bytes[asset_id] = data
        return asset_id

    def attach_data(self, fid):
        return self.gitee_attach[fid]["data"]

    def add_gitee_attach(self, release_id, name, data):
        fid = self.next_attach_id
        self.next_attach_id += 1
        self.gitee_attach[fid] = {
            "id": fid,
            "release_id": release_id,
            "name": name,
            "size": len(data),
            "data": data,
        }
        return fid


class MockHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "floe-mock/1"

    def log_message(self, *args):  # keep test output clean
        pass

    # -- helpers -----------------------------------------------------------

    @property
    def state(self):
        return self.server.state

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _send(self, status, payload, content_type="application/json"):
        if isinstance(payload, (dict, list)):
            body = json.dumps(payload).encode("utf-8")
            content_type = "application/json"
        elif isinstance(payload, str):
            body = payload.encode("utf-8")
            content_type = content_type or "text/plain"
        else:
            body = payload
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        header = self.headers.get("Authorization") or ""
        return header == "token %s" % TOKEN

    def _gitee_release_json(self, release):
        attach = [
            {"id": item["id"], "name": item["name"], "size": item["size"]}
            for item in self.state.gitee_attach.values()
            if item["release_id"] == release["id"]
        ]
        unique_names = []
        for item in attach:
            if item["name"] not in unique_names:
                unique_names.append(item["name"])
        payload = dict(release)
        payload["assets"] = [{"name": name} for name in unique_names]
        return payload

    def _parse_multipart(self):
        content_type = self.headers.get("Content-Type") or ""
        match = re.search(r"boundary=([A-Za-z0-9._-]+)", content_type)
        if not match:
            return None, None
        boundary = ("--" + match.group(1)).encode("ascii")
        body = self._read_body()
        parts = body.split(boundary)
        for part in parts:
            if b"Content-Disposition" not in part:
                continue
            split_at = part.find(b"\r\n\r\n")
            if split_at < 0:
                continue
            header = part[:split_at].decode("utf-8", "replace")
            content = part[split_at + 4:]
            if content.endswith(b"\r\n"):
                content = content[:-2]
            name_match = re.search(r'filename="([^"]*)"', header)
            return (name_match.group(1) if name_match else "file"), content
        return None, None

    # -- routing -----------------------------------------------------------

    def do_GET(self):
        self.state.requests.append(("GET", self.path))
        self._route("GET")

    def do_POST(self):
        self.state.requests.append(("POST", self.path))
        self._route("POST")

    def do_PATCH(self):
        self.state.requests.append(("PATCH", self.path))
        self._route("PATCH")

    def do_DELETE(self):
        self.state.requests.append(("DELETE", self.path))
        self._route("DELETE")

    def _route(self, method):
        path = self.path.split("?")[0]
        query = self.path.split("?", 1)[1] if "?" in self.path else ""

        # GitHub API (script uses an /api base).
        if path.startswith("/api/repos/"):
            return self._github(method, path, query)
        if path.startswith("/gh-objects/"):
            asset_id = int(path.rsplit("/", 1)[1])
            data = self.state.github_asset_override.get(asset_id) or self.state.github_asset_bytes[asset_id]
            return self._send(200, data, "application/octet-stream")
        # Gitee API.
        if path.startswith("/api/v5/repos/"):
            if not self._authorized():
                return self._send(401, {"message": "unauthorized"})
            return self._gitee(method, path, query)
        # Gitee public downloads.
        if path.startswith("/gitee/"):
            return self._gitee_download(path)
        return self._send(404, {"message": "not found"})

    # -- GitHub ------------------------------------------------------------

    def _github(self, method, path, query):
        if method != "GET":
            return self._send(405, {"message": "method"})
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            return self._send(401, {"message": "github auth required"})
        match = re.match(r"^/api/repos/[^/]+/[^/]+/releases/assets/(\d+)$", path)
        if match:
            asset_id = int(match.group(1))
            if asset_id not in self.state.github_asset_bytes:
                return self._send(404, {"message": "asset"})
            self.send_response(302)
            self.send_header("Location", "/gh-objects/%d" % asset_id)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        match = re.match(r"^/api/repos/[^/]+/[^/]+/releases/tags/([^/]+)$", path)
        if match:
            tag = match.group(1)
            release = self.state.github_releases.get(tag)
            if release is None:
                return self._send(404, {"message": "release"})
            return self._send(200, release)
        match = re.match(r"^/api/repos/[^/]+/[^/]+/releases/(\d+)/assets$", path)
        if match:
            release_id = int(match.group(1))
            return self._send(200, self.state.github_assets.get(release_id, []))
        match = re.match(r"^/api/repos/[^/]+/[^/]+/releases/(\d+)$", path)
        if match:
            release_id = int(match.group(1))
            for release in self.state.github_releases.values():
                if release["id"] == release_id:
                    return self._send(200, release)
            return self._send(404, {"message": "release"})
        return self._send(404, {"message": "github route"})

    # -- Gitee -------------------------------------------------------------

    def _gitee(self, method, path, query):
        if path.endswith("/releases") and method == "GET":
            return self._send(200, list(self.state.gitee_releases.values()))
        if path.endswith("/releases") and method == "POST":
            payload = json.loads(self._read_body().decode("utf-8"))
            release_id = self.state.next_release_id
            self.state.next_release_id += 1
            release = {
                "id": release_id,
                "tag_name": payload.get("tag_name"),
                "name": payload.get("name"),
                "body": payload.get("body"),
                "prerelease": bool(payload.get("prerelease")),
                "target_commitish": payload.get("target_commitish") or "",
            }
            self.state.gitee_releases[release_id] = release
            return self._send(201, release)
        match = re.match(r"^/api/v5/repos/[^/]+/[^/]+/releases/tags/([^/]+)$", path)
        if match and method == "GET":
            tag = match.group(1)
            for release in self.state.gitee_releases.values():
                if release["tag_name"] == tag:
                    return self._send(200, self._gitee_release_json(release))
            return self._send(404, {"message": "release not found"})
        match = re.match(r"^/api/v5/repos/[^/]+/[^/]+/releases/(\d+)/attach_files$", path)
        if match:
            release_id = int(match.group(1))
            if method == "GET":
                if self.state.fail_list_once > 0:
                    self.state.fail_list_once -= 1
                    return self._send(500, {"message": "transient list failure"})
                items = [
                    {"id": item["id"], "name": item["name"], "size": item["size"]}
                    for item in self.state.gitee_attach.values()
                    if item["release_id"] == release_id
                ]
                return self._send(200, items)
            if method == "POST":
                name, data = self._parse_multipart()
                if name is None:
                    return self._send(400, {"message": "bad multipart"})
                remaining = self.state.fail_upload_names.get(name, 0)
                if remaining > 0:
                    self.state.fail_upload_names[name] = remaining - 1
                    return self._send(500, {"message": "injected upload failure"})
                if len(data) > self.state.max_upload:
                    return self._send(400, {"message": "附件大小超出限制 (%d bytes)" % self.state.max_upload})
                fid = self.state.add_gitee_attach(release_id, name, data)
                lost = self.state.fail_after_create_names.get(name, 0)
                if lost > 0:
                    self.state.fail_after_create_names[name] = lost - 1
                    return self._send(500, {"message": "injected response loss after create"})
                return self._send(201, {"id": fid, "name": name, "size": len(data)})
        match = re.match(r"^/api/v5/repos/[^/]+/[^/]+/releases/(\d+)/attach_files/(\d+)$", path)
        if match and method == "DELETE":
            fid = int(match.group(2))
            item = self.state.gitee_attach.get(fid)
            if item is None:
                return self._send(404, {"message": "attach"})
            del self.state.gitee_attach[fid]
            return self._send(204, b"")
        match = re.match(r"^/api/v5/repos/[^/]+/[^/]+/releases/(\d+)$", path)
        if match:
            release_id = int(match.group(1))
            release = self.state.gitee_releases.get(release_id)
            if release is None:
                return self._send(404, {"message": "release"})
            if method == "GET":
                return self._send(200, self._gitee_release_json(release))
            if method == "PATCH":
                payload = json.loads(self._read_body().decode("utf-8"))
                for key in ("name", "body", "prerelease", "target_commitish"):
                    if key in payload:
                        release[key] = payload[key]
                return self._send(200, release)
        return self._send(404, {"message": "gitee route"})

    def _gitee_download(self, path):
        match = re.match(r"^/gitee/[^/]+/[^/]+/attach_files/(\d+)/download/(.+)$", path)
        if match:
            fid = int(match.group(1))
            item = self.state.gitee_attach.get(fid)
            if item is None:
                return self._send(404, {"message": "attach"})
            data = item.get("corrupt") or item["data"]
            return self._send(200, data, "application/octet-stream")
        match = re.match(r"^/gitee/[^/]+/[^/]+/releases/download/([^/]+)/(.+)$", path)
        if match:
            name = match.group(2)
            for item in self.state.gitee_attach.values():
                if item["name"] == name:
                    return self._send(200, item.get("corrupt") or item["data"], "application/octet-stream")
            return self._send(404, {"message": "asset"})
        return self._send(404, {"message": "download route"})


class MirrorTestCase(unittest.TestCase):
    max_upload = 262144
    shard_bytes = 262144

    def setUp(self):
        self.state = MockState(max_upload=self.max_upload)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
        self.server.state = self.state
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.tmp = tempfile.mkdtemp(prefix="gitee-mirror-test-")
        self.token_file = os.path.join(self.tmp, "token")
        with open(self.token_file, "w", encoding="utf-8") as handle:
            handle.write(TOKEN)
        os.chmod(self.token_file, 0o600)
        self.summary_path = os.path.join(self.tmp, "summary.json")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    # -- harness -----------------------------------------------------------

    def run_mirror(self, tag, extra=(), expect=0):
        args = [
            sys.executable, SCRIPT,
            "--tag", tag,
            "--github-repo", "example/repo",
            "--gitee-repo", "example/repo",
            "--github-api", self.base + "/api",
            "--gitee-api", self.base + "/api/v5",
            "--gitee-web", self.base + "/gitee",
            "--gitee-token-file", self.token_file,
            "--work-root", self.tmp,
            "--min-free-mib", "1",
            "--shard-bytes", str(self.shard_bytes),
            "--summary-json", self.summary_path,
            "--retries", "2",
        ]
        args.extend(extra)
        env = dict(os.environ)
        env["GITHUB_TOKEN"] = GITHUB_TOKEN
        result = subprocess.run(args, capture_output=True, text=True, env=env)
        summary = None
        if os.path.exists(self.summary_path):
            with open(self.summary_path, "r", encoding="utf-8") as handle:
                summary = json.load(handle)
        self.assertEqual(expect, result.returncode, "exit=%s\nstdout=%s\nstderr=%s" % (result.returncode, result.stdout, result.stderr))
        return result, summary

    def gitee_attach_by_name(self, name):
        return [item for item in self.state.gitee_attach.values() if item["name"] == name]

    def expected_block(self, size, shard=None):
        shard = shard or self.shard_bytes
        count = (size + shard - 1) // shard
        return [min(shard, size - i * shard) for i in range(count)]

    def attachment_data(self, name):
        items = [item for item in self.state.gitee_attach.values() if item["name"] == name]
        self.assertTrue(items, "missing attachment %s" % name)
        return items[0]["data"]

    def reassembled(self, prefix):
        """Byte concatenation of attachments whose names start with prefix,
        ordered by name (parallel uploads finish out of order)."""
        items = [item for item in self.state.gitee_attach.values() if item["name"].startswith(prefix)]
        items.sort(key=lambda item: item["name"])
        return b"".join(item["data"] for item in items)

    def seed_app_release(self):
        release_id = self.state.add_github_release("v1.7.0-beta.82", "Floe Agent (build 225)", "Release body", prerelease=True)
        self.state.add_github_asset(release_id, "notes.txt", b"hello mirror\n")
        self.state.add_github_asset(release_id, "small.json", json.dumps({"a": 1}).encode())
        big = bytes((i * 7 + 3) % 251 for i in range(600000))
        self.state.add_github_asset(release_id, "medium.bin", big)
        return release_id, big

    def mutations(self):
        return [entry for entry in self.state.requests if entry[0] in ("POST", "PATCH", "DELETE")]

    # -- tests -------------------------------------------------------------

    def test_first_sync_uploads_and_verifies(self):
        _, big = self.seed_app_release()
        result, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(summary["ok"])
        self.assertEqual(0, summary["gates"]["assets"]["failed"])
        self.assertEqual(3, summary["gates"]["assets"]["uploaded"])
        self.assertEqual(1, len(self.state.gitee_releases))
        names = sorted(item["name"] for item in self.state.gitee_attach.values())
        self.assertEqual(
            sorted(["notes.txt", "small.json", "medium.bin.part-00.bin", "medium.bin.part-01.bin",
                    "medium.bin.part-02.bin", "medium.bin.parts.json", "GITEE-MIRROR-MANIFEST.json"]),
            names,
        )
        # Reassembled shards are byte-identical to the GitHub asset.
        parts = self.reassembled("medium.bin.part-")
        self.assertEqual(big, parts)
        manifest = json.loads(self.gitee_attach_by_name("medium.bin.parts.json")[0]["data"].decode())
        self.assertEqual("floe-release-shard-manifest/v1", manifest["schema"])
        self.assertEqual(sha256_hex(big), manifest["sha256"])
        self.assertEqual(self.expected_block(len(big)), [part["bytes"] for part in manifest["parts"]])
        self.assertEqual(sha256_hex(self.attachment_data("medium.bin.part-00.bin")), manifest["parts"][0]["sha256"])
        # No credential leaks in logs or summary.
        self.assertNotIn(TOKEN, result.stdout + result.stderr + json.dumps(summary))

    def test_rerun_is_idempotent(self):
        self.seed_app_release()
        _, first = self.run_mirror("v1.7.0-beta.82")
        ids_before = sorted(self.state.gitee_attach)
        mutations_before = len(self.mutations())
        _, second = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(second["ok"])
        self.assertEqual(0, second["gates"]["assets"]["uploaded"])
        self.assertEqual(3, second["gates"]["assets"]["skipped"])
        self.assertEqual(ids_before, sorted(self.state.gitee_attach))
        self.assertEqual(mutations_before, len(self.mutations()), "second run must not mutate Gitee")
        self.assertEqual("unchanged", second["gates"]["releaseMetadata"]["status"])
        self.assertEqual(0, first["gates"]["assets"]["failed"])

    def test_corrupt_gitee_copy_is_repaired(self):
        self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        fid = self.gitee_attach_by_name("notes.txt")[0]["id"]
        self.state.gitee_attach[fid]["corrupt"] = b"X" * len(self.state.gitee_attach[fid]["data"])
        _, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(summary["ok"])
        items = self.gitee_attach_by_name("notes.txt")
        self.assertEqual(1, len(items), "duplicate name after repair")
        self.assertEqual(b"hello mirror\n", items[0]["data"])
        self.assertNotEqual(fid, items[0]["id"])

    def test_partial_failure_is_truthful_and_resumable(self):
        _, big = self.seed_app_release()
        self.state.fail_upload_names["medium.bin.part-01.bin"] = 99
        result, first = self.run_mirror("v1.7.0-beta.82", expect=3)
        self.assertFalse(first["ok"])
        self.assertEqual(1, first["gates"]["assets"]["failed"])
        self.assertFalse([item for item in self.state.gitee_attach.values() if item["name"] == "medium.bin.parts.json"])
        uploads_first = len([1 for method, path in self.state.requests if method == "POST" and "attach_files" in path])
        self.state.fail_upload_names.clear()
        result, second = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(second["ok"])
        uploads_second = len([1 for method, path in self.state.requests if method == "POST" and "attach_files" in path]) - uploads_first
        self.assertLess(uploads_second, uploads_first, "resume must not re-upload verified parts")
        parts = self.reassembled("medium.bin.part-")
        self.assertEqual(big, parts)

    def test_dry_run_never_mutates(self):
        self.seed_app_release()
        result, summary = self.run_mirror("v1.7.0-beta.82", extra=["--dry-run"])
        self.assertTrue(summary["dryRun"])
        self.assertEqual([], self.mutations())
        self.assertEqual(0, len(self.state.gitee_releases))

    def test_dry_run_on_existing_release_never_mutates(self):
        self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        mutations_before = len(self.mutations())
        _, summary = self.run_mirror("v1.7.0-beta.82", extra=["--dry-run"])
        self.assertEqual(mutations_before, len(self.mutations()))
        statuses = [item["status"] for item in summary["assets"]]
        self.assertIn("planned-present", statuses)

    def test_metadata_update_reaches_gitee(self):
        release_id, _ = self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        self.state.github_releases["v1.7.0-beta.82"]["body"] = "Updated body"
        self.state.github_releases["v1.7.0-beta.82"]["name"] = "Floe Agent (build 225) rev2"
        _, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertEqual("updated", summary["gates"]["releaseMetadata"]["status"])
        release = list(self.state.gitee_releases.values())[0]
        self.assertIn("Updated body", release["body"])
        self.assertEqual("Floe Agent (build 225) rev2", release["name"])
        self.assertEqual(0, summary["gates"]["assets"]["uploaded"])

    def test_duplicate_names_are_pruned(self):
        self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        release = list(self.state.gitee_releases.values())[0]
        original = self.gitee_attach_by_name("notes.txt")[0]
        self.state.add_gitee_attach(release["id"], "notes.txt", original["data"])
        self.assertEqual(2, len(self.gitee_attach_by_name("notes.txt")))
        _, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(summary["ok"])
        self.assertEqual(1, len(self.gitee_attach_by_name("notes.txt")))

    def test_guest_image_profile_keeps_pinned_manifest_contract(self):
        release_id = self.state.add_github_release(
            "floe-linux-guest-20260922.2", "Floe Linux guest image", "Component body", prerelease=True
        )
        archive = bytes((i * 11 + 5) % 253 for i in range(600000))
        self.state.add_github_asset(release_id, "floe-linux-guest-floe-debian13-riscv64-20260922.2.zip", archive)
        self.state.add_github_asset(release_id, "SHA512SUMS", ("%s  archive.zip\n" % sha512_hex(archive)).encode())
        _, summary = self.run_mirror("floe-linux-guest-20260922.2")
        self.assertTrue(summary["ok"])
        manifest_item = self.gitee_attach_by_name("shard-manifest.json")
        self.assertEqual(1, len(manifest_item))
        manifest = json.loads(manifest_item[0]["data"].decode())
        self.assertEqual("floe-image-shard-manifest/v1", manifest["schema"])
        self.assertEqual("floe-debian13-riscv64-20260922.2", manifest["imageID"])
        self.assertEqual("floe-linux-guest-floe-debian13-riscv64-20260922.2.zip", manifest["archive"])
        self.assertEqual(len(archive), manifest["archiveBytes"])
        self.assertEqual(sha512_hex(archive), manifest["archiveSHA512"])
        self.assertEqual([0, 1, 2], [shard["index"] for shard in manifest["shards"]])
        self.assertEqual(["part-00.bin", "part-01.bin", "part-02.bin"], [shard["name"] for shard in manifest["shards"]])
        parts = self.reassembled("part-")
        self.assertEqual(archive, parts)
        self.assertEqual(sha512_hex(self.attachment_data("part-00.bin")), manifest["shards"][0]["sha512"])
        # The oversized archive itself is not published verbatim.
        self.assertEqual([], [item for item in self.state.gitee_attach.values()
                              if item["name"].endswith(".zip")])

    def test_source_digest_mismatch_refuses_to_upload(self):
        release_id, _ = self.seed_app_release()
        asset_id = [asset for asset in self.state.github_assets[release_id] if asset["name"] == "notes.txt"][0]["id"]
        self.state.github_asset_override[asset_id] = b"tampered bytes"
        _, summary = self.run_mirror("v1.7.0-beta.82", expect=3)
        self.assertFalse(summary["ok"])
        self.assertEqual([], self.gitee_attach_by_name("notes.txt"))

    def test_transient_5xx_is_retried(self):
        self.seed_app_release()
        self.state.fail_list_once = 1
        _, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(summary["ok"])

    def test_include_assets_bounds_the_run(self):
        self.seed_app_release()
        _, summary = self.run_mirror("v1.7.0-beta.82", extra=["--include-assets", "notes.txt"])
        self.assertTrue(summary["ok"])
        self.assertEqual(1, len(summary["assets"]))
        self.assertEqual(["GITEE-MIRROR-MANIFEST.json", "notes.txt"],
                         sorted(item["name"] for item in self.state.gitee_attach.values()))

    def test_low_disk_preflight_blocks_before_any_request(self):
        self.seed_app_release()
        result, summary = self.run_mirror("v1.7.0-beta.82", extra=["--min-free-mib", "999999999"], expect=2)
        self.assertEqual([], self.state.requests)
        self.assertIn("free", (result.stdout + result.stderr).lower())

    def test_unknown_tag_fails_closed(self):
        self.seed_app_release()
        result, summary = self.run_mirror("v9.9.9-bogus", expect=2)
        self.assertEqual([], self.mutations())

    def test_asset_without_github_digest_records_computed_sha256(self):
        release_id = self.state.add_github_release("v1.7.0-beta.82", "Legacy release", "body")
        self.state.add_github_asset(release_id, "legacy.bin", b"legacy bytes", digest=False)
        _, summary = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(summary["ok"])
        manifest = json.loads(self.gitee_attach_by_name("GITEE-MIRROR-MANIFEST.json")[0]["data"].decode())
        self.assertEqual(sha256_hex(b"legacy bytes"), manifest["assets"][0]["sha256"])
        self.assertTrue(self.gitee_attach_by_name("legacy.bin"))

    def test_unsafe_tag_is_rejected_before_any_request(self):
        self.seed_app_release()
        result, summary = self.run_mirror("main;rm -rf", expect=2)
        self.assertEqual([], self.state.requests)
        self.assertIn("suspicious tag", result.stdout + result.stderr)

    def test_parallel_uploads_are_independent_and_resumable(self):
        _, big = self.seed_app_release()
        self.state.fail_upload_names["medium.bin.part-01.bin"] = 99
        result, first = self.run_mirror("v1.7.0-beta.82", extra=["--upload-workers", "3"], expect=3)
        self.assertFalse(first["ok"])
        # The other parts still completed; no manifest pins an incomplete set.
        self.assertEqual([], [item for item in self.state.gitee_attach.values()
                              if item["name"] == "medium.bin.parts.json"])
        self.assertEqual(2, len([1 for item in self.state.gitee_attach.values()
                                 if item["name"].startswith("medium.bin.part-")]))
        self.state.fail_upload_names.clear()
        _, second = self.run_mirror("v1.7.0-beta.82", extra=["--upload-workers", "3"])
        self.assertTrue(second["ok"])
        parts = self.reassembled("medium.bin.part-")
        self.assertEqual(big, parts)

    def test_manifest_has_unique_verified_ids(self):
        self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        manifest = json.loads(self.gitee_attach_by_name("GITEE-MIRROR-MANIFEST.json")[0]["data"].decode())
        self.assertTrue(manifest["complete"])
        by_name = {item["name"]: item for item in manifest["assets"]}
        self.assertEqual({"notes.txt", "small.json", "medium.bin"}, set(by_name))
        for item in by_name.values():
            self.assertEqual("verified", item["state"])
            self.assertTrue(item["complete"])
            self.assertTrue(item["giteeFiles"])
            for record in item["giteeFiles"]:
                self.assertEqual("hash", record["verification"])
                attach = self.state.gitee_attach[int(record["attachId"])]
                self.assertEqual(record["name"], attach["name"])
                self.assertEqual(record["bytes"], attach["size"])
                self.assertEqual(sha256_hex(attach["data"]), record["digests"]["sha256"])

    def test_manifest_upload_failure_keeps_partial_evidence(self):
        self.seed_app_release()
        self.state.fail_upload_names["GITEE-MIRROR-MANIFEST.json"] = 99
        result, summary = self.run_mirror("v1.7.0-beta.82", expect=3)
        self.assertIsNotNone(summary, "summary JSON must survive a manifest failure")
        self.assertFalse(summary["ok"])
        self.assertIn("GITEE-MIRROR-MANIFEST.json", summary["fatal"])
        self.assertGreaterEqual(summary["gates"]["assets"]["uploaded"], 2)
        self.assertEqual(0, summary["gates"]["assets"]["failed"])
        self.assertEqual("failed", summary["gates"]["releaseMetadata"]["mirrorManifest"]["status"])
        self.assertNotIn(TOKEN, json.dumps(summary))
        # The verified uploads are reused on the retry, not transferred again.
        uploads_before = len([1 for method, path in self.state.requests if method == "POST" and "attach_files" in path])
        self.state.fail_upload_names.clear()
        _, second = self.run_mirror("v1.7.0-beta.82")
        self.assertTrue(second["ok"])
        uploads_after = len([1 for method, path in self.state.requests if method == "POST" and "attach_files" in path]) - uploads_before
        self.assertEqual(1, uploads_after, "only the mirror manifest should be uploaded on the retry")

    def test_post_timeout_duplicate_is_reconciled(self):
        _, big = self.seed_app_release()
        self.state.fail_after_create_names["medium.bin.part-00.bin"] = 1
        _, summary = self.run_mirror("v1.7.0-beta.82", extra=["--upload-workers", "1"])
        self.assertTrue(summary["ok"])
        copies = self.gitee_attach_by_name("medium.bin.part-00.bin")
        self.assertEqual(1, len(copies), "a retried upload must leave exactly one attachment")
        self.assertEqual(sha256_hex(big[: self.shard_bytes]), sha256_hex(copies[0]["data"]))
        manifest = json.loads(self.gitee_attach_by_name("GITEE-MIRROR-MANIFEST.json")[0]["data"].decode())
        medium = [item for item in manifest["assets"] if item["name"] == "medium.bin"][0]
        ids = [record["attachId"] for record in medium["giteeFiles"]]
        self.assertIn(copies[0]["id"], [int(value) for value in ids])
        self.assertEqual(len(ids), len(set(ids)), "each planned file keeps one unique id")

    def test_wrong_existing_same_size_copy_is_repaired(self):
        _, big = self.seed_app_release()
        # First run mirrors everything, then a wrong same-size copy appears.
        self.run_mirror("v1.7.0-beta.82")
        release = list(self.state.gitee_releases.values())[0]
        correct = self.gitee_attach_by_name("medium.bin.part-01.bin")[0]
        self.state.gitee_attach[correct["id"]]["data"] = os.urandom(len(correct["data"]))
        self.state.add_gitee_attach(release["id"], "medium.bin.part-01.bin", correct["data"])
        self.run_mirror("v1.7.0-beta.82")
        copies = self.gitee_attach_by_name("medium.bin.part-01.bin")
        self.assertEqual(1, len(copies))
        self.assertEqual(sha256_hex(big[self.shard_bytes : 2 * self.shard_bytes]), sha256_hex(copies[0]["data"]))

    def test_subset_run_does_not_promote_replaced_sibling(self):
        self.seed_app_release()
        self.run_mirror("v1.7.0-beta.82")
        release = list(self.state.gitee_releases.values())[0]
        original = self.gitee_attach_by_name("notes.txt")[0]
        # A same-name same-size sibling replaces the verified attachment id.
        del self.state.gitee_attach[original["id"]]
        self.state.add_gitee_attach(release["id"], "notes.txt", b"X" * len(original["data"]))
        _, subset = self.run_mirror("v1.7.0-beta.82", extra=["--include-assets", "small.json"])
        manifest = json.loads(self.gitee_attach_by_name("GITEE-MIRROR-MANIFEST.json")[0]["data"].decode())
        notes = [item for item in manifest["assets"] if item["name"] == "notes.txt"][0]
        self.assertFalse(notes["complete"], "an unchecked replaced sibling must not be advertised complete")
        self.assertEqual("not-selected", notes["state"])
        self.assertEqual([], notes["giteeFiles"])
        small = [item for item in manifest["assets"] if item["name"] == "small.json"][0]
        self.assertTrue(small["complete"])
        self.assertFalse(manifest["complete"])
        # Selecting the sibling repairs it and the claim becomes verified again.
        _, repaired = self.run_mirror("v1.7.0-beta.82", extra=["--include-assets", "notes.txt"])
        manifest = json.loads(self.gitee_attach_by_name("GITEE-MIRROR-MANIFEST.json")[0]["data"].decode())
        notes = [item for item in manifest["assets"] if item["name"] == "notes.txt"][0]
        self.assertTrue(notes["complete"])
        self.assertEqual("verified", notes["state"])
        self.assertEqual(1, len(self.gitee_attach_by_name("notes.txt")))
        self.assertEqual(b"hello mirror\n", self.gitee_attach_by_name("notes.txt")[0]["data"])
        self.assertTrue(manifest["complete"], "carried-forward verified ids keep the release complete")

    def test_quota_preflight_skips_infeasible_asset_without_uploading(self):
        self.seed_app_release()
        _, summary = self.run_mirror(
            "v1.7.0-beta.82",
            extra=["--gitee-attachment-quota-mib", "0.4"],
            expect=3,
        )
        self.assertFalse(summary["ok"])
        self.assertEqual(1, summary["gates"]["assets"]["failed"])
        failed = [item for item in summary["assets"] if item["status"] == "failed"]
        self.assertEqual("medium.bin", failed[0]["name"])
        self.assertIn("quota", failed[0]["detail"])
        self.assertEqual(int(0.4 * 1024 * 1024), summary["limits"]["giteeAttachmentQuotaBytes"])
        names = sorted(item["name"] for item in self.state.gitee_attach.values())
        self.assertEqual(["GITEE-MIRROR-MANIFEST.json", "notes.txt", "small.json"], names)

    def test_time_budget_defers_work_truthfully(self):
        self.seed_app_release()
        _, summary = self.run_mirror(
            "v1.7.0-beta.82", extra=["--time-budget-minutes", "0.0001"], expect=3
        )
        self.assertFalse(summary["ok"])
        self.assertEqual(3, summary["gates"]["assets"]["deferred"])
        self.assertEqual(0, summary["gates"]["assets"]["failed"])
        # Only the stable mirror manifest may be written; no asset bytes move.
        uploads = [item["name"] for item in self.state.gitee_attach.values()]
        self.assertEqual(["GITEE-MIRROR-MANIFEST.json"], uploads)

    def test_missing_token_file_fails_closed(self):
        self.seed_app_release()
        result, summary = self.run_mirror(
            "v1.7.0-beta.82",
            extra=["--gitee-token-file", os.path.join(self.tmp, "absent-token")],
            expect=2,
        )
        self.assertEqual([], self.state.requests)

    def test_large_asset_streams_without_holding_it_in_ram(self):
        # One 48 MiB asset with 8 MiB shards: a bytes-in-RAM implementation
        # would grow the child process well past the bound below.
        release_id = self.state.add_github_release("v1.7.0-beta.82", "Large release", "body")
        data = os.urandom(48 * 1024 * 1024)
        self.state.add_github_asset(release_id, "large.bin", data)
        self.state.max_upload = 16 * 1024 * 1024
        result, summary = self.run_mirror(
            "v1.7.0-beta.82",
            extra=["--shard-bytes", str(8 * 1024 * 1024), "--progress-mib", "8"],
        )
        self.assertTrue(summary["ok"])
        self.assertIn("[progress]", result.stdout)
        import resource
        usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        peak = usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024
        self.assertLess(peak, 256 * 1024 * 1024, "child peak RSS %d bytes suggests the asset was buffered in memory" % peak)
        parts = self.reassembled("large.bin.part-")
        self.assertEqual(data, parts)


if __name__ == "__main__":
    unittest.main(verbosity=2)
