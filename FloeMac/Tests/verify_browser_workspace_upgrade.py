# SPDX-License-Identifier: MPL-2.0
"""Run the Mac Debug app through model discovery, WebKit input and PNG delivery."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from threading import Thread


STEPS = (
    ("preview", "browser.previewWorkspace"),
    ("load", "browser.wait"),
    ("first", "browser.screenshot"),
    ("text", "browser.clickVisualText"),
    ("stale", "browser.clickVisualText"),
    ("second", "browser.screenshot"),
    ("point", "browser.clickPoint"),
    ("export", "browser.exportFile"),
    ("existing", "browser.exportFile"),
)


def text(message):
    content = message.get("content") or ""
    if isinstance(content, list):
        return "\n".join(part.get("text", "") for part in content if part.get("type") == "text")
    return content


def payload(value, key):
    for match in re.finditer(r"\{", value):
        try:
            item, _ = json.JSONDecoder().raw_decode(value[match.start():])
        except ValueError:
            continue
        if isinstance(item, dict) and key in item:
            return item
    raise AssertionError(f"Missing {key} in {value[:600]}")


class BrowserFixture:
    def __init__(self, exercise_rejections):
        self.steps = STEPS if exercise_rejections else tuple(
            (step, tool) for step, tool in STEPS if step not in ("stale", "existing")
        )
        self.exercise_rejections = exercise_rejections
        self.results = {}
        self.sent = []
        self.errors = []
        self.provider_images = set()

    def arguments(self, step):
        if step == "preview":
            return {"path": "preview.html"}
        tab = re.search(r"tab ([0-9a-fA-F-]{36})", self.results["preview"])[1]
        if step == "load":
            return {"tabID": tab, "condition": "load", "timeoutMilliseconds": 5000}
        if step in ("first", "second"):
            return {"tabID": tab}
        if step in ("text", "stale", "point"):
            evidence = payload(self.results["second" if step == "point" else "first"], "visualTextRegions")
            label = "READY" if step == "point" else "PNG"
            region = next(item for item in evidence["visualTextRegions"] if label in item["text"].upper())
            arguments = {"tabID": tab, "documentID": evidence["documentID"], "screenshotSHA256": evidence["sha256"]}
            if step == "point":
                return dict(arguments, x=region["x"] + region["width"] / 2, y=region["y"] + region["height"] / 2,
                            fallbackReason="noStructuredTarget")
            return dict(arguments, reference=region["reference"])
        return {"tabID": tab, "path": "full.png", "expectedWidth": 1460, "expectedHeight": 930}

    def response(self, request):
        messages = request["messages"]
        if any("Create only a task title" in text(item) for item in messages if item["role"] == "system"):
            return {"content": "Browser workspace upgrade"}, "stop"
        for message in messages:
            if message.get("role") == "tool":
                self.results[message["tool_call_id"]] = text(message)
        if self.sent and self.sent[-1] in ("first", "second"):
            for message in messages:
                parts = message.get("content")
                if isinstance(parts, list) and any(
                    part.get("type") == "image_url" and part["image_url"]["url"].startswith("data:image/")
                    for part in parts
                ):
                    self.provider_images.add(self.sent[-1])
                    break
        pending = next(((step, name) for step, name in self.steps if step not in self.results), None)
        if pending is None:
            for stage in ("text", "point"):
                assert "Visual click verified" in self.results[stage], self.results[stage][:700]
            if self.exercise_rejections:
                assert "fresh screenshot" in self.results["stale"], self.results["stale"][:700]
                assert "already exists" in self.results["existing"], self.results["existing"][:700]
            return {"content": "Browser upgrade verified."}, "stop"
        step, name = pending
        wanted = re.sub(r"[^a-z]", "", name.lower())
        available = {re.sub(r"[^a-z]", "", tool["function"]["name"].lower()): tool["function"]["name"]
                     for tool in request.get("tools", [])}
        if wanted in available:
            function = available[wanted]
            arguments = self.arguments(step)
        else:
            step = "find-" + step
            assert step not in self.results and "toolssearch" in available, (step, list(available))
            function = available["toolssearch"]
            arguments = {"query": name}
        self.sent.append(step)
        return {"tool_calls": [{"index": 0, "id": step, "type": "function",
                               "function": {"name": function, "arguments": json.dumps(arguments)}}]}, "tool_calls"

    def handler(self):
        fixture = self

        class Loopback(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    delta, stop = fixture.response(request)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for payload, reason in ((dict(delta, role="assistant"), None), ({}, stop)):
                        response = {"id": "browser-upgrade", "object": "chat.completion.chunk", "model": request["model"],
                                    "choices": [{"index": 0, "delta": payload, "finish_reason": reason}]}
                        self.wfile.write(("data: " + json.dumps(response) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                except (AssertionError, KeyError, ValueError, OSError, StopIteration, TypeError) as error:
                    fixture.errors.append(str(error) or type(error).__name__)
                    self.send_error(400)

        return Loopback


def main(app, evidence, exercise_rejections):
    evidence.mkdir(parents=True)
    contents = app / "Contents"
    binary = contents / "MacOS" / plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"]
    fixture = BrowserFixture(exercise_rejections)
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler()) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = evidence / "app.json"
        command = [str(binary), "--browser-workspace-upgrade-only", "--project-task-fixture",
                   f"http://127.0.0.1:{server.server_port}/v1", "--unified-smoke-report", str(report)]
        try:
            with (evidence / "app.log").open("wb") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=65)
            assert not fixture.errors, fixture.errors
            result = json.loads(report.read_bytes())
            assert result["answered"] and result["width"] == 1460 and result["height"] == 930, result
            if not exercise_rejections:
                assert result["completed"], result
            assert fixture.provider_images == {"first", "second"}, fixture.provider_images
            receipt = payload(fixture.results["export"], "declaredSHA256Matched")
            assert receipt["declaredSHA256Matched"] and receipt["sha256"] == result["digest"], receipt
            print("Canvas text and pixel clicks, model image attachments and exact PNG export verified.")
            if exercise_rejections:
                print("Stale screenshot and overwrite attempts refused.")
        finally:
            server.shutdown()
            (evidence / "wire.json").write_text(json.dumps(
                {"sent": fixture.sent, "results": {key: value[:2000] for key, value in fixture.results.items()},
                 "providerImages": sorted(fixture.provider_images), "errors": fixture.errors}, indent=2) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), "--rejections" in sys.argv[3:])
