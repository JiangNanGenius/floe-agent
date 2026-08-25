#!/usr/bin/env python3
"""Generate a short-lived App Store Connect API token without extra packages."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import time


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def read_length(value: bytes, offset: int) -> tuple[int, int]:
    first = value[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    count = first & 0x7F
    if count == 0 or count > 4:
        raise ValueError("Unsupported DER length")
    end = offset + count
    return int.from_bytes(value[offset:end], "big"), end


def read_integer(value: bytes, offset: int) -> tuple[bytes, int]:
    if value[offset] != 0x02:
        raise ValueError("Expected DER integer")
    length, offset = read_length(value, offset + 1)
    end = offset + length
    integer = value[offset:end].lstrip(b"\x00")
    if len(integer) > 32:
        raise ValueError("Invalid ES256 integer width")
    return integer.rjust(32, b"\x00"), end


def der_es256_to_raw(signature: bytes) -> bytes:
    if not signature or signature[0] != 0x30:
        raise ValueError("Expected DER sequence")
    sequence_length, offset = read_length(signature, 1)
    if offset + sequence_length != len(signature):
        raise ValueError("Invalid DER sequence length")
    r, offset = read_integer(signature, offset)
    s, offset = read_integer(signature, offset)
    if offset != len(signature):
        raise ValueError("Unexpected trailing DER data")
    return r + s


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def main() -> None:
    key_id = required_environment("ASC_KEY_ID")
    issuer_id = required_environment("ASC_ISSUER_ID")
    key_path = required_environment("ASC_PRIVATE_KEY_PATH")
    now = int(time.time())
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": now,
        "exp": now + 1_200,
        "aud": "appstoreconnect-v1",
    }
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode())
    encoded_payload = base64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    signature = base64url(der_es256_to_raw(result.stdout))
    print(f"{signing_input.decode('ascii')}.{signature}")


if __name__ == "__main__":
    main()
