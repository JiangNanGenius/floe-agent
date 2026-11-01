#!/usr/bin/env python3
"""Floe Bridge reference client (protocol v1, stdlib only).

Pairs with a device owner's approval and speaks the pinned Bridge v1 contract:

  * POST /pair with a raw 32-byte X25519 public key (plain grants are accepted
    only on true loopback and are discouraged),
  * POST /rpc with one HMAC-SHA256 PRF-CTR envelope per request,
  * GET /stream with a single-use ticket minted by the encrypted stream_ticket
    RPC.

Adapted from OpenMinis/iCTRL Scripts/ictrl_rpc.py at commit
c1e4268859ba858d1579f7b846a56cb40641b7f6 (Apache-2.0). The X25519 ladder,
keystream construction and envelope labels are retained; discovery, AWDL,
/whoami, the ~/.ictrl/token.json store and iCTRL product copy are not. Floe's
client is localhost-first, uses a 0600 per-origin client file, records unknown
side effects before a POST, and never retries an action automatically.

No real phone, account or credential is used by the tests. Keys in the test
fixtures are synthetic.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import pathlib
import secrets
import socket
import stat
import sys
import tempfile
import time
import urllib.parse
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

VERSION = "1.0.0"
DEFAULT_PORT = 8200
MAX_RESPONSE_BYTES = 32 * 1024 * 1024
MAX_JSON_BYTES = 512 * 1024
LABEL_MAC = b"ictrl-v1|mac"
LABEL_ENC_REQ = b"ictrl-v1|enc-req"
LABEL_ENC_RESP = b"ictrl-v1|enc-resp"
LABEL_PAIR = b"ictrl-pair"
LABEL_WRAP = b"ictrl-wrap"
X25519_BASE = (9).to_bytes(32, "little")

READ_METHODS = {
    "device_info", "page_source", "screen_text", "logs", "screenshot",
    "find_element", "scroll_to_element", "collect", "list_apps", "resolve_app",
    "is_locked", "config", "stream_ticket",
}
MUTATING_METHODS = {
    "tap", "double_tap", "long_press", "swipe", "page", "scroll", "home", "lock",
    "unlock", "open_url", "launch_app", "activate_app", "terminate_app",
    "tap_element", "find_and_tap", "drag", "wait", "reset", "type", "clear_text",
}
# stream_ticket mints a short-lived credential but has no device side effect.
# It is treated as a read for journaling purposes.


class ClientError(Exception):
    """Base class for this client's bounded, user-facing failures."""
    exit_code = 5

    def __init__(self, message: str, code: str = "error", **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.details = details


class UsageError(ClientError):
    exit_code = 2


class TransportError(ClientError):
    exit_code = 5


class ProtocolError(ClientError):
    exit_code = 5


class AuthError(ClientError):
    exit_code = 3


class PairError(ClientError):
    exit_code = 3


class JournalError(ClientError):
    exit_code = 5


class UnknownOutcome(ClientError):
    exit_code = 4


@dataclass(frozen=True)
class Endpoint:
    scheme: str
    host: str
    port: int

    @property
    def is_loopback(self) -> bool:
        host = self.host.lower()
        return host in ("127.0.0.1", "::1", "localhost") or host.startswith("127.")

    @property
    def origin(self) -> str:
        if ":" in self.host and not self.host.startswith("["):
            return "%s://[%s]:%d" % (self.scheme, self.host, self.port)
        return "%s://%s:%d" % (self.scheme, self.host, self.port)

    @property
    def storage_key(self) -> str:
        return hashlib.sha256(self.origin.encode("utf-8")).hexdigest()[:16]


def parse_endpoint(value: str) -> Endpoint:
    raw = (value or "").strip()
    if not raw:
        raise UsageError("an endpoint is required, for example 127.0.0.1:8200")
    if any(ord(ch) < 0x21 or ord(ch) == 0x7F for ch in raw):
        raise UsageError("the endpoint contains whitespace or control characters")
    if "://" not in raw:
        raw = "http://" + raw
    try:
        parsed = urllib.parse.urlsplit(raw)
    except ValueError as error:
        raise UsageError("invalid endpoint: %s" % error)
    if parsed.scheme != "http":
        raise UsageError("Bridge uses http:// only; TLS termination is not part of this package")
    if parsed.username or parsed.password:
        raise UsageError("userinfo is not accepted in a Bridge endpoint")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise UsageError("the endpoint must not include a path, query or fragment")
    host = parsed.hostname
    if not host:
        raise UsageError("the endpoint has no host")
    if any(ch.isspace() for ch in host):
        raise UsageError("the endpoint host is invalid")
    try:
        port = parsed.port or DEFAULT_PORT
    except ValueError:
        raise UsageError("the endpoint port is invalid")
    if not 1 <= port <= 65535:
        raise UsageError("the endpoint port is out of range")
    return Endpoint("http", host, port)


def hmac_sha256(key: bytes, data: bytes) -> bytes:
    return hmac.new(key, data, hashlib.sha256).digest()


def token_id(key: bytes) -> str:
    return hashlib.sha256(key).digest()[:4].hex()


def keystream_xor(key: bytes, nonce: bytes, data: bytes) -> bytes:
    """PRF-CTR keystream XOR, optimized for bounded screenshot responses."""
    if not data:
        return b""
    block_key = key if len(key) <= 64 else hashlib.sha256(key).digest()
    padded = block_key + b"\x00" * (64 - len(block_key))
    inner = hashlib.sha256(bytes(b ^ 0x36 for b in padded))
    outer = hashlib.sha256(bytes(b ^ 0x5C for b in padded))
    stream = bytearray()
    counter = 0
    while len(stream) < len(data):
        inner_copy = inner.copy()
        inner_copy.update(nonce + counter.to_bytes(4, "big"))
        outer_copy = outer.copy()
        outer_copy.update(inner_copy.digest())
        stream.extend(outer_copy.digest())
        counter += 1
    length = len(data)
    return (int.from_bytes(data, "big") ^ int.from_bytes(bytes(stream[:length]), "big")).to_bytes(length, "big")


def x25519(scalar: bytes, u: bytes) -> bytes:
    """RFC 7748 X25519. This is the reviewable pure-stdlib fallback."""
    if len(scalar) != 32 or len(u) != 32:
        raise ValueError("X25519 inputs must be 32 bytes")
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
        diff = (aa - bb) % p
        c = (x3 + z3) % p
        d = (x3 - z3) % p
        da = d * a % p
        cb = c * b % p
        x3 = (da + cb) ** 2 % p
        z3 = x1 * (da - cb) ** 2 % p
        x2 = aa * bb % p
        z2 = diff * (aa + 121665 * diff) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def seal_request(body: bytes, key: bytes, tok: str, nonce: bytes, timestamp: int) -> Dict[str, Any]:
    if len(key) != 32 or len(nonce) != 16:
        raise ProtocolError("invalid local key or nonce", "protocol")
    if not isinstance(tok, str) or len(tok) != 8:
        raise ProtocolError("invalid token id", "protocol")
    try:
        tok_bytes = bytes.fromhex(tok)
    except ValueError:
        raise ProtocolError("invalid token id", "protocol")
    key_enc = hmac_sha256(key, LABEL_ENC_REQ + nonce)
    key_mac = hmac_sha256(key, LABEL_MAC + nonce)
    ciphertext = keystream_xor(key_enc, nonce, body)
    signed = b"v1" + tok_bytes + timestamp.to_bytes(8, "big") + nonce + ciphertext
    tag = hmac_sha256(key_mac, signed)
    return {
        "v": 1, "tok": tok, "ts": timestamp, "nonce": nonce.hex(),
        "ct": base64.b64encode(ciphertext).decode("ascii"), "tag": tag.hex(),
    }


def open_response(envelope: Any, key: bytes, nonce: bytes) -> Dict[str, Any]:
    if not isinstance(envelope, dict) or envelope.get("v") != 1:
        raise ProtocolError("response is not a v1 envelope", "protocol")
    ct_text = envelope.get("ct")
    tag_text = envelope.get("tag")
    if not isinstance(ct_text, str) or not isinstance(tag_text, str):
        raise ProtocolError("response envelope is malformed", "protocol")
    if len(ct_text) > 24 * 1024 * 1024:
        raise ProtocolError("response envelope is too large", "protocol")
    if envelope.get("nonce") is not None and envelope.get("nonce") != nonce.hex():
        raise ProtocolError("response nonce does not match the request", "protocol")
    try:
        ciphertext = base64.b64decode(ct_text, validate=True)
        tag = bytes.fromhex(tag_text)
    except Exception:
        raise ProtocolError("response envelope encoding is invalid", "protocol")
    if len(tag) != 32:
        raise ProtocolError("response tag is invalid", "protocol")
    key_mac = hmac_sha256(key, LABEL_MAC + nonce)
    expected = hmac_sha256(key_mac, b"resp" + nonce + ciphertext)
    if not hmac.compare_digest(expected, tag):
        raise ProtocolError("response MAC mismatch; response discarded", "protocol")
    key_enc = hmac_sha256(key, LABEL_ENC_RESP + nonce)
    plaintext = keystream_xor(key_enc, nonce, ciphertext)
    try:
        value = json.loads(plaintext.decode("utf-8"))
    except Exception:
        raise ProtocolError("response JSON is invalid", "protocol")
    if not isinstance(value, dict):
        raise ProtocolError("response JSON is not an object", "protocol")
    return value


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _bounded_text(value: Any, limit: int = 400) -> str:
    if value is None:
        return ""
    text = str(value)
    text = "".join(ch for ch in text if ord(ch) >= 0x20 and ord(ch) != 0x7F)
    return text[:limit]


class Journal:
    """Append-only local record of dispatched actions; never stores text/keys."""

    def __init__(self, path: pathlib.Path) -> None:
        self.path = path

    def _ensure(self) -> None:
        ensure_private_parent(self.path)
        if self.path.exists():
            if self.path.is_symlink() or not self.path.is_file():
                raise JournalError("journal path is not a regular file: %s" % self.path)
            mode = stat.S_IMODE(self.path.stat().st_mode)
            if mode & 0o077:
                raise JournalError("journal file is readable by others; chmod 600 %s" % self.path)
        else:
            try:
                fd = os.open(str(self.path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(fd)
            except FileExistsError:
                pass

    def append(self, entry: Dict[str, Any]) -> None:
        self._ensure()
        line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
        try:
            fd = os.open(str(self.path), os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
            try:
                os.write(fd, line.encode("utf-8"))
                os.fsync(fd)
            finally:
                os.close(fd)
        except OSError as error:
            raise JournalError("could not record the operation before dispatch: %s" % error)

    def entries(self, limit: int = 2000) -> List[Dict[str, Any]]:
        if not self.path.exists():
            return []
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                lines = handle.readlines()[-limit:]
        except OSError as error:
            raise JournalError("could not read the local journal: %s" % error)
        result: List[Dict[str, Any]] = []
        for line in lines:
            try:
                value = json.loads(line)
            except Exception:
                continue
            if isinstance(value, dict):
                result.append(value)
        return result

    def unconfirmed(self) -> List[Dict[str, Any]]:
        # A mutating call is recorded twice: once before POST and once with the
        # outcome. Report one operation per id, using its latest state, so a
        # single unknown action does not look like two.
        latest: Dict[str, Dict[str, Any]] = {}
        order: List[str] = []
        for index, entry in enumerate(self.entries()):
            key = entry.get("operation_id")
            if not isinstance(key, str) or not key:
                key = "row-%d" % index
            if key not in latest:
                order.append(key)
            latest[key] = entry
        return [latest[key] for key in order
                if latest[key].get("state") in ("dispatched", "unknown")]


def ensure_private_parent(path: pathlib.Path) -> None:
    parent = path.parent
    try:
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError as error:
        raise UsageError("cannot create the client directory %s: %s" % (parent, error))
    try:
        info = parent.stat()
    except OSError as error:
        raise UsageError("cannot inspect the client directory: %s" % error)
    if not stat.S_ISDIR(info.st_mode):
        raise UsageError("client path parent is not a directory: %s" % parent)
    if info.st_uid != os.getuid():
        raise UsageError("client directory is not owned by this user: %s" % parent)
    if stat.S_IMODE(info.st_mode) & 0o077:
        try:
            os.chmod(parent, 0o700)
        except OSError as error:
            raise UsageError("client directory is not private; chmod 700 %s (%s)" % (parent, error))


def default_client_path(endpoint: Endpoint) -> pathlib.Path:
    return pathlib.Path.home() / ".floe" / "bridge" / ("client-%s.json" % endpoint.storage_key)


def default_journal_path(client_path: pathlib.Path) -> pathlib.Path:
    return client_path.with_name(client_path.stem + ".journal.jsonl")


def write_private_bytes(path: pathlib.Path, data: bytes) -> None:
    ensure_private_parent(path)
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise UsageError("refusing to replace a non-regular file: %s" % path)
    if path.exists() and (stat.S_IMODE(path.stat().st_mode) & 0o077):
        raise UsageError("target file is readable by others; chmod 600 %s" % path)
    fd, temp_name = tempfile.mkstemp(prefix=".floe-", dir=str(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, str(path))
        os.chmod(path, 0o600)
        try:
            directory_fd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def write_client_file(path: pathlib.Path, record: Dict[str, Any]) -> None:
    data = json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    write_private_bytes(path, data)


def load_client_file(path: pathlib.Path, endpoint: Endpoint, allow_endpoint_change: bool = False) -> Dict[str, Any]:
    if not path.exists():
        raise AuthError("no local client file at %s; run `pair` first" % path)
    if path.is_symlink():
        raise AuthError("refusing a symlinked client file: %s" % path)
    try:
        fd = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise AuthError("cannot open the client file: %s" % error)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise AuthError("client file is not a private regular file owned by this user")
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise AuthError("client file is readable by others; chmod 600 %s" % path)
        raw = os.read(fd, 64 * 1024)
    finally:
        os.close(fd)
    try:
        record = json.loads(raw.decode("utf-8"))
    except Exception:
        raise AuthError("client file is not valid JSON")
    if not isinstance(record, dict):
        raise AuthError("client file has an invalid shape")
    key_hex = record.get("key_hex")
    tok = record.get("tok")
    if not isinstance(key_hex, str) or len(key_hex) != 64 or key_hex != key_hex.lower():
        raise AuthError("client file has an invalid key encoding")
    try:
        key = bytes.fromhex(key_hex)
    except ValueError:
        raise AuthError("client file has an invalid key encoding")
    if len(key) != 32 or token_id(key) != tok:
        raise AuthError("client file token does not match its key")
    stored_endpoint = record.get("endpoint")
    if stored_endpoint != endpoint.origin and not allow_endpoint_change:
        raise AuthError(
            "client file belongs to %s, not %s; pass --allow-endpoint-change only if this is the same device"
            % (stored_endpoint, endpoint.origin)
        )
    record["_key"] = key
    record["_path"] = str(path)
    return record


def http_request(endpoint: Endpoint, method: str, path: str, body: Optional[bytes] = None,
                 timeout: float = 30.0, max_bytes: int = MAX_RESPONSE_BYTES) -> Tuple[int, Dict[str, str], bytes]:
    headers = {
        "Accept": "application/json",
        "Connection": "close",
        "Cache-Control": "no-store",
        "User-Agent": "FloeBridgeRemote/%s (stdlib)" % VERSION,
    }
    if body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
        headers["Content-Length"] = str(len(body))
    connection = http.client.HTTPConnection(endpoint.host, endpoint.port, timeout=timeout)
    try:
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        data = response.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise ProtocolError("response exceeded the bounded size", "too_large")
        return response.status, {key.lower(): value for key, value in response.getheaders()}, data
    except (socket.timeout, TimeoutError):
        raise TransportError("the Bridge request timed out", "timeout")
    except OSError as error:
        raise TransportError("the Bridge request failed: %s" % error, "network")
    finally:
        connection.close()


def parse_json_body(data: bytes, limit: int = MAX_JSON_BYTES) -> Any:
    if len(data) > limit:
        raise ProtocolError("JSON response exceeded the bounded size", "too_large")
    try:
        return json.loads(data.decode("utf-8"))
    except Exception:
        raise ProtocolError("the Bridge returned invalid JSON", "protocol")


def error_from_body(body: Any, fallback: str) -> Tuple[str, str, Optional[int]]:
    if isinstance(body, dict):
        error = body.get("error")
        if isinstance(error, dict):
            code = error.get("code")
            message = error.get("message")
            retry = error.get("retry_after")
            return (
                _bounded_text(code if isinstance(code, str) else fallback, 80),
                _bounded_text(message if isinstance(message, str) else fallback, 500),
                int(retry) if isinstance(retry, (int, float)) else None,
            )
    return fallback, fallback.replace("_", " "), None


def pair(endpoint: Endpoint, client_name: str, client_path: pathlib.Path,
         plain: bool = False, force: bool = False, timeout: float = 90.0) -> Dict[str, Any]:
    if client_path.exists() and not force:
        raise PairError("a client file already exists at %s; use --force to replace it" % client_path)
    if plain and not endpoint.is_loopback:
        raise UsageError("plain grants are accepted only on true loopback; use X25519 instead")
    private_key = None
    public_key = None
    if plain:
        body: Dict[str, Any] = {"client_name": client_name, "plain": True}
        print("Requesting a plaintext grant on loopback. X25519 is preferred even here.", file=sys.stderr)
    else:
        private_key = secrets.token_bytes(32)
        public_key = x25519(private_key, X25519_BASE)
        fingerprint = hashlib.sha256(public_key).hexdigest()[:8]
        body = {"client_name": client_name, "pub": base64.b64encode(public_key).decode("ascii")}
        print("Pairing request sent. Approve it on the device within about 60 seconds.", file=sys.stderr)
        print("Key fingerprint: %s  (compare with the prompt on the device)" % fingerprint, file=sys.stderr)
    try:
        status, _headers, data = http_request(endpoint, "POST", "/pair", _json_bytes(body), timeout=timeout)
    except TransportError as error:
        if error.code == "timeout":
            raise PairError(
                "pairing timed out; no key was saved. The device may still show a pending request. "
                "Check Floe Bridge → Clients before trying again.",
                "pair_timeout",
            )
        raise
    payload = parse_json_body(data)
    if status != 200:
        code, message, retry = error_from_body(payload, "pair_failed")
        if status == 403 and code == "pair_denied":
            raise PairError("the device owner declined or did not answer; no key was saved", code)
        if status == 429:
            suffix = (" Try again after %ss." % retry) if retry else " Try again shortly."
            raise PairError("another pairing request is pending or cooling down." + suffix, code)
        if status == 503:
            raise PairError("the Bridge service is stopping; start it again on the device", code)
        raise PairError("pairing failed (%s): %s" % (status, message), code)
    if not isinstance(payload, dict):
        raise PairError("pairing response is malformed; no key was saved", "pair_bad_response")
    tok = payload.get("tok")
    if not isinstance(tok, str) or len(tok) != 8:
        raise PairError("pairing response has no token id; no key was saved", "pair_bad_response")
    key: Optional[bytes] = None
    if isinstance(payload.get("pub"), str) and isinstance(payload.get("token_ct"), str):
        try:
            device_public = base64.b64decode(payload["pub"], validate=True)
            token_ct = bytes.fromhex(payload["token_ct"])
        except Exception:
            raise PairError("pairing response has invalid wrapped-key fields", "pair_bad_response")
        if len(device_public) != 32 or len(token_ct) != 32 or private_key is None or public_key is None:
            raise PairError("pairing response has invalid wrapped-key lengths", "pair_bad_response")
        shared = x25519(private_key, device_public)
        key_wrap = hmac_sha256(shared, LABEL_PAIR + public_key + device_public)
        pad = hmac_sha256(key_wrap, LABEL_WRAP)
        key = bytes(a ^ b for a, b in zip(token_ct, pad))
    elif isinstance(payload.get("token"), str):
        if not plain:
            raise PairError("the device returned a plaintext key that this client did not request", "pair_plain_unexpected")
        try:
            key = bytes.fromhex(payload["token"])
        except ValueError:
            raise PairError("the device returned an invalid plaintext key", "pair_bad_response")
        if len(key) != 32:
            raise PairError("the device returned an invalid plaintext key length", "pair_bad_response")
    else:
        raise PairError("pairing response contains no key material", "pair_bad_response")
    if token_id(key) != tok:
        raise PairError("pairing response key does not match its token id; discarded", "pair_key_mismatch")
    record = {
        "version": 1,
        "endpoint": endpoint.origin,
        "tok": tok,
        "key_hex": key.hex(),
        "client_name": client_name,
        "paired_at": int(time.time()),
        "expires": payload.get("expires") if isinstance(payload.get("expires"), int) else None,
        "mode": "plain" if plain else "x25519",
    }
    write_client_file(client_path, record)
    record["_key"] = key
    record["_path"] = str(client_path)
    print("Paired. The client key is stored with mode 0600 at %s." % client_path, file=sys.stderr)
    return record


def rpc_call(endpoint: Endpoint, record: Dict[str, Any], method: str, params: Optional[Dict[str, Any]],
             journal: Journal, timeout: float = 60.0, operation_id: Optional[str] = None) -> Any:
    key = record.get("_key")
    tok = record.get("tok")
    if not isinstance(key, bytes) or len(key) != 32 or not isinstance(tok, str):
        raise AuthError("the local client record is incomplete; pair again")
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise UsageError("params must be a JSON object")
    mutating = method in MUTATING_METHODS
    if operation_id is not None and not mutating:
        raise UsageError("--operation-id is only for a single mutating intent")
    if operation_id is None and mutating:
        operation_id = secrets.token_hex(16)
    if operation_id is not None:
        if len(operation_id) > 128 or not operation_id[0].isalnum() or any(
                ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" for ch in operation_id):
            raise UsageError("operation id must be 1-128 characters: alphanumeric first, then alphanumeric . _ -")
    request_id = "floe-" + secrets.token_hex(8)
    body = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    if operation_id:
        body["operation_id"] = operation_id
    entry = {
        "ts": int(time.time()),
        "endpoint": endpoint.origin,
        "tok": tok,
        "operation_id": operation_id,
        "method": method,
        "state": "dispatched",
    }
    if mutating:
        journal.append(entry)
    nonce = secrets.token_bytes(16)
    timestamp = int(time.time())
    envelope = seal_request(_json_bytes(body), key, tok, nonce, timestamp)
    try:
        status, _headers, data = http_request(
            endpoint, "POST", "/rpc", _json_bytes(envelope), timeout=timeout,
            max_bytes=MAX_RESPONSE_BYTES,
        )
    except TransportError as error:
        if mutating:
            entry["state"] = "unknown"
            entry["error"] = error.code
            try:
                journal.append(entry)
            except JournalError:
                pass
            raise UnknownOutcome(
                "outcome unknown: the request did not complete; no retry was attempted. "
                "Operation %s is recorded in %s. Check the device, then use `reconcile`."
                % (operation_id, journal.path), "outcome_unknown", operation_id=operation_id,
                journal=str(journal.path),
            )
        raise
    try:
        payload = parse_json_body(data)
    except ProtocolError as error:
        if mutating:
            entry["state"] = "unknown"
            entry["error"] = "bad_response"
            try:
                journal.append(entry)
            except JournalError:
                pass
            raise UnknownOutcome(
                "outcome unknown: the device response could not be read. No retry was attempted. "
                "Operation %s is recorded in %s." % (operation_id, journal.path), "bad_response",
                operation_id=operation_id, journal=str(journal.path),
            )
        raise error
    if status != 200:
        code, message, retry = error_from_body(payload, "http_%d" % status)
        if mutating and status >= 500:
            entry["state"] = "unknown"
            entry["error"] = code
            try:
                journal.append(entry)
            except JournalError:
                pass
            raise UnknownOutcome(
                "outcome unknown (HTTP %d): %s. No retry was attempted. Operation %s is recorded in %s."
                % (status, message, operation_id, journal.path), code,
                operation_id=operation_id, journal=str(journal.path),
            )
        if mutating:
            entry["state"] = "error"
            entry["error"] = code
            try:
                journal.append(entry)
            except JournalError:
                pass
        if code in ("auth_failed", "auth_required"):
            raise AuthError("the device rejected this pairing key; pair again", code)
        if code == "ts_skew":
            raise ProtocolError("the device rejected the timestamp; check this machine's clock", code)
        if code == "nonce_replayed":
            raise ProtocolError("the device rejected a replayed nonce; reload/re-pair is not needed", code)
        if code == "nonce_flood":
            raise ProtocolError("the device refused too many requests; wait and try again", code)
        if code == "service_stopping":
            raise ClientError("the Bridge service is stopping; nothing was sent", code)
        if retry:
            raise ClientError("%s (retry after %ss)" % (message, retry), code)
        raise ClientError("Bridge HTTP %d: %s" % (status, message), code)
    try:
        opened = open_response(payload, key, nonce)
    except ProtocolError as error:
        if mutating:
            entry["state"] = "unknown"
            entry["error"] = "protocol"
            try:
                journal.append(entry)
            except JournalError:
                pass
            raise UnknownOutcome(
                "outcome unknown: %s. No retry was attempted. Operation %s is recorded in %s."
                % (error.message, operation_id, journal.path), "protocol",
                operation_id=operation_id, journal=str(journal.path),
            )
        raise
    if opened.get("id") is not None and opened.get("id") != request_id:
        if mutating:
            entry["state"] = "unknown"
            entry["error"] = "id_mismatch"
            try:
                journal.append(entry)
            except JournalError:
                pass
            raise UnknownOutcome(
                "outcome unknown: the response id did not match. No retry was attempted. "
                "Operation %s is recorded in %s." % (operation_id, journal.path), "id_mismatch",
                operation_id=operation_id, journal=str(journal.path),
            )
        raise ProtocolError("the response id did not match the request", "id_mismatch")
    error = opened.get("error")
    if isinstance(error, dict):
        code = error.get("code")
        message = _bounded_text(error.get("message") or "RPC error", 500)
        if code in (-32013, -32017):
            if mutating:
                entry["state"] = "unknown"
                entry["error"] = code
                try:
                    journal.append(entry)
                except JournalError:
                    pass
            raise UnknownOutcome(
                "%s. No retry was attempted. Operation %s is recorded in %s."
                % (message, operation_id, journal.path), "operation_unknown",
                operation_id=operation_id, journal=str(journal.path),
            )
        if mutating:
            entry["state"] = "error"
            entry["error"] = code
            try:
                journal.append(entry)
            except JournalError:
                pass
        if code == -32010:
            raise ClientError("the automation engine is not ready on the device: " + message, "engine_not_ready")
        if code == -32011:
            raise ClientError("the device does not expose this method in this build: " + message, "method_not_available")
        if code == -32012:
            raise ClientError("the device owner has not granted this permission: " + message, "permission_denied")
        if code == -32016:
            raise ClientError("the device automation queue is full; nothing was executed: " + message, "queue_full")
        if code == -32018:
            raise ClientError("the response exceeded the device's bounded size: " + message, "response_too_large")
        if code == -32019:
            raise ClientError("the Bridge service is stopping: " + message, "service_stopping")
        if code == -32020:
            raise ClientError("the operation already completed and its result was not retained: " + message, "already_completed")
        if code == -32021:
            raise ClientError("the operation was refused because the Bridge state changed: " + message, "fenced")
        raise ClientError("Bridge RPC error %s: %s" % (code, message), "rpc_error")
    if mutating:
        entry["state"] = "ok"
        try:
            journal.append(entry)
        except JournalError:
            print("warning: the operation succeeded but the local journal could not be updated", file=sys.stderr)
    result = opened.get("result")
    return result if result is not None else {}


def run_status(endpoint: Endpoint, client_path: pathlib.Path, allow_endpoint_change: bool = False,
               timeout: float = 10.0) -> Dict[str, Any]:
    status, _headers, data = http_request(endpoint, "GET", "/", timeout=timeout, max_bytes=MAX_JSON_BYTES)
    if status != 200:
        code, message, _ = error_from_body(parse_json_body(data), "service_unavailable")
        raise ClientError("the Bridge service is unavailable (%s): %s" % (code, message), code)
    info = parse_json_body(data)
    if not isinstance(info, dict):
        raise ProtocolError("the service info is not a JSON object", "protocol")
    schema = None
    try:
        schema_status, _h, schema_data = http_request(endpoint, "GET", "/schema", timeout=timeout, max_bytes=MAX_JSON_BYTES)
        if schema_status == 200:
            schema = parse_json_body(schema_data)
    except ClientError:
        schema = None
    result: Dict[str, Any] = {"endpoint": endpoint.origin, "service": info, "schema": schema, "client": None}
    if client_path.exists():
        record = load_client_file(client_path, endpoint, allow_endpoint_change)
        journal = Journal(default_journal_path(client_path))
        result["client_file"] = str(client_path)
        result["journal"] = str(journal.path)
        try:
            result["client"] = rpc_call(endpoint, record, "config", {}, journal, timeout=timeout)
        except AuthError as error:
            result["auth_error"] = error.message
        except ClientError as error:
            result["client_error"] = {"code": error.code, "message": error.message}
    return result


def print_status(result: Dict[str, Any], json_output: bool) -> None:
    if json_output:
        safe = dict(result)
        print(json.dumps(safe, ensure_ascii=False, indent=2, sort_keys=True))
        return
    service = result.get("service") or {}
    print("Service: %s %s (protocol %s) at %s" % (
        service.get("product", "Floe Bridge"), service.get("server_version", "?"),
        service.get("protocol_version", "?"), result.get("endpoint")))
    print("Engine:  %s" % service.get("engine", "unknown"))
    schema = result.get("schema") or {}
    methods = schema.get("methods") if isinstance(schema, dict) else None
    if isinstance(methods, list):
        available = [m.get("name") for m in methods if isinstance(m, dict) and m.get("available") is True]
        print("Schema:  %d method(s), %d available" % (len(methods), len(available)))
    else:
        print("Schema:  unavailable")
    client = result.get("client")
    if result.get("client_file"):
        print("Client:  %s" % result.get("client_file"))
    if result.get("auth_error"):
        print("Auth:    %s" % result["auth_error"])
    elif isinstance(client, dict):
        name = client.get("clients") if isinstance(client.get("clients"), list) else []
        print("Client engine: %s" % (client.get("engine", {}).get("state", "unknown") if isinstance(client.get("engine"), dict) else "unknown"))
        print("LAN:     %s" % ("on" if client.get("lan_enabled") else "off"))
        print("Clients: %d" % len(name))
        if result.get("journal"):
            unknown = Journal(pathlib.Path(result["journal"])).unconfirmed()
            print("Journal: %d unconfirmed operation(s)" % len(unknown))
    elif not result.get("client_file"):
        print("Client:  no local client file; run `pair` first")


def read_text_source(path_text: Optional[str]) -> str:
    if path_text is None or path_text == "-":
        if sys.stdin.isatty():
            print("Text to type (not stored in argv or history):", file=sys.stderr)
        return sys.stdin.read()
    path = pathlib.Path(path_text).expanduser()
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise UsageError("cannot read the text file: %s" % error)


def write_output_bytes(path: pathlib.Path, data: bytes) -> None:
    """Write a 0600 output file without demanding a private parent directory."""
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise UsageError("cannot create the output directory %s: %s" % (parent, error))
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise UsageError("refusing to replace a non-regular output file: %s" % path)
    fd, temp_name = tempfile.mkstemp(prefix=".floe-out-", dir=str(parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, str(path))
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def write_download(path_text: str, data: bytes) -> pathlib.Path:
    path = pathlib.Path(path_text).expanduser()
    write_output_bytes(path, data)
    return path


def sanitize_output(value: Any) -> Any:
    """Redact short-lived tickets and key-shaped fields from generic output."""
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if key in ("ticket", "token", "key", "key_hex", "token_ct"):
                cleaned[key] = "«redacted»"
            else:
                cleaned[key] = sanitize_output(item)
        return cleaned
    if isinstance(value, list):
        return [sanitize_output(item) for item in value]
    return value


def cmd_pair(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    name = args.name or ("Floe Bridge CLI · " + _bounded_text(socket.gethostname(), 60))
    pair(endpoint, name, client_path, plain=args.plain, force=args.force,
         timeout=max(90.0, args.timeout))
    return 0


def cmd_forget(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    if not client_path.exists():
        print("No local client file at %s; nothing to forget." % client_path, file=sys.stderr)
        return 0
    if not args.yes:
        print("This removes the local key and journal at %s. It does not revoke access on the device." % client_path, file=sys.stderr)
        try:
            answer = input("Forget the local key? [y/N] ")
        except EOFError:
            answer = ""
        if answer.strip().lower() not in ("y", "yes"):
            print("Kept the local key.", file=sys.stderr)
            return 1
    try:
        client_path.unlink()
    except OSError as error:
        raise UsageError("could not remove the local client file: %s" % error)
    journal = default_journal_path(client_path)
    try:
        if journal.exists():
            journal.unlink()
    except OSError:
        pass
    print("Local key removed. To end access, revoke this client in Floe Bridge → Clients on the device.", file=sys.stderr)
    return 0


def cmd_status(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    result = run_status(endpoint, client_path, args.allow_endpoint_change, timeout=args.timeout)
    print_status(result, args.json)
    if result.get("auth_error"):
        return 3
    return 0


def cmd_reconcile(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    journal = Journal(default_journal_path(client_path))
    unknown = journal.unconfirmed()
    print("Journal: %s" % journal.path)
    if not unknown:
        print("No dispatched-but-unconfirmed operations recorded.")
    else:
        print("Unconfirmed operations (never replayed automatically):")
        for entry in unknown:
            print("  %s  %s  %s  state=%s  operation=%s" % (
                entry.get("ts", "?"), entry.get("method", "?"), entry.get("endpoint", "?"),
                entry.get("state", "?"), entry.get("operation_id", "?")))
    if not client_path.exists():
        print("No local client file; run `pair` first.", file=sys.stderr)
        return 3
    try:
        result = run_status(endpoint, client_path, args.allow_endpoint_change, timeout=args.timeout)
        print_status(result, args.json)
        if result.get("auth_error"):
            return 3
        record = load_client_file(client_path, endpoint, args.allow_endpoint_change)
        try:
            logs = rpc_call(endpoint, record, "logs", {"max_elements": 50}, journal, timeout=args.timeout)
            lines = logs.get("lines") if isinstance(logs, dict) else None
            if isinstance(lines, list) and lines:
                print("Recent redacted device log lines:")
                for line in lines[-50:]:
                    print("  " + _bounded_text(line, 240))
        except ClientError as error:
            print("Device logs unavailable: %s" % error.message, file=sys.stderr)
    except ClientError as error:
        print("Status unavailable: %s" % error.message, file=sys.stderr)
        return error.exit_code
    return 0


def cmd_schema(args: argparse.Namespace, endpoint: Endpoint) -> int:
    status, _headers, data = http_request(endpoint, "GET", "/schema", timeout=args.timeout, max_bytes=MAX_JSON_BYTES)
    if status != 200:
        raise ProtocolError("schema unavailable (HTTP %d)" % status, "schema_unavailable")
    schema = parse_json_body(data)
    if args.json:
        print(json.dumps(schema, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    methods = schema.get("methods") if isinstance(schema, dict) else None
    if not isinstance(methods, list):
        raise ProtocolError("schema has no methods array", "protocol")
    print("Protocol: %s %s" % (schema.get("protocol", "?"), schema.get("protocol_version", "?")))
    for method in methods:
        if not isinstance(method, dict):
            continue
        marker = "available" if method.get("available") is True else "unavailable"
        print("%-24s %s" % (method.get("name", "?"), marker))
    return 0


def load_record(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> Dict[str, Any]:
    return load_client_file(client_path, endpoint, args.allow_endpoint_change)


def cmd_call(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    record = load_record(args, endpoint, client_path)
    if args.params == "-":
        raw = sys.stdin.read()
    else:
        raw = args.params
    try:
        params = json.loads(raw) if raw else {}
    except Exception as error:
        raise UsageError("params must be a JSON object: %s" % error)
    if not isinstance(params, dict):
        raise UsageError("params must be a JSON object")
    if args.method == "type" and isinstance(params.get("text"), str) and params.get("text"):
        raise UsageError(
            "text would be visible in argv and shell history; use the `type` command, "
            "which reads text from stdin or --text-file"
        )
    journal = Journal(default_journal_path(client_path))
    result = rpc_call(endpoint, record, args.method, params, journal, timeout=args.timeout,
                      operation_id=args.operation_id)
    if args.json:
        print(json.dumps(sanitize_output(result), ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(json.dumps(sanitize_output(result), ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def cmd_shot(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    record = load_record(args, endpoint, client_path)
    journal = Journal(default_journal_path(client_path))
    result = rpc_call(endpoint, record, "screenshot", {
        "scale": args.scale, "format": args.format, "quality": args.quality
    }, journal, timeout=args.timeout)
    if not isinstance(result, dict) or not isinstance(result.get("data"), str):
        raise ProtocolError("screenshot response has no data", "protocol")
    try:
        image = base64.b64decode(result["data"], validate=True)
    except Exception:
        raise ProtocolError("screenshot data is not valid base64", "protocol")
    path = write_download(args.path, image)
    print("Screenshot written to %s (%d bytes, %s)." % (path, len(image), result.get("format", "unknown")))
    return 0


def cmd_type(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    record = load_record(args, endpoint, client_path)
    text = read_text_source(args.text_file)
    if len(text.encode("utf-8")) > 16000:
        raise UsageError("text exceeds the 16,000-byte local bound; send a smaller input")
    params: Dict[str, Any] = {"text": text, "submit": bool(args.submit)}
    if args.clear:
        params["clear"] = True
    journal = Journal(default_journal_path(client_path))
    rpc_call(endpoint, record, "type", params, journal, timeout=args.timeout)
    print("Text sent. The local text was not written to the journal or argv.")
    return 0


def cmd_stream(args: argparse.Namespace, endpoint: Endpoint, client_path: pathlib.Path) -> int:
    record = load_record(args, endpoint, client_path)
    journal = Journal(default_journal_path(client_path))
    ticket_result = rpc_call(endpoint, record, "stream_ticket", {}, journal, timeout=args.timeout)
    ticket = ticket_result.get("ticket") if isinstance(ticket_result, dict) else None
    if not isinstance(ticket, str) or not ticket or len(ticket) > 2048:
        raise ProtocolError("the device returned no usable stream ticket", "stream_ticket")
    path = "/stream?ticket=" + urllib.parse.quote(ticket, safe="")
    target = pathlib.Path(args.path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and (target.is_symlink() or not target.is_file()):
        raise UsageError("refusing to replace a non-regular output file: %s" % target)
    connection = http.client.HTTPConnection(endpoint.host, endpoint.port, timeout=30.0)
    started = time.monotonic()
    written = 0
    try:
        connection.request("GET", path, headers={"Accept": "video/mp4,video/mp2t", "User-Agent": "FloeBridgeRemote/%s" % VERSION})
        response = connection.getresponse()
        if response.status != 200:
            body = response.read(MAX_JSON_BYTES)
            code, message, _ = error_from_body(parse_json_body(body), "stream_http_%d" % response.status)
            raise ClientError("stream refused (%s): %s" % (code, message), code)
        content_type = response.getheader("Content-Type") or "unknown"
        fd, temp_name = tempfile.mkstemp(prefix=".floe-stream-", dir=str(target.parent))
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as handle:
                while True:
                    if args.max_bytes and written >= args.max_bytes:
                        break
                    if args.seconds and time.monotonic() - started >= args.seconds:
                        break
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    remaining = (args.max_bytes - written) if args.max_bytes else len(chunk)
                    if remaining <= 0:
                        break
                    handle.write(chunk[:remaining])
                    written += len(chunk[:remaining])
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_name, str(target))
            os.chmod(target, 0o600)
        except Exception:
            try:
                os.unlink(temp_name)
            except OSError:
                pass
            raise
        print("Stream bytes written to %s (%d bytes, %s). The ticket was used once and is not printed." % (
            target, written, content_type))
        return 0
    finally:
        connection.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="floe_bridge_client.py",
        description="Floe Bridge reference client: owner-approved pairing and encrypted JSON-RPC.",
        epilog="Default endpoint: 127.0.0.1:8200. Use [::1]:8200 for IPv6. No discovery or LAN scan is performed.",
    )
    parser.add_argument("--host", default="127.0.0.1:8200", help="Bridge endpoint (default 127.0.0.1:8200)")
    parser.add_argument("--client-file", help="private client file (default under ~/.floe/bridge, mode 0600)")
    parser.add_argument("--allow-endpoint-change", action="store_true",
                        help="allow an explicit client file to be used with a different origin")
    parser.add_argument("--json", action="store_true", help="machine-readable output where supported")
    parser.add_argument("--timeout", type=float, default=60.0, help="request timeout in seconds")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("pair", help="pair with owner approval (X25519 by default)")
    p.add_argument("--name", default=None, help="client name shown to the device owner")
    p.add_argument("--plain", action="store_true", help="legacy plaintext grant; loopback only")
    p.add_argument("--force", action="store_true", help="replace an existing local client file")

    p = sub.add_parser("forget", help="remove the local client key and journal (does not revoke the device)")
    p.add_argument("--yes", action="store_true", help="do not prompt")

    sub.add_parser("status", help="read-only service, schema and local client status")
    sub.add_parser("reconcile", help="read-only journal and device log check; never replays an action")
    sub.add_parser("schema", help="list the device's advertised methods")

    p = sub.add_parser("call", help="transparent named JSON-RPC call")
    p.add_argument("method")
    p.add_argument("params", nargs="?", default="{}", help="JSON object, or - to read stdin")
    p.add_argument("--operation-id", default=None,
                   help="stable id for one actual mutating intent (never a correlation id)")

    p = sub.add_parser("shot", help="save a screenshot")
    p.add_argument("path")
    p.add_argument("--format", choices=("jpeg", "png"), default="jpeg")
    p.add_argument("--scale", type=float, default=2.0)
    p.add_argument("--quality", type=float, default=0.6)

    p = sub.add_parser("type", help="type text read from stdin or a file (never argv)")
    p.add_argument("--text-file", default=None, help="file containing the text, or - for stdin")
    p.add_argument("--submit", action="store_true")
    p.add_argument("--clear", action="store_true")

    p = sub.add_parser("stream", help="save a bounded single-use /stream response")
    p.add_argument("path")
    p.add_argument("--seconds", type=float, default=5.0)
    p.add_argument("--max-bytes", type=int, default=0)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        endpoint = parse_endpoint(args.host)
        client_path = pathlib.Path(args.client_file).expanduser() if args.client_file else default_client_path(endpoint)
        if args.command == "pair":
            return cmd_pair(args, endpoint, client_path)
        if args.command == "forget":
            return cmd_forget(args, endpoint, client_path)
        if args.command == "status":
            return cmd_status(args, endpoint, client_path)
        if args.command == "reconcile":
            return cmd_reconcile(args, endpoint, client_path)
        if args.command == "schema":
            return cmd_schema(args, endpoint)
        if args.command == "call":
            return cmd_call(args, endpoint, client_path)
        if args.command == "shot":
            return cmd_shot(args, endpoint, client_path)
        if args.command == "type":
            return cmd_type(args, endpoint, client_path)
        if args.command == "stream":
            return cmd_stream(args, endpoint, client_path)
        raise UsageError("unknown command")
    except UnknownOutcome as error:
        print("OUTCOME UNKNOWN: %s" % error.message, file=sys.stderr)
        if error.details.get("operation_id"):
            print("Operation: %s" % error.details["operation_id"], file=sys.stderr)
        if error.details.get("journal"):
            print("Journal:   %s" % error.details["journal"], file=sys.stderr)
        print("No retry was attempted. Inspect the device or run `reconcile`.", file=sys.stderr)
        return error.exit_code
    except ClientError as error:
        print("error: %s" % error.message, file=sys.stderr)
        if error.code and error.code not in ("error",):
            print("code:  %s" % error.code, file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
