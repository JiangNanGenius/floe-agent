#!/usr/bin/env python3
"""Exercise Creative in a built Debug OTA app using local provider responses."""
import argparse
import base64
import json
import struct
import subprocess
import tempfile
import threading
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def image_fixture():
    def chunk(kind, content):
        return (struct.pack(">I", len(content)) + kind + content
                + struct.pack(">I", zlib.crc32(kind + content)))

    header = struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)
    pixels = (b"\0" + bytes((45, 90, 150)) * 8) * 8
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


class MediaFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_bytes(self, payload, mime):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, obj):
        self.send_bytes(json.dumps(obj).encode(), "application/json")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        token = self.headers.get("Authorization")
        if self.path == "/v1/images/generations" and token == "Bearer floe-image-fixture":
            count = int(body.get("n", 1))
            assert count in (1, 2)
            self.server.images += count
            self.send_json({"data": [{"b64_json": base64.b64encode(image_fixture()).decode()} for _ in range(count)]})
        elif self.path == "/v1/contents/generations/tasks" and token == "Bearer floe-video-fixture":
            if body["content"][0]["text"] == "Cancel fixture":
                self.server.cancel_submissions += 1
                self.send_json({"id": "cancel-clip"})
                return
            assert body["duration"] == 5 and body["content"][0]["text"] == "Synthetic clip"
            frame = body["content"][1]
            assert frame["role"] == "first_frame" and frame["image_url"]["url"].startswith("data:image/")
            self.server.submitted += 1
            self.send_json({"id": "local-clip"})
        else:
            self.send_error(400)

    def do_DELETE(self):
        if self.path == "/v1/contents/generations/tasks/cancel-clip" and self.headers.get("Authorization") == "Bearer floe-video-fixture":
            self.server.cancelled += 1
            self.send_json({})
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path == "/v1/contents/generations/tasks/cancel-clip":
            self.send_json({"status": "running"})
            return
        if self.path == "/v1/contents/generations/tasks/local-clip":
            if self.headers.get("Authorization") != "Bearer floe-video-fixture":
                self.send_error(401)
                return
            self.server.polled += 1
            url = f"http://127.0.0.1:{self.server.server_port}/test-clip.mp4?token=fixture-media-signature"
            self.send_json({"status": "succeeded", "content": {"video_url": url}})
        elif self.path == "/test-clip.mp4?token=fixture-media-signature":
            assert self.headers.get("Authorization") is None and self.headers.get("x-goog-api-key") is None
            self.server.downloaded += 1
            self.send_bytes(self.server.movie, "video/mp4")
        else:
            self.send_error(404)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--movie", type=Path, help="Small playable MP4 fixture (otherwise generated with ffmpeg)")
    parser.add_argument("--evidence", type=Path, help="Retain the JSON report and window captures")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="floe-creative-") as scratch:
        root = Path(scratch)
        movie = args.movie or root / "clip.mp4"
        if not args.movie:
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=96x64:d=1",
                            "-an", "-vcodec", "libx264", "-pix_fmt", "yuv420p", str(movie)], check=True)
        evidence = args.evidence.resolve() if args.evidence else root
        evidence.mkdir(parents=True, exist_ok=True)
        report = root / "report.json"
        with ThreadingHTTPServer(("127.0.0.1", 0), MediaFixture) as server:
            server.movie = movie.read_bytes()
            server.images = server.submitted = server.polled = server.downloaded = server.cancel_submissions = server.cancelled = 0
            threading.Thread(target=server.serve_forever, daemon=True).start()
            endpoint = f"http://127.0.0.1:{server.server_port}/v1"
            try:
                subprocess.run(["open", "-n", "-W", "-a", str(args.app.resolve()), "--args", "--creative-only",
                                "--unified-smoke-report", str(report), "--model-catalog-fixture", endpoint,
                                "--project-task-fixture", endpoint], timeout=65, check=True)
            finally:
                server.shutdown()
            result = json.loads(report.read_text())
            counts = [server.images, server.submitted, server.polled, server.downloaded, server.cancel_submissions, server.cancelled]
            result["candidateImagesAndVideoRequests"] = counts
            print(json.dumps(result, indent=2))
            if args.evidence:
                (evidence / "creative-report.json").write_text(json.dumps(result, indent=2))
                for file in root.glob("report.json.*.png"):
                    (evidence / file.name).write_bytes(file.read_bytes())
            if not (result["images"] and result["creative"] and counts == [3, 1, 2, 2, 1, 1]):
                raise SystemExit(1)


if __name__ == "__main__":
    main()
