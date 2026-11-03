#!/usr/bin/env python3
"""Reference controller for the Floe Bridge prototype LAN control endpoint.

Protocol compatibility: pinned OpenMinis/iCTRL v1 envelope (HMAC-SHA256
direction-separated keys, PRF-CTR keystream, tok/ts/nonce/ct/tag). The
controller key is a separate 32-byte credential provisioned through the
authenticated local setup file; it is never the read-only diagnostics bearer.

The script reads the key from a 0600 JSON file and never prints it. Every
mutating command writes a bounded 0600 operation receipt before transmission
(id/action/lane/pid/generation/session plus a non-secret parameter summary; text
is stored only as a byte count). A lost reply is outcome_unknown, not a retry.
Use `reconcile` to fetch the exact receipted operation through /v1/session and
/v1/result without dispatching: it refuses a different current session. An
unresolved receipt is retained rather than overwritten; use a distinct
--receipt-file for a new parallel operation.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import stat
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

LABEL_MAC = b"ictrl-v1|mac"
LABEL_ENC_REQ = b"ictrl-v1|enc-req"
LABEL_ENC_RESP = b"ictrl-v1|enc-resp"
TIMESTAMP_WINDOW = 120
HOST_ACTIONS = {"status", "start", "stop", "resume", "shutdown"}
PARAMETERIZED_ACTIONS = {"activate_app", "inspect_ui", "tap", "swipe", "type_text"}
ENGINE_ACTIONS = {"status", "screenshot", "open_settings", "tap_general", "home", "stop_engine"} | PARAMETERIZED_ACTIONS
RUN_ACTIONS = (HOST_ACTIONS | ENGINE_ACTIONS) - PARAMETERIZED_ACTIONS - {"shutdown"}
READ_ONLY_ACTIONS = {"status", "screenshot", "inspect_ui"}
RECEIPT_SCHEMA = 1
MAX_RECEIPT_BYTES = 8_192
RECEIPT_STATES = {
    "sending", "accepted", "refused_pre_dispatch", "result_timeout",
    "outcome_unknown", "result_ready", "result_rejected",
}
UNRESOLVED_RECEIPT_STATES = {
    "sending", "accepted", "result_timeout", "outcome_unknown",
}
# The sealed transport and the engine action are two different outcomes. The
# engine reports `ok` only for the action it actually completed; anything else
# (unverified, refused, error, ...) must not look like successful typing.
SUCCESSFUL_ACTION_STATUS = "ok"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def key_id(key: bytes) -> str:
    return hashlib.sha256(key).digest()[:4].hex()


def is_session(value: str) -> bool:
    return len(value) == 32 and value == value.lower() and all(
        byte in b"0123456789abcdef" for byte in value.encode("ascii", "ignore")
    ) and len(value.encode("ascii", "ignore")) == 32


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def keystream_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    output = bytearray()
    counter = 0
    while len(output) < len(data):
        output.extend(hmac_sha256(key, nonce + counter.to_bytes(4, "big")))
        counter += 1
    return bytes(a ^ b for a, b in zip(data, output[: len(data)]))


def seal_request(inner: dict[str, Any], key: bytes, nonce: bytes, timestamp: int) -> dict[str, Any]:
    plaintext = json.dumps(inner, separators=(",", ":"), sort_keys=True).encode("utf-8")
    token = hashlib.sha256(key).digest()[:4]
    k_mac = hmac_sha256(key, LABEL_MAC + nonce)
    k_enc = hmac_sha256(key, LABEL_ENC_REQ + nonce)
    ciphertext = keystream_xor(k_enc, nonce, plaintext)
    tag = hmac_sha256(
        k_mac,
        b"v1" + token + timestamp.to_bytes(8, "big") + nonce + ciphertext,
    )
    return {
        "v": 1,
        "tok": token.hex(),
        "ts": timestamp,
        "nonce": nonce.hex(),
        "ct": base64.b64encode(ciphertext).decode("ascii"),
        "tag": tag.hex(),
    }


def open_response(envelope: dict[str, Any], key: bytes, nonce_hex: str) -> dict[str, Any]:
    if envelope.get("v") != 1 or envelope.get("nonce") != nonce_hex:
        raise ValueError("response envelope identity")
    ciphertext = base64.b64decode(envelope.get("ct", ""), validate=True)
    tag = bytes.fromhex(envelope.get("tag", ""))
    nonce = bytes.fromhex(nonce_hex)
    k_mac = hmac_sha256(key, LABEL_MAC + nonce)
    expected = hmac_sha256(k_mac, b"resp" + nonce + ciphertext)
    if len(tag) != 32 or not hmac.compare_digest(tag, expected):
        raise ValueError("response tag")
    k_enc = hmac_sha256(key, LABEL_ENC_RESP + nonce)
    plaintext = keystream_xor(k_enc, nonce, ciphertext)
    value = json.loads(plaintext.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("response body")
    return value


def decode_canonical(value: str, *, label: str) -> bytes:
    if len(value) != 43:
        raise ValueError(f"{label} must be 43 base64url characters")
    if any(byte not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
           for byte in value.encode("ascii")):
        raise ValueError(f"{label} contains a non-canonical character")
    padded = value.replace("-", "+").replace("_", "/")
    padded += "=" * ((4 - len(padded) % 4) % 4)
    data = base64.b64decode(padded, validate=True)
    if len(data) != 32 or b64url(data) != value:
        raise ValueError(f"{label} must decode to 32 canonical bytes")
    return data


def check_private(path: Path, *, label: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SystemExit(f"{label} must not be group/other accessible (expected 0600)")


def private_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, data)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def default_receipt_path(key_path: Path) -> Path:
    return Path(str(key_path) + ".operation.json")


def iso_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def normalized_parameter_summary(action: str,
                                 parameters: dict[str, Any] | None) -> dict[str, Any]:
    """Bounded, non-secret receipt summary; raw text is replaced by its size."""
    if not parameters:
        return {}
    fields = (
        "bundleIdentifier", "identifier", "label", "placeholder",
        "normalizedX", "normalizedY",
        "startNormalizedX", "startNormalizedY", "endNormalizedX",
        "endNormalizedY", "durationMilliseconds", "maxDepth", "maxNodes",
        "maxStringBytes", "maxTotalBytes",
    )
    summary: dict[str, Any] = {}
    for field in fields:
        value = parameters.get(field)
        if isinstance(value, (str, int, float, bool)):
            summary[field] = value
    text = parameters.get("text")
    if isinstance(text, str):
        summary["textUTF8Bytes"] = len(text.encode("utf-8"))
    bundle = summary.get("bundleIdentifier")
    if isinstance(bundle, str):
        summary["bundleIdentifier"] = bundle.strip()
    if action == "inspect_ui":
        summary.setdefault("maxDepth", 40)
        summary.setdefault("maxNodes", 400)
        summary.setdefault("maxStringBytes", 512)
        summary.setdefault("maxTotalBytes", 65_536)
    if action == "swipe":
        summary.setdefault("durationMilliseconds", 300)
    encoded = json.dumps(summary, sort_keys=True, separators=(",", ":"))
    if len(encoded.encode("utf-8")) > 4_096:
        raise SystemExit("normalized operation parameters are too large")
    return summary


def write_receipt(path: Path, record: dict[str, Any]) -> None:
    data = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(data) > MAX_RECEIPT_BYTES:
        raise SystemExit("operation receipt is too large")
    private_write(path, data)


def read_receipt(path: Path, *, required: bool = True) -> dict[str, Any] | None:
    if not path.is_file():
        if required:
            raise SystemExit("no operation receipt exists")
        return None
    check_private(path, label="operation receipt")
    data = path.read_bytes()
    if len(data) > MAX_RECEIPT_BYTES:
        raise SystemExit("operation receipt is too large")
    try:
        record = json.loads(data.decode("utf-8"))
    except Exception:
        raise SystemExit("operation receipt is malformed")
    if not isinstance(record, dict) or record.get("schema") != RECEIPT_SCHEMA:
        raise SystemExit("operation receipt schema is invalid")
    for field in ("id", "action", "lane", "pid", "generation", "session", "state"):
        if field not in record:
            raise SystemExit(f"operation receipt is missing {field}")
    if not isinstance(record["id"], str) or not (1 <= len(record["id"]) <= 64):
        raise SystemExit("operation receipt has an invalid id")
    if record["lane"] not in {"host", "engine"}:
        raise SystemExit("operation receipt has an invalid lane")
    if not isinstance(record["pid"], int) or record["pid"] <= 0:
        raise SystemExit("operation receipt has an invalid pid")
    if not isinstance(record["generation"], int) or record["generation"] < 0:
        raise SystemExit("operation receipt has an invalid generation")
    if not isinstance(record["session"], str) or not is_session(record["session"]):
        raise SystemExit("operation receipt has an invalid session")
    if record["state"] not in RECEIPT_STATES:
        raise SystemExit("operation receipt has an invalid state")
    parameters = record.get("parameters", {})
    if not isinstance(parameters, dict) or "text" in parameters:
        raise SystemExit("operation receipt parameters are invalid")
    return record


def create_operation_receipt(path: Path,
                             *,
                             operation_id: str,
                             action: str,
                             lane: str,
                             pid: int,
                             generation: int,
                             session: str,
                             parameters: dict[str, Any] | None) -> dict[str, Any]:
    existing = read_receipt(path, required=False)
    if existing is not None and existing["state"] in UNRESOLVED_RECEIPT_STATES:
        raise SystemExit(
            f"unresolved operation {existing['id']} ({existing['state']}) "
            f"is retained in {path}; reconcile it first or pass a distinct "
            f"--receipt-file for the new operation"
        )
    now = iso_timestamp()
    record = {
        "schema": RECEIPT_SCHEMA,
        "id": operation_id,
        "action": action,
        "lane": lane,
        "pid": pid,
        "generation": generation,
        "session": session,
        "parameters": normalized_parameter_summary(action, parameters),
        "state": "sending",
        "createdAt": now,
        "updatedAt": now,
    }
    write_receipt(path, record)
    return record


def update_receipt(path: Path,
                   operation_id: str,
                   state: str,
                   **extra: Any) -> None:
    if state not in RECEIPT_STATES:
        return
    record = read_receipt(path, required=False)
    if not record or record.get("id") != operation_id:
        return
    record["state"] = state
    record["updatedAt"] = iso_timestamp()
    record.update(extra)
    write_receipt(path, record)


def load_state(path: Path) -> dict[str, Any]:
    check_private(path, label="controller key file")
    record = json.loads(path.read_text(encoding="utf-8"))
    key_hex = record.get("key_hex")
    if not isinstance(key_hex, str) or len(key_hex) != 64:
        raise SystemExit("controller key file has no canonical key_hex")
    key = bytes.fromhex(key_hex)
    expected = key_id(key)
    if record.get("tok") != expected:
        raise SystemExit("controller key file tok does not match the key")
    if not isinstance(record.get("pid"), int) or record["pid"] <= 0:
        raise SystemExit("controller key file has no valid pid")
    if not isinstance(record.get("generation"), int) or record["generation"] < 0:
        raise SystemExit("controller key file has no valid generation")
    session = record.get("session", "")
    if session and (not isinstance(session, str) or not is_session(session)):
        raise SystemExit("controller key file has an invalid session")
    record["session"] = session
    record["_key"] = key
    return record


def save_state(path: Path, record: dict[str, Any]) -> None:
    record = {k: v for k, v in record.items() if not k.startswith("_")}
    private_write(path, (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8"))


def endpoint(host: str, port: int, path: str) -> str:
    literal = f"[{host}]" if ":" in host else host
    return f"http://{literal}:{port}{path}"


def post(host: str, port: int, path: str, body: bytes, timeout: float) -> tuple[int | None, bytes]:
    url = endpoint(host, port, path)
    host_header = f"[{host}]" if ":" in host else host
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Connection": "close",
            "Host": f"{host_header}:{port}",
        },
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except Exception as error:  # transport/DNS/timeout/connection close
        return None, str(error).encode("utf-8")


def read_private_text(path_value: str) -> str:
    """Read a 0600 UTF-8 text file without putting its content in argv or logs."""
    path = Path(path_value).expanduser()
    if not path.is_file():
        raise SystemExit("text file is not a regular file")
    check_private(path, label="text file")
    data = path.read_bytes()
    if not (1 <= len(data) <= 4096):
        raise SystemExit("text file must contain 1...4096 UTF-8 bytes")
    if b"\x00" in data:
        raise SystemExit("text file must not contain NUL")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise SystemExit("text file must be valid UTF-8")


def unit_coordinate(value: float, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise SystemExit(f"{label} must be a number")
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")) or not (0.0 <= number <= 1.0):
        raise SystemExit(f"{label} must be a finite value between 0 and 1")
    return number


def build_parameters(action: str, args: argparse.Namespace) -> dict[str, Any]:
    """Build the closed typed-parameter object for one generic action."""
    params: dict[str, Any] = {"bundleIdentifier": args.bundle_id}
    if action == "activate_app":
        return params
    if action == "inspect_ui":
        for attribute, wire in (
            ("max_depth", "maxDepth"),
            ("max_nodes", "maxNodes"),
            ("max_string_bytes", "maxStringBytes"),
            ("max_total_bytes", "maxTotalBytes"),
        ):
            value = getattr(args, attribute, None)
            if value is not None:
                params[wire] = value
        return params
    if action == "tap":
        if args.identifier is not None:
            if args.x is not None or args.y is not None:
                raise SystemExit("tap accepts either --identifier or --x/--y, not both")
            if not args.identifier:
                raise SystemExit("--identifier must not be empty")
            params["identifier"] = args.identifier
            return params
        if args.x is None or args.y is None:
            raise SystemExit("tap requires --identifier or both --x and --y")
        params["normalizedX"] = unit_coordinate(args.x, "--x")
        params["normalizedY"] = unit_coordinate(args.y, "--y")
        return params
    if action == "swipe":
        params["startNormalizedX"] = unit_coordinate(args.start_x, "--start-x")
        params["startNormalizedY"] = unit_coordinate(args.start_y, "--start-y")
        params["endNormalizedX"] = unit_coordinate(args.end_x, "--end-x")
        params["endNormalizedY"] = unit_coordinate(args.end_y, "--end-y")
        if args.duration_ms is not None:
            if not (50 <= args.duration_ms <= 2000):
                raise SystemExit("--duration-ms must be between 50 and 2000")
            params["durationMilliseconds"] = args.duration_ms
        if (params["startNormalizedX"], params["startNormalizedY"]) == (
            params["endNormalizedX"], params["endNormalizedY"]
        ):
            raise SystemExit("swipe start and end must differ")
        return params
    if action == "type_text":
        # Selector shape is validated before the private text file is read, so
        # an invalid/ambiguous target never even loads local text.
        if (args.x is None) != (args.y is None):
            raise SystemExit("type-text coordinates require both --x and --y")
        named = sum(1 for value in (args.identifier, args.label, args.placeholder)
                    if value is not None)
        point = 1 if args.x is not None else 0
        if named + point > 1:
            raise SystemExit(
                "type-text accepts at most one field selector: "
                "--identifier, --label, --placeholder or --x/--y"
            )
        if args.identifier is not None:
            if not args.identifier:
                raise SystemExit("--identifier must not be empty")
            params["identifier"] = args.identifier
        elif args.label is not None:
            if not args.label:
                raise SystemExit("--label must not be empty")
            params["label"] = args.label
        elif args.placeholder is not None:
            if not args.placeholder:
                raise SystemExit("--placeholder must not be empty")
            params["placeholder"] = args.placeholder
        elif args.x is not None and args.y is not None:
            params["normalizedX"] = unit_coordinate(args.x, "--x")
            params["normalizedY"] = unit_coordinate(args.y, "--y")
        params["text"] = read_private_text(args.text_file)
        return params
    raise SystemExit("action does not accept typed parameters")


class Client:
    def __init__(self, state: dict[str, Any], path: Path, host: str, port: int, timeout: float):
        self.state = state
        self.path = path
        self.host = host
        self.port = port
        self.timeout = timeout
        self.key: bytes = state["_key"]

    def update_state(self, *, pid: int | None = None, generation: int | None = None,
                     session: str | None = None) -> None:
        if pid is not None and pid > 0:
            self.state["pid"] = pid
        if generation is not None and generation >= 0:
            self.state["generation"] = generation
        if session is not None:
            if not is_session(session):
                raise ValueError("invalid control session")
            self.state["session"] = session
        self.state["host"] = self.host
        self.state["port"] = self.port
        save_state(self.path, self.state)

    def discover(self) -> tuple[dict[str, Any] | None, int | None]:
        """Authenticated no-side-effect session/PID/generation discovery."""
        status, opened, failure, _ = self.send({
            "v": 1,
            "kind": "session",
            "_path": "/v1/session",
        })
        if status is None:
            print(json.dumps({
                "ok": False,
                "state": "outcome_unknown",
                "error": "The connection ended during session discovery.",
            }, sort_keys=True))
            return None, 3
        if opened is None or not opened.get("ok") or opened.get("state") != "session":
            print(json.dumps({
                "ok": False,
                "state": "rejected",
                "httpStatus": status,
                "error": (opened or {}).get("error", failure or "session discovery failed"),
            }, sort_keys=True))
            return None, 1
        session = opened.get("sessionId")
        pid = opened.get("currentPid")
        generation = opened.get("currentGeneration")
        if not isinstance(session, str) or not is_session(session) or \
           not isinstance(pid, int) or not isinstance(generation, int):
            print(json.dumps({
                "ok": False,
                "state": "rejected",
                "error": "Session discovery returned invalid metadata.",
            }, sort_keys=True))
            return None, 1
        self.update_state(pid=pid, generation=generation, session=session)
        return opened, None

    def send(self, inner: dict[str, Any]) -> tuple[int | None, dict[str, Any] | None, str | None, bytes]:
        path = inner.get("_path", "/v1/control")
        payload = {key: value for key, value in inner.items() if not key.startswith("_")}
        nonce = secrets.token_bytes(16)
        nonce_hex = nonce.hex()
        envelope = seal_request(payload, self.key, nonce, int(time.time()))
        body = json.dumps(envelope, separators=(",", ":"), sort_keys=True).encode("utf-8")
        status, response_body = post(self.host, self.port, path, body, self.timeout)
        if status is None:
            return None, None, "transport", response_body
        if status != 200:
            try:
                plain = json.loads(response_body.decode("utf-8"))
                error = plain.get("error", {})
                return status, {"ok": False, "error": error}, None, response_body
            except Exception:
                return status, {"ok": False, "error": {"code": "http_error"}}, None, response_body
        try:
            envelope_response = json.loads(response_body.decode("utf-8"))
            opened = open_response(envelope_response, self.key, nonce_hex)
            return status, opened, None, response_body
        except Exception:
            return status, None, "bad_sealed_response", response_body


def response_generation(opened: dict[str, Any]) -> tuple[int | None, int | None]:
    current_pid = opened.get("currentPid")
    current_generation = opened.get("currentGeneration")
    result = opened.get("result") or {}
    resulting = result.get("resultingGeneration")
    pid = current_pid if isinstance(current_pid, int) else None
    generation = current_generation if isinstance(current_generation, int) else None
    if resulting is None:
        details = result.get("details") or {}
        value = details.get("resultingGeneration")
        if isinstance(value, str) and value.isdigit():
            resulting = int(value)
    # The live generation is authoritative for the next request. The
    # per-command resulting generation remains in the printed result.
    return pid, generation


def submit(client: Client,
           action: str,
           lane: str,
           *,
           read_only_retry: bool,
           parameters: dict[str, Any] | None = None,
           receipt_path: Path | None = None,
           mutating: bool = False) -> tuple[dict[str, Any] | None, int | None]:
    if not client.state.get("session"):
        _, failure = client.discover()
        if failure is not None:
            return None, failure
    command_id = f"ctl-{secrets.token_hex(8)}"
    if mutating:
        if receipt_path is None:
            print(json.dumps({
                "ok": False,
                "state": "receipt_unavailable",
                "error": "A mutating command requires an operation receipt path.",
            }, sort_keys=True))
            return None, 5
        try:
            create_operation_receipt(
                receipt_path,
                operation_id=command_id,
                action=action,
                lane=lane,
                pid=client.state["pid"],
                generation=client.state["generation"],
                session=client.state.get("session", ""),
                parameters=parameters,
            )
        except (SystemExit, OSError, ValueError) as error:
            print(json.dumps({
                "ok": False,
                "state": "receipt_unavailable",
                "error": str(error),
            }, sort_keys=True))
            return None, 5
    inner: dict[str, Any] = {
        "v": 1,
        "id": command_id,
        "lane": lane,
        "action": action,
        "pid": client.state["pid"],
        "generation": client.state["generation"],
        "session": client.state.get("session", ""),
        "_path": "/v1/control",
    }
    if parameters is not None:
        inner["params"] = parameters
    status, opened, failure, raw = client.send(inner)
    if status is None:
        if mutating and receipt_path is not None:
            update_receipt(receipt_path, command_id, "outcome_unknown",
                           lastError="transport-before-reply")
        if read_only_retry:
            return None, 3
        print(json.dumps({
            "ok": False,
            "state": "outcome_unknown",
            "id": command_id,
            "action": action,
            "error": "The connection ended before a sealed reply. Do not retry; observe device state or use reconcile.",
        }, sort_keys=True))
        return None, 3
    if opened is None:
        if mutating and receipt_path is not None:
            update_receipt(receipt_path, command_id, "outcome_unknown",
                           httpStatus=status,
                           lastError=failure or "unreadable sealed response")
        print(json.dumps({
            "ok": False,
            "state": "outcome_unknown" if status == 200 else "rejected",
            "id": command_id,
            "action": action,
            "httpStatus": status,
            "error": failure or "unreadable sealed response",
        }, sort_keys=True))
        return None, 3 if status == 200 else 1
    if not opened.get("ok"):
        error = opened.get("error") or {}
        code = error.get("code")
        if mutating and receipt_path is not None:
            update_receipt(receipt_path, command_id, "refused_pre_dispatch",
                           httpStatus=status, decision=code)
        # A stale generation/PID or session response is definitive: the server
        # rejected before dispatch. Refresh the authenticated session metadata
        # and allow the caller one explicit retry with a freshly receipted
        # operation. A transport failure is never retried.
        if code in {"stale_generation", "stale_pid", "session_mismatch"}:
            pid, generation = response_generation(opened)
            client.update_state(pid=pid, generation=generation)
            _, refresh_failure = client.discover()
            if refresh_failure is not None:
                return None, refresh_failure
            return None, 2
        print(json.dumps({
            "ok": False,
            "state": "rejected",
            "id": command_id,
            "action": action,
            "error": error,
            "currentPid": opened.get("currentPid"),
            "currentGeneration": opened.get("currentGeneration"),
        }, sort_keys=True))
        return None, 1
    pid, generation = response_generation(opened)
    client.update_state(pid=pid, generation=generation)
    if mutating and receipt_path is not None:
        update_receipt(receipt_path, command_id, "accepted",
                       duplicate=bool(opened.get("duplicate")),
                       parametersDigest=opened.get("parametersDigest"))
    opened["_id"] = command_id
    return opened, None


def fetch_result(client: Client,
                 command_id: str,
                 pid: int,
                 generation: int,
                 *,
                 deadline: float) -> tuple[dict[str, Any] | None, int | None]:
    inner = {
        "v": 1,
        "id": command_id,
        "pid": pid,
        "generation": generation,
        "session": client.state.get("session", ""),
        "_path": "/v1/result",
    }
    while True:
        status, opened, failure, _ = client.send(inner)
        if status is None:
            print(json.dumps({
                "ok": False,
                "state": "outcome_unknown",
                "id": command_id,
                "error": "The connection ended before a sealed result. Do not retry the action.",
            }, sort_keys=True))
            return None, 3
        if opened is None:
            print(json.dumps({
                "ok": False,
                "state": "outcome_unknown" if status == 200 else "rejected",
                "id": command_id,
                "httpStatus": status,
                "error": failure or "unreadable sealed result",
            }, sort_keys=True))
            return None, 3 if status == 200 else 1
        state = opened.get("state")
        pid_now, generation_now = response_generation(opened)
        client.update_state(pid=pid_now, generation=generation_now)
        if state in {"pending", "fenced"}:
            if time.time() >= deadline:
                print(json.dumps({
                    "ok": False,
                    "state": "outcome_unknown",
                    "id": command_id,
                    "lastState": state,
                    "error": "The bounded result wait expired. The command may still execute; do not retry.",
                }, sort_keys=True))
                return None, 4
            time.sleep(0.25)
            continue
        if state == "ready":
            opened["_id"] = command_id
            return opened, None
        print(json.dumps({
            "ok": False,
            "state": state or "unknown",
            "id": command_id,
            "response": opened,
        }, sort_keys=True))
        return opened, 4


def action_outcome(result: dict[str, Any] | None) -> tuple[bool, str | None]:
    """Separate a completed sealed transport from the engine's action outcome."""
    status = result.get("status") if isinstance(result, dict) else None
    return status == SUCCESSFUL_ACTION_STATUS, status if isinstance(status, str) else None


def print_result(opened: dict[str, Any], *, action: str, command_id: str) -> int:
    result = opened.get("result") or {}
    action_ok, action_status = action_outcome(result)
    output = {
        # `ok` is the end-to-end action result, not just a sealed reply. A
        # transport-ready `unverified` text action remains visible in
        # transportOk/state/actionStatus but is not presented as success.
        "ok": action_ok,
        "transportOk": True,
        "state": opened.get("state"),
        "id": command_id,
        "action": action,
        "actionStatus": action_status,
        "actionOk": action_ok,
        "result": result,
        "currentPid": opened.get("currentPid"),
        "currentGeneration": opened.get("currentGeneration"),
    }
    print(json.dumps(output, sort_keys=True))
    return 0 if action_ok else 1


def run_action(client: Client, action: str, lane: str,
               *, result_timeout: float, screenshot_out: str | None,
               receipt_path: Path,
               parameters: dict[str, Any] | None = None) -> int:
    # Authenticated, no-side-effect discovery gives the current PID,
    # generation and fresh per-arm session before any command is submitted.
    _, discovery_failure = client.discover()
    if discovery_failure is not None:
        return discovery_failure
    deadline = time.time() + result_timeout
    mutating = action not in READ_ONLY_ACTIONS

    if action == "shutdown":
        for _ in range(2):
            opened, failure = submit(client, action, lane, read_only_retry=False,
                                     receipt_path=receipt_path, mutating=True)
            if failure == 2:
                continue
            if failure is not None:
                return failure
            assert opened is not None
            print(json.dumps({
                "ok": True,
                "state": "accepted",
                "final": True,
                "id": opened.get("_id"),
                "action": "shutdown",
                "closes": ["control", "readonly"],
                "revokesControlKey": True,
                "note": "The control entrance closes after this acknowledgement. If it was lost, the outcome is unknown; do not retry.",
            }, sort_keys=True))
            return 0
        return 1

    retry = action == "status"
    for _ in range(2):
        opened, failure = submit(client, action, lane, read_only_retry=retry,
                                 parameters=parameters,
                                 receipt_path=receipt_path,
                                 mutating=mutating)
        if failure == 2:
            continue
        if failure is not None:
            return failure
        assert opened is not None
        command_id = opened["_id"]
        pid = opened.get("currentPid")
        generation = opened.get("generation")
        if not isinstance(pid, int) or not isinstance(generation, int):
            # Fall back to the request identity retained in the key file.
            pid = client.state["pid"]
            generation = client.state["generation"]
        result, result_failure = fetch_result(
            client, command_id, pid, generation, deadline=deadline
        )
        if result_failure is not None:
            if mutating:
                if result_failure == 4:
                    update_receipt(receipt_path, command_id, "result_timeout")
                elif result_failure == 3:
                    update_receipt(receipt_path, command_id, "outcome_unknown",
                                   lastError="result-transport")
                else:
                    update_receipt(receipt_path, command_id, "result_rejected")
            return result_failure
        assert result is not None
        if action == "screenshot":
            action_ok, action_status = action_outcome(result.get("result") or {})
            if not action_ok:
                print(json.dumps({
                    "ok": False,
                    "transportOk": True,
                    "state": "ready",
                    "id": command_id,
                    "action": "screenshot",
                    "actionStatus": action_status,
                    "actionOk": False,
                    "error": "The screenshot action did not report success.",
                }, sort_keys=True))
                return 1
            artifact = (result.get("result") or {}).get("artifact")
            if not isinstance(artifact, dict):
                print(json.dumps({
                    "ok": False,
                    "state": "artifact_missing",
                    "id": command_id,
                    "error": (result.get("result") or {}).get("artifactError", "no artifact"),
                }, sort_keys=True))
                return 1
            try:
                data = base64.b64decode(artifact.get("base64", ""), validate=True)
            except Exception:
                print(json.dumps({"ok": False, "state": "artifact_corrupt",
                                  "id": command_id}, sort_keys=True))
                return 1
            if len(data) != artifact.get("byteCount"):
                print(json.dumps({"ok": False, "state": "artifact_size_mismatch",
                                  "id": command_id}, sort_keys=True))
                return 1
            digest = hashlib.sha256(data).hexdigest()
            if digest != artifact.get("sha256"):
                print(json.dumps({"ok": False, "state": "artifact_hash_mismatch",
                                  "id": command_id}, sort_keys=True))
                return 1
            destination = Path(screenshot_out or artifact.get("name", "screenshot.png"))
            private_write(destination, data)
            print(json.dumps({
                "ok": True,
                "state": "ready",
                "id": command_id,
                "action": "screenshot",
                "file": str(destination),
                "sha256": digest,
                "bytes": len(data),
                "pixelWidth": (result.get("result") or {}).get("details", {}).get("pixelWidth"),
                "pixelHeight": (result.get("result") or {}).get("details", {}).get("pixelHeight"),
                "currentGeneration": result.get("currentGeneration"),
            }, sort_keys=True))
            return 0
        if mutating:
            update_receipt(receipt_path, command_id, "result_ready",
                           resultStatus=(result.get("result") or {}).get("status"))
        return print_result(result, action=action, command_id=command_id)
    return 1


def reconcile(client: Client, receipt_path: Path, out: str | None) -> int:
    """Fetch one persisted operation's result without dispatching or retrying."""
    record = read_receipt(receipt_path)
    _, discovery_failure = client.discover()
    if discovery_failure is not None:
        return discovery_failure
    current_session = client.state.get("session")
    if current_session != record["session"]:
        print(json.dumps({
            "ok": False,
            "state": "session_mismatch",
            "id": record["id"],
            "action": record["action"],
            "error": "The receipt belongs to a different control session. No result was fetched.",
        }, sort_keys=True))
        return 2
    if client.state.get("pid") != record["pid"]:
        print(json.dumps({
            "ok": False,
            "state": "stale_pid",
            "id": record["id"],
            "action": record["action"],
            "error": "The receipt belongs to a previous host process. No result was fetched.",
        }, sort_keys=True))
        return 2
    status, opened, failure, _ = client.send({
        "v": 1,
        "id": record["id"],
        "pid": record["pid"],
        "generation": record["generation"],
        "session": record["session"],
        "_path": "/v1/result",
    })
    if status is None:
        print(json.dumps({
            "ok": False,
            "state": "outcome_unknown",
            "id": record["id"],
            "action": record["action"],
            "error": "The connection ended before a sealed reconciliation reply. No mutation was dispatched.",
        }, sort_keys=True))
        return 3
    if opened is None:
        print(json.dumps({
            "ok": False,
            "state": "outcome_unknown" if status == 200 else "rejected",
            "id": record["id"],
            "action": record["action"],
            "httpStatus": status,
            "error": failure or "unreadable sealed reconciliation reply",
        }, sort_keys=True))
        return 3 if status == 200 else 1
    if not opened.get("ok"):
        error = opened.get("error") or {}
        code = error.get("code")
        print(json.dumps({
            "ok": False,
            "state": "session_mismatch" if code == "session_mismatch" else "rejected",
            "id": record["id"],
            "action": record["action"],
            "error": error,
        }, sort_keys=True))
        return 2 if code == "session_mismatch" else 1
    state = opened.get("state")
    if state == "ready":
        result = opened.get("result") or {}
        if record["action"] == "screenshot":
            action_ok, action_status = action_outcome(result)
            if not action_ok:
                print(json.dumps({
                    "ok": False,
                    "transportOk": True,
                    "state": "ready",
                    "id": record["id"],
                    "action": record["action"],
                    "actionStatus": action_status,
                    "actionOk": False,
                    "error": "The reconciled screenshot action did not report success.",
                }, sort_keys=True))
                return 1
            artifact = result.get("artifact")
            if isinstance(artifact, dict):
                if out:
                    try:
                        data = base64.b64decode(artifact.get("base64", ""), validate=True)
                    except Exception:
                        print(json.dumps({"ok": False, "state": "artifact_corrupt",
                                          "id": record["id"]}, sort_keys=True))
                        return 1
                    if len(data) != artifact.get("byteCount") or                             hashlib.sha256(data).hexdigest() != artifact.get("sha256"):
                        print(json.dumps({"ok": False, "state": "artifact_mismatch",
                                          "id": record["id"]}, sort_keys=True))
                        return 1
                    private_write(Path(out), data)
                print(json.dumps({
                    "ok": True,
                    "transportOk": True,
                    "actionStatus": action_status,
                    "actionOk": True,
                    "state": "ready",
                    "id": record["id"],
                    "action": record["action"],
                    "file": str(Path(out)) if out else None,
                    "artifactName": artifact.get("name"),
                    "sha256": artifact.get("sha256"),
                    "bytes": artifact.get("byteCount"),
                }, sort_keys=True))
                return 0
        return print_result(opened, action=record["action"], command_id=record["id"])
    if state in {"late"}:
        action_ok, action_status = action_outcome(opened.get("result"))
        print(json.dumps({
            "ok": False,
            "transportOk": True,
            "state": "late",
            "late": True,
            "id": record["id"],
            "action": record["action"],
            "actionStatus": action_status,
            "actionOk": False,
            "result": opened.get("result"),
            "error": "This operation was fenced; the result is retained as late and is not a current success. Do not retry.",
        }, sort_keys=True))
        return 4
    _, action_status = action_outcome(opened.get("result"))
    print(json.dumps({
        "ok": False,
        "transportOk": True,
        "state": state or "unknown",
        "id": record["id"],
        "action": record["action"],
        "actionStatus": action_status,
        "actionOk": False,
        "result": opened.get("result"),
        "note": "Read-only reconciliation; no mutation was dispatched.",
    }, sort_keys=True))
    return 4


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-file", required=True, help="0600 controller key JSON")
    parser.add_argument("--host", default=None, help="override the phone LAN address")
    parser.add_argument("--port", type=int, default=None, help="override the control port")
    parser.add_argument("--timeout", type=float, default=8.0,
                        help="bounded result wait in seconds")
    parser.add_argument("--receipt-file", default=None,
                        help="0600 operation receipt path (default: <key-file>.operation.json)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    status = subparsers.add_parser("status", help="read host or engine status")
    status.add_argument("--lane", choices=["host", "engine"], default="host")
    status.add_argument("--json", action="store_true", help="accepted for script compatibility")

    run = subparsers.add_parser("run", help="submit one no-argument allowlisted command")
    run.add_argument("action", choices=sorted(RUN_ACTIONS))
    run.add_argument("--lane", choices=["host", "engine"], default=None)

    screenshot = subparsers.add_parser("screenshot", help="fetch an authenticated screenshot")
    screenshot.add_argument("--out", default=None)

    shutdown = subparsers.add_parser(
        "shutdown", help="one-way stop/fence, close both listeners and revoke the key"
    )
    shutdown.add_argument("--json", action="store_true", help="accepted for script compatibility")

    activate = subparsers.add_parser("activate", help="activate an installed app by bundle identifier")
    activate.add_argument("--bundle-id", required=True)

    inspect = subparsers.add_parser("inspect", help="read a bounded UI tree for the foreground app")
    inspect.add_argument("--bundle-id", required=True)
    inspect.add_argument("--max-depth", type=int, default=None,
                         help="1...64 (default 40; deep SwiftUI/UIKit wrappers need more than 10)")
    inspect.add_argument("--max-nodes", type=int, default=None,
                         help="1...800 (default 400)")
    inspect.add_argument("--max-string-bytes", type=int, default=None,
                         help="32...2048 (default 512)")
    inspect.add_argument("--max-total-bytes", type=int, default=None,
                         help="1024...131072 (default 65536)")

    tap = subparsers.add_parser("tap", help="tap by accessibility identifier or app-normalized coordinates")
    tap.add_argument("--bundle-id", required=True)
    tap.add_argument("--identifier", default=None, help="unique accessibility identifier")
    tap.add_argument("--x", type=float, default=None, help="normalized 0...1 from app-frame left")
    tap.add_argument("--y", type=float, default=None, help="normalized 0...1 from app-frame top")

    swipe = subparsers.add_parser("swipe", help="swipe between app-normalized coordinates")
    swipe.add_argument("--bundle-id", required=True)
    swipe.add_argument("--start-x", type=float, required=True)
    swipe.add_argument("--start-y", type=float, required=True)
    swipe.add_argument("--end-x", type=float, required=True)
    swipe.add_argument("--end-y", type=float, required=True)
    swipe.add_argument("--duration-ms", type=int, default=None,
                       help="50...2000 ms; velocity is derived from the point distance")

    type_text = subparsers.add_parser("type-text", help="type UTF-8 text from a private 0600 file")
    type_text.add_argument("--bundle-id", required=True)
    type_text.add_argument("--text-file", required=True)
    type_text.add_argument("--identifier", default=None,
                           help="exact accessibility identifier of the editable field")
    type_text.add_argument("--label", default=None,
                           help="exact accessibility label of the editable field")
    type_text.add_argument("--placeholder", default=None,
                           help="exact placeholder text of the editable field")
    type_text.add_argument("--x", type=float, default=None,
                           help="normalized 0...1 point that must land in exactly one editable field")
    type_text.add_argument("--y", type=float, default=None,
                           help="normalized 0...1 point that must land in exactly one editable field")

    reconcile_parser = subparsers.add_parser(
        "reconcile",
        help="read the persisted operation receipt and fetch its result without dispatching"
    )
    reconcile_parser.add_argument("--out", default=None,
                                  help="optional destination for a reconciled screenshot")

    args = parser.parse_args()
    path = Path(args.key_file).expanduser()
    receipt_path = (Path(args.receipt_file).expanduser()
                    if args.receipt_file else default_receipt_path(path))
    state = load_state(path)
    host = args.host or state.get("host")
    port = args.port or state.get("port")
    if not isinstance(host, str) or not host:
        raise SystemExit("no host in the controller file; pass --host")
    if not isinstance(port, int) or not (1 <= port <= 65535):
        raise SystemExit("no valid port in the controller file; pass --port")
    client = Client(state, path, host, port, args.timeout)

    if args.command == "reconcile":
        return reconcile(client, receipt_path, args.out)
    if args.command == "status":
        lane = args.lane
        return run_action(client, "status", lane, result_timeout=args.timeout,
                          screenshot_out=None, receipt_path=receipt_path)
    if args.command == "screenshot":
        return run_action(client, "screenshot", "engine", result_timeout=args.timeout,
                          screenshot_out=args.out, receipt_path=receipt_path)
    if args.command == "shutdown":
        return run_action(client, "shutdown", "host", result_timeout=args.timeout,
                          screenshot_out=None, receipt_path=receipt_path)
    if args.command == "run":
        action = args.action
        if action in HOST_ACTIONS:
            lane = "host"
        elif action in ENGINE_ACTIONS:
            lane = "engine"
        else:
            raise SystemExit("action is not allowlisted")
        if args.lane and args.lane != lane:
            raise SystemExit(f"{action} belongs to the {lane} lane")
        return run_action(client, action, lane, result_timeout=args.timeout,
                          screenshot_out=None, receipt_path=receipt_path)

    generic = {
        "activate": "activate_app",
        "inspect": "inspect_ui",
        "tap": "tap",
        "swipe": "swipe",
        "type-text": "type_text",
    }
    if args.command in generic:
        action = generic[args.command]
        parameters = build_parameters(action, args)
        return run_action(client, action, "engine", result_timeout=args.timeout,
                          screenshot_out=None, receipt_path=receipt_path,
                          parameters=parameters)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
