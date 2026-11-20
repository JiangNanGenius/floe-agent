#!/usr/bin/env python3
"""Verify actual Mac child command execution and refusal with a disposable project."""
import argparse
import json
import re
import subprocess
import tempfile
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from verify_native_workspace import Model


class ChildModel(Model):
    returned = set()
    errors = []

    def handle_turn(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        text = json.dumps(messages)
        if "Create only a task title" in text:
            self.stream({"content": "Child execution check"}, "stop")
            return
        child = any(m.get("role") == "system" and "as a delegated subagent" in str(m.get("content")) for m in messages)
        label = re.search(r"(accepted|denied) independent command check", text)
        assert label, "No child fixture objective"
        label = label.group(1)
        tools = {re.sub(r"[^a-z0-9]", "", t["function"]["name"].lower()): t["function"]["name"] for t in request.get("tools", [])}
        evidence = {m.get("tool_call_id"): str(m.get("content")) for m in messages if m.get("role") == "tool"}
        if child:
            assert "delegate" not in tools and "conversationspawn" not in tools, "Child received a main-run-only action"
            if "shell-" + label in evidence:
                result = evidence["shell-" + label]
                if label == "denied":
                    assert re.search(r"deni|declin|refus|拒绝", result, re.I), result[:250]
                self.returned.add(label)
                self.stream({"content": "Verified " + label + " independent command check."}, "stop")
                return
            if "execshell" in tools:
                action = tools["execshell"]
                call_id = "shell-" + label
                args = {"command": "echo child-verified > child-" + label + ".txt", "access": "workspace"}
            else:
                assert "toolssearch" in tools and "discover-" + label not in evidence, "exec.shell was unavailable to executing child"
                action = tools["toolssearch"]
                call_id = "discover-" + label
                args = {"query": "exec.shell"}
        else:
            if "start-" + label in evidence:
                self.stream({"content": "Received the child outcome for the " + label + " independent command check."}, "stop")
                return
            action = tools["delegate"]
            call_id = "start-" + label
            args = {"type": "execute", "task": "Perform the " + label + " independent command check using exec.shell.",
                    "background": False, "maxIterations": 6}
        self.stream({"role": "assistant", "tool_calls": [
            {"index": 0, "id": call_id, "type": "function", "function": {"name": action, "arguments": json.dumps(args)}}
        ]}, "tool_calls")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="floe-child-work-") as directory, ThreadingHTTPServer(("127.0.0.1", 0), ChildModel) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = Path(directory) / "child.json"
        try:
            subprocess.run([str(args.app.resolve() / "Contents/MacOS/Floe Agent"), "--unified-smoke-report", str(report),
                            "--child-execution-only", "--project-task-fixture", f"http://127.0.0.1:{server.server_port}/v1"],
                           check=True, timeout=135)
        finally:
            server.shutdown()
        data = json.loads(report.read_bytes())
        data.update(modelErrors=ChildModel.errors, modelToolResults=sorted(ChildModel.returned))
        if args.report:
            args.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            for screenshot in Path(directory).glob("child.json.child-*.png"):
                args.report.with_suffix("." + screenshot.name.removeprefix("child.json.")).write_bytes(screenshot.read_bytes())
        assert data["checks"] == {"accepted": True, "denied": True}, data
        assert ChildModel.returned == {"accepted", "denied"} and not ChildModel.errors, data
        print("Child exec.shell succeeded after approval; declined command left no file.")


if __name__ == "__main__":
    main()
