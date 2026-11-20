#!/usr/bin/env python3
"""Exercise explicit task creation and quoted history retrieval through the Mac app."""
import argparse
import json
import re
import subprocess
import tempfile
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from verify_native_workspace import Model


class ThreadModel(Model):
    observed = set()
    errors = []

    def handle_turn(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = data["messages"]
        if "Create only a task title" in json.dumps(messages):
            self.stream({"content": "Origin review"}, "stop")
            return
        user = max(i for i, m in enumerate(messages) if m["role"] == "user")
        prompt = str(messages[user]["content"])
        results = {m.get("tool_call_id"): str(m["content"]) for m in messages[user + 1:] if m["role"] == "tool"}
        available = {re.sub(r"[^a-z0-9]", "", t["function"]["name"].lower()): t["function"]["name"] for t in data.get("tools", [])}
        if "Find the task whose messages" in prompt:
            if "read" in results:
                assert "Floe-Origin-34" in results["read"], results["read"][:350]
                self.observed.add("read")
                self.stream({"content": "History confirmed: Floe-Origin-34"}, "stop")
                return
            if "search" in results:
                match = re.search(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}', results["search"], re.I)
                assert match, results["search"][:350]
                action, identity, args = "conversationread", "read", {"conversationID": match[0]}
            else:
                action, identity, args = "conversationsearch", "search", {"query": "Floe-Origin-34", "includeAllWorkspaces": True}
        else:
            explicit = "Create a new task named Reference notebook" in prompt
            identity = "spawn" if explicit else "unsolicited"
            if identity in results:
                assert ("status=created" if explicit else "needsExplicitUserRequest") in results[identity], results[identity][:350]
                self.observed.add(identity)
                self.stream({"content": "The task was created." if explicit else "The task count is unchanged."}, "stop")
                return
            action = "conversationspawn"
            args = {"title": "Reference notebook" if explicit else "Unrequested notebook", "objective": "Prepare the separate notebook."}
        if action not in available:
            assert "toolssearch" in available and "discover-" + action not in results, f"{action} unavailable"
            identity = "discover-" + action
            args = {"query": "conversation." + action.removeprefix("conversation")}
            action = "toolssearch"
        self.stream({"role": "assistant", "tool_calls": [
            {"index": 0, "id": identity, "type": "function", "function": {"name": available[action], "arguments": json.dumps(args)}}
        ]}, "tool_calls")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="floe-thread-work-") as directory, ThreadingHTTPServer(("127.0.0.1", 0), ThreadModel) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = Path(directory) / "threads.json"
        try:
            subprocess.run([str(args.app.resolve() / "Contents/MacOS/Floe Agent"), "--unified-smoke-report", str(report),
                            "--thread-ownership-only", "--project-task-fixture", f"http://127.0.0.1:{server.server_port}/v1"], check=True, timeout=130)
        finally:
            server.shutdown()
        data = json.loads(report.read_bytes())
        data.update(modelErrors=ThreadModel.errors, observed=sorted(ThreadModel.observed))
        if args.report:
            args.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        assert data.get("checks") == dict.fromkeys(["sourceStayedSelected", "separateInitialMessage", "independentPermissionsAndFolder", "readSource", "noImplicitSpawn"], True), data
        assert ThreadModel.observed == {"spawn", "read", "unsolicited"} and not ThreadModel.errors, data
        print("Separate task, independent ownership, quoted history and implicit spawn refusal verified.")


if __name__ == "__main__":
    main()
