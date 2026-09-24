#!/usr/bin/env bash
# host_protocol_check.sh — minimal real-chain check for the Floe Linux guest
# runner (FloeAgent/LinuxGuest/runner/floe_exec.c) and the host transport.
#
# Two binaries are built and run:
#
#   1. host-protocol-check — builds the runner for the current host, extracts
#      the *real* host framing code (enum LinuxGuestFraming) from
#      FloeExecution/Linux/LinuxGuestCommandChannel.swift, and drives the
#      runner through real stdio: argv escaping, stdin/cwd, stdout/stderr
#      split, exit codes, concurrency, targeted cancellation and channel
#      reuse.
#
#   2. channel-router-check — compiles the *whole production channel*
#      (LinuxGuestCommandChannel.swift plus its real supporting types,
#      extracted verbatim from the module sources) against a scripted
#      LinuxGuestConsoleTransport and exercises the real actor: HELLO/CAPS
#      negotiation, token routing, raw 0x1e/newline preservation, interleaved
#      commands, interrupt bookkeeping and PTY sessions. It also typechecks
#      the extracted production module under -swift-version 6.
#
# This is not guest-image qualification; it proves the wire format and the
# process semantics on both sides of the contract. The same harness can run
# on Linux CI.
#
# Usage: bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
# Env:
#   FLOE_GUEST_TEST_SCRATCH  scratch dir (default: mktemp under $TMPDIR)
#   FLOE_GUEST_KEEP_SCRATCH  1 = keep the scratch dir (artifacts stay)
#   FLOE_GUEST_SKIP_SWIFT6   1 = skip the -swift-version 6 typecheck
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guest_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$guest_root/.." && pwd)"
runner_src="$guest_root/runner/floe_exec.c"
framing_src="$guest_root/../Sources/FloeExecution/Linux/LinuxGuestCommandChannel.swift"
service_src="$guest_root/../Sources/FloeExecution/Linux/LinuxGuestService.swift"
error_src="$guest_root/../Sources/FloeCore/FloeError.swift"
token_src="$guest_root/../Sources/FloeTools/ToolContext.swift"
result_src="$guest_root/../Sources/FloeExecution/Packages/LinuxCommandService.swift"
runtime_src="$guest_root/../Sources/FloeExecution/Linux/TinyEMUGuestRuntime.swift"
resource_shape_src="$guest_root/../Sources/FloeExecution/ResourcePolicy/GuestResourceShape.swift"
runtime_stub_dir="$here/runtime_stub"

for source in "$runner_src" "$framing_src" "$service_src" "$error_src" "$token_src" "$result_src" "$runtime_src" "$resource_shape_src"; do
  if [ ! -f "$source" ]; then
    echo "missing source: $source" >&2
    exit 2
  fi
done

if [ -n "${FLOE_GUEST_TEST_SCRATCH:-}" ]; then
  scratch="$FLOE_GUEST_TEST_SCRATCH"
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/floe-guest-check.XXXXXX")"
  trap 'if [ "${FLOE_GUEST_KEEP_SCRATCH:-0}" != "1" ]; then rm -rf "$scratch"; fi' EXIT
fi

# The enum is self-contained: from its declaration to the first column-0
# closing brace in the file (inner declarations are indented).
extract_framing() {
  {
    echo "import Foundation"
    sed -n '/^enum LinuxGuestFraming {/,/^}$/p' "$framing_src"
  } > "$scratch/LinuxGuestFraming.swift"
  if ! grep -q 'static func execEnvelope' "$scratch/LinuxGuestFraming.swift"; then
    echo "failed to extract LinuxGuestFraming (source moved?)" >&2
    exit 2
  fi
}

# The whole production channel file plus the real supporting declarations it
# needs (imports stripped: the extracted file is compiled as its own module).
extract_channel_module() {
  {
    echo "import Foundation"
    sed -n '/^public enum FloeError/,/^}$/p' "$error_src"
    sed -n '/^public final class CancellationToken/,/^}$/p' "$token_src"
    sed -n '/^public struct LinuxCommandResult/,/^}$/p' "$result_src"
    sed -n '/^public enum LinuxGuestError/,/^}$/p' "$service_src"
    sed -n '/^public struct LinuxGuestLimits/,/^}$/p' "$service_src"
    sed -n '/^public protocol LinuxGuestConsoleTransport/,/^}$/p' "$service_src"
    grep -v '^import FloeCore$' "$framing_src" | grep -v '^import FloeTools$'
  } > "$scratch/GuestChannelModule.swift"
  if ! grep -q 'public actor LinuxGuestCommandChannel' "$scratch/GuestChannelModule.swift"; then
    echo "failed to extract LinuxGuestCommandChannel (source moved?)" >&2
    exit 2
  fi
  if ! grep -q 'public actor LinuxGuestInteractiveSession' "$scratch/GuestChannelModule.swift"; then
    echo "failed to extract LinuxGuestInteractiveSession (source moved?)" >&2
    exit 2
  fi
}

cc_bin="${CC:-cc}"
echo "==> building runner for this host with $cc_bin"
"$cc_bin" -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
  -o "$scratch/floe-exec" "$runner_src"

echo "==> extracting LinuxGuestFraming from $framing_src"
extract_framing

echo "==> compiling host harness with swiftc"
swiftc -O -o "$scratch/host-protocol-check" \
  "$here/HostProtocolCheck.swift" "$scratch/LinuxGuestFraming.swift"

echo "==> running real stdio checks"
"$scratch/host-protocol-check" "$scratch/floe-exec"

echo "==> extracting production channel module"
extract_channel_module

if [ "${FLOE_GUEST_SKIP_SWIFT6:-0}" != "1" ]; then
  echo "==> strict typecheck (swift-version 6) of the production channel module"
  swiftc -swift-version 6 -typecheck "$scratch/GuestChannelModule.swift"
fi

echo "==> compiling channel/router harness with swiftc"
swiftc -O -swift-version 6 -o "$scratch/channel-router-check" \
  "$here/ChannelRouterCheck.swift" "$scratch/GuestChannelModule.swift"

echo "==> running transport/router checks"
"$scratch/channel-router-check"

echo "==> building the stub engine for the runtime lifecycle checks"
for stub_file in "$runtime_stub_dir/floe_tinyemu_stub.h" "$runtime_stub_dir/floe_tinyemu_stub.c" "$runtime_stub_dir/module.modulemap"; do
  if [ ! -f "$stub_file" ]; then
    echo "missing runtime stub file: $stub_file" >&2
    exit 2
  fi
done
"$cc_bin" -std=gnu11 -O2 -Wall -Wextra -Werror -c \
  "$runtime_stub_dir/floe_tinyemu_stub.c" -o "$scratch/floe_stub.o"
grep -v '^import FloeCore$' "$runtime_src" | grep -v '^import FloeTools$' \
  > "$scratch/TinyEMUGuestRuntime.swift"
{
  echo 'import Foundation'
  sed -n '/^public struct LinuxGuestEmulatorCPUSample/,/^}$/p' "$service_src"
} > "$scratch/RuntimeSample.swift"
if ! grep -q 'public final class TinyEMUGuestMachine' "$scratch/TinyEMUGuestRuntime.swift"; then
  echo "failed to extract TinyEMUGuestRuntime (source moved?)" >&2
  exit 2
fi

echo "==> compiling runtime lifecycle harness with swiftc"
swiftc -swift-version 6 -o "$scratch/runtime-lifecycle-check" \
  "$here/RuntimeLifecycleCheck.swift" "$scratch/TinyEMUGuestRuntime.swift" \
  "$scratch/RuntimeSample.swift" "$resource_shape_src" \
  -I "$runtime_stub_dir" "$scratch/floe_stub.o"

echo "==> running runtime lifecycle checks"
"$scratch/runtime-lifecycle-check"

echo "==> all host protocol checks passed"
