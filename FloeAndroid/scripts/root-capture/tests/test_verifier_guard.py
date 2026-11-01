#!/usr/bin/env python3
"""Guard-binding tests for the root-capture helper verifier/stager.

These tests do not build or inspect a real helper ELF. They exercise the pure
identity parser and manifest guard validator that make an old unguarded helper
unacceptable to the staging path.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
import types


def load_module(path: str, name: str) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def expect_failure(module: types.ModuleType, data: bytes, label: str) -> None:
    try:
        module.parse_guard_identity(data)
    except module.VerificationError:
        return
    raise AssertionError(f"{label}: parser accepted invalid identity")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-script", required=True)
    parser.add_argument("--stage-script", required=True)
    parser.add_argument("--guard-source", required=True)
    parser.add_argument("--guard-header", required=True)
    parser.add_argument("--guard-patch", required=True)
    args = parser.parse_args()

    verify = load_module(args.verify_script, "floe_verify_helper")
    # Importing the stager verifies its constants and syntax; its main() needs a
    # real repo tree, which source lanes intentionally do not stage.
    load_module(args.stage_script, "floe_stage_helper")

    record = (
        "FLOE_CAPTURE_GUARD_V1|arm64-v8a|1|"
        f"{args.guard_source}|{args.guard_header}|{args.guard_patch}"
    )
    blob = b"\x7fELF-ish padding\x00" + record.encode("ascii") + b"\x00trailing"
    parsed = verify.parse_guard_identity(blob)
    assert parsed["schema"] == "floe.capture-guard.v1", parsed
    assert parsed["abi"] == "arm64-v8a", parsed
    assert parsed["sourceSha256"] == args.guard_source, parsed
    assert parsed["headerSha256"] == args.guard_header, parsed
    assert parsed["patchSha256"] == args.guard_patch, parsed

    expect_failure(verify, b"no guard marker here", "missing")
    expect_failure(verify, (record + "\x00" + record).encode(), "duplicate")
    expect_failure(
        verify,
        (
            "FLOE_CAPTURE_GUARD_V1|x86_64|1|"
            f"{args.guard_source}|{args.guard_header}|{args.guard_patch}"
        ).encode(),
        "wrong abi",
    )
    expect_failure(
        verify,
        (
            "FLOE_CAPTURE_GUARD_V1|arm64-v8a|2|"
            f"{args.guard_source}|{args.guard_header}|{args.guard_patch}"
        ).encode(),
        "wrong version",
    )
    expect_failure(
        verify,
        (
            "FLOE_CAPTURE_GUARD_V1|arm64-v8a|1|"
            f"{'0' * 63}|{args.guard_header}|{args.guard_patch}"
        ).encode(),
        "short source hash",
    )

    valid_guard = {
        "schema": "floe.capture-guard.v1",
        "version": "1",
        "abi": "arm64-v8a",
        "sourceSha256": args.guard_source,
        "headerSha256": args.guard_header,
        "patchSha256": args.guard_patch,
    }
    assert verify.guard_problem(valid_guard) is None
    assert verify.guard_problem(None) is not None
    assert verify.guard_problem({**valid_guard, "schema": "other"}) is not None
    assert verify.guard_problem({**valid_guard, "patchSha256": "x"}) is not None
    assert verify.EXPECTED_SCHEMA == "floe.root-capture-helper.v2"

    print("verifier guard binding: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
