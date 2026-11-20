#!/usr/bin/env python3
"""Run a task-scoped image through the actual Mac workbench and a local model/provider."""
import argparse
import base64
import hashlib
import json
import re
import subprocess
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

from verify_creative_media import image_fixture
from verify_native_workspace import Model
from verify_peer_workbench import message_text, output_object


class TaskMediaModel(Model):
    def handle_turn(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/images/generations":
            assert self.headers.get("Authorization") == "Bearer floe-image-fixture", "Unexpected image provider credential"
            assert body["prompt"] == "Draw the workbench fixture." and body["model"] == "gpt-image-fixture", "Wrong paid request"
            assert body.get("n", 1) == 1 and self.server.events[-1:] == ["proposed-generation"], self.server.events
            self.server.events.append("image-http")
            payload = json.dumps({"data": [{"b64_json": base64.b64encode(image_fixture()).decode()}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        assert self.path == "/v1/chat/completions", self.path
        messages = body["messages"]
        if any("Create only a task title" in message_text(m) for m in messages):
            self.stream({"content": "Task media fixture"}, "stop")
            return
        assert body["model"] == "task-media-workbench-fixture", "Unexpected chat model"
        assert any(m.get("role") == "user" and "task-media-workbench fixture" in message_text(m) for m in messages), "Missing root prompt"
        available = {re.sub(r"[^a-z0-9]", "", t["function"]["name"].lower()): t["function"]["name"]
                     for t in body.get("tools", [])}
        results = {m.get("tool_call_id"): message_text(m) for m in messages if m.get("role") == "tool"}

        if "workbench-generate" in results:
            result = results["workbench-generate"]
            # The provider sees the tool's summary text. The persisted dispatch status is checked in the App.
            path = re.search(r"GeneratedImages/[a-f0-9-]{36}/[a-f0-9]{64}/Image-1\.png", result, re.I)
            assert path, result[:700]
            self.server.model_path = path.group(0)
            self.server.events.append("model-received-file")
            self.stream({"content": "Task media receipt confirmed."}, "stop")
            return
        if "workbench-models" in results:
            catalog = output_object(results["workbench-models"], "models")
            candidates = [entry for entry in catalog["models"] if entry["selectable"]]
            assert len(candidates) == 1 and candidates[0]["model"] == "gpt-image-fixture", candidates
            action, identity = "image.generate", "workbench-generate"
            arguments = {"model": candidates[0]["model"], "prompt": "Draw the workbench fixture.", "count": 1}
        else:
            action, identity, arguments = "image.models", "workbench-models", {"operation": "generate"}
        tool = action.replace(".", "")
        if tool not in available:
            assert "toolssearch" in available and "discover-" + tool not in results, f"{action} unavailable"
            arguments, tool, identity = {"query": action}, "toolssearch", "discover-" + tool
        elif tool == "imagegenerate":
            self.server.events.extend(["model-received-catalog", "proposed-generation"])
        elif tool == "imagemodels":
            self.server.events.append("proposed-catalog")
        self.stream({"role": "assistant", "tool_calls": [
            {"index": 0, "id": identity, "type": "function", "function": {"name": available[tool], "arguments": json.dumps(arguments)}}
        ]}, "tool_calls")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], check=True)
    expected_events = ["proposed-catalog", "model-received-catalog", "proposed-generation", "image-http", "model-received-file"]
    expected_checks = {"modelListedImageRoute", "paidApprovalClicked", "restoredExecutionArtifact",
                       "finderResolvedOriginalFile", "receiptMatchesFileSHA256", "modelReceivedToolResult"}
    with tempfile.TemporaryDirectory(prefix="floe-task-media-") as scratch, ThreadingHTTPServer(("127.0.0.1", 0), TaskMediaModel) as server:
        server.events = []
        server.model_path = None
        TaskMediaModel.errors = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        report = Path(scratch) / "task-media.json"
        try:
            run = subprocess.run([str(app / "Contents/MacOS/Floe Agent"), "--unified-smoke-report", str(report),
                                  "--task-media-workbench-only", "--project-task-fixture", f"http://127.0.0.1:{server.server_port}/v1"],
                                 timeout=80, check=False)
        finally:
            server.shutdown()
            thread.join()
        data = json.loads(report.read_bytes()) if report.is_file() else {}
        data.update(modelErrors=TaskMediaModel.errors, providerEvents=server.events, modelPath=server.model_path, expectedSHA256=hashlib.sha256(image_fixture()).hexdigest())
        if args.report:
            args.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            screenshot = report.with_suffix(".json.task-media-approval.png")
            if screenshot.is_file():
                args.report.with_suffix(".task-media-approval.png").write_bytes(screenshot.read_bytes())
        assert run.returncode == 0 and not TaskMediaModel.errors, data
        assert data.get("checks") == dict.fromkeys(expected_checks, True), data
        assert server.events == expected_events and data["expectedSHA256"] == data["receiptSHA256"] == data["fileSHA256"], data
        assert data["byteCount"] == len(image_fixture()) and data["artifactPath"] == server.model_path, data
        print("Signed workbench submitted one approved image request and recovered the Finder file and matching digest after reopening the task.")


if __name__ == "__main__":
    main()
