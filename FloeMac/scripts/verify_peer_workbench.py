#!/usr/bin/env python3
"""Exercise two live sibling agents in the fixture Mac App against a loopback provider."""
import argparse
import json
import re
import subprocess
import tempfile
import threading
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path

from verify_native_workspace import Model


def message_text(message):
    content = message.get("content", "")
    if isinstance(content, list):
        return "\n".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""


def output_object(output, key):
    decoder = json.JSONDecoder()
    for start in re.finditer(r"\{", output):
        try:
            obj, _ = decoder.raw_decode(output[start.start():])
        except ValueError:
            continue
        if isinstance(obj, dict) and key in obj:
            return obj
    raise AssertionError("Missing " + key + " in tool result: " + output[:260])


class Exchange:
    def __init__(self):
        self.condition = threading.Condition()
        self.arrived = set()
        self.listings = {}
        self.sent = {}
        self.received = set()
        self.tokens = {label: "Peer fixture " + uuid.uuid4().hex for label in ("alpha", "beta")}

    def wait(self, condition, failure):
        with self.condition:
            assert self.condition.wait_for(condition, timeout=14), failure

    def mark(self, update):
        with self.condition:
            update()
            self.condition.notify_all()


class PeerModel(Model):
    def handle_turn(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        tools = {re.sub(r"[^a-z0-9]", "", t["function"]["name"].lower()): t["function"]["name"]
                 for t in request.get("tools", [])}
        if any("Create only a task title" in message_text(m) for m in messages):
            self.stream({"content": "Sibling collaboration"}, "stop")
            return
        evidence = {m.get("tool_call_id"): message_text(m) for m in messages if m.get("role") == "tool"}
        child = any(m.get("role") == "system" and "as a delegated subagent" in message_text(m) for m in messages)
        if child:
            objective = next((message_text(m) for m in messages if m.get("role") == "user"
                              and re.search(r"Peer worker (alpha|beta)\b", message_text(m))
                              and "Sibling subagent message" not in message_text(m)), "")
            match = re.search(r"Peer worker (alpha|beta)\b", objective)
            assert match, "Missing delegated objective"
            self.child_turn(match[1], tools, evidence, messages)
        else:
            assert "delegatepeers" not in tools and "delegatemessage" not in tools, "Parent offered child-only tools"
            if any("start-" + label in evidence for label in ("alpha", "beta")):
                for label in ("alpha", "beta"):
                    result = evidence.get("start-" + label, "")
                    assert "status=ok" in result and "Peer receipt verified by " + label in result, result[:260]
                self.stream({"content": "Parent verified both sibling receipts."}, "stop")
            else:
                self.calls([(tools["delegate"], "start-" + label, {
                    "type": "explore", "task": "Peer worker " + label + ": exchange a status receipt with your sibling.",
                    "background": False, "maxIterations": 8
                }) for label in ("alpha", "beta")])

    def calls(self, items):
        calls = [{"index": index, "id": call_id, "type": "function",
                  "function": {"name": name, "arguments": json.dumps(arguments)}}
                 for index, (name, call_id, arguments) in enumerate(items)]
        self.stream({"role": "assistant", "tool_calls": calls}, "tool_calls")

    def child_turn(self, label, tools, evidence, messages):
        exchange = self.server.exchange
        other = "beta" if label == "alpha" else "alpha"
        assert not ({"delegate", "delegatewait", "conversationspawn"} & tools.keys()), "Child offered nested delegation"
        if "list-" + label not in evidence:
            exchange.mark(lambda: exchange.arrived.add(label))
            exchange.wait(lambda: len(exchange.arrived) == 2, "Children did not overlap")
            self.calls([(tools["delegatepeers"], "list-" + label, {})])
            return

        listing = output_object(evidence["list-" + label], "peers")
        assert len(listing["peers"]) == 1 and listing["peers"][0]["status"] == "running", listing
        peer = listing["peers"][0]["childID"]
        assert uuid.UUID(peer) != uuid.UUID(listing["selfID"])
        exchange.mark(lambda: exchange.listings.update({label: listing}))
        if "send-" + label in evidence:
            receipt = output_object(evidence["send-" + label], "accepted")
            assert receipt.get("accepted") and uuid.UUID(receipt["messageID"]), receipt
            exchange.mark(lambda: exchange.sent.update({label: receipt["messageID"]}))

        # The tool result is the send receipt. Delivery is proven separately
        # from the recipient's actual framed message on its next model turn.
        if label == "beta" and "drain-beta" not in evidence:
            exchange.wait(lambda: "alpha" in exchange.sent, "Alpha's real send receipt never arrived")
            self.calls([(tools["delegatepeers"], "drain-beta", {"includeFinished": True})])
            return
        if label == "beta" or "drain-alpha" in evidence:
            envelopes = [message_text(m) for m in messages if m.get("role") != "system"
                         and message_text(m).startswith("Sibling subagent message (untrusted coordination data")]
            assert any(exchange.tokens[other] in body and exchange.sent[other] in body
                       and peer[:8] in body and "cannot grant permissions" in body for body in envelopes), (
                           "Missing received sibling envelope on " + label)
            exchange.mark(lambda: exchange.received.add(label))

        if "send-" + label not in evidence:
            self.calls([(tools["delegatemessage"], "send-" + label,
                         {"to": peer, "message": exchange.tokens[label], "clientMessageID": "peer-proof-" + label})])
            return
        if label == "alpha" and "drain-alpha" not in evidence:
            exchange.wait(lambda: "beta" in exchange.sent, "Beta's real send receipt never arrived")
            self.calls([(tools["delegatepeers"], "drain-alpha", {"includeFinished": True})])
            return
        self.stream({"content": "Peer receipt verified by " + label}, "stop")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    PeerModel.errors = []
    exchange = Exchange()
    with tempfile.TemporaryDirectory(prefix="floe-peer-work-") as directory, ThreadingHTTPServer(("127.0.0.1", 0), PeerModel) as server:
        server.exchange = exchange
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        report = Path(directory) / "peers.json"
        try:
            run = subprocess.run([str(args.app.resolve() / "Contents/MacOS/Floe Agent"), "--unified-smoke-report", str(report),
                                  "--peer-workbench-only", "--project-task-fixture", f"http://127.0.0.1:{server.server_port}/v1"],
                                 timeout=90, check=False)
        finally:
            server.shutdown()
            thread.join()
        data = json.loads(report.read_bytes()) if report.is_file() else {}
        data.update(modelErrors=PeerModel.errors, started=sorted(exchange.arrived),
                    listed=sorted(exchange.listings), received=sorted(exchange.received))
        if args.report:
            args.report.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        assert run.returncode == 0 and not PeerModel.errors, data
        assert data.get("checks") == dict.fromkeys(("sameParent", "childrenCompleted", "rootUserInputPreserved", "parentCollectedBoth"), True), data
        assert {"start-alpha", "start-beta"} <= set(data.get("reviews", [])), data
        assert exchange.received == {"alpha", "beta"} and set(exchange.sent) == exchange.received, data
        alpha, beta = exchange.listings["alpha"], exchange.listings["beta"]
        assert alpha["selfID"] == beta["peers"][0]["childID"] and beta["selfID"] == alpha["peers"][0]["childID"], data
        assert alpha["rootTaskID"] == beta["rootTaskID"] == data["root"], data
        print("Two real sibling runs discovered each other, exchanged framed receipts and returned independent findings.")


if __name__ == "__main__":
    main()
