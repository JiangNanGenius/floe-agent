#!/usr/bin/env python3
"""Run the focused real-browser checks against the synthetic Bridge.

Uses a locally installed Edge in headless mode and a generated H.264/fMP4
fixture. The browser is a test tool, not a shipped component. If Edge or ffmpeg
is unavailable, the test reports a skip instead of pretending the page was
exercised.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mock_bridge  # noqa: E402

EDGE = pathlib.Path("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
NODE = shutil.which("node")
FFMPEG = shutil.which("ffmpeg")


def free_port() -> int:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def make_video(path: pathlib.Path) -> bool:
    if not FFMPEG:
        return False
    command = [
        FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=390x844:rate=10",
        "-t", "6", "-c:v", "libx264", "-profile:v", "baseline", "-level", "3.1",
        "-pix_fmt", "yuv420p", "-g", "10", "-keyint_min", "10", "-sc_threshold", "0",
        "-b:v", "350k", "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
        "-f", "mp4", str(path),
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print("ffmpeg failed: " + result.stderr[-800:], file=sys.stderr)
        return False
    return path.exists() and path.stat().st_size > 1000


class Fixture:
    def __init__(self, video) -> None:
        self.state = mock_bridge.State(video)
        self.server = mock_bridge.Server(("127.0.0.1", 0), mock_bridge.Handler)
        self.server.state = self.state  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    @property
    def base(self) -> str:
        return "http://127.0.0.1:%d" % self.port

    def reset(self) -> None:
        req = urllib.request.Request(self.base + "/__test/reset", method="POST")
        with urllib.request.urlopen(req, timeout=5):
            pass

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def run_node(cdp_port: int, base: str, mock: str, label: str, output: pathlib.Path) -> int:
    command = [
        NODE, str(HERE / "browser_check.mjs"),
        "--cdp", str(cdp_port), "--base", base, "--mock", mock, "--label", label,
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    output.write_text(
        "COMMAND: %s\nRC: %d\n--- stdout ---\n%s\n--- stderr ---\n%s\n"
        % (" ".join(command), result.returncode, result.stdout, result.stderr),
        encoding="utf-8",
    )
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-dir", type=pathlib.Path, default=HERE / "evidence")
    args = parser.parse_args()
    args.evidence_dir.mkdir(parents=True, exist_ok=True)
    if not EDGE.exists() or not NODE:
        print("SKIP browser checks: Edge or Node is unavailable", file=sys.stderr)
        (args.evidence_dir / "browser-skip.txt").write_text(
            "Edge=%s Node=%s\n" % (EDGE, NODE), encoding="utf-8")
        return 0
    temp = pathlib.Path(tempfile.mkdtemp(prefix="floe-browser-test-"))
    video = temp / "live.mp4"
    if not make_video(video):
        print("SKIP browser checks: ffmpeg is unavailable or failed; core/reference checks still ran", file=sys.stderr)
        (args.evidence_dir / "browser-video-skip.txt").write_text(
            "ffmpeg=%s\n" % FFMPEG, encoding="utf-8")
        shutil.rmtree(temp, ignore_errors=True)
        return 0
    fixture = Fixture(video)
    cdp_port = free_port()
    user_data = temp / "edge-profile"
    edge_log = (args.evidence_dir / "browser-edge.log").open("w", encoding="utf-8")
    edge = subprocess.Popen([
        str(EDGE), "--headless=new", "--disable-gpu", "--no-first-run",
        "--no-default-browser-check", "--autoplay-policy=no-user-gesture-required",
        "--user-data-dir=" + str(user_data), "--remote-debugging-port=" + str(cdp_port),
        "--host-resolver-rules=MAP floe.test 127.0.0.1", "about:blank",
    ], stdout=edge_log, stderr=subprocess.STDOUT)
    try:
        deadline = time.time() + 15
        ready = False
        while time.time() < deadline:
            try:
                with urllib.request.urlopen("http://127.0.0.1:%d/json/version" % cdp_port, timeout=1):
                    ready = True
                    break
            except Exception:
                time.sleep(0.2)
        if not ready:
            print("BROWSER FAIL: Edge DevTools did not become ready", file=sys.stderr)
            return 1
        statuses = []
        fixture.reset()
        statuses.append(run_node(cdp_port, fixture.base, fixture.base, "secure",
                                 args.evidence_dir / "browser-secure.log"))
        fixture.reset()
        statuses.append(run_node(cdp_port, "http://floe.test:%d" % fixture.port, fixture.base, "insecure",
                                 args.evidence_dir / "browser-insecure.log"))
        if any(status != 0 for status in statuses):
            print("BROWSER FAIL: one or more runs failed", file=sys.stderr)
            return 1
        print("BROWSER CHECKS OK: secure WebCrypto and plain-HTTP JS-fallback runs")
        return 0
    finally:
        try:
            edge.terminate()
            edge.wait(timeout=10)
        except Exception:
            try:
                edge.kill()
            except Exception:
                pass
        edge_log.close()
        fixture.close()
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
