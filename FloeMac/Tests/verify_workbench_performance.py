# SPDX-License-Identifier: MPL-2.0
"""Measure Mac workbench updates during live model output, paste and task switching."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import sys
from threading import Thread
from time import sleep


class StreamingFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = request["model"]
        prefixes = {"performance-history": "HISTORY", "performance-other": "OTHER"}
        if model not in prefixes:
            self.send_error(400)
            return
        prefix = prefixes[model]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def send(delta, reason=None):
            frame = {"id": model, "object": "chat.completion.chunk", "model": model,
                     "choices": [{"index": 0, "delta": delta, "finish_reason": reason}]}
            self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
            self.wfile.flush()

        try:
            send({"role": "assistant", "content": prefix + "_BEGIN\n\n"})
            frame_count = 124 if model == "performance-history" else 80
            for index in range(frame_count):
                sleep(0.048)
                send({"content": f"Fixture paragraph **{index}**.\n\n"})
            send({"content": prefix + "_DONE"})
            send({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError):
            return


def main(app, evidence):
    evidence.mkdir(parents=True)
    contents = app / "Contents"
    binary = contents / "MacOS" / plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleExecutable"]
    with ThreadingHTTPServer(("127.0.0.1", 0), StreamingFixture) as server:
        Thread(target=server.serve_forever, daemon=True).start()
        report = evidence / "app.json"
        command = [str(binary), "--workbench-performance-only", "--project-task-fixture",
                   f"http://127.0.0.1:{server.server_port}/v1", "--unified-smoke-report", str(report)]
        try:
            with (evidence / "app.log").open("wb") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=70)
        finally:
            server.shutdown()
    result = json.loads(report.read_bytes())
    print(json.dumps(result, indent=2))
    assert result.get("historyRows") == 602 and result.get("streamUpdates", 0) >= 32, result
    assert result.get("renderedUpdates", 0) >= result["streamUpdates"] - 3, result
    for key in ("pasteRetained", "newTaskOpened", "draftIsolated", "returnedToActiveStream", "independentRepliesSaved"):
        assert result.get(key) is True, key


if __name__ == "__main__":
    main(*(Path(value) for value in sys.argv[1:]))
