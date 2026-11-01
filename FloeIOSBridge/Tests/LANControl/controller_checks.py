#!/usr/bin/env python3
"""Controller-side checks for the typed generic automation arguments.

The Swift LAN loopback test proves transport/dispatch binding. This script
checks the reference controller's closed argument construction, 0600 text-file
handling, and a real encrypted Python -> Swift NWListener round trip. Text is
never printed.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import shutil
import socket
import stat
import subprocess
import threading
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parents[1] / "scripts" / "LANControl"))
import bridge_control as bc  # noqa: E402

checks = 0
failures = 0


def expect(condition: bool, name: str, detail: str = "") -> None:
    global checks, failures
    checks += 1
    if condition:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name} {detail}")


def expect_raises(function, name: str) -> None:
    try:
        function()
    except SystemExit:
        expect(True, name)
    except Exception as error:  # noqa: BLE001 - report the unexpected type
        expect(False, name, f"unexpected {type(error).__name__}")
    else:
        expect(False, name, "did not refuse")


def write_private(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, data)
    finally:
        os.close(descriptor)
    os.chmod(path, 0o600)


def namespace(**values: object) -> SimpleNamespace:
    defaults = {
        "bundle_id": "com.apple.Preferences",
        "identifier": None,
        "label": None,
        "placeholder": None,
        "x": None,
        "y": None,
        "start_x": 0.5,
        "start_y": 0.8,
        "end_x": 0.5,
        "end_y": 0.2,
        "duration_ms": None,
        "text_file": None,
        "max_depth": None,
        "max_nodes": None,
        "max_string_bytes": None,
        "max_total_bytes": None,
    }
    defaults.update(values)
    return SimpleNamespace(**defaults)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True, help="built lan-control-checks binary")
    parser.add_argument("--controller", required=True, help="bridge_control.py")
    args = parser.parse_args()

    expect(bc.build_parameters("activate_app", namespace()) == {
        "bundleIdentifier": "com.apple.Preferences",
    }, "controller builds activate parameters")
    expect(bc.build_parameters("inspect_ui", namespace(max_nodes=50, max_total_bytes=4096)) == {
        "bundleIdentifier": "com.apple.Preferences",
        "maxNodes": 50,
        "maxTotalBytes": 4096,
    }, "controller builds inspect bounds")
    expect(bc.build_parameters("tap", namespace(identifier="floe.controlTest.counterButton")) == {
        "bundleIdentifier": "com.apple.Preferences",
        "identifier": "floe.controlTest.counterButton",
    }, "controller builds identifier tap")
    expect(bc.build_parameters("tap", namespace(x=0.5, y=0.25)) == {
        "bundleIdentifier": "com.apple.Preferences",
        "normalizedX": 0.5,
        "normalizedY": 0.25,
    }, "controller builds coordinate tap")
    expect_raises(lambda: bc.build_parameters("tap", namespace(identifier="x", x=0.5, y=0.5)),
                  "controller refuses identifier plus coordinates")
    expect_raises(lambda: bc.build_parameters("tap", namespace(x=0.5)),
                  "controller refuses a partial coordinate")
    expect_raises(lambda: bc.build_parameters("tap", namespace(x=1.5, y=0.5)),
                  "controller refuses an out-of-range coordinate")
    expect_raises(lambda: bc.build_parameters("tap", namespace(x=float("nan"), y=0.5)),
                  "controller refuses a non-finite coordinate")
    expect(bc.build_parameters("swipe", namespace()) == {
        "bundleIdentifier": "com.apple.Preferences",
        "startNormalizedX": 0.5,
        "startNormalizedY": 0.8,
        "endNormalizedX": 0.5,
        "endNormalizedY": 0.2,
    }, "controller builds swipe parameters")
    expect_raises(lambda: bc.build_parameters("swipe", namespace(end_y=0.8)),
                  "controller refuses a zero-distance swipe")
    expect_raises(lambda: bc.build_parameters("swipe", namespace(duration_ms=20)),
                  "controller refuses an out-of-range swipe duration")

    with tempfile.TemporaryDirectory(prefix="floe-controller-") as directory:
        root = Path(directory)
        text_path = root / "text"
        write_private(text_path, "héllo world".encode("utf-8"))
        expect(bc.read_private_text(str(text_path)) == "héllo world",
               "controller reads private UTF-8 text")
        expect(bc.build_parameters("type_text", namespace(
            text_file=str(text_path), identifier="floe.controlTest.textField"
        )) == {
            "bundleIdentifier": "com.apple.Preferences",
            "identifier": "floe.controlTest.textField",
            "text": "héllo world",
        }, "controller builds typed text parameters")
        expect(bc.build_parameters("type_text", namespace(
            text_file=str(text_path), label="搜索"
        )) == {
            "bundleIdentifier": "com.apple.Preferences",
            "label": "搜索",
            "text": "héllo world",
        }, "controller builds a label-targeted text request")
        expect(bc.build_parameters("type_text", namespace(
            text_file=str(text_path), x=0.5, y=0.13
        )) == {
            "bundleIdentifier": "com.apple.Preferences",
            "normalizedX": 0.5,
            "normalizedY": 0.13,
            "text": "héllo world",
        }, "controller builds a point-targeted text request")
        expect_raises(lambda: bc.build_parameters("type_text", namespace(
            text_file=str(text_path), identifier="x", label="y"
        )), "controller refuses two text field selectors")
        expect_raises(lambda: bc.build_parameters("type_text", namespace(
            text_file=str(text_path), x=0.5
        )), "controller refuses a partial text point")

        public_path = root / "public"
        write_private(public_path, b"x")
        os.chmod(public_path, 0o644)
        expect_raises(lambda: bc.read_private_text(str(public_path)),
                      "controller refuses group/world-readable text")
        large_path = root / "large"
        write_private(large_path, b"x" * 4097)
        expect_raises(lambda: bc.read_private_text(str(large_path)),
                      "controller refuses oversized text")
        nul_path = root / "nul"
        write_private(nul_path, b"a\x00b")
        expect_raises(lambda: bc.read_private_text(str(nul_path)),
                      "controller refuses NUL text")
        expect_raises(lambda: bc.read_private_text(str(root / "missing")),
                      "controller refuses a missing text file")

        # Deterministic controller receipt/reconciliation checks. The fake
        # client supplies already-opened responses; encryption itself is
        # covered by the real Swift round trip below.
        class FakeClient:
            def __init__(self, session: str = "a" * 32,
                         control: dict[str, object] | None = None,
                         result: dict[str, object] | None = None,
                         transport_lost: bool = False):
                self.state = {"pid": 4242, "generation": 7, "session": session}
                self.control = control or {
                    "ok": True,
                    "state": "accepted",
                    "currentPid": 4242,
                    "currentGeneration": 7,
                    "generation": 7,
                    "duplicate": False,
                    "parametersDigest": "digest",
                }
                self.result = result or {
                    "ok": True,
                    "state": "pending",
                    "currentPid": 4242,
                    "currentGeneration": 7,
                }
                self.transport_lost = transport_lost
                self.calls: list[tuple[str, dict[str, object]]] = []
                self.discover_calls = 0

            def update_state(self, *, pid=None, generation=None, session=None) -> None:
                if pid is not None and pid > 0:
                    self.state["pid"] = pid
                if generation is not None and generation >= 0:
                    self.state["generation"] = generation
                if session is not None:
                    self.state["session"] = session

            def discover(self):
                self.discover_calls += 1
                return {
                    "ok": True,
                    "state": "session",
                    "sessionId": self.state["session"],
                    "currentPid": self.state["pid"],
                    "currentGeneration": self.state["generation"],
                }, None

            def send(self, inner):
                self.calls.append((inner.get("_path", "/v1/control"), dict(inner)))
                if self.transport_lost:
                    return None, None, "transport", b""
                if inner.get("_path") == "/v1/result":
                    return 200, dict(self.result), None, b""
                return 200, dict(self.control), None, b""

        receipt = root / "operation.json"
        fake_secret = "receipt-secret-91"
        text_params = {"bundleIdentifier": "com.apple.Preferences",
                       "text": fake_secret,
                       "identifier": "floe.controlTest.textField"}
        summary = bc.normalized_parameter_summary("type_text", text_params)
        expect(summary.get("textUTF8Bytes") == len(fake_secret.encode("utf-8")),
               "receipt summary records text byte count")
        expect("text" not in summary and fake_secret not in json.dumps(summary),
               "receipt summary never contains raw text")
        inspect_summary = bc.normalized_parameter_summary(
            "inspect_ui", {"bundleIdentifier": "com.apple.Preferences"}
        )
        expect(inspect_summary.get("maxDepth") == 40 and
               inspect_summary.get("maxNodes") == 400 and
               inspect_summary.get("maxTotalBytes") == 65536,
               "receipt summary normalizes inspect defaults")

        # A sealed, ready transport is distinct from the engine action result.
        # An unverified text action must not be presented as successful typing.
        unverified_opened = {
            "state": "ready",
            "result": {
                "status": "unverified",
                "action": "type_text",
                "details": {"textDispatched": "false", "focusVerified": "false"},
            },
            "currentPid": 1,
            "currentGeneration": 1,
        }
        unverified_stdout = io.StringIO()
        with contextlib.redirect_stdout(unverified_stdout):
            unverified_code = bc.print_result(
                unverified_opened, action="type_text", command_id="ctl-unverified"
            )
        unverified_payload = json.loads(unverified_stdout.getvalue().strip())
        expect(unverified_code == 1, "unverified action exits nonzero")
        expect(unverified_payload.get("ok") is False,
               "unverified action is not ok")
        expect(unverified_payload.get("transportOk") is True,
               "transport completion is still reported")
        expect(unverified_payload.get("actionStatus") == "unverified",
               "nested action status is exposed")
        expect(unverified_payload.get("actionOk") is False,
               "nested action is not success")
        expect(unverified_payload.get("result", {}).get("details", {}).get(
            "textDispatched") == "false",
               "unverified text result retains textDispatched=false")
        success_opened = {
            "state": "ready",
            "result": {"status": "ok", "action": "type_text",
                       "details": {"textDispatched": "true"}},
            "currentPid": 1,
            "currentGeneration": 1,
        }
        success_stdout = io.StringIO()
        with contextlib.redirect_stdout(success_stdout):
            success_code = bc.print_result(
                success_opened, action="type_text", command_id="ctl-success"
            )
        success_payload = json.loads(success_stdout.getvalue().strip())
        expect(success_code == 0, "successful action exits zero")
        expect(success_payload.get("ok") is True,
               "successful action is ok")
        expect(success_payload.get("transportOk") is True,
               "successful transport is reported")
        expect(success_payload.get("actionStatus") == "ok",
               "successful action status is exposed")
        expect(success_payload.get("actionOk") is True,
               "successful nested action is success")

        lost_client = FakeClient(transport_lost=True)
        lost_stdout = io.StringIO()
        with contextlib.redirect_stdout(lost_stdout):
            lost_opened, lost_failure = bc.submit(
                lost_client, "type_text", "engine",
                read_only_retry=False, parameters=text_params,
                receipt_path=receipt, mutating=True
            )
        lost_payload = json.loads(lost_stdout.getvalue().strip().splitlines()[-1])
        lost_record = bc.read_receipt(receipt)
        expect(lost_opened is None and lost_failure == 3,
               "transport-lost mutation reports unknown")
        expect(lost_record["state"] == "outcome_unknown",
               "transport-lost receipt survives as outcome_unknown")
        expect(lost_record["id"] == lost_payload["id"],
               "transport-lost receipt keeps the printed operation id")
        expect(len(lost_client.calls) == 1 and
               lost_client.calls[0][0] == "/v1/control",
               "transport-lost mutation is transmitted once and never retried")
        expect(fake_secret not in json.dumps(lost_record) and
               fake_secret not in lost_stdout.getvalue(),
               "transport-lost receipt and output contain no text")
        expect(stat.S_IMODE(receipt.stat().st_mode) == 0o600,
               "operation receipt is owner-only")

        timeout_receipt = root / "timeout-operation.json"
        timeout_client = FakeClient()
        timeout_stdout = io.StringIO()
        with contextlib.redirect_stdout(timeout_stdout):
            timeout_code = bc.run_action(
                timeout_client, "type_text", "engine",
                result_timeout=0.05, screenshot_out=None,
                receipt_path=timeout_receipt, parameters=text_params
            )
        timeout_payload = json.loads(timeout_stdout.getvalue().strip().splitlines()[-1])
        timeout_record = bc.read_receipt(timeout_receipt)
        control_calls = [call for call in timeout_client.calls
                         if call[0] == "/v1/control"]
        result_calls = [call for call in timeout_client.calls
                        if call[0] == "/v1/result"]
        expect(timeout_code == 4, "accepted-but-result-timeout is bounded")
        expect(timeout_record["state"] == "result_timeout",
               "accepted-but-result-timeout receipt is retained")
        expect(timeout_record["id"] == timeout_payload["id"],
               "timeout receipt keeps the printed operation id")
        expect(len(control_calls) == 1,
               "timeout path transmits the mutation exactly once")
        expect(len(result_calls) >= 1 and
               result_calls[0][1]["id"] == timeout_record["id"],
               "timeout path reconciles the exact operation id")
        expect(fake_secret not in json.dumps(timeout_record) and
               fake_secret not in timeout_stdout.getvalue(),
               "timeout receipt and output contain no text")

        # A second mutation must not erase an unresolved receipt or dispatch
        # before the refusal. A completed operation may be reused; an explicit
        # distinct --receipt-file is the allowed escape hatch.
        blocked_client = FakeClient()
        blocked_stdout = io.StringIO()
        with contextlib.redirect_stdout(blocked_stdout):
            blocked_code = bc.run_action(
                blocked_client, "tap", "engine",
                result_timeout=0.05, screenshot_out=None,
                receipt_path=timeout_receipt,
                parameters={"bundleIdentifier": "com.apple.Preferences",
                            "identifier": "floe.controlTest.counterButton"}
            )
        blocked_payload = json.loads(
            blocked_stdout.getvalue().strip().splitlines()[-1]
        )
        unchanged_record = bc.read_receipt(timeout_receipt)
        expect(blocked_code == 5 and
               blocked_payload["state"] == "receipt_unavailable",
               "second mutation refuses an unresolved operation receipt")
        expect(unchanged_record["id"] == timeout_record["id"] and
               unchanged_record["state"] == "result_timeout",
               "second mutation cannot overwrite the unresolved operation identity")
        expect(blocked_client.calls == [],
               "second mutation dispatches nothing before the receipt refusal")

        distinct_receipt = root / "distinct-operation.json"
        distinct_client = FakeClient()
        distinct_stdout = io.StringIO()
        with contextlib.redirect_stdout(distinct_stdout):
            distinct_code = bc.run_action(
                distinct_client, "tap", "engine",
                result_timeout=0.05, screenshot_out=None,
                receipt_path=distinct_receipt,
                parameters={"bundleIdentifier": "com.apple.Preferences",
                            "identifier": "floe.controlTest.counterButton"}
            )
        distinct_record = bc.read_receipt(distinct_receipt)
        distinct_control_calls = [call for call in distinct_client.calls
                                  if call[0] == "/v1/control"]
        expect(distinct_code == 4 and len(distinct_control_calls) == 1,
               "an explicit distinct receipt path allows a second mutation")
        expect(distinct_record["id"] != timeout_record["id"],
               "distinct receipt path keeps a separate operation identity")

        # A different current session refuses reconciliation before any result
        # fetch and therefore cannot dispatch or leak a stale operation.
        other_session = "b" * 32
        reconcile_receipt = root / "reconcile-operation.json"
        bc.create_operation_receipt(
            reconcile_receipt,
            operation_id="ctl-reconcile-session",
            action="type_text",
            lane="engine",
            pid=4242,
            generation=7,
            session="a" * 32,
            parameters=text_params,
        )
        different_client = FakeClient(session=other_session)
        different_stdout = io.StringIO()
        with contextlib.redirect_stdout(different_stdout):
            different_code = bc.reconcile(different_client, reconcile_receipt, None)
        different_payload = json.loads(
            different_stdout.getvalue().strip().splitlines()[-1]
        )
        expect(different_code == 2 and
               different_payload["state"] == "session_mismatch",
               "reconciliation refuses a different current session")
        expect(different_client.calls == [],
               "different-session reconciliation performs no result fetch or dispatch")

        same_client = FakeClient()
        same_stdout = io.StringIO()
        with contextlib.redirect_stdout(same_stdout):
            same_code = bc.reconcile(same_client, reconcile_receipt, None)
        same_payload = json.loads(same_stdout.getvalue().strip().splitlines()[-1])
        expect(same_code == 4 and same_payload["state"] == "pending",
               "same-session reconciliation fetches the exact pending operation")
        expect(len(same_client.calls) == 1 and
               same_client.calls[0][0] == "/v1/result" and
               same_client.calls[0][1]["id"] == "ctl-reconcile-session",
               "reconciliation is read-only and uses the receipt id")
        expect(fake_secret not in same_stdout.getvalue(),
               "reconciliation output contains no text")

        ready_client = FakeClient(result={
            "ok": True,
            "state": "ready",
            "currentPid": 4242,
            "currentGeneration": 7,
            "result": {
                "status": "ok",
                "action": "type_text",
                "processIdentifier": 4242,
                "generation": 7,
                "processedAt": "2026-11-01T00:00:00.000Z",
                "details": {"textDispatched": "true", "characters": "3"},
            },
        })
        ready_stdout = io.StringIO()
        with contextlib.redirect_stdout(ready_stdout):
            ready_code = bc.reconcile(ready_client, reconcile_receipt, None)
        ready_payload = json.loads(ready_stdout.getvalue().strip().splitlines()[-1])
        expect(ready_code == 0 and ready_payload["id"] == "ctl-reconcile-session",
               "reconciliation returns the exact ready operation")
        expect(fake_secret not in ready_stdout.getvalue(),
               "ready reconciliation output contains no text")

        # A receipt that contains raw text is refused rather than read.
        bad_receipt = root / "bad-operation.json"
        write_private(bad_receipt, (json.dumps({
            "schema": 1, "id": "ctl-bad", "action": "type_text", "lane": "engine",
            "pid": 4242, "generation": 7, "session": "a" * 32, "state": "sending",
            "parameters": {"text": fake_secret},
        }) + "\n").encode("utf-8"))
        expect_raises(lambda: bc.read_receipt(bad_receipt),
                      "receipt reader refuses raw text parameters")

        # Real encrypted round trip through the Swift NWListener. The serve
        # mode's synthetic driver accepts typed requests and returns a status
        # result; the transport/auth/argument path is the real one.
        port = free_port()
        key = os.urandom(32)
        key_path = root / "controller-key.json"
        os.chmod(root, 0o700)
        write_private(key_path, (json.dumps({
            "key_hex": key.hex(),
            "tok": bc.key_id(key),
            "pid": 4242,
            "generation": 7,
            "session": "",
            "host": "127.0.0.1",
            "port": port,
        }, indent=2, sort_keys=True) + "\n").encode("utf-8"))
        secret = "floe-e2e-secret-73"
        secret_path = root / "secret"
        write_private(secret_path, secret.encode("utf-8"))

        environment = dict(os.environ)
        environment.update({
            "FLOE_LAN_CONTROL_SERVE": "1",
            "FLOE_LAN_CONTROL_KEY_HEX": key.hex(),
            "FLOE_LAN_CONTROL_PORT": str(port),
            "FLOE_LAN_CONTROL_SECONDS": "40",
        })
        server = subprocess.Popen(
            [args.server],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=environment,
        )
        server_log: list[str] = []
        outputs: list[str] = []
        ready_event = threading.Event()

        def read_server_output() -> None:
            assert server.stdout is not None
            for line in server.stdout:
                server_log.append(line)
                if "READY" in line:
                    ready_event.set()

        reader = threading.Thread(target=read_server_output, daemon=True)
        reader.start()
        try:
            ready = ready_event.wait(8)
            expect(ready, "Swift serve mode is ready for the controller")

            def run_cli(arguments: list[str]) -> tuple[int, str, str, dict[str, object] | None]:
                command = [
                    sys.executable, args.controller,
                    "--key-file", str(key_path),
                    "--host", "127.0.0.1",
                    "--port", str(port),
                    "--timeout", "5",
                    *arguments,
                ]
                completed = subprocess.run(
                    command, capture_output=True, text=True, timeout=20
                )
                payload = None
                if completed.stdout.strip():
                    try:
                        payload = json.loads(completed.stdout.strip().splitlines()[-1])
                    except json.JSONDecodeError:
                        payload = None
                return completed.returncode, completed.stdout, completed.stderr, payload

            if ready:
                cases = [
                    (["status", "--lane", "engine"], "status"),
                    (["activate", "--bundle-id", "com.apple.Preferences"], "activate_app"),
                    (["inspect", "--bundle-id", "com.apple.Preferences", "--max-nodes", "50"],
                     "inspect_ui"),
                    (["tap", "--bundle-id", "com.apple.Preferences",
                      "--identifier", "floe.controlTest.counterButton"], "tap"),
                    (["swipe", "--bundle-id", "com.apple.Preferences",
                      "--start-x", "0.5", "--start-y", "0.8",
                      "--end-x", "0.5", "--end-y", "0.2", "--duration-ms", "250"], "swipe"),
                    (["type-text", "--bundle-id", "com.apple.Preferences",
                      "--text-file", str(secret_path),
                      "--identifier", "floe.controlTest.textField"], "type_text"),
                    (["type-text", "--bundle-id", "com.apple.Preferences",
                      "--text-file", str(secret_path),
                      "--label", "搜索"], "type_text"),
                ]
                for arguments, action in cases:
                    code, stdout, stderr, payload = run_cli(arguments)
                    outputs.append(stdout)
                    outputs.append(stderr)
                    expect(code == 0, f"controller {action} exits 0", f"code={code}")
                    expect(isinstance(payload, dict) and payload.get("action") == action,
                           f"controller {action} reports its action")
                expect(all(secret not in output for output in outputs),
                       "controller text is not in CLI output")
            else:
                expect(False, "controller round trip skipped without a ready server")

            if server.poll() is None:
                server.terminate()
                try:
                    remainder, _ = server.communicate(timeout=5)
                    server_log.append(remainder or "")
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.communicate(timeout=5)
        finally:
            if server.poll() is None:
                server.kill()
                server.communicate(timeout=5)
            combined_log = "".join(server_log)
            expect(secret not in combined_log, "controller text is not in the server log")
            key_file_text = key_path.read_text(encoding="utf-8")
            expect(secret not in key_file_text, "controller text is not retained in the key file")

    print(f"CONTROLLER {'PASS' if failures == 0 else 'FAIL'} checks={checks} failures={failures}")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
