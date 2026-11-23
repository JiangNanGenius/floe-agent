# SPDX-License-Identifier: MPL-2.0
"""Check the Mac Debug workbench and reasoning request fields on loopback.

Usage: python3 FloeMac/Tests/verify_automatic_reasoning.py APP EVIDENCE
"""

from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from threading import Thread
import time


TURN_PATTERN = re.compile(r"Reasoning fixture (fast|automatic|fallback|manual|task)\.")
FILE_CONTENT = "Recovered one synthetic file.\n"


def message_text(message):
    content = message.get("content") or ""
    if isinstance(content, list):
        return "\n".join(part.get("text", "") for part in content if part.get("type") == "text")
    return content


class ReasoningFixture:
    def __init__(self):
        self.phase = "chat"
        self.requests = []
        self.errors = []

    def response(self, request):
        messages = request["messages"]
        system = "\n".join(message_text(item) for item in messages if item["role"] == "system")
        if "task title" in system.lower() and "You choose the reasoning effort" not in system:
            return {"content": "Fixture reasoning task"}, "stop"

        users = [message_text(item) for item in messages if item["role"] == "user"]
        turn = next((match[1] for user in reversed(users) if (match := TURN_PATTERN.search(user))), "")
        helper = "You choose the reasoning effort" in system
        self.requests.append({
            "phase": self.phase, "turn": turn, "helper": helper, "model": request["model"],
            "effort": request.get("reasoning_effort"), "toolCount": len(request.get("tools") or []),
        })
        if helper:
            assert not request.get("tools"), "The classifier was offered tools"
            assert len(users) == 1 and users[0].startswith("Request: "), users
            if self.phase == "chat":
                assert request["model"] == "effort-helper-fixture"
            content = "Unusable effort response" if turn == "fallback" else '{"effort":"high"}'
            return {"content": content}, "stop"

        assert request["model"] == "o3", request["model"]
        if self.phase == "chat":
            assert turn, "Missing current turn"
            return {"content": "Reasoning fixture completed."}, "stop"

        tools = {re.sub(r"[^a-z]", "", item["function"]["name"].lower()): item["function"]["name"]
                 for item in request.get("tools", [])}
        if any(item.get("tool_call_id") == "cold-create" for item in messages):
            return {"content": "Cold recovery verified."}, "stop"
        if "workspacecreatefile" in tools:
            call_id = "cold-create"
            name = tools["workspacecreatefile"]
            arguments = {"path": "cold-proof.txt", "content": FILE_CONTENT}
        else:
            call_id = "find-create"
            name = tools["toolssearch"]
            arguments = {"query": "workspace.createFile"}
            assert not any(item.get("tool_call_id") == call_id for item in messages), tools
        return {"tool_calls": [{"index": 0, "id": call_id, "type": "function",
                               "function": {"name": name, "arguments": json.dumps(arguments)}}]}, "tool_calls"

    def handler(self):
        fixture = self

        class Loopback(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                try:
                    assert self.path == "/v1/chat/completions", self.path
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    delta, finish = fixture.response(request)
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for payload, reason in ((dict(delta, role="assistant"), None), ({}, finish)):
                        chunk = {"id": "reasoning-fixture", "object": "chat.completion.chunk", "model": request["model"],
                                 "choices": [{"index": 0, "delta": payload, "finish_reason": reason}]}
                        self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                except (AssertionError, KeyError, ValueError, OSError) as error:
                    fixture.errors.append(str(error))
                    self.send_error(400)

        return Loopback


def run(app, output):
    output.mkdir(parents=True)
    (output / "cold").mkdir()
    contents = app / "Contents"
    binary = contents / "MacOS" / plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"]
    fixture = ReasoningFixture()
    env = dict(os.environ, AppleLanguages="(en)")
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler()) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        command = [str(binary), "--project-task-fixture", f"http://127.0.0.1:{server.server_port}/v1"]
        try:
            report = output / "app.json"
            with (output / "app.log").open("wb") as log:
                subprocess.run(command + ["--automatic-reasoning-only", "--unified-smoke-report", str(report)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=50, env=env)
            result = json.loads(report.read_bytes())
            assert len(result["checks"]) == 10 and all(result["checks"].values()), result
            main = [row for row in fixture.requests if not row["helper"]]
            assert [(row["turn"], row["effort"]) for row in main] == [
                ("fast", "low"), ("automatic", "high"), ("fallback", None), ("manual", "medium"), ("task", "high")
            ], main
            assert Counter(row["turn"] for row in fixture.requests if row["helper"]) == {
                "automatic": 1, "fallback": 1, "task": 1
            }, fixture.requests
            assert not fixture.errors, fixture.errors
            print("Mac Chat menu, persistence, fallback and main provider effort verified.")

            fixture.phase = "cold-stage"
            cold_output = output / "cold"
            parked_report = cold_output / "parked.json"
            cold = command + ["--cold-recovery-only", "--cold-automatic-reasoning"]
            with (cold_output / "parked.log").open("wb") as log:
                with subprocess.Popen(cold + ["--unified-smoke-report", str(parked_report)],
                                      stdout=log, stderr=subprocess.STDOUT, env=env) as process:
                    try:
                        deadline = time.monotonic() + 22
                        while not parked_report.exists() and process.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.05)
                        parked = json.loads(parked_report.read_bytes()) if parked_report.exists() else {}
                        assert parked.get("parked") and parked["pid"] == process.pid and not parked["fileExists"], parked
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=5)

            fixture.phase = "cold-resume"
            resumed_report = cold_output / "resumed.json"
            with (cold_output / "resumed.log").open("wb") as log:
                subprocess.run(cold + ["--workbench-reopen", "--unified-smoke-report", str(resumed_report)],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=35, env=env)
            resumed = json.loads(resumed_report.read_bytes())
            assert resumed["finished"] and resumed["activeBranchCorrect"] and resumed["freshDecision"], resumed
            assert resumed["state"] == "completed" and resumed["originalRunID"] == parked["runID"], resumed
            assert resumed["file"] == FILE_CONTENT, resumed
            cold_requests = [row for row in fixture.requests if row["phase"].startswith("cold-")]
            assert [row["phase"] for row in cold_requests if row["helper"]] == ["cold-stage"], cold_requests
            assert any(row["phase"] == "cold-resume" for row in cold_requests), cold_requests
            assert all(row["effort"] == "high" for row in cold_requests if not row["helper"]), cold_requests
            assert not fixture.errors, fixture.errors
            print("Cold continuation reused the original effort after changing the saved model tier.")
        finally:
            server.shutdown()
            (output / "wire.json").write_text(json.dumps(
                {"requests": fixture.requests, "errors": fixture.errors}, indent=2) + "\n")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
