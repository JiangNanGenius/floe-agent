#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Bounded subprocess runner: hard deadline so a real native deadlock fails
# with logs instead of occupying the shared window (added 2026-11-11 after
# the cancel-test deadlock; see coord/cancel-hang-01 and
# host/evidence/stage2/attempts/attempt-11-full).
# usage: run_bounded.sh <seconds> <command...>
# Exit codes: child status, or 124 when the deadline killed it.
set -eu
exec python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

deadline = float(sys.argv[1])
if deadline <= 0 or len(sys.argv) < 3:
    raise SystemExit('usage: run_bounded.sh <positive seconds> <command...>')

child = subprocess.Popen(sys.argv[2:], start_new_session=True)

def stop_group(sig):
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass

def interrupted(signum, _frame):
    raise InterruptedError(signum)

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
code = 125
try:
    code = child.wait(timeout=deadline)
    if code < 0:
        code = 128 - code
except subprocess.TimeoutExpired:
    print(f'run_bounded: DEADLINE {deadline:g}s exceeded; stopping owned group {child.pid}', file=sys.stderr)
    code = 124
except InterruptedError as error:
    code = 128 + error.args[0]
finally:
    # Also remove descendants if the direct child returned before they did.
    stop_group(signal.SIGTERM)
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        stop_group(signal.SIGKILL)
        child.wait(timeout=5)
    stop_group(signal.SIGKILL)
raise SystemExit(code)
PY
