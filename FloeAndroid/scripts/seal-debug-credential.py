#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline host sealer for the Floe Android debug sealed-enrollment protocol.

This is the host-side counterpart of the debug-only
``com.floe.android.credentials.debug.DebugSealedEnrollment`` helper.  It takes
only the public session descriptor produced by ``begin`` and a bounded payload
supplied by the caller, and returns the ``FLQE`` v1 envelope expected by
``importSealed``.  It never holds or requests an RSA private key, never reads a
real credential, and never talks to a device.

Wire format (all integers are big endian)::

    0    4  "FLQE"
    4    1  protocol version (1)
    5    1  session id length (16)
    6   16  session id bytes
    22   1  AES-GCM IV length (12)
    23  12  random AES-GCM IV
    35   2  RSA-wrapped AES key length (384)
    37 384  RSA-OAEP(SHA-256, MGF1-SHA-1, empty label) wrapped AES-256 key
    421 ..  AES-256-GCM ciphertext followed by the 16-byte GCM tag

AAD (authenticated but not encrypted)::

    "FLEN" | version(1) | u16+sessionID(UTF-8) | u16+packageName(UTF-8) |
    u16+namespace(UTF-8) | u16+reference(UTF-8) | u64(expiresAtEpochMillis)

The descriptor is a JSON object with exactly these keys::

    protocolVersion          integer, must be 1
    sessionID               32 lowercase hex characters (16 bytes)
    packageName             non-blank, at most 256 UTF-16 code units
    namespace               [A-Za-z0-9][A-Za-z0-9._-]{0,63}
    reference               [A-Za-z0-9][A-Za-z0-9._:-]{0,127}
    expiresAtEpochMillis    positive signed 64-bit integer, not expired
    publicKeyDerBase64      canonical standard padded Base64 of the X.509
                            SubjectPublicKeyInfo DER for an RSA-3072 key

The matching Kotlin ``EnrollmentDescriptor`` is public metadata.  The future
debug binder should serialise it as::

    JSONObject()
        .put("protocolVersion", descriptor.protocolVersion)
        .put("sessionID", descriptor.sessionID)
        .put("packageName", descriptor.packageName)
        .put("namespace", descriptor.namespace)
        .put("reference", descriptor.reference)
        .put("expiresAtEpochMillis", descriptor.expiresAtEpochMillis)
        .put(
            "publicKeyDerBase64",
            Base64.encodeToString(descriptor.publicKeyDer, Base64.NO_WRAP),
        )

CLI payload input is deliberately restricted to bounded stdin or an explicit
file descriptor; there is no payload argument, environment variable, clipboard
or plaintext temporary file.  The only file this tool writes is the sealed
ciphertext.  Descriptor and output paths are never echoed.

Error handling uses fixed, secret-free codes.  Importable callers receive
``SealError`` with a ``code`` attribute; the CLI prints only the code and exits
2 for a defined rejection, 1 for an unexpected internal failure.
"""
import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import stat
import struct
import sys
import tempfile
import time
from collections.abc import Mapping as AbcMapping
from dataclasses import dataclass
from typing import Any, Dict, Mapping, Optional, Sequence

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# Constants mirrored from SealedEnrollmentProtocol.kt and CredentialLimits.kt.
PROTOCOL_VERSION = 1
SESSION_ID_BYTES = 16
SESSION_ID_HEX_CHARS = 32
AES_KEY_BYTES = 32
AES_GCM_IV_BYTES = 12
GCM_TAG_BYTES = 16
RSA_KEY_BITS = 3072
RSA_WRAPPED_KEY_BYTES = RSA_KEY_BITS // 8
MAX_PAYLOAD_BYTES = 65_536
MAX_NAMESPACE_CHARS = 64
MAX_REFERENCE_CHARS = 128
MAX_PACKAGE_NAME_UNITS = 256
INT64_MAX = (1 << 63) - 1

# Envelope offsets and bounds, derived exactly as in SealedEnvelopeCodec.
OFFSET_MAGIC = 0
OFFSET_VERSION = 4
OFFSET_SESSION_LENGTH = 5
OFFSET_SESSION = 6
OFFSET_IV_LENGTH = 22
OFFSET_IV = 23
OFFSET_WRAPPED_LENGTH = 35
OFFSET_WRAPPED = 37
OFFSET_CIPHERTEXT = 421
HEADER_AND_WRAPPED_BYTES = 4 + 1 + 1 + SESSION_ID_BYTES + 1 + AES_GCM_IV_BYTES + 2 + RSA_WRAPPED_KEY_BYTES
MIN_SEALED_BYTES = HEADER_AND_WRAPPED_BYTES + GCM_TAG_BYTES
MAX_SEALED_BYTES = HEADER_AND_WRAPPED_BYTES + MAX_PAYLOAD_BYTES + GCM_TAG_BYTES

# Public descriptor bound.  A real descriptor with a 4096-byte DER key and all
# fields is well below this; the cap stops a pathologically large public file.
MAX_DESCRIPTOR_BYTES = 16_384

ENVELOPE_MAGIC = b"FLQE"
AAD_MAGIC = b"FLEN"

DESCRIPTOR_FIELDS = frozenset(
    {
        "protocolVersion",
        "sessionID",
        "packageName",
        "namespace",
        "reference",
        "expiresAtEpochMillis",
        "publicKeyDerBase64",
    }
)

SESSION_ID_RE = re.compile(r"[0-9a-f]{32}")
NAMESPACE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
REFERENCE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]*")

# Java's OAEPParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA1,
# PSource.PSpecified.DEFAULT): SHA-256 main digest, SHA-1 MGF1, empty label.
OAEP = padding.OAEP(
    mgf=padding.MGF1(algorithm=hashes.SHA1()),
    algorithm=hashes.SHA256(),
    label=None,
)


class SealError(ValueError):
    """A fixed, secret-free rejection code."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


class _DuplicateKey(Exception):
    pass


@dataclass(frozen=True)
class _Descriptor:
    protocol_version: int
    session_id: str
    session_id_bytes: bytes
    package_name: str
    namespace: str
    reference: str
    expires_at_epoch_millis: int
    public_key: rsa.RSAPublicKey


def _fail(code: str) -> None:
    raise SealError(code)


def _require_plain_int(value: Any, code: str, minimum: int, maximum: int) -> int:
    # bool is an int subclass; JSON booleans must not be accepted as numbers.
    if type(value) is not int or value < minimum or value > maximum:
        _fail(code)
    return value


def _require_string(value: Any, code: str) -> str:
    if type(value) is not str:
        _fail(code)
    return value


def _validate_package_name(value: Any) -> str:
    text = _require_string(value, "invalid_package_name")
    if not text or text.strip() == "":
        _fail("invalid_package_name")
    try:
        # Kotlin String.length counts UTF-16 code units, not code points.
        utf16_units = len(text.encode("utf-16-le")) // 2
        utf8_bytes = text.encode("utf-8")
    except UnicodeEncodeError:
        _fail("invalid_package_name")
    if utf16_units < 1 or utf16_units > MAX_PACKAGE_NAME_UNITS:
        _fail("invalid_package_name")
    # EnrollmentAad.writeField stores the UTF-8 length in a u16.
    if len(utf8_bytes) > 0xFFFF:
        _fail("invalid_package_name")
    return text


def _validate_public_key(value: Any) -> rsa.RSAPublicKey:
    text = _require_string(value, "invalid_public_key")
    try:
        raw = base64.b64decode(text.encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error, ValueError):
        _fail("invalid_public_key")
    if not raw or len(raw) > 4096:
        _fail("invalid_public_key")
    # Require the canonical standard padded encoding a Kotlin NO_WRAP encoder
    # produces.  This rejects omitted padding and non-zero padding bits.
    if base64.b64encode(raw).decode("ascii") != text:
        _fail("invalid_public_key")
    try:
        public_key = serialization.load_der_public_key(raw)
    except Exception:
        _fail("invalid_public_key")
    if not isinstance(public_key, rsa.RSAPublicKey):
        _fail("invalid_public_key")
    if public_key.key_size != RSA_KEY_BITS:
        _fail("invalid_public_key_size")
    # Android emits a canonical X.509 SubjectPublicKeyInfo.  Reject trailing
    # or otherwise non-canonical DER instead of accepting a parser quirk.
    try:
        canonical = public_key.public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    except Exception:
        _fail("invalid_public_key")
    if canonical != raw:
        _fail("invalid_public_key")
    return public_key


def _now_millis() -> int:
    return time.time_ns() // 1_000_000


def _validate_descriptor(descriptor: Mapping[str, Any]) -> _Descriptor:
    if not isinstance(descriptor, AbcMapping):
        _fail("descriptor_schema_invalid")
    try:
        keys = set(descriptor.keys())
    except Exception:
        _fail("descriptor_schema_invalid")
    if keys != DESCRIPTOR_FIELDS:
        _fail("descriptor_schema_invalid")

    protocol_version = _require_plain_int(
        descriptor["protocolVersion"], "invalid_protocol_version", 1, 1
    )
    session_id = _require_string(descriptor["sessionID"], "invalid_session_id")
    if SESSION_ID_RE.fullmatch(session_id) is None:
        _fail("invalid_session_id")
    package_name = _validate_package_name(descriptor["packageName"])
    namespace = _require_string(descriptor["namespace"], "invalid_namespace")
    if len(namespace) > MAX_NAMESPACE_CHARS or NAMESPACE_RE.fullmatch(namespace) is None:
        _fail("invalid_namespace")
    reference = _require_string(descriptor["reference"], "invalid_reference")
    if len(reference) > MAX_REFERENCE_CHARS or REFERENCE_RE.fullmatch(reference) is None:
        _fail("invalid_reference")
    expires_at = _require_plain_int(
        descriptor["expiresAtEpochMillis"], "invalid_expiry", 1, INT64_MAX
    )
    if expires_at <= _now_millis():
        _fail("descriptor_expired")
    public_key = _validate_public_key(descriptor["publicKeyDerBase64"])

    try:
        session_id_bytes = bytes.fromhex(session_id)
    except ValueError:
        _fail("invalid_session_id")
    if len(session_id_bytes) != SESSION_ID_BYTES:
        _fail("invalid_session_id")

    return _Descriptor(
        protocol_version=protocol_version,
        session_id=session_id,
        session_id_bytes=session_id_bytes,
        package_name=package_name,
        namespace=namespace,
        reference=reference,
        expires_at_epoch_millis=expires_at,
        public_key=public_key,
    )


def _encode_aad(descriptor: _Descriptor) -> bytes:
    output = bytearray()
    output.extend(AAD_MAGIC)
    output.append(descriptor.protocol_version)
    fields = (
        descriptor.session_id,
        descriptor.package_name,
        descriptor.namespace,
        descriptor.reference,
    )
    for value in fields:
        encoded = value.encode("utf-8")
        if len(encoded) > 0xFFFF:
            _fail("invalid_session_id")
        output.extend(struct.pack(">H", len(encoded)))
        output.extend(encoded)
    output.extend(struct.pack(">Q", descriptor.expires_at_epoch_millis))
    return bytes(output)


def _encode_envelope(
    session_id: bytes,
    iv: bytes,
    wrapped_key: bytes,
    ciphertext: bytes,
) -> bytes:
    if (
        len(session_id) != SESSION_ID_BYTES
        or len(iv) != AES_GCM_IV_BYTES
        or len(wrapped_key) != RSA_WRAPPED_KEY_BYTES
        or len(ciphertext) < GCM_TAG_BYTES
        or len(ciphertext) > MAX_PAYLOAD_BYTES + GCM_TAG_BYTES
    ):
        _fail("seal_failed")
    total = HEADER_AND_WRAPPED_BYTES + len(ciphertext)
    if total > MAX_SEALED_BYTES:
        _fail("seal_failed")
    output = bytearray(total)
    output[OFFSET_MAGIC : OFFSET_MAGIC + 4] = ENVELOPE_MAGIC
    output[OFFSET_VERSION] = PROTOCOL_VERSION
    output[OFFSET_SESSION_LENGTH] = SESSION_ID_BYTES
    output[OFFSET_SESSION : OFFSET_SESSION + SESSION_ID_BYTES] = session_id
    output[OFFSET_IV_LENGTH] = AES_GCM_IV_BYTES
    output[OFFSET_IV : OFFSET_IV + AES_GCM_IV_BYTES] = iv
    output[OFFSET_WRAPPED_LENGTH : OFFSET_WRAPPED_LENGTH + 2] = struct.pack(
        ">H", len(wrapped_key)
    )
    output[OFFSET_WRAPPED : OFFSET_WRAPPED + len(wrapped_key)] = wrapped_key
    output[OFFSET_CIPHERTEXT :] = ciphertext
    return bytes(output)


def _seal_validated(parsed: _Descriptor, payload: bytes) -> bytes:
    # Re-check after any payload read: a slow payload must not produce an
    # envelope whose session has expired in the meantime.
    if parsed.expires_at_epoch_millis <= _now_millis():
        _fail("descriptor_expired")
    if isinstance(payload, bytes):
        payload_bytes = payload
    elif isinstance(payload, (bytearray, memoryview)):
        try:
            payload_bytes = bytes(payload)
        except Exception:
            _fail("invalid_payload")
    else:
        _fail("invalid_payload")
    if len(payload_bytes) > MAX_PAYLOAD_BYTES:
        _fail("payload_too_large")

    try:
        aes_key = os.urandom(AES_KEY_BYTES)
        iv = os.urandom(AES_GCM_IV_BYTES)
    except Exception:
        _fail("seal_failed")
    aad = _encode_aad(parsed)
    try:
        ciphertext = AESGCM(aes_key).encrypt(iv, payload_bytes, aad)
        wrapped_key = parsed.public_key.encrypt(aes_key, OAEP)
    except Exception:
        _fail("seal_failed")
    if len(ciphertext) != len(payload_bytes) + GCM_TAG_BYTES:
        _fail("seal_failed")
    if len(wrapped_key) != RSA_WRAPPED_KEY_BYTES:
        _fail("seal_failed")
    return _encode_envelope(parsed.session_id_bytes, iv, wrapped_key, ciphertext)


def seal(descriptor: Mapping[str, Any], payload: bytes) -> bytes:
    """Seal ``payload`` for the public enrollment ``descriptor``.

    ``descriptor`` is the JSON-compatible mapping documented in the module
    docstring.  ``payload`` is 0..65536 bytes.  The return value is the exact
    ``FLQE`` v1 envelope consumed by Android ``importSealed``.  This function
    is pure apart from operating-system randomness; it writes no files and
    keeps no state.

    Raises ``SealError`` with a fixed ``code`` for every rejected input.
    """
    return _seal_validated(_validate_descriptor(descriptor), payload)


def _pairs_no_duplicates(pairs: Sequence[Any]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey()
        result[key] = value
    return result


def _reject_json_constant(_value: str) -> None:
    raise ValueError("non-finite JSON number")


def _parse_descriptor_json(raw: bytes) -> Dict[str, Any]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        _fail("descriptor_invalid_json")
    try:
        value = json.loads(
            text,
            object_pairs_hook=_pairs_no_duplicates,
            parse_constant=_reject_json_constant,
        )
    except _DuplicateKey:
        _fail("descriptor_schema_invalid")
    except (json.JSONDecodeError, ValueError, RecursionError):
        _fail("descriptor_invalid_json")
    if not isinstance(value, dict):
        _fail("descriptor_schema_invalid")
    return value


def _read_descriptor_file(path: str) -> Dict[str, Any]:
    if not isinstance(path, str) or not path:
        _fail("descriptor_unreadable")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        # A FIFO or device path must not block the bounded regular-file read.
        flags |= os.O_NONBLOCK
    try:
        descriptor_fd = os.open(path, flags)
    except OSError:
        _fail("descriptor_unreadable")
    try:
        try:
            attributes = os.fstat(descriptor_fd)
        except OSError:
            _fail("descriptor_unreadable")
        if not stat.S_ISREG(attributes.st_mode):
            _fail("descriptor_unreadable")
        if attributes.st_size > MAX_DESCRIPTOR_BYTES:
            _fail("descriptor_too_large")
        try:
            stream = os.fdopen(descriptor_fd, "rb", closefd=True)
        except OSError:
            _fail("descriptor_unreadable")
        descriptor_fd = -1
        try:
            with stream:
                raw = stream.read(MAX_DESCRIPTOR_BYTES + 1)
        except OSError:
            _fail("descriptor_unreadable")
    finally:
        if descriptor_fd >= 0:
            try:
                os.close(descriptor_fd)
            except OSError:
                pass
    if len(raw) > MAX_DESCRIPTOR_BYTES:
        _fail("descriptor_too_large")
    return _parse_descriptor_json(raw)


def _read_fd_bounded(payload_fd: int) -> bytes:
    if payload_fd < 0:
        _fail("payload_unavailable")
    try:
        if os.isatty(payload_fd):
            # Reading an echoed terminal secret is not an accepted source.
            _fail("payload_unavailable")
    except OSError:
        _fail("payload_unavailable")
    chunks = bytearray()
    while len(chunks) <= MAX_PAYLOAD_BYTES:
        remaining = MAX_PAYLOAD_BYTES + 1 - len(chunks)
        try:
            chunk = os.read(payload_fd, min(65_536, remaining))
        except OSError:
            _fail("payload_unavailable")
        if not chunk:
            break
        chunks.extend(chunk)
        if len(chunks) > MAX_PAYLOAD_BYTES:
            _fail("payload_too_large")
    return bytes(chunks)


def _read_payload(payload_fd: Optional[int]) -> bytes:
    if payload_fd is not None:
        return _read_fd_bounded(payload_fd)
    stream = getattr(sys.stdin, "buffer", None)
    if stream is None:
        _fail("payload_unavailable")
    try:
        stdin_fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        stdin_fd = None
    if stdin_fd is not None:
        try:
            if os.isatty(stdin_fd):
                _fail("payload_unavailable")
        except OSError:
            _fail("payload_unavailable")
    try:
        raw = stream.read(MAX_PAYLOAD_BYTES + 1)
    except (OSError, ValueError):
        _fail("payload_unavailable")
    if raw is None:
        _fail("payload_unavailable")
    if len(raw) > MAX_PAYLOAD_BYTES:
        _fail("payload_too_large")
    return bytes(raw)


def _write_output(path: Optional[str], ciphertext: bytes) -> None:
    if path is None or path == "-":
        stream = getattr(sys.stdout, "buffer", None)
        if stream is None:
            _fail("output_unavailable")
        try:
            if stream.isatty():
                # Binary ciphertext to a terminal is not a useful default.
                _fail("output_unavailable")
            stream.write(ciphertext)
            stream.flush()
        except SealError:
            raise
        except OSError:
            _fail("output_unavailable")
        return

    if not isinstance(path, str) or not path:
        _fail("output_unavailable")
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        existing = None
    except OSError:
        _fail("output_unavailable")
    if existing is not None and not stat.S_ISREG(existing.st_mode):
        _fail("output_unavailable")

    directory = os.path.dirname(os.path.abspath(path)) or "."
    temporary_path: Optional[str] = None
    temporary_fd = -1
    try:
        temporary_fd, temporary_path = tempfile.mkstemp(
            prefix=".floe-seal-", suffix=".tmp", dir=directory
        )
        os.fchmod(temporary_fd, 0o600)
        with os.fdopen(temporary_fd, "wb", closefd=True) as stream:
            temporary_fd = -1
            stream.write(ciphertext)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except SealError:
        raise
    except OSError:
        _fail("output_unavailable")
    finally:
        if temporary_fd >= 0:
            try:
                os.close(temporary_fd)
            except OSError:
                pass
        if temporary_path is not None:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass


def _emit_metadata(descriptor: Mapping[str, Any], ciphertext: bytes) -> None:
    metadata = {
        "envelopeBytes": len(ciphertext),
        "envelopeSha256": hashlib.sha256(ciphertext).hexdigest(),
        "protocolVersion": PROTOCOL_VERSION,
        "sessionID": descriptor["sessionID"],
    }
    try:
        sys.stderr.write(
            json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n"
        )
        sys.stderr.flush()
    except OSError:
        pass


def _print_error(code: str) -> None:
    try:
        sys.stderr.write("seal-debug-credential.py: error: %s\n" % code)
        sys.stderr.flush()
    except OSError:
        pass


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # Never let argparse echo a supplied value (it could be pasted input).
        raise SealError("usage_error")


def _build_parser() -> argparse.ArgumentParser:
    parser = _ArgumentParser(
        prog="seal-debug-credential.py",
        description=(
            "Seal a bounded payload for the Floe Android debug enrollment "
            "protocol using only the public session descriptor."
        ),
    )
    parser.add_argument(
        "--descriptor",
        required=True,
        metavar="PATH",
        help="regular file containing the public descriptor JSON",
    )
    parser.add_argument(
        "--output",
        metavar="PATH",
        help="write only the ciphertext to PATH; omit or use '-' for stdout",
    )
    parser.add_argument(
        "--payload-fd",
        type=int,
        metavar="FD",
        help="read the payload from this already-open descriptor; default is stdin",
    )
    parser.add_argument(
        "--metadata",
        action="store_true",
        help="after success, print fixed public metadata to stderr",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        args = _build_parser().parse_args(argv)
        descriptor = _read_descriptor_file(args.descriptor)
        # Validate the public descriptor before reading the secret payload, so
        # a malformed or expired session never causes a wait for stdin/fd data.
        parsed = _validate_descriptor(descriptor)
        payload = _read_payload(args.payload_fd)
        ciphertext = _seal_validated(parsed, payload)
        _write_output(args.output, ciphertext)
        if args.metadata:
            _emit_metadata(descriptor, ciphertext)
        return 0
    except SealError as error:
        _print_error(error.code)
        return 2
    except BrokenPipeError:
        return 1
    except Exception:
        # No traceback: a cryptography/OS exception representation could
        # contain caller paths or values and is not part of the CLI contract.
        _print_error("internal_error")
        return 1


if __name__ == "__main__":
    sys.exit(main())
