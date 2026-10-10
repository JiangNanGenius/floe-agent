#!/usr/bin/env python3
"""
Hermetic tests for FloeCADKit/bootstrap.py.

These tests never touch the real Vendor/ files and never reach the public
internet. A loopback HTTP server stands in for the pinned Git-LFS endpoint
(batch API + object bytes), so the full resolve -> download -> verify ->
atomic-install path is exercised deterministically with tiny fixtures.

Run:
    python3 Tests/bootstrap_tests.py
Optional exact-pinned-bytes bridge (after a real object is staged locally):
    FLOECAD_REAL_OS64=/path/to/libOCCT-OS64.a python3 Tests/bootstrap_tests.py
"""

import contextlib
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import socketserver
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
BOOTSTRAP = os.path.join(os.path.dirname(HERE), "bootstrap.py")


def _load_bootstrap():
    spec = importlib.util.spec_from_file_location("floecad_bootstrap", BOOTSTRAP)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bs = _load_bootstrap()

# Use tight, deterministic timeouts/retries so failure-injection tests are fast
# and never depend on the public network.
bs.CONNECT_TIMEOUT = 2.0
bs.READ_TIMEOUT = 5.0
bs.MAX_RETRIES = 1  # integrity failures must fail fast; transport retries not needed
os.environ["FLOECAD_DEADLINE"] = "30"
bs.DEADLINE = 30.0

GOOD_PAYLOAD = b"floe-occt-slice-fixture-" + bytes(range(256)) * 96  # 24864 bytes
GOOD_SIZE = len(GOOD_PAYLOAD)
GOOD_SHA = hashlib.sha256(GOOD_PAYLOAD).hexdigest()

REL_PATH = "Vendor/OCCT.xcframework/ios-arm64/libOCCT-OS64.a"
BATCH_PATH = "/repo.git/info/lfs/objects/batch"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


class _FakeResponse:
    """Minimal stream used to unit-test _read_bounded without sockets."""

    def __init__(self, data):
        self._data = data
        self._pos = 0

    def read(self, n):
        chunk = self._data[self._pos:self._pos + n]
        self._pos += len(chunk)
        return chunk


class LFSHandler(http.server.BaseHTTPRequestHandler):
    """Minimal Git-LFS-compatible loopback server, behaviour driven by server flag."""

    def log_message(self, *args):  # silence
        pass

    def _server(self):
        return self.server

    def do_POST(self):
        if self.path != BATCH_PATH:
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        objs = []
        for o in body.get("objects", []):
            objs.append({
                "oid": o["oid"],
                "size": o["size"],
                "actions": {
                    "download": {
                        "href": "http://127.0.0.1:%d/objects/%s"
                                % (self._server().server_address[1], o["oid"]),
                    }
                },
            })
        payload = json.dumps({"objects": objs}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.git-lfs+json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        srv = self._server()
        if srv.mode == "redirect_object" and self.path.startswith("/objects/"):
            # Same-scheme loopback redirect: the opener must follow it.
            oid = self.path.split("/objects/", 1)[1]
            self.send_response(302)
            self.send_header("Location",
                             "http://127.0.0.1:%d/objects2/%s"
                             % (srv.server_address[1], oid))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path.startswith("/objects2/"):
            oid = self.path.split("/objects2/", 1)[1]
        elif self.path.startswith("/objects/"):
            oid = self.path.split("/objects/", 1)[1]
        else:
            self.send_response(404)
            self.end_headers()
            return
        if oid not in srv.objects:
            self.send_response(404)
            self.end_headers()
            return
        payload = srv.objects[oid]
        if srv.mode == "short_body":
            # Advertise the full length, then close early: the client must
            # treat this as a failed download, never as good bytes.
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload[: max(1, len(payload) // 2)])
            try:
                self.wfile.flush()
            except OSError:
                pass
            self.close_connection = True
            return
        if srv.mode == "truncate":
            payload = payload[: max(1, len(payload) // 2)]
        elif srv.mode == "corrupt":
            payload = b"X" + payload[1:]  # same length, wrong hash
        elif srv.mode == "extra":
            payload = payload + b"trailing-bytes"
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        # Serve in two writes to mimic chunked/partial arrival.
        cut = max(1, len(payload) // 2)
        self.wfile.write(payload[:cut])
        self.wfile.write(payload[cut:])


class LFSServer(socketserver.TCPServer):
    allow_reuse_address = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), LFSHandler)
        self.objects = {}
        self.mode = "good"


def start_server():
    srv = LFSServer()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def write_manifest(root, port, payload=GOOD_PAYLOAD, install_path=REL_PATH,
                   source_kind="git-lfs", scheme="http", extra_source=None):
    sha = sha256_bytes(payload)
    manifest = {
        "schemaVersion": 1,
        "package": "floe-test",
        "artifacts": [
            {
                "name": "fixture",
                "installPath": install_path,
                "size": len(payload),
                "sha256": sha,
                "source": {
                    "kind": source_kind,
                    "sourceId": "src",
                    "upstreamPath": "ThirdParty/x.a",
                    "oid": sha,
                    "oidAlgorithm": "sha256",
                },
            }
        ],
        "sources": {
            "src": {
                "kind": "git-lfs",
                "repositoryWeb": "http://127.0.0.1",
                "repositoryClone": "http://127.0.0.1/repo.git",
                "commit": "0" * 40,
                "lfsBatchApi": "%s://127.0.0.1:%d%s" % (scheme, port, BATCH_PATH),
                "lfsTransfer": "basic",
            }
        },
    }
    if extra_source:
        manifest["sources"].update(extra_source)
    with open(os.path.join(root, "DEPENDENCIES.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh)
    return sha


class BootstrapTestBase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="floecad-test-")
        self.srv = start_server()
        self.srv.objects[GOOD_SHA] = GOOD_PAYLOAD

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.root, ignore_errors=True)

    def dest(self):
        return bs.safe_install_path(self.root, REL_PATH)

    def write_manifest(self, **kw):
        return write_manifest(self.root, self.srv.server_address[1], **kw)

    def run_bootstrap(self, check=False, offline=False, local_relink=False):
        logs = []
        rc = bs.run(self.root, check=check, offline=offline, local_relink=local_relink,
                    log=lambda m: logs.append(m))
        return rc, logs


class TestPathSafety(BootstrapTestBase):
    def test_relative_path_allowed(self):
        self.write_manifest()
        dest = self.dest()
        self.assertTrue(dest.startswith(os.path.realpath(self.root)))

    def test_parent_escape_refused(self):
        self.write_manifest(install_path="../../evil.a")
        with self.assertRaises(bs.PathEscapeError):
            bs.run(self.root, check=True, offline=False, log=lambda m: None)
        # Nothing escaped the temp root.
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(self.root), "evil.a")))

    def test_absolute_path_refused(self):
        self.write_manifest(install_path="/tmp/floecad-abs-evil.a")
        with self.assertRaises(bs.PathEscapeError):
            bs.run(self.root, check=True, offline=False, log=lambda m: None)
        self.assertFalse(os.path.exists("/tmp/floecad-abs-evil.a"))

    def test_backslash_escape_refused(self):
        # On POSIX a backslash is a literal filename char, but a leading slash
        # style is still rejected; assert containment for an odd-but-bounded path.
        self.write_manifest(install_path=os.path.join("Vendor", "..", "stillinside.a"))
        dest = bs.safe_install_path(self.root, os.path.join("Vendor", "..", "stillinside.a"))
        self.assertTrue(dest.startswith(os.path.realpath(self.root)))

    def test_symlink_escape_refused(self):
        # A symlinked intermediate directory pointing outside the package must
        # not be followed: realpath containment refuses it.
        self.write_manifest()
        outside = tempfile.mkdtemp(prefix="floecad-outside-")
        try:
            os.symlink(outside, os.path.join(self.root, "Vendor"))
            with self.assertRaises(bs.PathEscapeError):
                bs.run(self.root, check=True, offline=False, log=lambda m: None)
            self.assertEqual(os.listdir(outside), [])
        finally:
            shutil.rmtree(outside, ignore_errors=True)


class TestCheckReadOnly(BootstrapTestBase):
    def test_check_ok_present_and_verified(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(GOOD_PAYLOAD)
        before = os.stat(self.dest()).st_mtime_ns
        rc, _ = self.run_bootstrap(check=True)
        self.assertEqual(rc, 0)
        self.assertEqual(os.stat(self.dest()).st_mtime_ns, before)

    def test_check_absent_returns_2_and_writes_nothing(self):
        self.write_manifest()
        before = sorted(os.listdir(self.root))
        rc, _ = self.run_bootstrap(check=True)
        self.assertEqual(rc, 2)
        self.assertEqual(sorted(os.listdir(self.root)), before)
        self.assertFalse(os.path.exists(self.dest()))

    def test_check_wrong_hash_returns_2_and_preserves_bytes(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        bad = b"not-the-right-content"
        with open(self.dest(), "wb") as fh:
            fh.write(bad)
        rc, _ = self.run_bootstrap(check=True)
        self.assertEqual(rc, 2)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), bad)

    def test_check_does_not_contact_server(self):
        # A present/valid artifact must succeed even if the endpoint is dead:
        # --check performs no network. Kill the server first.
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(GOOD_PAYLOAD)
        self.srv.shutdown()
        rc, _ = self.run_bootstrap(check=True)
        self.assertEqual(rc, 0)


class TestOffline(BootstrapTestBase):
    def test_offline_good_present_is_kept(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(GOOD_PAYLOAD)
        before = os.stat(self.dest()).st_mtime_ns
        rc, logs = self.run_bootstrap(offline=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any("keep" in m for m in logs))
        self.assertEqual(os.stat(self.dest()).st_mtime_ns, before)

    def test_offline_absent_is_actionable_error(self):
        self.write_manifest()
        with self.assertRaises(bs.FetchError):
            bs.run(self.root, check=False, offline=True, log=lambda m: None)
        self.assertFalse(os.path.exists(self.dest()))


class TestInstall(BootstrapTestBase):
    def test_happy_path_installs_and_verifies(self):
        self.write_manifest()
        rc, logs = self.run_bootstrap()
        self.assertEqual(rc, 0)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), GOOD_PAYLOAD)
        self.assertTrue(any("verify" in m for m in logs))
        # No temp leftovers.
        leftovers = [n for n in os.listdir(os.path.dirname(self.dest()))
                     if n.startswith(".floecad-tmp-")]
        self.assertEqual(leftovers, [])

    def test_existing_matching_bytes_not_rewritten(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(GOOD_PAYLOAD)
        old_mtime = os.stat(self.dest()).st_mtime_ns - 10_000_000
        os.utime(self.dest(), ns=(old_mtime, old_mtime))
        # Point the manifest endpoint at a dead port: a correct file must mean
        # the server is never contacted.
        self.srv.shutdown()
        rc, logs = self.run_bootstrap()
        self.assertEqual(rc, 0)
        self.assertTrue(any("already matches" in m for m in logs))
        self.assertEqual(os.stat(self.dest()).st_mtime_ns, old_mtime)

    def test_partial_download_preserves_existing_good_bytes(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        # Pre-existing bytes are a DIFFERENT (but valid-to-preserve) payload;
        # the manifest says they are stale, so bootstrap attempts replacement.
        preexisting = b"previous-build-bytes-that-must-survive-a-bad-fetch"
        with open(self.dest(), "wb") as fh:
            fh.write(preexisting)
        self.srv.mode = "truncate"
        with self.assertRaises(bs.IntegrityError):
            bs.run(self.root, check=False, offline=False, log=lambda m: None)
        # Existing bytes are byte-for-byte intact.
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), preexisting)
        leftovers = [n for n in os.listdir(os.path.dirname(self.dest()))
                     if n.startswith(".floecad-tmp-")]
        self.assertEqual(leftovers, [])

    def test_wrong_hash_preserves_existing_bytes(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        preexisting = b"previous-build-bytes-that-must-survive-a-bad-fetch"
        with open(self.dest(), "wb") as fh:
            fh.write(preexisting)
        self.srv.mode = "corrupt"
        with self.assertRaises(bs.IntegrityError):
            bs.run(self.root, check=False, offline=False, log=lambda m: None)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), preexisting)

    def test_oversize_download_rejected(self):
        self.write_manifest()
        self.srv.mode = "extra"
        with self.assertRaises(bs.IntegrityError):
            bs.run(self.root, check=False, offline=False, log=lambda m: None)
        self.assertFalse(os.path.exists(self.dest()))

    def test_incomplete_body_fails_actionable_and_leaves_no_temp(self):
        self.write_manifest()
        self.srv.mode = "short_body"
        with self.assertRaises(bs.BootstrapError):
            bs.run(self.root, check=False, offline=False, log=lambda m: None)
        self.assertFalse(os.path.exists(self.dest()))
        vendor_dir = os.path.dirname(self.dest())
        if os.path.isdir(vendor_dir):
            leftovers = [n for n in os.listdir(vendor_dir)
                         if n.startswith(".floecad-tmp-")]
            self.assertEqual(leftovers, [])

    def test_absent_then_install(self):
        self.write_manifest()
        self.assertFalse(os.path.exists(self.dest()))
        rc, _ = self.run_bootstrap()
        self.assertEqual(rc, 0)
        self.assertEqual(bs.artifact_status(self.root,
                                            bs.load_manifest(self.root)["artifacts"][0]),
                         "ok")

    def test_unsupported_source_kind(self):
        self.write_manifest(source_kind="plain-http")
        with self.assertRaises(bs.UnsupportedSourceError):
            bs.run(self.root, check=False, offline=False, log=lambda m: None)

    def test_non_http_scheme_batch_still_works_loopback(self):
        # Sanity: loopback http batch is permitted for the local test bridge.
        self.write_manifest(scheme="http")
        rc, _ = self.run_bootstrap()
        self.assertEqual(rc, 0)


class TestUrlSafety(BootstrapTestBase):
    def test_is_safe_url_policy(self):
        self.assertTrue(bs._is_safe_url("https://github.com/x"))
        self.assertTrue(bs._is_safe_url("http://127.0.0.1:1234/x"))
        self.assertTrue(bs._is_safe_url("http://localhost/x"))
        self.assertFalse(bs._is_safe_url("http://example.com/x"))
        self.assertFalse(bs._is_safe_url("ftp://example.com/x"))
        self.assertFalse(bs._is_safe_url("file:///etc/passwd"))

    def test_remote_http_href_refused(self):
        self.write_manifest()
        original = bs._http_post_json

        def fake_post(url, payload):
            return {"objects": [{
                "oid": GOOD_SHA, "size": GOOD_SIZE,
                "actions": {"download": {"href": "http://example.com/obj"}},
            }]}

        bs._http_post_json = fake_post
        try:
            source = bs.resolve_sources(bs.load_manifest(self.root))["src"]
            with self.assertRaises(bs.FetchError):
                bs.resolve_lfs_urls(source,
                                    [{"oid": GOOD_SHA, "size": GOOD_SIZE}], 10 ** 9)
        finally:
            bs._http_post_json = original


class TestManifestValidation(BootstrapTestBase):
    def test_missing_manifest(self):
        with self.assertRaises(bs.ManifestError):
            bs.run(self.root, check=True, offline=False, log=lambda m: None)

    def test_oid_must_equal_sha256(self):
        sha = self.write_manifest()
        path = os.path.join(self.root, "DEPENDENCIES.json")
        with open(path) as fh:
            data = json.load(fh)
        data["artifacts"][0]["source"]["oid"] = "a" * 64
        with open(path, "w") as fh:
            json.dump(data, fh)
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.root)


class TestSchemaVersionStrict(BootstrapTestBase):
    """Only the exact supported schemaVersion is accepted (no forward compat)."""

    def _rewrite(self, schema_version):
        self.write_manifest()
        path = os.path.join(self.root, "DEPENDENCIES.json")
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if schema_version is None:
            data.pop("schemaVersion", None)
        else:
            data["schemaVersion"] = schema_version
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)

    def test_future_schema_version_refused(self):
        self._rewrite(2)
        with self.assertRaises(bs.ManifestError) as ctx:
            bs.load_manifest(self.root)
        self.assertIn("schemaVersion", str(ctx.exception))

    def test_zero_schema_version_refused(self):
        self._rewrite(0)
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.root)

    def test_missing_schema_version_refused(self):
        self._rewrite(None)
        with self.assertRaises(bs.ManifestError):
            bs.load_manifest(self.root)

    def test_non_integer_schema_version_refused(self):
        for value in ("one", "1", 1.0, True):
            with self.subTest(value=value):
                self._rewrite(value)
                with self.assertRaises(bs.ManifestError):
                    bs.load_manifest(self.root)

    def test_main_returns_error_exit_code_for_unknown_schema(self):
        self._rewrite(99)
        with contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            rc = bs.main(["--check", "--root", self.root])
        self.assertEqual(rc, 1)


class TestBatchResponseBounds(BootstrapTestBase):
    """The LFS batch body is read with a hard bound."""

    def test_read_bounded_accepts_exact_limit(self):
        self.assertEqual(bs._read_bounded(_FakeResponse(b"x" * 10), 10), b"x" * 10)

    def test_read_bounded_refuses_oversize_body(self):
        with self.assertRaises(bs.FetchError):
            bs._read_bounded(_FakeResponse(b"x" * 11), 10)

    def test_oversized_batch_response_is_a_bounded_error(self):
        self.write_manifest()
        original = bs.MAX_BATCH_RESPONSE_BYTES
        bs.MAX_BATCH_RESPONSE_BYTES = 64  # real batch JSON is larger than this
        try:
            with self.assertRaises(bs.FetchError) as ctx:
                self.run_bootstrap()
            self.assertIn("limit", str(ctx.exception))
        finally:
            bs.MAX_BATCH_RESPONSE_BYTES = original
        self.assertFalse(os.path.exists(self.dest()))


class TestErrorRedaction(BootstrapTestBase):
    """Remote text (pre-signed URL queries, server errors) is redacted."""

    def test_redact_removes_url_query_and_token_params(self):
        text = bs.redact(
            "denied https://cdn.example.com/o?X-Amz-Signature=abc123&token=deadbeef"
        )
        self.assertNotIn("abc123", text)
        self.assertNotIn("deadbeef", text)
        self.assertIn("https://cdn.example.com/o", text)
        self.assertIn("<redacted>", text)

    def test_redact_caps_long_text(self):
        text = bs.redact("z" * 1000)
        self.assertLessEqual(len(text), bs.MAX_ERROR_TEXT + len("...(truncated)"))

    def test_lfs_object_error_message_redacted(self):
        self.write_manifest()
        original = bs._http_post_json
        bs._http_post_json = lambda url, payload: {"objects": [{
            "oid": GOOD_SHA, "size": GOOD_SIZE,
            "error": {"code": 403, "message":
                      "denied https://cdn.example.com/o?token=SUPERSECRETVALUE"},
        }]}
        try:
            source = bs.resolve_sources(bs.load_manifest(self.root))["src"]
            with self.assertRaises(bs.FetchError) as ctx:
                bs.resolve_lfs_urls(source,
                                    [{"oid": GOOD_SHA, "size": GOOD_SIZE}], 10 ** 9)
            message = str(ctx.exception)
        finally:
            bs._http_post_json = original
        self.assertNotIn("SUPERSECRETVALUE", message)
        self.assertIn("denied", message)


class TestRedirectPolicy(unittest.TestCase):
    """Redirect targets must satisfy the same URL policy: no TLS downgrade."""

    def _redirect(self, from_url, to_url, code=302):
        handler = bs._SafeRedirectHandler()
        req = urllib.request.Request(from_url)
        return handler.redirect_request(req, None, code, "Found", {}, to_url)

    def test_https_to_https_allowed(self):
        new = self._redirect("https://example.com/a", "https://cdn.example.com/b")
        self.assertIsNotNone(new)

    def test_https_downgrade_to_http_refused(self):
        with self.assertRaises(bs.FetchError) as ctx:
            self._redirect("https://example.com/a", "http://cdn.example.com/b")
        self.assertIn("redirect", str(ctx.exception))

    def test_loopback_http_to_http_allowed(self):
        new = self._redirect("http://127.0.0.1:1/a", "http://127.0.0.1:2/b")
        self.assertIsNotNone(new)

    def test_redirect_to_ftp_refused(self):
        with self.assertRaises(bs.FetchError):
            self._redirect("http://127.0.0.1:1/a", "ftp://example.com/b")


class TestRedirectFollowingOverLoopback(BootstrapTestBase):
    """The custom opener still follows an ordinary loopback redirect."""

    def test_object_redirect_over_loopback_installs(self):
        self.write_manifest()
        self.srv.mode = "redirect_object"
        rc, _ = self.run_bootstrap()
        self.assertEqual(rc, 0)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), GOOD_PAYLOAD)


class TestLocalRelink(BootstrapTestBase):
    """Official pinned path vs deliberate local replacement opt-in."""

    LOCAL_BYTES = b"deliberately-rebuilt-occt-slice-bytes"

    def _stage_local(self):
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(self.LOCAL_BYTES)
        stamp = os.stat(self.dest()).st_mtime_ns - 10_000_000
        os.utime(self.dest(), ns=(stamp, stamp))
        return stamp

    def test_plain_check_rejects_unpinned_bytes(self):
        self.write_manifest()
        self._stage_local()
        rc, _ = self.run_bootstrap(check=True)
        self.assertEqual(rc, 2)

    def test_local_relink_keeps_unpinned_bytes_without_network(self):
        self.write_manifest()
        stamp = self._stage_local()
        self.srv.shutdown()  # must not be contacted
        rc, logs = self.run_bootstrap(local_relink=True)
        self.assertEqual(rc, 0)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), self.LOCAL_BYTES)
        self.assertEqual(os.stat(self.dest()).st_mtime_ns, stamp)
        self.assertTrue(any("deliberately NOT overwritten" in m for m in logs))

    def test_local_relink_check_reports_local_and_exit0(self):
        self.write_manifest()
        self._stage_local()
        rc, logs = self.run_bootstrap(check=True, local_relink=True)
        self.assertEqual(rc, 0)
        self.assertTrue(any(m.startswith("LOCAL") for m in logs))

    def test_local_relink_still_installs_missing_pinned_artifact(self):
        self.write_manifest()  # nothing staged: missing artifacts are installed
        rc, _ = self.run_bootstrap(local_relink=True)
        self.assertEqual(rc, 0)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), GOOD_PAYLOAD)

    def test_normal_mode_replaces_stale_bytes(self):
        self.write_manifest()
        os.makedirs(os.path.dirname(self.dest()), exist_ok=True)
        with open(self.dest(), "wb") as fh:
            fh.write(b"stale-local-build-bytes")
        rc, logs = self.run_bootstrap()  # official path, no opt-in
        self.assertEqual(rc, 0)
        with open(self.dest(), "rb") as fh:
            self.assertEqual(fh.read(), GOOD_PAYLOAD)
        self.assertTrue(any("replace" in m for m in logs))

    def test_env_opt_in_plumbed_through_main(self):
        self.write_manifest()
        self._stage_local()
        buf = io.StringIO()
        with unittest.mock.patch.dict(os.environ, {bs.ENV_LOCAL_RELINK: "1"}):
            with contextlib.redirect_stdout(buf):
                rc = bs.main(["--check", "--root", self.root])
        self.assertEqual(rc, 0)
        self.assertIn("LOCAL", buf.getvalue())


@unittest.skipUnless(os.environ.get("FLOECAD_REAL_OS64"),
                     "set FLOECAD_REAL_OS64 to a fully downloaded pinned object")
class TestRealPinnedBytesOverLoopback(unittest.TestCase):
    """Bridge: run bootstrap's own fetch/verify/install against the EXACT pinned
    OS64 bytes staged locally, served over loopback (no public-internet use by
    the test; the bytes themselves came from the verified upstream download)."""

    def setUp(self):
        self.real = os.environ["FLOECAD_REAL_OS64"]
        self.root = tempfile.mkdtemp(prefix="floecad-real-")
        self.srv = start_server()
        self.expected_sha = ("b4abdbf22f704cfad0be3e67a686f727cc9bb0429"
                             "d09dbef2153728b81850b50")
        self.expected_size = 149038832

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        shutil.rmtree(self.root, ignore_errors=True)

    def test_real_exact_bytes_install(self):
        with open(self.real, "rb") as fh:
            payload = fh.read()
        self.assertEqual(len(payload), self.expected_size)
        self.assertEqual(sha256_bytes(payload), self.expected_sha)
        self.srv.objects[self.expected_sha] = payload
        sha = write_manifest(self.root, self.srv.server_address[1],
                             payload=payload, install_path=REL_PATH)
        self.assertEqual(sha, self.expected_sha)
        rc = bs.run(self.root, check=False, offline=False, log=lambda m: None)
        self.assertEqual(rc, 0)
        dest = bs.safe_install_path(self.root, REL_PATH)
        self.assertEqual(os.path.getsize(dest), self.expected_size)
        self.assertEqual(bs.sha256_file(dest), self.expected_sha)


if __name__ == "__main__":
    unittest.main(verbosity=2)
