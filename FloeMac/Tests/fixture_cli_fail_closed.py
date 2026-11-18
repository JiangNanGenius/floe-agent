#!/usr/bin/env python3
"""Exercise only the rejected fixture CLI, using entirely synthetic paths.

Usage: python3 FloeMac/Tests/fixture_cli_fail_closed.py /path/to/FloeMacBridgeService
The helper must exit before starting a server or writing any fixture data.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile


def exercise(binary: Path, base: Path, symlinked: bool) -> None:
    fixture = base / ("linked" if symlinked else "ordinary")
    control = fixture / "Control"
    worker = fixture / "worker-home"
    home = fixture / "service-home"
    victim = base / ("victim-linked" if symlinked else "victim-ordinary")
    for directory in (control, worker, home, victim / "Floe Bridge" / "State"):
        directory.mkdir(parents=True, exist_ok=True)
    pair = victim / "Floe Bridge" / "State" / "paired-clients.json"
    original = b'{"synthetic-sentinel": true}\n'
    pair.write_bytes(original)
    ready_target = victim / "ready-sentinel.json"
    ready_target.write_bytes(b"synthetic-ready-sentinel\n")
    (control / "ready.json").symlink_to(ready_target)
    if symlinked:
        library = home / "Library"
        library.mkdir()
        (library / "Application Support").symlink_to(victim, target_is_directory=True)
    before = {str(p.relative_to(base)) for p in base.rglob("*")}
    environment = dict(os.environ, HOME=str(worker), CFFIXED_USER_HOME=str(worker))
    command = [str(binary), "--mode", "test", "--test-fixture", str(fixture),
               "--control-socket", str(control / "control.sock"),
               "--ready-file", str(control / "ready.json"),
               "--discovery-file", str(control / "discovery.json"),
               "--probe-client-key", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="]
    for suffix in ([], ["--mode", "production"], ["--identity-and-permissions-check"]):
        result = subprocess.run(command + suffix, env=environment, capture_output=True, timeout=5)
        if result.returncode != 2:
            raise AssertionError(f"fixture CLI unexpectedly accepted startup: {result.returncode}")
        if b"Fixture service startup is disabled" not in result.stderr:
            raise AssertionError(f"fixture did not reach the intended refusal: {result.stderr!r}")
    if pair.read_bytes() != original:
        raise AssertionError("synthetic target pairing store was modified")
    if ready_target.read_bytes() != b"synthetic-ready-sentinel\n" or not (control / "ready.json").is_symlink():
        raise AssertionError("synthetic ready-file target or link was modified")
    after = {str(p.relative_to(base)) for p in base.rglob("*")}
    if after != before:
        raise AssertionError(f"fixture refusal created or removed paths: {after ^ before}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    binary = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="floe-fixture-guard-") as directory:
        # Foundation normalizes the system /private/var alias back to /var
        # on this host. Keep tempfile's spelling to match the CLI validator.
        base = Path(directory)
        exercise(binary, base, symlinked=False)
        exercise(binary, base, symlinked=True)
    print("PASS: ordinary and ancestor-symlink fixtures rejected without writes")


if __name__ == "__main__":
    main()
