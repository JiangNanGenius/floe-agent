# SPDX-License-Identifier: MPL-2.0
"""Exercise the native question and approval cards with two loopback models."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from threading import Thread


class ApprovalFixture:
    def __init__(self):
        self.reviews = []
        self.errors = []

    def response(self, request):
        messages = request["messages"]
        if request["model"] == "basic-approval-reviewer":
            prompt = messages[-1]["content"]
            context, arguments = prompt.split("Action context JSON:\n", 1)[1].split("\nExact arguments JSON:\n", 1)
            self.reviews.append(json.loads(context)["tool"])
            payload, _ = json.JSONDecoder().raw_decode(arguments.lstrip())
            assert payload == {"command": "echo Approved > choice.txt", "access": "workspace"}
            assert "idempotencyKey" not in prompt and "sk-fixture-approval-redaction" not in prompt
            return {"content": '{"decision":"ask","reason":"Verify the named file"}'}, "stop"
        assert request["model"] == "basic-approval-primary", request["model"]
        if any("Create only a task title" in entry.get("content", "")
               for entry in messages if entry["role"] == "system"):
            return {"content": "Output choice"}, "stop"
        results = {entry["tool_call_id"]: entry.get("content", "") for entry in messages if entry["role"] == "tool"}
        if "choice" not in results:
            step, tool = "choice", "user.ask"
            arguments = {"waitPolicy": "required", "questions": [{
                "question": "Which output?", "selection": "single",
                "options": [{"id": "report", "label": "Report"}, {"id": "notes", "label": "Notes"}],
            }]}
        elif "write" not in results:
            assert "report" in results["choice"], results["choice"]
            step, tool = "write", "exec.shell"
            arguments = {"command": "echo Approved > choice.txt", "access": "workspace"}
        elif "private" not in results:
            step, tool = "private", "exec.shell"
            arguments = {"command": "echo sk-fixture-approval-redaction > private.txt", "access": "workspace"}
        else:
            return {"content": "Basic flow verified."}, "stop"
        names = {self.normalized(entry["function"]["name"]): entry["function"]["name"]
                 for entry in request.get("tools", [])}
        function = names.get(self.normalized(tool))
        if function is None:
            step = "find-" + step
            assert step not in results and "toolssearch" in names, (tool, list(names))
            function = names["toolssearch"]
            arguments = {"query": tool}
        return {"tool_calls": [{"index": 0, "id": step, "type": "function",
                                "function": {"name": function, "arguments": json.dumps(arguments)}}]}, "tool_calls"

    @staticmethod
    def normalized(name):
        return re.sub(r"[^a-z]", "", name.lower())

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
                        frame = {"id": "basic-approval", "object": "chat.completion.chunk", "model": request["model"],
                                 "choices": [{"index": 0, "delta": payload, "finish_reason": reason}]}
                        self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                except (AssertionError, KeyError, ValueError, TypeError, IndexError) as error:
                    fixture.errors.append(str(error))
                    self.send_error(400)

        return Loopback


def main(app, evidence):
    evidence.mkdir(parents=True)
    contents = app / "Contents"
    binary = contents / "MacOS" / plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"]
    fixture = ApprovalFixture()
    with ThreadingHTTPServer(("127.0.0.1", 0), fixture.handler()) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = evidence / "app.json"
        command = [str(binary), "--basic-approval-flow-only", "--project-task-fixture",
                   f"http://127.0.0.1:{server.server_port}/v1", "--unified-smoke-report", str(report)]
        try:
            with (evidence / "app.log").open("wb") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        finally:
            server.shutdown()
            wire = {"reviewedTools": fixture.reviews, "fixtureErrors": fixture.errors}
            (evidence / "wire.json").write_text(json.dumps(wire, indent=2) + "\n")
    result = json.loads(report.read_bytes())
    print(json.dumps({"app": result, "wire": wire}, indent=2))
    assert not fixture.errors and fixture.reviews == ["exec.shell"], wire
    for item in ("directQuestion", "answeredInApp", "approvedFile", "fileUnchangedBeforeApproval",
                 "savedToProject", "privateActionDenied", "answeredAfterDenial", "persistedOnReopen"):
        assert result.get(item) is True, item


if __name__ == "__main__":
    main(*(Path(value) for value in sys.argv[1:]))
