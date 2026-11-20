#!/usr/bin/env python3
"""Exercise the Mac Agent's real tool dispatch with a loopback model and disposable files."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
from threading import Thread


class Model(BaseHTTPRequestHandler):
    errors = []
    returned = set()

    def log_message(self, *_):
        pass

    def do_POST(self):
        try:
            self.handle_turn()
        except Exception as error:
            self.errors.append(str(error))
            self.send_error(400)

    def handle_turn(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = data["messages"]
        if "Create only a task title" in json.dumps(messages):
            self.stream({"content": "Native workspace"}, "stop")
            return
        last = max(i for i, m in enumerate(messages) if m["role"] == "user"
                   and "Native fixture " in str(m["content"]))
        prompt = messages[last]["content"]
        if isinstance(prompt, list):
            prompt = "\n".join(x.get("text", "") for x in prompt)
        scenario, outside = re.search(r'Native fixture (\w+)\nHost fixture: ([^\n]+)', prompt).groups()
        # The command can only name the fixture App's own disposable path.
        path = Path(outside)
        assert path.name == "approval-fixture.txt" and path.parent.name.startswith("floe-unified-smoke.")
        quoted = shlex.quote(str(path))
        commands = {
            "native": "uname -s", "write": "printf from-mac > result.txt",
            "deny": f"printf denied > {quoted}", "approve": f"printf approved > {quoted}",
            "confine": f"printf escaped > {quoted}", "confineRead": f"ln -s {quoted} outside-link && cat outside-link", "full": f"printf full > {quoted}", "second": "pwd",
        }
        call_id = "fixture-" + scenario
        result = next((m for m in messages[last:] if m.get("role") == "tool" and m.get("tool_call_id") == call_id), None)
        if result:
            self.returned.add(scenario)
            if scenario == "native":
                assert "Darwin" in str(result["content"]), "Native uname did not report Darwin"
            if scenario in ("confine", "confineRead"):
                output = str(result["content"])
                assert "Operation not permitted" in output or "Permission denied" in output, f"Missing OS boundary failure during {scenario}"
            self.stream({"content": "finished-" + scenario}, "stop")
            return
        available = {re.sub(r'[^a-z0-9]', '', t["function"]["name"].lower()): t["function"]["name"] for t in data.get("tools", [])}
        assert "execshell" in available, f"exec.shell missing from tool catalog during {scenario}: {sorted(available)}"
        arguments = {"command": commands[scenario]}
        if scenario in ("deny", "approve"):
            arguments["access"] = "host"
        self.stream({"role": "assistant", "tool_calls": [{"index": 0, "id": call_id, "type": "function",
                     "function": {"name": available["execshell"], "arguments": json.dumps(arguments)}}]}, "tool_calls")

    def stream(self, delta, reason):
        chunks = [{"choices": [{"index": 0, "delta": d, "finish_reason": r}]} for d, r in [(delta, None), ({}, reason)]]
        payload = ("".join("data: " + json.dumps(x) + "\n\n" for x in chunks) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    args = argparse.ArgumentParser()
    args.add_argument("app", type=Path)
    args.add_argument("--report", type=Path)
    opts = args.parse_args()
    binary = opts.app.resolve() / "Contents/MacOS/Floe Agent"
    with tempfile.TemporaryDirectory(prefix="floe-native-workspace-") as directory, ThreadingHTTPServer(("127.0.0.1", 0), Model) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = Path(directory) / "native.json"
        try:
            subprocess.run([str(binary), "--unified-smoke-report", str(report), "--native-command-fixture",
                            f"http://127.0.0.1:{server.server_port}/v1"], check=True, timeout=150)
        finally:
            server.shutdown()
        data = json.loads(report.read_bytes())
        data.update(modelErrors=Model.errors, toolResults=sorted(Model.returned))
        if opts.report:
            opts.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
            for suffix in ("content-search.png", "content-search-open.png"):
                screenshot = report.with_suffix(".json." + suffix)
                if screenshot.is_file():
                    opts.report.with_suffix("." + suffix).write_bytes(screenshot.read_bytes())
        print(json.dumps(data, ensure_ascii=False))
        checks = data["checks"]
        required = {"changeApprovalWhileWaiting", "messageContentSearch", "archivedSearchScope", "revealSearchMessage", "openSearchResultFromTaskCenter"}
        assert required <= checks.keys(), required - checks.keys()
        assert all(checks.values()) and not Model.errors
        assert Model.returned == {"native", "write", "deny", "approve", "confine", "confineRead", "full", "second"}


if __name__ == "__main__":
    main()
