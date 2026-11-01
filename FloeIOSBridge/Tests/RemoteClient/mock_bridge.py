#!/usr/bin/env python3
"""Synthetic Bridge v1 service for the remote-client tests.

This is test code, not a shipped server. It implements the pinned pairing and
HMAC-CTR envelope contract independently of the reference client so a successful
call proves interoperability rather than two copies of the same bug.

Nothing here uses a real phone, account, credential or persisted client key.
Keys are generated per process and live only in memory; the test-only state
endpoint deliberately does not expose them.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import pathlib
import secrets
import socket
import socketserver
import struct
import sys
import threading
import time
import zlib

LABEL_MAC = b"ictrl-v1|mac"
LABEL_ENC_REQ = b"ictrl-v1|enc-req"
LABEL_ENC_RESP = b"ictrl-v1|enc-resp"
LABEL_PAIR = b"ictrl-pair"
LABEL_WRAP = b"ictrl-wrap"
BASE = (9).to_bytes(32, "little")


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def keystream_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < len(data):
        out += hmac_sha256(key, nonce + counter.to_bytes(4, "big"))
        counter += 1
    if not data:
        return b""
    return (int.from_bytes(data, "big") ^ int.from_bytes(bytes(out[:len(data)]), "big")).to_bytes(len(data), "big")


def token_id(key: bytes) -> str:
    return hashlib.sha256(key).digest()[:4].hex()


def x25519(scalar: bytes, u: bytes) -> bytes:
    """RFC 7748 Montgomery ladder; used only for synthetic pair tests."""
    p = 2 ** 255 - 19
    k = bytearray(scalar)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    e = int.from_bytes(k, "little")
    x1 = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x2, z2, x3, z3, swap = 1, 0, x1, 1, 0
    for t in reversed(range(255)):
        bit = (e >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a = (x2 + z2) % p
        aa = a * a % p
        b = (x2 - z2) % p
        bb = b * b % p
        e2 = (aa - bb) % p
        c = (x3 + z3) % p
        d = (x3 - z3) % p
        da = d * a % p
        cb = c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = e2 * (aa + 121665 * e2) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def unb64(text: str) -> bytes:
    return base64.b64decode(text, validate=True)


def make_png(width: int, height: int) -> bytes:
    """Small deterministic RGB PNG with a visible gradient/box pattern."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            r = 8 + (x * 80 // max(1, width - 1))
            g = 14 + (y * 90 // max(1, height - 1))
            b = 28 + ((x + y) * 70 // max(1, width + height - 2))
            if 40 <= x < width - 40 and 40 <= y < height - 40:
                r, g, b = 18, 80, 110
            rows.extend((r, g, b))
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")


METHODS = [
    "config", "stream_ticket", "device_info", "page_source", "screen_text", "logs",
    "screenshot", "tap", "double_tap", "long_press", "swipe", "page", "drag",
    "home", "lock", "unlock", "type", "clear_text", "list_apps", "resolve_app",
    "launch_app", "find_element", "scroll_to_element", "collect", "is_locked",
    "activate_app", "terminate_app", "open_url", "wait", "reset", "tap_element",
    "find_and_tap", "scroll"
]


class State:
    def __init__(self, video_path: pathlib.Path | None = None) -> None:
        self.lock = threading.RLock()
        self.clients: dict[str, dict] = {}
        self.nonces: dict[str, set[str]] = {}
        self.tickets: dict[str, dict] = {}
        self.calls: list[dict] = []
        self.pair_requests: list[dict] = []
        self.stream_requests: list[dict] = []
        self.modes: dict = {
            "engine": "ready",
            "pair_denied": False,
            "pair_busy": False,
            "pair_cooldown": False,
            "auth_fail": False,
            "unavailable_methods": [],
            "unknown_methods": [],
            "permission_methods": [],
            "queue_methods": [],
            "logger": [],
            "stream": True,
            "stream_type": "video/mp4",
            "stream_delay_ms": 18,
            "video_path": str(video_path) if video_path else "",
            "screenshot_broken": False,
            "drop_methods": []
        }
        self.screenshot_png = make_png(780, 1688)
        self.video_bytes: bytes | None = None
        if video_path and video_path.exists():
            self.video_bytes = video_path.read_bytes()

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "modes": dict(self.modes),
                "clients": [
                    {"client_id": tok, "client_name": rec["client_name"]}
                    for tok, rec in self.clients.items()
                ],
                "calls": list(self.calls),
                "pair_requests": list(self.pair_requests),
                "stream_requests": list(self.stream_requests),
                "tickets": [
                    {"ticket": ticket, "client_id": rec["client_id"],
                     "used": rec["used"], "expires": rec["expires"]}
                    for ticket, rec in self.tickets.items()
                ]
            }


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FloeBridgeMock/1.0"

    @property
    def state(self) -> State:
        return self.server.state  # type: ignore[attr-defined]

    def log_message(self, fmt, *args):  # keep test output clean
        if os.environ.get("FLOE_MOCK_VERBOSE"):
            sys.stderr.write("mock: " + (fmt % args) + "\n")

    def _send_json(self, status: int, value) -> None:
        data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_error_json(self, status: int, code: str, message: str, extra=None) -> None:
        error = {"code": code, "message": message}
        if extra:
            error.update(extra)
        self._send_json(status, {"error": error})

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > 262144:
            raise ValueError("body too large")
        return self.rfile.read(length) if length else b""

    def _request_json(self) -> dict:
        body = self._read_body()
        value = json.loads(body.decode("utf-8")) if body else None
        if not isinstance(value, dict):
            raise ValueError("JSON object required")
        return value

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/remote":
            page = pathlib.Path(__file__).resolve().parents[2] / "Resources" / "BridgeRemote" / "REMOTE.html"
            data = page.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/":
            self._send_json(200, {
                "product": "Floe Bridge",
                "server_version": "1.0.0",
                "protocol_version": 1,
                "transport": "localhost-first test fixture",
                "lan_enabled": False,
                "engine": self.state.modes["engine"],
                "capabilities": self._capabilities(),
                "endpoints": ["GET /schema", "GET /skill", "POST /pair", "POST /rpc", "GET /stream"],
                "note": "Synthetic test fixture; no real device."
            })
            return
        if path == "/schema":
            self._send_json(200, self._schema())
            return
        if path == "/skill":
            data = b"# Floe Bridge synthetic test fixture\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/markdown; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/stream":
            self._stream()
            return
        if path == "/__test/state":
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self._send_error_json(403, "loopback_only", "test endpoint is loopback-only")
                return
            self._send_json(200, self.state.snapshot())
            return
        self._send_error_json(404, "not_found", "Not Found")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            if path == "/pair":
                self._pair()
            elif path == "/rpc":
                self._rpc()
            elif path == "/__test/mode":
                if self.client_address[0] not in ("127.0.0.1", "::1"):
                    self._send_error_json(403, "loopback_only", "test endpoint is loopback-only")
                    return
                body = self._request_json()
                with self.state.lock:
                    self.state.modes.update(body)
                self._send_json(200, {"ok": True, "modes": self.state.modes})
            elif path == "/__test/reset":
                if self.client_address[0] not in ("127.0.0.1", "::1"):
                    self._send_error_json(403, "loopback_only", "test endpoint is loopback-only")
                    return
                with self.state.lock:
                    self.state.calls.clear()
                    self.state.pair_requests.clear()
                    self.state.stream_requests.clear()
                    self.state.tickets.clear()
                self._send_json(200, {"ok": True})
            else:
                self._send_error_json(404, "not_found", "Not Found")
        except ValueError as error:
            self._send_error_json(400, "bad_request", str(error))
        except Exception as error:  # test fixture: expose a bounded diagnostic
            self._send_error_json(500, "mock_error", type(error).__name__ + ": " + str(error)[:200])

    def _capabilities(self) -> list:
        tags = ["envelope_v1", "jsonrpc_2.0", "schema", "dual_loopback", "config"]
        if self.state.modes.get("stream"):
            tags += ["stream", "stream_ticket"]
        for name in ("device_info", "screenshot", "screen_text", "tap", "drag", "type"):
            if name not in self.state.modes.get("unavailable_methods", []):
                tags.append(name)
        return tags

    def _schema(self) -> dict:
        unavailable = set(self.state.modes.get("unavailable_methods", []))
        methods = []
        for name in METHODS:
            available = name not in unavailable
            if name == "stream_ticket" and not self.state.modes.get("stream"):
                available = False
            methods.append({
                "name": name,
                "description": "Synthetic fixture method " + name,
                "params": [],
                "returns": "object",
                "available": available
            })
        return {
            "protocol": "JSON-RPC 2.0",
            "server_version": "1.0.0",
            "skill_version": "1.0.0",
            "protocol_version": 1,
            "capability_tags": self._capabilities(),
            "transport": "synthetic loopback fixture",
            "endpoints": {"info": "GET /", "schema": "GET /schema", "pair": "POST /pair", "rpc": "POST /rpc"},
            "methods": methods
        }

    def _pair(self):
        body = self._request_json()
        name = body.get("client_name")
        if not isinstance(name, str) or not name:
            self._send_error_json(400, "bad_request", "client_name is required")
            return
        with self.state.lock:
            self.state.pair_requests.append({"client_name": name, "at": time.time()})
            modes = self.state.modes
            if modes.get("pair_denied"):
                self._send_error_json(403, "pair_denied", "The synthetic owner denied pairing.")
                return
            if modes.get("pair_busy"):
                self._send_error_json(429, "pair_busy", "Synthetic pairing slot is busy.", {"retry_after": 7})
                return
            if modes.get("pair_cooldown"):
                self._send_error_json(429, "pair_cooldown", "Synthetic pairing cooldown.", {"retry_after": 4})
                return
            key = secrets.token_bytes(32)
            tok = token_id(key)
            record = {"key": key, "client_name": name, "created": time.time()}
            if body.get("plain") is True:
                if self.client_address[0] not in ("127.0.0.1", "::1"):
                    self._send_error_json(403, "plain_forbidden", "plain is loopback-only")
                    return
                record["plain"] = True
                self.state.clients[tok] = record
                self._send_json(200, {"tok": tok, "client_name": name,
                                      "expires": int(time.time()) + 30 * 24 * 3600,
                                      "token": key.hex()})
                return
            pub_text = body.get("pub")
            try:
                client_pub = unb64(pub_text) if isinstance(pub_text, str) else b""
            except Exception:
                client_pub = b""
            if len(client_pub) != 32:
                self._send_error_json(400, "bad_request", "pub must be a raw 32-byte X25519 key in base64")
                return
            device_private = secrets.token_bytes(32)
            device_public = x25519(device_private, BASE)
            shared = x25519(device_private, client_pub)
            wrap_key = hmac_sha256(shared, LABEL_PAIR + client_pub + device_public)
            pad = hmac_sha256(wrap_key, LABEL_WRAP)
            token_ct = bytes(a ^ b for a, b in zip(key, pad))
            record["plain"] = False
            self.state.clients[tok] = record
            self._send_json(200, {
                "tok": tok,
                "client_name": name,
                "expires": int(time.time()) + 30 * 24 * 3600,
                "pub": b64(device_public),
                "token_ct": token_ct.hex()
            })

    def _rpc(self):
        raw = self._read_body()
        try:
            envelope = json.loads(raw.decode("utf-8")) if raw else None
        except Exception:
            envelope = None
        if not isinstance(envelope, dict) or envelope.get("v") != 1:
            self._send_error_json(400, "bad_envelope", "Body must be a v1 encrypted envelope.")
            return
        try:
            tok = envelope["tok"]
            ts = int(envelope["ts"])
            nonce = bytes.fromhex(envelope["nonce"])
            ct = unb64(envelope["ct"])
            tag = bytes.fromhex(envelope["tag"])
        except Exception:
            self._send_error_json(400, "bad_envelope", "Malformed envelope fields")
            return
        if len(nonce) != 16 or len(tag) != 32 or len(ct) > 262144:
            self._send_error_json(400, "bad_envelope", "Malformed envelope fields")
            return
        with self.state.lock:
            record = self.state.clients.get(tok)
            if record is None or self.state.modes.get("auth_fail"):
                self._send_error_json(401, "auth_failed", "Invalid or expired key.")
                return
            if abs(ts - int(time.time())) > 120:
                self._send_error_json(401, "ts_skew", "Timestamp outside the accepted window.")
                return
            nonces = self.state.nonces.setdefault(tok, set())
            if nonce.hex() in nonces:
                self._send_error_json(401, "nonce_replayed", "Duplicate nonce.")
                return
            key = record["key"]
            self._current_tok = tok
            key_mac = hmac_sha256(key, LABEL_MAC + nonce)
            signed = b"v1" + bytes.fromhex(tok) + ts.to_bytes(8, "big") + nonce + ct
            if not hmac.compare_digest(hmac_sha256(key_mac, signed), tag):
                self._send_error_json(401, "auth_failed", "MAC verification failed.")
                return
            nonces.add(nonce.hex())
            key_enc = hmac_sha256(key, LABEL_ENC_REQ + nonce)
            plaintext = keystream_xor(key_enc, nonce, ct)
        try:
            request = json.loads(plaintext.decode("utf-8"))
        except Exception:
            self._sealed(record, nonce, {"jsonrpc": "2.0", "id": None,
                                          "error": {"code": -32700, "message": "Parse error"}})
            return
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            self._sealed(record, nonce, {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None,
                                          "error": {"code": -32600, "message": "Invalid Request"}})
            return
        response = self._dispatch(request)
        with self.state.lock:
            drop = request.get("method") in self.state.modes.get("drop_methods", [])
        if drop:
            self.close_connection = True
            return
        self._sealed(record, nonce, response)

    def _sealed(self, record, nonce: bytes, value: dict) -> None:
        plaintext = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        key = record["key"]
        key_mac = hmac_sha256(key, LABEL_MAC + nonce)
        key_enc = hmac_sha256(key, LABEL_ENC_RESP + nonce)
        ct = keystream_xor(key_enc, nonce, plaintext)
        tag = hmac_sha256(key_mac, b"resp" + nonce + ct)
        self._send_json(200, {"v": 1, "nonce": nonce.hex(), "ct": b64(ct), "tag": tag.hex()})

    def _dispatch(self, request: dict) -> dict:
        method = request["method"]
        params = request.get("params") if isinstance(request.get("params"), dict) else {}
        request_id = request.get("id")
        with self.state.lock:
            self.state.calls.append({"method": method, "params": params, "id": request_id,
                                     "operation_id": request.get("operation_id"), "at": time.time()})
            modes = self.state.modes
            if (modes.get("engine") == "not_ready" and
                    method not in ("config", "logs", "stream_ticket")):
                return {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32010, "message": "The automation engine is not ready.",
                                  "data": {"reason": "synthetic engine not ready"}}}
            if method in modes.get("unavailable_methods", []):
                return {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32011, "message": "Method not available in this build."}}
            if method in modes.get("unknown_methods", []):
                return {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32013, "message": "The operation may already have taken effect."}}
            if method in modes.get("permission_methods", []):
                return {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32012, "message": "The device owner has not granted this permission."}}
            if method in modes.get("queue_methods", []):
                return {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": -32016, "message": "The automation queue is full."}}
            if method in ("tap", "double_tap", "long_press", "swipe", "page", "drag", "home",
                          "lock", "unlock", "type", "clear_text", "launch_app", "activate_app",
                          "terminate_app", "open_url", "find_and_tap", "tap_element", "reset",
                          "wait", "scroll"):
                return {"jsonrpc": "2.0", "id": request_id,
                        "result": {"message": "synthetic " + method, "foreground_app": "com.example.fixture"}}
            if method == "config":
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "port": self.server.server_address[1],
                    "lan_enabled": False,
                    "bonjour_enabled": False,
                    "engine": {
                        "state": modes.get("engine", "ready"),
                        "reason": "synthetic engine not ready" if modes.get("engine") == "not_ready" else None,
                        "supported_methods": [name for name in METHODS if name not in ("config", "logs", "stream_ticket")]
                    },
                    "capabilities": self._capabilities(),
                    "clients": [
                        {"client_id": tok, "client_name": rec["client_name"],
                         "granted_at": int(rec["created"]), "last_active_at": int(time.time()),
                         "expires_at": int(time.time()) + 30 * 24 * 3600,
                         "last_address": "127.0.0.1", "last_via": "local",
                         "sensitive_input_granted": False}
                        for tok, rec in self.state.clients.items()
                    ],
                    "stopping": False
                }}
            if method == "device_info":
                if modes.get("engine") == "not_ready":
                    return {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32010, "message": "The automation engine is not ready.",
                                      "data": {"reason": "synthetic engine not ready"}}}
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "device_name": "Floe Test iPhone",
                    "model": "iPhone17,1",
                    "system_version": "26.1",
                    "point_width": 390, "point_height": 844,
                    "pixel_width": 780, "pixel_height": 1688,
                    "scale": 2,
                    "server_version": "1.0.0", "protocol_version": 1,
                    "capabilities": self._capabilities(),
                    "hint": "synthetic fixture",
                    "system": {"battery_percent": 71, "battery_state": "charging",
                               "thermal_state": "nominal", "low_power_mode": False}
                }}
            if method == "screenshot":
                if modes.get("screenshot_broken"):
                    return {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32011, "message": "screenshot unavailable"}}
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "data": b64(self.state.screenshot_png), "format": "png",
                    "bytes": len(self.state.screenshot_png),
                    "pixel_width": 780, "pixel_height": 1688,
                    "point_width": 390, "point_height": 844, "scale": 2,
                    "scope": "screen", "hint": "synthetic fixture"
                }}
            if method == "screen_text":
                labels = [
                    "Settings", "Wi-Fi", "Synthetic <script>alert(1)</script>",
                    "中文 & symbols", "A very long OCR label " + ("x" * 120)
                ]
                items = []
                for index, label in enumerate(labels):
                    items.append({"label": label, "confidence": 0.9 - index * 0.05,
                                  "x": 20 + index * 10, "y": 60 + index * 50,
                                  "width": 200, "height": 30,
                                  "center_x": 20 + index * 10 + 100,
                                  "center_y": 60 + index * 50 + 15,
                                  "element_type": "OCRText", "is_text_input": False, "exists": True})
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "count": len(items), "items": items, "coordinate_space": "points",
                    "channel": {"recommended": "ocr", "why": "synthetic"},
                    "overlay_text": ["Status bar & clock"],
                    "hint": "synthetic OCR"
                }}
            if method == "page_source":
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "source": "Synthetic AX tree\n<unsafe> & text", "truncated": False,
                    "total_returned": 2, "coordinate_space": "points", "hint": "synthetic"
                }}
            if method == "list_apps":
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "count": 3, "source": "fixture", "apps": [
                        {"name": "Safari", "bundle_id": "com.apple.mobilesafari"},
                        {"name": "Settings", "bundle_id": "com.apple.Preferences"},
                        {"name": "Floe Test <App>", "bundle_id": "com.example.floe"}
                    ], "hint": "synthetic"
                }}
            if method == "resolve_app":
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "count": 1, "term": params.get("text", ""), "source": "fixture",
                    "apps": [{"name": "Safari", "bundle_id": "com.apple.mobilesafari"}],
                    "hint": "synthetic"
                }}
            if method == "logs":
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "lines": ["synthetic log line", "tap completed"],
                    "count": 2, "total": 2, "hint": "synthetic redacted"
                }}
            if method == "stream_ticket":
                if not modes.get("stream"):
                    return {"jsonrpc": "2.0", "id": request_id,
                            "error": {"code": -32011, "message": "stream unavailable"}}
                ticket = secrets.token_hex(16)
                self.state.tickets[ticket] = {
                    "client_id": getattr(self, "_current_tok", ""),
                    "used": False,
                    "expires": time.time() + 60
                }
                return {"jsonrpc": "2.0", "id": request_id, "result": {
                    "ticket": ticket, "expires_in": 60,
                    "hint": "Synthetic single-use ticket; append ?ticket=<ticket>."
                }}
        return {"jsonrpc": "2.0", "id": request_id,
                "error": {"code": -32601, "message": "Method not found"}}

    def _stream(self):
        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        ticket = None
        for part in query.split("&"):
            if part.startswith("ticket="):
                ticket = part.split("=", 1)[1]
        with self.state.lock:
            record = self.state.tickets.get(ticket) if ticket else None
            if record is None or record["used"] or record["expires"] < time.time():
                self._send_error_json(401, "unauthorized", "GET /stream needs a valid single-use ticket.")
                return
            record["used"] = True
            self.state.stream_requests.append({"ticket": ticket, "at": time.time(),
                                               "content_type": self.state.modes.get("stream_type")})
            video = self.state.video_bytes
            delay = int(self.state.modes.get("stream_delay_ms", 18))
        if not video:
            self._send_error_json(503, "stream_unavailable", "No synthetic video fixture installed.")
            return
        self.send_response(200)
        self.send_header("Content-Type", self.state.modes.get("stream_type", "video/mp4"))
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            chunk_size = 4096
            for start in range(0, len(video), chunk_size):
                chunk = video[start:start + chunk_size]
                self.wfile.write(("%X\r\n" % len(chunk)).encode("ascii") + chunk + b"\r\n")
                self.wfile.flush()
                if delay:
                    time.sleep(delay / 1000.0)
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--video", type=pathlib.Path, default=None)
    args = parser.parse_args()
    state = State(args.video)
    server = Server(("127.0.0.1", args.port), Handler)
    server.state = state  # type: ignore[attr-defined]
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
