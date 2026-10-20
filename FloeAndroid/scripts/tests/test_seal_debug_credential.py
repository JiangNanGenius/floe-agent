#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Focused synthetic tests for the offline debug credential host sealer.

These tests use only an ephemeral RSA key generated in memory and synthetic
payload bytes.  They never read a real credential, touch a device, run Gradle,
or write a private key.  The independent decryption path below reconstructs
the Android envelope and AAD from the documented bytes rather than calling the
sealer's private helpers, so a round trip also checks the wire contract.

Run with::

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
        FloeAndroid/scripts/tests/test_seal_debug_credential.py
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SCRIPT = Path(__file__).resolve().parents[1] / "seal-debug-credential.py"


def _load_sealer():
    spec = importlib.util.spec_from_file_location(
        "floe_seal_debug_credential_under_test", SCRIPT
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load sealer script")
    module = importlib.util.module_from_spec(spec)
    # Register before exec so dataclasses and introspection work on Python 3.9.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sealer = _load_sealer()

SESSION_ID = "00112233445566778899aabbccddeeff"
SESSION_ID_BYTES = bytes.fromhex(SESSION_ID)
FIXED_EXPIRY = 4_102_444_800_000  # 2100-01-01T00:00:00Z
MAX_PAYLOAD = 65_536
SECRET_MARKER = b"SYNTHETIC-PAYLOAD-MARKER-7f3c"

OAEP = padding.OAEP(
    mgf=padding.MGF1(algorithm=hashes.SHA1()),
    algorithm=hashes.SHA256(),
    label=None,
)


class SealDebugCredentialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.private_key = rsa.generate_private_key(
            public_exponent=65537, key_size=3072
        )
        cls.other_private_key = rsa.generate_private_key(
            public_exponent=65537, key_size=2048
        )
        cls.ec_private_key = ec.generate_private_key(ec.SECP256R1())
        cls.public_der = cls.private_key.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------
    def descriptor(self, public_der=None, **overrides):
        der = self.public_der if public_der is None else public_der
        value = {
            "protocolVersion": 1,
            "sessionID": SESSION_ID,
            "packageName": "com.floe.android.debug",
            "namespace": "provider.test",
            "reference": "openai.default",
            "expiresAtEpochMillis": FIXED_EXPIRY,
            "publicKeyDerBase64": base64.b64encode(der).decode("ascii"),
        }
        value.update(overrides)
        return value

    def aad(self, descriptor, version=1):
        output = bytearray(b"FLEN")
        output.append(version)
        for field in ("sessionID", "packageName", "namespace", "reference"):
            encoded = descriptor[field].encode("utf-8")
            output.extend(len(encoded).to_bytes(2, "big"))
            output.extend(encoded)
        output.extend(
            int(descriptor["expiresAtEpochMillis"]).to_bytes(
                8, "big", signed=False
            )
        )
        return bytes(output)

    def parse_envelope(self, blob):
        if len(blob) < sealer.MIN_SEALED_BYTES:
            raise ValueError("short envelope")
        if len(blob) > sealer.MAX_SEALED_BYTES:
            raise ValueError("oversize envelope")
        if blob[:4] != b"FLQE":
            raise ValueError("bad magic")
        if blob[4] != sealer.PROTOCOL_VERSION:
            raise ValueError("bad version")
        if blob[5] != 16:
            raise ValueError("bad session length")
        session_id = blob[6:22]
        if blob[22] != 12:
            raise ValueError("bad iv length")
        iv = blob[23:35]
        wrapped_length = int.from_bytes(blob[35:37], "big")
        if wrapped_length != 384:
            raise ValueError("bad wrapped length")
        wrapped_end = 37 + wrapped_length
        if len(blob) < wrapped_end + 16:
            raise ValueError("short ciphertext")
        wrapped_key = blob[37:wrapped_end]
        ciphertext = blob[wrapped_end:]
        return session_id, iv, wrapped_key, ciphertext

    def open_envelope(self, blob, private_key, aad):
        _session_id, iv, wrapped_key, ciphertext = self.parse_envelope(blob)
        aes_key = private_key.decrypt(wrapped_key, OAEP)
        self.assertEqual(len(aes_key), 32)
        return AESGCM(aes_key).decrypt(iv, ciphertext, aad)

    def assert_code(self, expected_code, function, *args):
        with self.assertRaises(sealer.SealError) as raised:
            function(*args)
        self.assertEqual(raised.exception.code, expected_code)
        self.assertEqual(str(raised.exception), expected_code)
        return raised.exception

    def write_descriptor(self, directory, descriptor, name="descriptor.json"):
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as stream:
            json.dump(descriptor, stream, separators=(",", ":"))
        return path

    def run_cli(self, arguments, input_bytes=b""):
        environment = dict(os.environ)
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        return subprocess.run(
            [sys.executable, str(SCRIPT)] + list(arguments),
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=90,
            check=False,
        )

    # ------------------------------------------------------------------
    # Wire contract and round trip
    # ------------------------------------------------------------------
    def test_constants_match_android_wire_contract(self):
        self.assertEqual(sealer.PROTOCOL_VERSION, 1)
        self.assertEqual(sealer.SESSION_ID_BYTES, 16)
        self.assertEqual(sealer.AES_KEY_BYTES, 32)
        self.assertEqual(sealer.AES_GCM_IV_BYTES, 12)
        self.assertEqual(sealer.GCM_TAG_BYTES, 16)
        self.assertEqual(sealer.RSA_KEY_BITS, 3072)
        self.assertEqual(sealer.RSA_WRAPPED_KEY_BYTES, 384)
        self.assertEqual(sealer.MAX_PAYLOAD_BYTES, 65_536)
        self.assertEqual(sealer.HEADER_AND_WRAPPED_BYTES, 421)
        self.assertEqual(sealer.MIN_SEALED_BYTES, 437)
        self.assertEqual(sealer.MAX_SEALED_BYTES, 65_973)

    def test_round_trip_and_exact_envelope_layout(self):
        descriptor = self.descriptor()
        payload = b"synthetic-payload-" + bytes(range(64))
        blob = sealer.seal(descriptor, payload)

        self.assertEqual(
            len(blob), 421 + len(payload) + 16
        )
        session_id, iv, wrapped_key, ciphertext = self.parse_envelope(blob)
        self.assertEqual(session_id, SESSION_ID_BYTES)
        self.assertEqual(len(iv), 12)
        self.assertEqual(len(wrapped_key), 384)
        self.assertEqual(len(ciphertext), len(payload) + 16)

        plaintext = self.open_envelope(blob, self.private_key, self.aad(descriptor))
        self.assertEqual(plaintext, payload)

    def test_aad_matches_literal_android_vector(self):
        descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
        expected_aad = (
            b"FLEN\x01"
            b"\x00\x20"
            + SESSION_ID.encode("ascii")
            + b"\x00\x16"
            + b"com.floe.android.debug"
            + b"\x00\x0d"
            + b"provider.test"
            + b"\x00\x0e"
            + b"openai.default"
            + FIXED_EXPIRY.to_bytes(8, "big")
        )
        self.assertEqual(len(expected_aad), 102)
        blob = sealer.seal(descriptor, b"synthetic-aad-vector")
        plaintext = self.open_envelope(blob, self.private_key, expected_aad)
        self.assertEqual(plaintext, b"synthetic-aad-vector")

    def test_empty_and_maximum_payload_bounds(self):
        descriptor = self.descriptor()
        maximum_payload = bytes(range(256)) * 256
        self.assertEqual(len(maximum_payload), MAX_PAYLOAD)

        for payload in (b"", maximum_payload):
            with self.subTest(size=len(payload)):
                blob = sealer.seal(descriptor, payload)
                self.assertEqual(len(blob), 437 + len(payload))
                self.assertEqual(
                    self.open_envelope(blob, self.private_key, self.aad(descriptor)),
                    payload,
                )

        self.assert_code(
            "payload_too_large",
            sealer.seal,
            descriptor,
            b"\x00" * (MAX_PAYLOAD + 1),
        )

    def test_seals_are_randomized(self):
        descriptor = self.descriptor()
        payload = b"synthetic-randomness"
        first = sealer.seal(descriptor, payload)
        second = sealer.seal(descriptor, payload)
        self.assertNotEqual(first, second)
        self.assertNotEqual(first[23:35], second[23:35])
        self.assertNotEqual(first[37:421], second[37:421])
        self.assertEqual(
            self.open_envelope(first, self.private_key, self.aad(descriptor)),
            payload,
        )
        self.assertEqual(
            self.open_envelope(second, self.private_key, self.aad(descriptor)),
            payload,
        )

    def test_allowed_identifier_alphabet_and_max_lengths(self):
        descriptor = self.descriptor(
            namespace="A" + "b" * 61 + "-_",
            reference="Z" + "a" * 125 + ":_",
        )
        self.assertEqual(len(descriptor["namespace"]), 64)
        self.assertEqual(len(descriptor["reference"]), 128)
        payload = b"synthetic-identifier-alphabet"
        blob = sealer.seal(descriptor, payload)
        self.assertEqual(
            self.open_envelope(blob, self.private_key, self.aad(descriptor)),
            payload,
        )

    def test_aad_binds_every_descriptor_field(self):
        descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
        payload = b"synthetic-field-binding"
        blob = sealer.seal(descriptor, payload)
        self.assertEqual(
            self.open_envelope(blob, self.private_key, self.aad(descriptor)),
            payload,
        )

        altered_values = (
            ("sessionID", "ffeeddccbbaa99887766554433221100"),
            ("packageName", "com.floe.android.other"),
            ("namespace", "provider.other"),
            ("reference", "openai.other"),
            ("expiresAtEpochMillis", FIXED_EXPIRY + 1),
        )
        for field, value in altered_values:
            with self.subTest(field=field):
                altered = dict(descriptor)
                altered[field] = value
                with self.assertRaises(InvalidTag):
                    self.open_envelope(blob, self.private_key, self.aad(altered))

        # Version is authenticated in AAD as well as parsed from the envelope.
        with self.assertRaises(InvalidTag):
            self.open_envelope(blob, self.private_key, self.aad(descriptor, version=2))

    def test_envelope_tamper_wrong_key_and_truncation(self):
        descriptor = self.descriptor()
        payload = b"synthetic-tamper-payload-0123456789"
        blob = sealer.seal(descriptor, payload)
        aad = self.aad(descriptor)

        # A one-bit change in IV, ciphertext or tag must fail GCM authentication.
        for name, offset in (
            ("iv", 23),
            ("ciphertext", 421),
            ("tag", len(blob) - 1),
        ):
            with self.subTest(name=name):
                tampered = bytearray(blob)
                tampered[offset] ^= 0x01
                with self.assertRaises(InvalidTag):
                    self.open_envelope(bytes(tampered), self.private_key, aad)

        # A wrapped-key change fails RSA-OAEP before GCM.
        tampered_wrapped = bytearray(blob)
        tampered_wrapped[37] ^= 0x01
        with self.assertRaises(ValueError):
            self.open_envelope(bytes(tampered_wrapped), self.private_key, aad)

        # Header fields and truncation are rejected structurally.
        for offset in (0, 4, 5, 22, 35):
            with self.subTest(header_offset=offset):
                tampered = bytearray(blob)
                tampered[offset] ^= 0x01
                with self.assertRaises(ValueError):
                    self.parse_envelope(bytes(tampered))
        with self.assertRaises(ValueError):
            self.parse_envelope(blob[:100])
        with self.assertRaises(InvalidTag):
            self.open_envelope(blob[:-1], self.private_key, aad)
        with self.assertRaises(InvalidTag):
            self.open_envelope(blob + b"\x00", self.private_key, aad)

        # A different private key cannot unwrap the AES key.
        with self.assertRaises(ValueError):
            self.open_envelope(blob, self.other_private_key, aad)

    def test_session_id_in_envelope_must_match_verifier_state(self):
        descriptor = self.descriptor()
        blob = bytearray(sealer.seal(descriptor, b"synthetic-session-binding"))
        blob[6] ^= 0x01
        tampered = bytes(blob)
        parsed_session = self.parse_envelope(tampered)[0]
        self.assertNotEqual(parsed_session, SESSION_ID_BYTES)

        # Android loads state by the envelope session id; the AAD then uses that
        # state's session string.  Simulate that verifier choice here.
        altered = dict(descriptor)
        altered["sessionID"] = parsed_session.hex()
        with self.assertRaises(InvalidTag):
            self.open_envelope(tampered, self.private_key, self.aad(altered))

    # ------------------------------------------------------------------
    # Descriptor and payload validation
    # ------------------------------------------------------------------
    def test_descriptor_and_payload_validation_codes(self):
        base = self.descriptor()
        trailing_der = self.public_der + b"\x00"
        ec_der = self.ec_private_key.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        other_der = self.other_private_key.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )

        def mutate(function):
            value = dict(base)
            function(value)
            return value

        cases = []
        cases.append(("missing field", mutate(lambda d: d.pop("namespace")), "descriptor_schema_invalid"))
        cases.append(("unknown field", mutate(lambda d: d.update({"extra": 1})), "descriptor_schema_invalid"))
        cases.append(("bool version", mutate(lambda d: d.update({"protocolVersion": True})), "invalid_protocol_version"))
        cases.append(("version 2", mutate(lambda d: d.update({"protocolVersion": 2})), "invalid_protocol_version"))
        cases.append(("uppercase session", mutate(lambda d: d.update({"sessionID": d["sessionID"].upper()})), "invalid_session_id"))
        cases.append(("short session", mutate(lambda d: d.update({"sessionID": d["sessionID"][:-1]})), "invalid_session_id"))
        cases.append(("nonhex session", mutate(lambda d: d.update({"sessionID": "g" * 32})), "invalid_session_id"))
        cases.append(("blank package", mutate(lambda d: d.update({"packageName": "   "})), "invalid_package_name"))
        cases.append(("long package", mutate(lambda d: d.update({"packageName": "x" * 257})), "invalid_package_name"))
        cases.append(("empty namespace", mutate(lambda d: d.update({"namespace": ""})), "invalid_namespace"))
        cases.append(("traversal namespace", mutate(lambda d: d.update({"namespace": "../evil"})), "invalid_namespace"))
        cases.append(("long namespace", mutate(lambda d: d.update({"namespace": "a" * 65})), "invalid_namespace"))
        cases.append(("empty reference", mutate(lambda d: d.update({"reference": ""})), "invalid_reference"))
        cases.append(("space reference", mutate(lambda d: d.update({"reference": "bad ref"})), "invalid_reference"))
        cases.append(("long reference", mutate(lambda d: d.update({"reference": "a" * 129})), "invalid_reference"))
        cases.append(("zero expiry", mutate(lambda d: d.update({"expiresAtEpochMillis": 0})), "invalid_expiry"))
        cases.append(("negative expiry", mutate(lambda d: d.update({"expiresAtEpochMillis": -1})), "invalid_expiry"))
        cases.append(("int64 overflow", mutate(lambda d: d.update({"expiresAtEpochMillis": 1 << 63})), "invalid_expiry"))
        cases.append(("float expiry", mutate(lambda d: d.update({"expiresAtEpochMillis": 1.0})), "invalid_expiry"))
        cases.append(("bool expiry", mutate(lambda d: d.update({"expiresAtEpochMillis": True})), "invalid_expiry"))
        cases.append(("empty key", mutate(lambda d: d.update({"publicKeyDerBase64": ""})), "invalid_public_key"))
        cases.append(("bad base64", mutate(lambda d: d.update({"publicKeyDerBase64": "not base64 " + SECRET_MARKER.decode()})), "invalid_public_key"))
        cases.append(("unpadded base64", mutate(lambda d: d.update({"publicKeyDerBase64": base64.b64encode(self.public_der).decode("ascii").rstrip("=")})), "invalid_public_key"))
        cases.append(("oversize der", mutate(lambda d: d.update({"publicKeyDerBase64": base64.b64encode(b"\x00" * 4097).decode("ascii")})), "invalid_public_key"))
        cases.append(("trailing der", mutate(lambda d: d.update({"publicKeyDerBase64": base64.b64encode(trailing_der).decode("ascii")})), "invalid_public_key"))
        cases.append(("ec key", mutate(lambda d: d.update({"publicKeyDerBase64": base64.b64encode(ec_der).decode("ascii")})), "invalid_public_key"))
        cases.append(("rsa 2048 key", mutate(lambda d: d.update({"publicKeyDerBase64": base64.b64encode(other_der).decode("ascii")})), "invalid_public_key_size"))

        for name, descriptor, expected in cases:
            with self.subTest(name=name):
                self.assert_code(expected, sealer.seal, descriptor, b"synthetic")

        expired = self.descriptor(expiresAtEpochMillis=int(time.time() * 1000) - 1)
        self.assert_code("descriptor_expired", sealer.seal, expired, b"synthetic")
        self.assert_code("descriptor_schema_invalid", sealer.seal, [], b"synthetic")
        self.assert_code("invalid_payload", sealer.seal, base, None)
        self.assert_code("invalid_payload", sealer.seal, base, "text")

    def test_seal_does_not_mutate_inputs_or_write_files(self):
        descriptor = self.descriptor()
        snapshot = copy.deepcopy(descriptor)
        payload = bytearray(b"synthetic-mutable-payload")
        payload_snapshot = bytes(payload)
        with tempfile.TemporaryDirectory() as directory:
            before = set(os.listdir(directory))
            previous = os.getcwd()
            try:
                os.chdir(directory)
                sealed = sealer.seal(descriptor, payload)
            finally:
                os.chdir(previous)
            self.assertEqual(set(os.listdir(directory)), before)
        self.assertEqual(descriptor, snapshot)
        self.assertEqual(payload, bytearray(payload_snapshot))
        self.assertEqual(len(sealed), 437 + len(payload_snapshot))

    # ------------------------------------------------------------------
    # CLI
    # ------------------------------------------------------------------
    def test_cli_stdin_to_binary_stdout(self):
        descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
        payload = SECRET_MARKER + b"-cli-stdin"
        with tempfile.TemporaryDirectory() as directory:
            path = self.write_descriptor(directory, descriptor)
            result = self.run_cli(["--descriptor", path], input_bytes=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout[:4], b"FLQE")
        self.assertEqual(len(result.stdout), 437 + len(payload))
        self.assertNotIn(payload, result.stdout)
        plaintext = self.open_envelope(
            result.stdout, self.private_key, self.aad(descriptor)
        )
        self.assertEqual(plaintext, payload)

    def test_cli_payload_fd_output_file_and_metadata(self):
        descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
        payload = SECRET_MARKER + b"-cli-fd"
        with tempfile.TemporaryDirectory() as directory:
            descriptor_path = self.write_descriptor(directory, descriptor)
            output_directory = os.path.join(directory, "out")
            os.mkdir(output_directory)
            output_path = os.path.join(output_directory, "sealed.bin")

            read_fd, write_fd = os.pipe()
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--descriptor",
                        descriptor_path,
                        "--payload-fd",
                        str(read_fd),
                        "--output",
                        output_path,
                        "--metadata",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    pass_fds=(read_fd,),
                    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                )
            finally:
                os.close(read_fd)
            try:
                os.write(write_fd, payload)
            finally:
                os.close(write_fd)
            stdout, stderr = process.communicate(timeout=90)

            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, b"")
            self.assertTrue(os.path.isfile(output_path))
            self.assertEqual(stat.S_IMODE(os.stat(output_path).st_mode), 0o600)
            with open(output_path, "rb") as stream:
                sealed = stream.read()
            self.assertEqual(len(sealed), 437 + len(payload))
            self.assertNotIn(payload, sealed)
            self.assertEqual(
                self.open_envelope(sealed, self.private_key, self.aad(descriptor)),
                payload,
            )
            self.assertEqual(os.listdir(output_directory), ["sealed.bin"])
            metadata = json.loads(stderr.decode("ascii"))
            self.assertEqual(metadata["protocolVersion"], 1)
            self.assertEqual(metadata["sessionID"], SESSION_ID)
            self.assertEqual(metadata["envelopeBytes"], len(sealed))
            self.assertEqual(
                metadata["envelopeSha256"], hashlib.sha256(sealed).hexdigest()
            )
            self.assertNotIn(SECRET_MARKER.decode(), stderr.decode("ascii"))

    def test_cli_fixed_errors_without_traceback_or_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            invalid_path = os.path.join(directory, "invalid.json")
            with open(invalid_path, "wb") as stream:
                stream.write(b"{")
            result = self.run_cli(["--descriptor", invalid_path], input_bytes=SECRET_MARKER)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_invalid_json", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)
            self.assertNotIn(SECRET_MARKER, result.stderr)

            valid_descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
            valid_path = self.write_descriptor(directory, valid_descriptor, "valid.json")
            result = self.run_cli(
                ["--descriptor", valid_path], input_bytes=b"x" * (MAX_PAYLOAD + 1)
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: payload_too_large", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)

            output_directory = os.path.join(directory, "not-a-file")
            os.mkdir(output_directory)
            result = self.run_cli(
                ["--descriptor", valid_path, "--output", output_directory],
                input_bytes=b"synthetic",
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: output_unavailable", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)

            missing = os.path.join(directory, "synthetic-missing-path.json")
            result = self.run_cli(["--descriptor", missing], input_bytes=b"synthetic")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_unreadable", result.stderr)
            self.assertNotIn(b"synthetic-missing-path", result.stderr)

            result = self.run_cli([], input_bytes=b"synthetic")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: usage_error", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)

            result = self.run_cli(
                ["--descriptor", valid_path, "--payload-fd=-1"],
                input_bytes=b"synthetic",
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: payload_unavailable", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)

            result = self.run_cli(
                [
                    "--descriptor",
                    valid_path,
                    "--payload",
                    SECRET_MARKER.decode("ascii"),
                ],
                input_bytes=b"",
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: usage_error", result.stderr)
            self.assertNotIn(SECRET_MARKER, result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)

    def test_cli_does_not_touch_output_on_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            expired = self.descriptor(
                expiresAtEpochMillis=int(time.time() * 1000) - 1
            )
            descriptor_path = self.write_descriptor(directory, expired)
            output_path = os.path.join(directory, "existing.bin")
            original = b"synthetic-existing-output"
            with open(output_path, "wb") as stream:
                stream.write(original)
            result = self.run_cli(
                ["--descriptor", descriptor_path, "--output", output_path],
                input_bytes=b"synthetic",
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_expired", result.stderr)
            with open(output_path, "rb") as stream:
                self.assertEqual(stream.read(), original)

    def test_cli_rejects_semantic_descriptor_before_payload_read(self):
        with tempfile.TemporaryDirectory() as directory:
            expired = self.descriptor(
                expiresAtEpochMillis=int(time.time() * 1000) - 1
            )
            descriptor_path = self.write_descriptor(directory, expired)
            read_fd, write_fd = os.pipe()
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(SCRIPT),
                        "--descriptor",
                        descriptor_path,
                        "--payload-fd",
                        str(read_fd),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    pass_fds=(read_fd,),
                    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                )
            finally:
                os.close(read_fd)
            try:
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.communicate()
                    self.fail("descriptor rejection waited for payload data")
            finally:
                os.close(write_fd)
            self.assertEqual(process.returncode, 2, stderr)
            self.assertEqual(stdout, b"")
            self.assertIn(b"error: descriptor_expired", stderr)
            self.assertNotIn(b"Traceback", stderr)

    def test_cli_descriptor_bounds_duplicates_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            descriptor = self.descriptor(expiresAtEpochMillis=FIXED_EXPIRY)
            raw = json.dumps(descriptor, separators=(",", ":")).encode("utf-8")
            duplicate = raw.replace(
                b'"namespace":"provider.test"',
                b'"namespace":"provider.test","namespace":"provider.other"',
                1,
            )
            duplicate_path = os.path.join(directory, "duplicate.json")
            with open(duplicate_path, "wb") as stream:
                stream.write(duplicate)
            result = self.run_cli(["--descriptor", duplicate_path], input_bytes=b"x")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_schema_invalid", result.stderr)

            list_path = os.path.join(directory, "list.json")
            with open(list_path, "wb") as stream:
                stream.write(b"[]")
            result = self.run_cli(["--descriptor", list_path], input_bytes=b"x")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_schema_invalid", result.stderr)

            invalid_utf8_path = os.path.join(directory, "invalid-utf8.json")
            with open(invalid_utf8_path, "wb") as stream:
                stream.write(b"\xff")
            result = self.run_cli(["--descriptor", invalid_utf8_path], input_bytes=b"x")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_invalid_json", result.stderr)

            oversize_path = os.path.join(directory, "oversize.json")
            with open(oversize_path, "wb") as stream:
                stream.write(b" " * (sealer.MAX_DESCRIPTOR_BYTES + 1))
            result = self.run_cli(["--descriptor", oversize_path], input_bytes=b"x")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_too_large", result.stderr)

            target_path = self.write_descriptor(directory, descriptor, "target.json")
            link_path = os.path.join(directory, "link.json")
            try:
                os.symlink(target_path, link_path)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks are not supported on this filesystem")
            result = self.run_cli(["--descriptor", link_path], input_bytes=b"x")
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"error: descriptor_unreadable", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
