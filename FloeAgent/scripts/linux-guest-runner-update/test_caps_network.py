#!/usr/bin/env python3
"""Unit tests for the first-boot network field in the runner CAPS contract.

The component boot gate accepts the runner's `net=up|partial|down` field
instead of assuming the slirp device works. These tests pin the parser, the
source-derived field discovery and the workflow `--net` guard that failed
open in run 35645930554 (the component boot was invoked without the network
switch, so the guest had no eth0).
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_contract  # noqa: E402

CAPS = {
    "runner_version": "2.0.0",
    "protocol": 3,
    "max_commands": 8,
    "max_sessions": 4,
}

EMIT_NET = ('snprintf(buf, sizeof buf, "\\x1e" "FLOE-CAPS %s runner=%s protocol=%d '
            'maxCommands=%d maxSessions=%d net=%s\\x1e",')
EMIT_NO_NET = ('snprintf(buf, sizeof buf, "\\x1e" "FLOE-CAPS %s runner=%s protocol=%d '
               'maxCommands=%d maxSessions=%d\\x1e",')


class CapsNetworkTests(unittest.TestCase):
    def test_payload_with_the_network_field_round_trips(self):
        payload = pipeline_contract.expected_caps(CAPS, net_status="up")
        self.assertEqual(payload,
                         "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=up")
        parsed = pipeline_contract.parse_caps(payload)
        self.assertEqual(parsed["net"], "up")
        self.assertEqual(parsed["protocol"], 3)
        self.assertEqual(parsed["maxCommands"], 8)
        self.assertEqual(parsed["maxSessions"], 4)

    def test_each_state_parses_and_an_unknown_state_does_not(self):
        for state in pipeline_contract.CAPS_NET_STATUSES:
            parsed = pipeline_contract.parse_caps(
                "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=" + state)
            self.assertEqual(parsed["net"], state)
        self.assertIsNone(
            pipeline_contract.parse_caps(
                "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=degraded"))
        with self.assertRaises(ValueError):
            pipeline_contract.expected_caps(CAPS, net_status="degraded")

    def test_a_pre_network_payload_still_parses_without_a_claim(self):
        payload = pipeline_contract.expected_caps(CAPS)
        self.assertEqual(payload,
                         "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4")
        parsed = pipeline_contract.parse_caps(payload)
        self.assertIsNone(parsed["net"])

    def test_payloads_with_extra_or_missing_fields_do_not_parse(self):
        base = "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4"
        self.assertIsNone(pipeline_contract.parse_caps(base + " net=up extra"))
        self.assertIsNone(pipeline_contract.parse_caps("runner=2.0.0 protocol=3 "
                                                        "maxCommands=8"))

    def test_source_discovery_finds_only_the_real_emit_slot(self):
        self.assertTrue(pipeline_contract.caps_net_field(EMIT_NET))
        self.assertFalse(pipeline_contract.caps_net_field(EMIT_NO_NET))
        self.assertFalse(pipeline_contract.caps_net_field(
            '/* FLOE-CAPS payload ends with maxSessions=%d; net= reported elsewhere */'))


class WorkflowNetworkGuardTests(unittest.TestCase):
    HOST_LINE = 'timeout 420 "$RUNNER_TEMP/tinyemu-build/floe_vm_host" \\'

    def test_argument_line_satisfies_the_guard(self):
        workflow = self.HOST_LINE + "\n  --bios b \\\n  --net \\\n  --disk d\n"
        self.assertTrue(pipeline_contract.workflow_enables_guest_network(workflow))

    def test_inline_flag_satisfies_the_guard(self):
        workflow = self.HOST_LINE + "\n  --bios b --net \\\n"
        self.assertTrue(pipeline_contract.workflow_enables_guest_network(workflow))

    def test_missing_flag_fails_the_guard(self):
        workflow = self.HOST_LINE + "\n  --bios b \\\n  --disk d\n"
        self.assertFalse(pipeline_contract.workflow_enables_guest_network(workflow))

    def test_a_comment_mentioning_the_flag_is_not_enough(self):
        workflow = ("# the host must be started like floe_vm_host --net, see the\n"
                    + self.HOST_LINE + "\n  --bios b\n")
        self.assertFalse(pipeline_contract.workflow_enables_guest_network(workflow))

    def test_text_without_a_boot_command_is_rejected(self):
        self.assertFalse(pipeline_contract.workflow_enables_guest_network(
            "floe_vm_host --net appears nowhere as a command"))


class AdapterMacTests(unittest.TestCase):
    SOURCE = (
        "net->mac_addr[0] = 0x02;\n"
        "net->mac_addr[1] = 0x00;\n"
        "net->mac_addr[2] = 0x00;\n"
        "net->mac_addr[3] = 0x00;\n"
        "net->mac_addr[4] = 0x00;\n"
        "net->mac_addr[5] = 0x01;\n")

    def test_mac_is_parsed_from_the_six_assignments(self):
        self.assertEqual(
            pipeline_contract.adapter_guest_mac(self.SOURCE),
            "02:00:00:00:00:01")

    def test_hex_bytes_are_lowercased(self):
        self.assertEqual(
            pipeline_contract.adapter_guest_mac(self.SOURCE.replace("0x02", "0x0A")),
            "0a:00:00:00:00:01")

    def test_a_missing_assignment_returns_none(self):
        self.assertIsNone(
            pipeline_contract.adapter_guest_mac(self.SOURCE.replace("mac_addr[5]", "mac_addr[6]")))
        self.assertIsNone(pipeline_contract.adapter_guest_mac(""))


if __name__ == "__main__":
    unittest.main()
