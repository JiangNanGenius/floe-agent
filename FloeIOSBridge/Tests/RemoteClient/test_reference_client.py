#!/usr/bin/env python3
"""Contract tests for the stdlib reference client against the synthetic bridge."""
from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import mock_bridge  # noqa: E402

SPEC = importlib.util.spec_from_file_location(
    "floe_bridge_client", pathlib.Path(__file__).resolve().parents[2] / "scripts" / "RemoteClient" / "floe_bridge_client.py"
)
client = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = client
SPEC.loader.exec_module(client)


class Fixture:
    def __init__(self) -> None:
        self.state = mock_bridge.State(None)
        self.server = mock_bridge.Server(("127.0.0.1", 0), mock_bridge.Handler)
        self.server.state = self.state  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]
        self.endpoint = client.Endpoint("http", "127.0.0.1", self.port)

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class ReferenceClientTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="floe-client-test-"))
        self.client_path = self.tmp / "client.json"
        self.home = self.tmp / "home"
        self.home.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.fixture.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def pair(self) -> dict:
        return client.pair(self.fixture.endpoint, "unit-test", self.client_path, force=True, timeout=10)

    def record(self) -> dict:
        return client.load_client_file(self.client_path, self.fixture.endpoint)

    def test_envelope_and_crypto_vectors(self) -> None:
        key = bytes(range(32))
        nonce = bytes(range(16))
        body = b'{"id":1,"jsonrpc":"2.0","method":"device_info"}'
        envelope = client.seal_request(body, key, "630dcd29", nonce, 1700000000)
        self.assertEqual(envelope["ct"], "LBWCQvXPN3n1VJyojcZyCT+qamW0x3ZEeZftn9zQ5NohSRVhTnMrexYNVUnnbeo=")
        self.assertEqual(envelope["tag"], "59519f46ceec95fbc41aad96b85098cae37fc8e91f4f63b5228bcc672fb0d0fe")
        response = {
            "v": 1, "nonce": nonce.hex(),
            "ct": "LWca1EWiHk4JimI4eCduEwxp3qSclaRMXU5BQkcw6Yo8vWPtRDu1cZH3okaD",
            "tag": "d8c8bbce687a80a243893a2507821623f37b76d0abd24246c2e301a2b211fbc1",
        }
        self.assertEqual(client.open_response(response, key, nonce)["result"], {"ok": True})
        tampered = dict(response, tag="00" * 32)
        with self.assertRaises(client.ProtocolError):
            client.open_response(tampered, key, nonce)
        # X25519 RFC 7748 section 5.2.
        scalar = bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        u = bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        self.assertEqual(client.x25519(scalar, u).hex(),
                         "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        # Pair wrap vector checked independently against the mock/server formula.
        shared = bytes(range(32))
        client_pub = bytes(range(32, 64))
        device_pub = bytes(range(64, 96))
        token_ct = bytes(range(96, 128))
        wrap_key = client.hmac_sha256(shared, client.LABEL_PAIR + client_pub + device_pub)
        pad = client.hmac_sha256(wrap_key, client.LABEL_WRAP)
        expected = bytes(a ^ b for a, b in zip(token_ct, pad))
        self.assertEqual(expected.hex(), "9e03975ff2b31dc20854a2d9c6d6bcdb11f48dae2bd46249c2030f709f934636")

    def test_pair_and_contract_calls(self) -> None:
        record = self.pair()
        self.assertEqual(stat.S_IMODE(self.client_path.stat().st_mode), 0o600)
        self.assertEqual(client.token_id(record["_key"]), record["tok"])
        journal = client.Journal(client.default_journal_path(self.client_path))
        config = client.rpc_call(self.fixture.endpoint, self.record(), "config", {}, journal, timeout=10)
        self.assertEqual(config["engine"]["state"], "ready")
        info = client.rpc_call(self.fixture.endpoint, self.record(), "device_info", {}, journal, timeout=10)
        self.assertEqual(info["device_name"], "Floe Test iPhone")
        self.assertEqual((info["point_width"], info["point_height"]), (390, 844))
        tap = client.rpc_call(self.fixture.endpoint, self.record(), "tap", {"x": 12, "y": 34}, journal, timeout=10)
        self.assertEqual(tap["message"], "synthetic tap")
        calls = self.fixture.state.snapshot()["calls"]
        tap_calls = [entry for entry in calls if entry["method"] == "tap"]
        self.assertEqual(len(tap_calls), 1)
        self.assertTrue(tap_calls[0]["operation_id"])
        self.assertEqual(self.fixture.state.snapshot()["clients"][0]["client_name"], "unit-test")

    def test_type_text_not_in_journal(self) -> None:
        self.pair()
        journal = client.Journal(client.default_journal_path(self.client_path))
        text = "Hello 世界 & <b>not html</b>"
        client.rpc_call(self.fixture.endpoint, self.record(), "type",
                        {"text": text, "submit": True}, journal, timeout=10)
        raw = journal.path.read_bytes()
        self.assertNotIn(text.encode("utf-8"), raw)
        self.assertNotIn(b"Hello", raw)
        self.assertNotIn(b"params_sha256", raw)
        params_digest = hashlib.sha256(client._json_bytes({"text": text, "submit": True})).hexdigest()
        self.assertNotIn(params_digest.encode("ascii"), raw)
        self.assertNotIn(hashlib.sha256(text.encode("utf-8")).hexdigest().encode("ascii"), raw)
        # The textarea/CLI must clear locally; this is exercised in the CLI test.

    def test_unknown_outcome_single_dispatch(self) -> None:
        self.pair()
        with self.fixture.state.lock:
            self.fixture.state.modes["unknown_methods"] = ["tap"]
        journal = client.Journal(client.default_journal_path(self.client_path))
        with self.assertRaises(client.UnknownOutcome):
            client.rpc_call(self.fixture.endpoint, self.record(), "tap", {"x": 1, "y": 2}, journal, timeout=10)
        calls = self.fixture.state.snapshot()["calls"]
        self.assertEqual(len([entry for entry in calls if entry["method"] == "tap"]), 1)
        unknown = journal.unconfirmed()
        self.assertEqual(len(unknown), 1)
        self.assertEqual(unknown[0]["state"], "unknown")

    def test_network_drop_is_unknown_and_not_retried(self) -> None:
        self.pair()
        with self.fixture.state.lock:
            self.fixture.state.modes["drop_methods"] = ["tap"]
        journal = client.Journal(client.default_journal_path(self.client_path))
        with self.assertRaises(client.UnknownOutcome):
            client.rpc_call(self.fixture.endpoint, self.record(), "tap", {"x": 1, "y": 2}, journal, timeout=10)
        calls = self.fixture.state.snapshot()["calls"]
        self.assertEqual(len([entry for entry in calls if entry["method"] == "tap"]), 1)
        self.assertEqual(len(journal.unconfirmed()), 1)

    def test_engine_not_ready_and_method_unavailable_are_distinct(self) -> None:
        self.pair()
        journal = client.Journal(client.default_journal_path(self.client_path))
        with self.fixture.state.lock:
            self.fixture.state.modes["engine"] = "not_ready"
        with self.assertRaises(client.ClientError) as raised:
            client.rpc_call(self.fixture.endpoint, self.record(), "device_info", {}, journal, timeout=10)
        self.assertEqual(raised.exception.code, "engine_not_ready")
        # config remains service-level and works while the engine is down.
        config = client.rpc_call(self.fixture.endpoint, self.record(), "config", {}, journal, timeout=10)
        self.assertEqual(config["engine"]["state"], "not_ready")
        with self.fixture.state.lock:
            self.fixture.state.modes["engine"] = "ready"
            self.fixture.state.modes["unavailable_methods"] = ["tap"]
        with self.assertRaises(client.ClientError) as raised:
            client.rpc_call(self.fixture.endpoint, self.record(), "tap", {}, journal, timeout=10)
        self.assertEqual(raised.exception.code, "method_not_available")

    def test_auth_failure_preserves_file_for_explicit_recovery(self) -> None:
        self.pair()
        journal = client.Journal(client.default_journal_path(self.client_path))
        with self.fixture.state.lock:
            self.fixture.state.modes["auth_fail"] = True
        with self.assertRaises(client.AuthError):
            client.rpc_call(self.fixture.endpoint, self.record(), "config", {}, journal, timeout=10)
        self.assertTrue(self.client_path.exists())
        with self.fixture.state.lock:
            self.fixture.state.modes["auth_fail"] = False
        config = client.rpc_call(self.fixture.endpoint, self.record(), "config", {}, journal, timeout=10)
        self.assertEqual(config["engine"]["state"], "ready")

    def test_journal_write_failure_blocks_mutating_post(self) -> None:
        self.pair()
        blocking_path = self.tmp / "journal-is-a-directory"
        blocking_path.mkdir()
        journal = client.Journal(blocking_path)
        with self.assertRaises(client.JournalError):
            client.rpc_call(self.fixture.endpoint, self.record(), "tap", {"x": 1, "y": 2}, journal, timeout=10)
        calls = self.fixture.state.snapshot()["calls"]
        self.assertEqual([entry for entry in calls if entry["method"] == "tap"], [])

    def test_client_file_permissions_and_symlink(self) -> None:
        self.pair()
        os.chmod(self.client_path, 0o644)
        with self.assertRaises(client.AuthError):
            client.load_client_file(self.client_path, self.fixture.endpoint)
        os.chmod(self.client_path, 0o600)
        symlink = self.tmp / "symlink.json"
        symlink.symlink_to(self.client_path)
        with self.assertRaises(client.AuthError):
            client.load_client_file(symlink, self.fixture.endpoint)

    def test_plain_pairing_is_loopback_only(self) -> None:
        with self.assertRaises(client.UsageError):
            client.pair(client.Endpoint("http", "192.0.2.1", 8200), "plain", self.client_path,
                        plain=True, force=True, timeout=1)
        # The mock does support a plain loopback grant; the shipped client
        # prefers X25519 but retains this legacy path for loopback.
        record = client.pair(self.fixture.endpoint, "plain-test", self.client_path, plain=True, force=True, timeout=10)
        self.assertEqual(record["mode"], "plain")
        self.assertEqual(stat.S_IMODE(self.client_path.stat().st_mode), 0o600)

    def test_screenshot_and_stream_files_are_private(self) -> None:
        self.pair()
        with self.fixture.state.lock:
            self.fixture.state.video_bytes = b"\x00" * 512
            self.fixture.state.modes["stream"] = True
        shot_path = self.tmp / "shot.png"
        args = type("Args", (), {"path": str(shot_path), "format": "png", "scale": 1.0, "quality": 0.5,
                                 "timeout": 10, "allow_endpoint_change": False})()
        self.assertEqual(client.cmd_shot(args, self.fixture.endpoint, self.client_path), 0)
        self.assertEqual(stat.S_IMODE(shot_path.stat().st_mode), 0o600)
        stream_path = self.tmp / "stream.bin"
        stream_args = type("Args", (), {"path": str(stream_path), "seconds": 1.0, "max_bytes": 4096,
                                        "timeout": 10, "allow_endpoint_change": False})()
        self.assertEqual(client.cmd_stream(stream_args, self.fixture.endpoint, self.client_path), 0)
        self.assertEqual(stat.S_IMODE(stream_path.stat().st_mode), 0o600)
        self.assertTrue(stream_path.read_bytes())
        state = self.fixture.state.snapshot()
        ticket = state["tickets"][0]["ticket"]
        status, _headers, data = client.http_request(
            self.fixture.endpoint, "GET", "/stream?ticket=" + ticket, timeout=5, max_bytes=4096)
        self.assertEqual(status, 401)
        self.assertIn("unauthorized", data.decode("utf-8"))

    def test_ticket_redaction_and_status_are_read_only(self) -> None:
        self.pair()
        journal = client.Journal(client.default_journal_path(self.client_path))
        ticket_result = client.rpc_call(self.fixture.endpoint, self.record(), "stream_ticket", {}, journal, timeout=10)
        self.assertIn("ticket", ticket_result)
        redacted = json.dumps(client.sanitize_output(ticket_result))
        self.assertNotIn(ticket_result["ticket"], redacted)
        before = [entry for entry in self.fixture.state.snapshot()["calls"] if entry["method"] not in ("config", "logs", "stream_ticket")]
        result = client.run_status(self.fixture.endpoint, self.client_path, timeout=10)
        self.assertIsNotNone(result.get("client"))
        after = [entry for entry in self.fixture.state.snapshot()["calls"] if entry["method"] not in ("config", "logs", "stream_ticket")]
        self.assertEqual(before, after)
        self.assertNotIn(str(self.record()["_key"].hex()), json.dumps(result))

    def test_cli_pair_type_and_help(self) -> None:
        env = dict(os.environ, HOME=str(self.home))
        script = str(pathlib.Path(__file__).resolve().parents[2] / "scripts" / "RemoteClient" / "floe_bridge_client.py")
        pair = subprocess.run(
            [sys.executable, script, "--host", "127.0.0.1:%d" % self.fixture.port,
             "--client-file", str(self.client_path), "pair", "--name", "cli-test"],
            env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(pair.returncode, 0, pair.stderr)
        key = self.record()["_key"].hex()
        self.assertNotIn(key, pair.stdout)
        self.assertNotIn(key, pair.stderr)
        text = "CLI 世界 & <tag>"
        typed = subprocess.run(
            [sys.executable, script, "--host", "127.0.0.1:%d" % self.fixture.port,
             "--client-file", str(self.client_path), "type", "--submit"],
            env=env, input=text, capture_output=True, text=True, timeout=30)
        self.assertEqual(typed.returncode, 0, typed.stderr)
        self.assertNotIn(text, typed.stdout)
        self.assertNotIn(text, typed.stderr)
        self.assertNotIn(text, self.client_path.read_text(encoding="utf-8"))
        journal = client.default_journal_path(self.client_path).read_text(encoding="utf-8")
        self.assertNotIn(text, journal)
        self.assertNotIn("params_sha256", journal)
        self.assertNotIn(key, journal)
        help_result = subprocess.run([sys.executable, script, "--help"], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("pair", help_result.stdout)


    def test_ipv6_loopback_contract(self) -> None:
        import socket
        class Server6(mock_bridge.Server):
            address_family = socket.AF_INET6
        state = mock_bridge.State(None)
        try:
            server = Server6(("::1", 0), mock_bridge.Handler)
        except OSError as error:
            self.skipTest("IPv6 loopback unavailable: %s" % error)
        server.state = state  # type: ignore[attr-defined]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            endpoint = client.Endpoint("http", "::1", port)
            path = self.tmp / "ipv6-client.json"
            record = client.pair(endpoint, "ipv6-test", path, force=True, timeout=10)
            journal = client.Journal(client.default_journal_path(path))
            info = client.rpc_call(endpoint, record, "device_info", {}, journal, timeout=10)
            self.assertEqual(info["device_name"], "Floe Test iPhone")
            self.assertEqual(client.parse_endpoint("[::1]:%d" % port).origin,
                             "http://[::1]:%d" % port)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


    def test_forget_is_local_only(self) -> None:
        self.pair()
        self.assertTrue(self.client_path.exists())
        args = type("Args", (), {"yes": True})()
        self.assertEqual(client.cmd_forget(args, self.fixture.endpoint, self.client_path), 0)
        self.assertFalse(self.client_path.exists())
        # Local deletion does not revoke the paired client on the device.
        self.assertEqual(len(self.fixture.state.snapshot()["clients"]), 1)

    def test_explicit_client_file_is_bound_to_origin(self) -> None:
        self.pair()
        other = client.Endpoint("http", "127.0.0.1", self.fixture.port + 1)
        with self.assertRaises(client.AuthError):
            client.load_client_file(self.client_path, other)
        record = client.load_client_file(self.client_path, other, allow_endpoint_change=True)
        self.assertEqual(record["endpoint"], self.fixture.endpoint.origin)


    def test_call_type_refuses_argv_text(self) -> None:
        self.pair()
        args = type("Args", (), {"method": "type", "params": '{"text":"arg-secret"}',
                                 "json": False, "operation_id": None, "timeout": 10,
                                 "allow_endpoint_change": False})()
        with self.assertRaises(client.UsageError):
            client.cmd_call(args, self.fixture.endpoint, self.client_path)
        self.assertEqual([c for c in self.fixture.state.snapshot()["calls"] if c["method"] == "type"], [])

    def test_endpoint_parsing(self) -> None:
        self.assertEqual(client.parse_endpoint("127.0.0.1:8200").origin, "http://127.0.0.1:8200")
        self.assertEqual(client.parse_endpoint("[::1]:8200").origin, "http://[::1]:8200")
        self.assertTrue(client.parse_endpoint("[::1]:8200").is_loopback)
        with self.assertRaises(client.UsageError):
            client.parse_endpoint("https://127.0.0.1:8200")
        with self.assertRaises(client.UsageError):
            client.parse_endpoint("http://127.0.0.1:8200/path")


if __name__ == "__main__":
    unittest.main(verbosity=2)
