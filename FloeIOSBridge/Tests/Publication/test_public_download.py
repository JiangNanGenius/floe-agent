#!/usr/bin/env python3
"""Streamed, bounded, unauthenticated public download tests."""

from __future__ import annotations

import hashlib
import http.server
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import publish_bridge_release as pub


class AssetHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def do_GET(self) -> None:
        server = self.server
        server.seen_auth.append(self.headers.get("Authorization"))
        route = server.routes.get(self.path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return
        if route.get("status"):
            self.send_response(route["status"])
            self.end_headers()
            return
        data = route["data"]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        declared = route.get("content_length")
        if declared is not None:
            self.send_header("Content-Length", str(declared))
        self.end_headers()
        try:
            for index in range(0, len(data), 11):
                self.wfile.write(data[index:index + 11])
                server.write_count += 1
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, *args) -> None:
        return


class PublicDownloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), AssetHandler)
        self.server.routes = {}
        self.server.seen_auth = []
        self.server.write_count = 0
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-download-")
        self.root = Path(self.temporary.name)
        self.downloader = pub.PublicDownloader(
            allow_http=True,
            allowed_hosts={"127.0.0.1", "localhost"},
            chunk_size=7,
        )

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temporary.cleanup()

    def test_chunked_unauthenticated_download(self) -> None:
        data = b"bridge-public-asset-" * 8
        self.server.routes["/asset"] = {"data": data, "content_length": len(data)}
        destination = self.root / "asset.bin"
        size, digest = self.downloader.fetch(
            self.base + "/asset",
            destination,
            expected_size=len(data),
            expected_sha256=hashlib.sha256(data).hexdigest(),
            max_bytes=1024,
        )
        self.assertEqual(size, len(data))
        self.assertEqual(digest, hashlib.sha256(data).hexdigest())
        self.assertEqual(destination.read_bytes(), data)
        self.assertTrue(all(value is None for value in self.server.seen_auth))
        self.assertGreater(self.server.write_count, 1)

    def test_content_length_mismatch_is_rejected(self) -> None:
        data = b"x" * 40
        self.server.routes["/asset"] = {"data": data, "content_length": len(data) + 1}
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                self.base + "/asset",
                self.root / "asset.bin",
                expected_size=len(data),
                expected_sha256=hashlib.sha256(data).hexdigest(),
                max_bytes=1024,
            )
        self.assertFalse((self.root / "asset.bin").exists())
        self.assertFalse((self.root / "asset.bin.part").exists())

    def test_stream_oversize_aborts(self) -> None:
        data = b"x" * 80
        self.server.routes["/asset"] = {"data": data}
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                self.base + "/asset",
                self.root / "asset.bin",
                expected_size=40,
                expected_sha256=hashlib.sha256(data).hexdigest(),
                max_bytes=1024,
            )
        self.assertFalse((self.root / "asset.bin").exists())

    def test_hash_mismatch_is_rejected(self) -> None:
        data = b"hash mismatch"
        self.server.routes["/asset"] = {"data": data, "content_length": len(data)}
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                self.base + "/asset",
                self.root / "asset.bin",
                expected_size=len(data),
                expected_sha256="0" * 64,
                max_bytes=1024,
            )

    def test_http_is_rejected_without_test_override(self) -> None:
        downloader = pub.PublicDownloader()
        with self.assertRaises(pub.DownloadError):
            downloader.fetch(
                self.base + "/asset",
                self.root / "asset.bin",
                expected_size=1,
                expected_sha256=hashlib.sha256(b"x").hexdigest(),
                max_bytes=1024,
            )

    def test_unknown_host_is_rejected(self) -> None:
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                "https://evil.example/asset",
                self.root / "asset.bin",
                expected_size=1,
                expected_sha256=hashlib.sha256(b"x").hexdigest(),
                max_bytes=1024,
            )

    def test_credentials_in_url_are_rejected(self) -> None:
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                f"http://user:pass@127.0.0.1:{self.server.server_address[1]}/asset",
                self.root / "asset.bin",
                expected_size=1,
                expected_sha256=hashlib.sha256(b"x").hexdigest(),
                max_bytes=1024,
            )

    def test_404_is_rejected(self) -> None:
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                self.base + "/missing",
                self.root / "asset.bin",
                expected_size=1,
                expected_sha256=hashlib.sha256(b"x").hexdigest(),
                max_bytes=1024,
            )

    def test_expected_size_cap_is_enforced(self) -> None:
        with self.assertRaises(pub.DownloadError):
            self.downloader.fetch(
                self.base + "/asset",
                self.root / "asset.bin",
                expected_size=2048,
                expected_sha256=hashlib.sha256(b"x").hexdigest(),
                max_bytes=1024,
            )


if __name__ == "__main__":
    unittest.main()
