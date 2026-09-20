#!/usr/bin/env bash
# host_protocol_check.sh — minimal real-chain check for the Floe Linux guest
# runner (FloeAgent/LinuxGuest/runner/floe_exec.c).
#
# Builds the runner for the current host, extracts the *real* host framing
# code (enum LinuxGuestFraming) from
# FloeExecution/Linux/LinuxGuestCommandChannel.swift, and drives the runner
# through real stdio: argv escaping, stdin/cwd, stdout/stderr split, exit
# codes, cancellation and channel reuse. This is not guest-image
# qualification; the same harness can run on Linux CI.
#
# Usage: bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
# Env:
#   FLOE_GUEST_TEST_SCRATCH  scratch dir (default: mktemp under $TMPDIR)
#   FLOE_GUEST_KEEP_SCRATCH  1 = keep the scratch dir (artifacts stay)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest_root="$(cd "$here/.." && pwd)"
runner_src="$guest_root/runner/floe_exec.c"
framing_src="$guest_root/../Sources/FloeExecution/Linux/LinuxGuestCommandChannel.swift"

if [ ! -f "$runner_src" ]; then
  echo "missing runner source: $runner_src" >&2
  exit 2
fi
if [ ! -f "$framing_src" ]; then
  echo "missing host framing source: $framing_src" >&2
  exit 2
fi

if [ -n "${FLOE_GUEST_TEST_SCRATCH:-}" ]; then
  scratch="$FLOE_GUEST_TEST_SCRATCH"
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/floe-guest-check.XXXXXX")"
  trap 'if [ "${FLOE_GUEST_KEEP_SCRATCH:-0}" != "1" ]; then rm -rf "$scratch"; fi' EXIT
fi

cc_bin="${CC:-cc}"
echo "==> building runner for this host with $cc_bin"
"$cc_bin" -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
  -o "$scratch/floe-exec" "$runner_src"

echo "==> extracting LinuxGuestFraming from $framing_src"
{
  echo "import Foundation"
  # The enum is self-contained: from its declaration to the first column-0
  # closing brace in the file (inner declarations are indented).
  sed -n '/^enum LinuxGuestFraming {/,/^}$/p' "$framing_src"
} > "$scratch/LinuxGuestFraming.swift"
if ! grep -q 'static func execEnvelope' "$scratch/LinuxGuestFraming.swift"; then
  echo "failed to extract LinuxGuestFraming (source moved?)" >&2
  exit 2
fi

echo "==> compiling host harness with swiftc"
swiftc -O -o "$scratch/host-protocol-check" \
  "$here/HostProtocolCheck.swift" "$scratch/LinuxGuestFraming.swift"

echo "==> running real stdio checks"
"$scratch/host-protocol-check" "$scratch/floe-exec"
echo "==> host protocol check passed"
