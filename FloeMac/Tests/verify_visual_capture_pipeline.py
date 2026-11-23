# SPDX-License-Identifier: MPL-2.0
"""Exercise the Mac Debug workbench, real captures, and a loopback model.

Usage: python3 FloeMac/Tests/verify_visual_capture_pipeline.py APP EVIDENCE
Requires Pillow and macOS Screen Recording access for the signed Debug app.
The window and browser page contain synthetic colors only.
"""

import base64
import hashlib
import io
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import subprocess
import sys
from threading import Thread
import time

from PIL import Image, ImageCms


BUNDLE = "org.floeagent.qa.background-window"
PAGE = b"""<!doctype html><meta name="color-scheme" content="light"><style>
body { margin:0; display:flex } div { width:50vw; height:100vh }
#left { background:rgb(212,23,42) } #right { background:rgb(12,205,231) }
strong { position:absolute; top:32px; left:32px; padding:12px; color:black;
background:white; font: bold 36px system-ui }
</style><div id="left"></div><div id="right"></div><strong>FLOE TEXT 421</strong>
<script>
setInterval(() => document.body.setAttribute('data-tick', String(Date.now())), 25);
</script>"""
PROMPT = "Find the two colored markers in the fixture window and browser viewport."
COLORS = {
    "window": ((255, 0, 255), (0, 255, 0)),
    "browser": ((212, 23, 42), (12, 205, 231)),
}


def text(message):
    content = message.get("content") or ""
    if isinstance(content, list):
        return "\n".join(part.get("text", "") for part in content if part.get("type") == "text")
    return content


def decode_image(url):
    header, _, encoded = url.partition(",")
    assert header.startswith(("data:image/png;", "data:image/jpeg;")), header[:40]
    data = base64.b64decode(encoded, validate=True)
    image = Image.open(io.BytesIO(data))
    profile = image.info.get("icc_profile")
    image = image.convert("RGB")
    if profile:
        image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                          ImageCms.createProfile("sRGB"))
    width, height = image.size
    pixels = [image.getpixel((x, height // 2)) for x in (width // 4, 3 * width // 4)]
    source = "attachment" if width <= 128 and all(pixel[1] > 160 for pixel in pixels) else "unknown"
    if width > 128:
        source = next(
            (name for name, colors in COLORS.items()
             if all(max(abs(actual - expected) for actual, expected in zip(pixel, color)) < 64
                    for pixel, color in zip(pixels, colors))),
            "unknown",
        )
    return {"source": source, "size": image.size, "pixels": pixels, "sha256": hashlib.sha256(data).hexdigest()}


def image_parts(messages):
    return [decode_image(part["image_url"]["url"])
            for message in messages if isinstance(message.get("content"), list)
            for part in message["content"] if part.get("type") == "image_url"]


class CaptureFixture:
    def __init__(self, process, window, auxiliary):
        self.auxiliary = auxiliary
        self.window = window
        self.process = process
        self.port = None
        self.calls = []
        self.searches = set()
        self.checked = {}
        self.errors = []
        self.helper = []
        self.expected_sources = {"window": "window", "shell": "window", "page": "browser"}

    def steps(self):
        probe = {"access": "host", "captureImagePath": "shell-capture.png", "timeoutSeconds": 12}
        screen = f"/usr/sbin/screencapture -x -o -l {self.window} shell-capture.png"
        return [
            ("window", "mac.desktop.control", {"action": "screenshot", "app": BUNDLE,
                                               "pid": self.process, "windowID": self.window}),
            ("shell", "exec.shell", dict(probe, command=screen)),
            ("stale", "exec.shell", dict(probe, command="true")),
            ("failed", "exec.shell", dict(probe, command="/bin/cp diagram.png shell-capture.png; exit 3")),
            ("navigate", "browser.navigate", {"url": f"http://127.0.0.1:{self.port}/visual-page"}),
            ("page", "browser.screenshot", {}),
        ]

    def next_response(self, request):
        messages = request["messages"]
        joined = "\n".join(text(message) for message in messages)
        images = image_parts(messages)
        if "Create only a task title" in joined:
            return {"content": "Visual capture fixture"}, "stop"

        if request["model"] == "vision-helper-fixture":
            assert self.auxiliary and len(images) == 1, images
            expected = self.expected_sources.get(self.calls[-1]) if self.calls else "attachment"
            assert images[0]["source"] == expected, (expected, images)
            if expected != "attachment":
                assert PROMPT in joined, "Tool image helper did not receive the current visual task focus"
            evidence = dict(images[0], after=self.calls[-1] if self.calls else "attachment")
            self.helper.append(evidence)
            return {"content": "QA-PIXEL-" + evidence["after"]}, "stop"

        assert request["model"] == "vision-primary-fixture", request["model"]
        results = {message.get("tool_call_id"): text(message)
                   for message in messages if message.get("role") == "tool"}
        if self.auxiliary:
            assert not images, "A text-only primary received raw images"
            assert "QA-PIXEL-attachment" in joined, "Primary did not get the attachment description"
        else:
            assert images and images[0]["source"] == "attachment", images

        if self.calls and self.calls[-1] in results and self.calls[-1] not in self.checked:
            identifier = self.calls[-1]
            expected = self.expected_sources.get(identifier)
            summary = results[identifier]
            if expected:
                if self.auxiliary:
                    evidence = next((entry for entry in self.helper if entry["after"] == identifier), None)
                    assert evidence and ("QA-PIXEL-" + identifier) in joined, (identifier, self.helper, summary[:850])
                else:
                    evidence = images[-1]
                    assert evidence["source"] == expected, (identifier, images, summary[:850])
                if identifier == "page":
                    assert "FLOE TEXT 421" in summary and "visualTextRegions" in summary, summary[:1100]
                    page = next((json.loads(line) for line in summary.splitlines()
                                 if line.startswith("{") and '"visualTextRegions"' in line), {})
                    text_region = next((region for region in page.get("visualTextRegions", [])
                                        if "FLOE TEXT 421" in region["text"]), None)
                    assert text_region is not None, page
                    assert 0 <= text_region["x"] < page["width"] and 0 <= text_region["y"] < page["height"], text_region
                    evidence = dict(evidence, ocr=text_region)
                self.checked[identifier] = evidence
            elif identifier in {"stale", "failed"}:
                assert "not attached" in summary.lower(), (identifier, summary[:850])
                assert not any(entry["after"] == identifier for entry in self.helper), self.helper
                assert len(images) == (0 if self.auxiliary else 1), (identifier, images)
                self.checked[identifier] = True
            else:
                assert "/visual-page" in summary, summary[:850]
                self.checked[identifier] = True

        next_step = next((step for step in self.steps() if step[0] not in results), None)
        if not next_step:
            return {"content": "Vision route verified."}, "stop"
        identifier, name, arguments = next_step
        normalized = "".join(char for char in name if char.isalnum())
        offered = {"".join(char for char in item["function"]["name"].lower() if char.isalnum()): item["function"]["name"]
                   for item in request.get("tools", [])}
        if normalized in offered:
            self.calls.append(identifier)
        else:
            assert "toolssearch" in offered and identifier not in self.searches, (name, list(offered))
            self.searches.add(identifier)
            identifier, normalized, arguments = "find-" + identifier, "toolssearch", {"query": name}
        return {"tool_calls": [{"index": 0, "id": identifier, "type": "function",
                               "function": {"name": offered[normalized], "arguments": json.dumps(arguments)}}]}, "tool_calls"

    def handler(self):
        fixture = self

        class Loopback(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                if self.path != "/visual-page":
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(PAGE)))
                self.end_headers()
                self.wfile.write(PAGE)

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    delta, finish = fixture.next_response(request)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for payload, reason in ((dict(delta, role="assistant"), None), ({}, finish)):
                        chunk = {"id": "visual-capture", "object": "chat.completion.chunk", "model": request["model"],
                                 "choices": [{"index": 0, "delta": payload, "finish_reason": reason}]}
                        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                except (AssertionError, KeyError, ValueError, OSError) as error:
                    fixture.errors.append(str(error))
                    self.send_error(400)

        return Loopback


def exercise(binary, output, fixture):
    output.mkdir()
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler()) as server:
        fixture.port = server.server_port
        Thread(target=server.serve_forever, daemon=True).start()
        report = output / "app.json"
        command = [str(binary), "--vision-routing-only", "--visual-capture-pipeline", "--project-task-fixture",
                   f"http://127.0.0.1:{fixture.port}/v1", "--unified-smoke-report", str(report)]
        if fixture.auxiliary:
            command.append("--auxiliary-vision")
        try:
            with (output / "app.log").open("wb") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=92)
            result = json.loads(report.read_bytes())
            assert not fixture.errors, fixture.errors
            assert result["completed"] and result["retainedAttachment"], result
            assert fixture.calls == [identifier for identifier, _, _ in fixture.steps()], fixture.calls
            for tool, identifier in [("mac.desktop.control", "window"), ("exec.shell", "shell"), ("browser.screenshot", "page")]:
                digests = result["visualReceipts"].get(tool + "/" + identifier, [])
                assert digests == [fixture.checked[identifier]["sha256"]], (identifier, digests, fixture.checked[identifier])
            for identifier in ("failed", "stale"):
                assert not result["visualReceipts"].get("exec.shell/" + identifier), result["visualReceipts"]
            print(output.name, json.dumps(fixture.checked))
        finally:
            server.shutdown()
            (output / "wire.json").write_text(json.dumps(
                {"calls": fixture.calls, "checked": fixture.checked, "helper": fixture.helper, "errors": fixture.errors}, indent=2))


def run(app, output):
    output.mkdir(parents=True)
    contents = app / "Contents"
    executable = plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"]
    binary = contents / "MacOS" / executable
    fixture_bundle = output / "Floe Background Fixture.app" / "Contents"
    fixture_binary = fixture_bundle / "MacOS" / "Fixture"
    fixture_binary.parent.mkdir(parents=True)
    (fixture_bundle / "Info.plist").write_bytes(plistlib.dumps(
        {"CFBundleIdentifier": BUNDLE, "CFBundleName": "Floe Background Fixture", "CFBundleExecutable": "Fixture",
         "CFBundlePackageType": "APPL", "LSUIElement": True}))
    source = Path(__file__).with_name("BackgroundWindowFixture.swift")
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(source), "-o", str(fixture_binary)],
                   check=True, env=env)
    with subprocess.Popen([str(fixture_binary), str(output), "--vision-colors"]) as process:
        try:
            state_path = output / "state.json"
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if state_path.exists():
                    state = json.loads(state_path.read_bytes())
                    if state["dragWindow"]:
                        break
                time.sleep(0.05)
            else:
                raise RuntimeError("The synthetic background window did not appear")
            assert state["pid"] == process.pid and not state["becameFrontmost"], state
            failures = []
            for auxiliary in (False, True):
                label = "helper" if auxiliary else "direct"
                try:
                    exercise(binary, output / label, CaptureFixture(process.pid, state["dragWindow"], auxiliary))
                except (AssertionError, OSError, subprocess.SubprocessError) as error:
                    failures.append(f"{label}: {error}")
            state = json.loads(state_path.read_bytes())
            assert not state["becameFrontmost"], state
            assert not failures, "\n".join(failures)
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    run(*(Path(argument).resolve() for argument in sys.argv[1:3]))
