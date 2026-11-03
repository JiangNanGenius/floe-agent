#!/usr/bin/env python3
"""Provision a separate 32-byte LAN control key through the authenticated local
configure_recovery file lane.

The install token is read from a private local file (never argv), used only to
authorise the existing host command, and is never printed. The generated
control key is written to a separate 0600 controller file. The command file is
also 0600 and contains both secrets until the app claims and deletes it.

This is limited provisioning, not full upstream /pair parity. See
HANDOFF.md in the private lan-control-source directory.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import sys
import time
from pathlib import Path

CANONICAL_LENGTH = 43


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def decode_canonical(value: str, *, label: str) -> bytes:
    if len(value) != CANONICAL_LENGTH:
        raise SystemExit(f"{label} must be a canonical 43-character base64url value")
    raw = value.encode("ascii")
    allowed = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    if any(byte not in allowed for byte in raw):
        raise SystemExit(f"{label} contains a non-canonical character")
    padded = value.replace("-", "+").replace("_", "/")
    padded += "=" * ((4 - len(padded) % 4) % 4)
    data = base64.b64decode(padded, validate=True)
    if len(data) != 32 or b64url(data) != value:
        raise SystemExit(f"{label} must decode to exactly 32 canonical bytes")
    return data


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


def check_private(path: Path, *, label: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise SystemExit(f"{label} must not be group/other accessible (expected 0600)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--token-file", required=True,
                        help="private file containing the existing install token")
    parser.add_argument("--pid", required=True, type=int,
                        help="current Bridge host PID")
    parser.add_argument("--generation", type=int, default=0,
                        help="last observed shared generation (default 0)")
    parser.add_argument("--host", default="", help="phone LAN address for the controller file")
    parser.add_argument("--port", type=int, default=47655)
    parser.add_argument("--command-id", default=f"control-provision-{secrets.token_hex(8)}")
    parser.add_argument("--key-out", required=True, help="controller key file to create")
    parser.add_argument("--command-out", required=True,
                        help="configure_recovery command JSON to copy into the app inbox")
    parser.add_argument("--no-enable-control", dest="enable_control",
                        action="store_false", default=True,
                        help="store the key but leave the device owner toggle off")
    args = parser.parse_args()

    if args.pid <= 0:
        raise SystemExit("--pid must be positive")
    if not (1 <= args.port <= 65535):
        raise SystemExit("--port is invalid")

    token_path = Path(args.token_file).expanduser()
    try:
        check_private(token_path, label="install token file")
        token = token_path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise SystemExit(f"cannot read the install token file: {error}") from error
    decode_canonical(token, label="install token")

    key = secrets.token_bytes(32)
    control_key = b64url(key)
    if control_key == token:
        raise SystemExit("generated control key equals the install token; aborting")

    fingerprint = hashlib.sha256(key).digest()[:4].hex()
    command = {
        "id": args.command_id,
        "action": "configure_recovery",
        "pid": args.pid,
        "token": token,
        "controlKey": control_key,
    }
    if args.enable_control:
        command["controlEnabled"] = True
    command_data = json.dumps(command, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    private_write(Path(args.command_out).expanduser(), command_data)

    key_record = {
        "version": 1,
        "host": args.host,
        "port": args.port,
        "tok": fingerprint,
        "key_hex": key.hex(),
        "pid": args.pid,
        "generation": args.generation,
        "session": "",
        "client_name": "primary-local-setup",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    private_write(Path(args.key_out).expanduser(),
                  (json.dumps(key_record, indent=2, sort_keys=True) + "\n").encode("utf-8"))

    print(json.dumps({
        "ok": True,
        "command_file": str(Path(args.command_out).expanduser()),
        "key_file": str(Path(args.key_out).expanduser()),
        "fingerprint": fingerprint,
        "pid": args.pid,
        "generation": args.generation,
        "control_enabled": args.enable_control,
        "note": "Copy command_file to Documents/Bridge/commands/host/ before disconnecting developer tools.",
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
