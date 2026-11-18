#!/usr/bin/env python3
"""Floe Mac M00 — host-death / active-task lifecycle probe (test fixture only).

This script starts the embedded Bridge helper under a disposable parent
process, starts a real PTY task through the signed RPC, kills the parent and
verifies:
  - the helper survives while the task is active;
  - the task reaches a persisted result without the UI/host;
  - the helper exits after the task and the orphan grace expires;
  - a parent death with no active work does not leave an orphan.

It never reads or writes the real Floe Bridge data or Keychain. It requires
the explicit test-fixture mode of the helper and refuses a busy port.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
    from cryptography.hazmat.primitives import serialization
except Exception as exc:  # pragma: no cover - qualification host guard
    print(json.dumps({"passed": False, "error": f"cryptography unavailable: {exc}"}))
    sys.exit(2)

PORT = 43871


def port_free() -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", PORT))
        return True
    except OSError:
        return False
    finally:
        sock.close()


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def canonical_json(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def run_helper_wrapper(helper: Path, fixture: Path, client_pub: bytes, log_path: Path) -> subprocess.Popen:
    wrapper = f"""
import json, os, subprocess, sys, time
helper, fixture, pub, log = sys.argv[1:5]
home = os.path.join(fixture, "worker-home")
env = dict(os.environ)
env["HOME"] = home
env["CFFIXED_USER_HOME"] = home
logf = open(log, "wb")
control = os.path.join(fixture, "Control")
p = subprocess.Popen([
    helper,
    "--mode", "test",
    "--test-fixture", fixture,
    "--control-socket", os.path.join(control, "b.sock"),
    "--ready-file", os.path.join(control, "ready.json"),
    "--discovery-file", os.path.join(control, "discovery.json"),
    "--parent-pid", str(os.getpid()),
    "--probe-client-key", pub,
    "--orphan-idle-grace", "2",
], env=env, stdout=logf, stderr=subprocess.STDOUT, close_fds=True)
with open(os.path.join(control, "wrapper.json"), "w") as handle:
    json.dump({{"wrapperPID": os.getpid(), "helperPID": p.pid}}, handle)
while True:
    time.sleep(0.5)
"""
    process = subprocess.Popen(
        [sys.executable, "-c", wrapper, str(helper), str(fixture), b64(client_pub), str(log_path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return process


def wait_for(path: Path, timeout: float, predicate=None) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            if predicate is None:
                return True
            try:
                if predicate(json.loads(path.read_text())):
                    return True
            except Exception:
                pass
        time.sleep(0.1)
    return False


def make_request(private_key: Ed25519PrivateKey, method: str, payload: dict) -> tuple[dict, dict]:
    body = {
        "clientKey": b64(private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )),
        "id": str(uuid.uuid4()).upper(),
        "issuedAt": int(time.time() * 1000),
        "method": method,
        "payload": payload,
        "version": 1,
    }
    signature = private_key.sign(canonical_json(body))
    return body, {"body": body, "signature": b64(signature)}


def rpc(private_key: Ed25519PrivateKey, pinned: bytes, method: str, payload: dict) -> dict:
    body, request = make_request(private_key, method, payload)
    encoded = json.dumps(request, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=8)
    connection.request("POST", "/rpc", body=encoded, headers={
        "Content-Type": "application/json",
        "Host": f"127.0.0.1:{PORT}",
    })
    response = connection.getresponse()
    data = response.read()
    connection.close()
    if response.status != 200:
        raise RuntimeError(f"HTTP {response.status}")
    decoded = json.loads(data)
    server_key = base64.b64decode(decoded["body"]["serverKey"])
    if server_key != pinned:
        raise RuntimeError("response key did not match the pinned helper identity")
    signature = base64.b64decode(decoded["signature"])
    Ed25519PublicKey.from_public_bytes(pinned).verify(signature, canonical_json(decoded["body"]))
    if decoded["body"].get("error"):
        raise RuntimeError(decoded["body"]["error"])
    return decoded["body"]["result"]


def poll_until_done(private_key: Ed25519PrivateKey, pinned: bytes, job_id: str, timeout: float = 20) -> tuple[bool, str, bool]:
    offset = 0
    output = ""
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = rpc(private_key, pinned, "poll", {"jobID": job_id, "offset": offset, "limit": 65536})
        output += base64.b64decode(result.get("data", "")).decode("utf-8", "replace")
        offset = int(result.get("offset", offset))
        if not result.get("alive", False):
            return True, output, True
        time.sleep(0.1)
    return False, output, False


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_dead(pid: int, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            return True
        time.sleep(0.1)
    return False


def prepare_fixture(root: Path, name: str) -> tuple[Path, bytes, Ed25519PrivateKey]:
    fixture = Path(os.path.realpath(root / name))
    for child in ["Control", "service-home", "worker-home"]:
        path = fixture / child
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o700)
    key = Ed25519PrivateKey.generate()
    public = key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    return fixture, public, key


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()
    helper = Path(args.helper)
    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    if not port_free():
        print(json.dumps({"schema": "floe-mac-m00-orphan-probe-v1", "passed": False,
                          "blockedByExistingListener": True}, sort_keys=True))
        return 3

    summary = {"schema": "floe-mac-m00-orphan-probe-v1"}
    cleanup: list[subprocess.Popen] = []
    try:
        # 1. Active task survives host death, completes and is persisted.
        fixture, public, key = prepare_fixture(root, "active")
        wrapper = run_helper_wrapper(helper, fixture, public, root / "active-helper.log")
        cleanup.append(wrapper)
        ready = fixture / "Control" / "ready.json"
        if not wait_for(ready, 12, lambda value: value.get("state") == "ready"):
            raise RuntimeError("helper did not become ready")
        wrapper_info = json.loads((fixture / "Control" / "wrapper.json").read_text())
        helper_pid = int(wrapper_info["helperPID"])
        identity = json.loads((fixture / "service-identity.json").read_text())
        pinned = base64.b64decode(identity["publicKey"])
        job_id = str(uuid.uuid4()).upper()
        rpc(key, pinned, "start", {
            "workspaceID": "orphanworkspace",
            "jobID": job_id,
            "command": "printf 'started\\n'; sleep 4; printf 'done\\n'",
        })
        active_before = helper_pid and process_alive(helper_pid)
        os.kill(wrapper.pid, signal.SIGKILL)
        wrapper.wait(timeout=5)
        time.sleep(0.8)
        survived_parent = process_alive(helper_pid)
        completed, output, saw_exit = poll_until_done(key, pinned, job_id, timeout=20)
        task_dir = fixture / "service-home" / "Library/Application Support/Floe Bridge/Tasks" / job_id
        result_present = (task_dir / "result.json").exists()
        owner_present = (task_dir / "owner.json").exists()
        orphan_marker = fixture / "Control" / "orphaned.json"
        helper_exited = wait_dead(helper_pid, timeout=10)
        task_preserved = task_dir.exists() and owner_present

        # 2. No active work: a missing host must not leave a long-lived orphan.
        fixture2, public2, _ = prepare_fixture(root, "idle")
        wrapper2 = run_helper_wrapper(helper, fixture2, public2, root / "idle-helper.log")
        cleanup.append(wrapper2)
        ready2 = fixture2 / "Control" / "ready.json"
        if not wait_for(ready2, 12, lambda value: value.get("state") == "ready"):
            raise RuntimeError("idle helper did not become ready")
        info2 = json.loads((fixture2 / "Control" / "wrapper.json").read_text())
        helper_pid2 = int(info2["helperPID"])
        os.kill(wrapper2.pid, signal.SIGKILL)
        wrapper2.wait(timeout=5)
        idle_exited = wait_dead(helper_pid2, timeout=8)

        passed = (
            active_before and survived_parent and completed and saw_exit
            and output.find("started") >= 0 and output.find("done") >= 0
            and result_present and owner_present and task_preserved
            and helper_exited and idle_exited and orphan_marker.exists()
        )
        summary.update({
            "passed": passed,
            "helperPID": helper_pid,
            "activeBeforeParentDeath": active_before,
            "survivedParentDeath": survived_parent,
            "taskCompletedAfterParentDeath": completed,
            "taskOutput": output,
            "resultRecordPresent": result_present,
            "ownerRecordPresent": owner_present,
            "taskDirectoryPreserved": task_preserved,
            "orphanMarkerPresent": orphan_marker.exists(),
            "helperExitedAfterIdleGrace": helper_exited,
            "idleHelperExitedAfterParentDeath": idle_exited,
        })
        return 0 if passed else 1
    except Exception as exc:
        summary.update({"passed": False, "error": str(exc)})
        return 1
    finally:
        for process in cleanup:
            if process.poll() is None:
                process.kill()
        print(json.dumps(summary, sort_keys=True, indent=2))
        # Leave the fixture logs for the verification evidence directory.
        # The caller owns the parent sandbox and removes it on cleanup.


if __name__ == "__main__":
    sys.exit(main())
