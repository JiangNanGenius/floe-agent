#!/usr/bin/env python3
"""Additive environment capability and stable-vs-host-echo component contracts."""
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pipeline_contract

class EnvironmentCapabilityTests(unittest.TestCase):
    constants = {"runner_version": "2.1.0", "protocol": 3, "max_commands": 8, "max_sessions": 4}

    def test_source_constant_and_current_capability_rendering(self):
        payload = pipeline_contract.expected_caps(self.constants, net_status="up", env_status=1)
        self.assertEqual(payload, "runner=2.1.0 protocol=3 maxCommands=8 maxSessions=4 env=1 net=up")
        parsed = pipeline_contract.parse_caps(payload)
        self.assertEqual(parsed["env"], "1")
        self.assertEqual(parsed["payload"], payload)

    def test_old_manifest_payload_still_parses_without_claiming_environment_support(self):
        payload = pipeline_contract.expected_caps(self.constants, net_status="up")
        parsed = pipeline_contract.parse_caps(payload)
        self.assertIsNone(parsed["env"])
        self.assertEqual(parsed["payload"], payload)

    def test_host_echo_is_preserved_as_evidence_but_excluded_from_runner_identity(self):
        stable = pipeline_contract.expected_caps(self.constants, net_status="up", env_status=1)
        raw = stable + " hostArchive=fixture-host-advertisement"
        parsed = pipeline_contract.parse_caps(raw)
        self.assertEqual(parsed["payload"], stable)
        self.assertEqual(parsed["rawPayload"], raw)
        self.assertEqual(parsed["hostArchive"], "fixture-host-advertisement")

    def test_invalid_environment_values_never_satisfy_the_wire_contract(self):
        base = pipeline_contract.expected_caps(self.constants)
        for value in ("01", "10", "true", "yes", "-1"):
            self.assertIsNone(pipeline_contract.parse_caps(base + " env=" + value + " net=up"))
            with self.assertRaises(ValueError):
                pipeline_contract.expected_caps(self.constants, net_status="up", env_status=value)

    def test_actual_runner_source_emits_capability(self):
        source = Path(__file__).resolve().parents[2] / "LinuxGuest/runner/floe_exec.c"
        text = source.read_text()
        self.assertTrue(pipeline_contract.caps_env_field(text))
        self.assertFalse(pipeline_contract.caps_env_field(text.replace(" env=1", "")))

if __name__ == "__main__":
    unittest.main()
