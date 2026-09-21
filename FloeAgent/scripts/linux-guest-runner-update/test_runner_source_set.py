#!/usr/bin/env python3
"""Unit tests for the complete runner source-set contract.

Every runner-owned header that floe_exec.c quotes-includes (floe_clock.h,
floe_net.h, ...) participates in the static riscv64 build and must therefore be
covered by runner-source-sha256.txt, the LGPL-2.1 relink archive and the
source offer. These tests pin the derivation logic in pipeline_contract that
keeps those artifacts in sync.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_contract  # noqa: E402


class RunnerSourceSetTests(unittest.TestCase):
    def test_includes_discover_quoted_headers_only(self):
        source = (
            '#include "floe_clock.h"\n'
            '# include "floe_net.h"\n'
            '#include <stdio.h>\n'
            '// #include "not_a_real_include.h"\n'
        )
        self.assertEqual(pipeline_contract.local_includes(source),
                         ["floe_clock.h", "floe_net.h"])

    def test_source_set_order_is_c_plus_headers_plus_makefile(self):
        source = '#include "floe_net.h"\n#include "floe_clock.h"\n'
        self.assertEqual(
            pipeline_contract.runner_source_set(source),
            ("floe_exec.c", "floe_clock.h", "floe_net.h", "Makefile"))

    def test_omitting_a_participating_header_shrinks_the_set(self):
        with_net = pipeline_contract.runner_source_set('#include "floe_net.h"\n')
        without_net = pipeline_contract.runner_source_set("")
        self.assertIn("floe_net.h", with_net)
        self.assertNotIn("floe_net.h", without_net)

    def test_source_sha256_record_parses_paths_to_basenames(self):
        record = pipeline_contract.parse_source_sha256_record(
            ("a" * 64) + "  floe_exec.c\n"
            + ("b" * 64) + "  /build/out/floe_net.h\n"
            + "not-a-digest  junk.txt\n")
        self.assertEqual(record, {"floe_exec.c": "a" * 64, "floe_net.h": "b" * 64})


if __name__ == "__main__":
    unittest.main()
