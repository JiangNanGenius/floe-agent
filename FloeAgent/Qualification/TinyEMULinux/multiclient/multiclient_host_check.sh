#!/usr/bin/env bash
# multiclient_host_check.sh — host-side multi-client multiplex check for the
# Floe Linux guest channel (protocol 3).
#
# This is the "local module barrier" for the parent-task + multiple
# full-power-children requirement: ONE shared client (the production
# `LinuxGuestCommandChannel`) drives ONE real guest console (the real
# `floe-exec` runner built for this host, real fork/exec, real stdout/stderr,
# real exit statuses, real PTY sessions) with several concurrent clients, and
# proves that:
#
#   * three clients (parent + two children) genuinely run concurrently
#     (mutual start-file barrier; a serialized channel cannot pass);
#   * each client keeps its own identity, session token, cwd, stdout, stderr
#     and exit code — nothing crosses;
#   * cancelling one client reaps only that client's process group: the other
#     clients finish normally and the console stays usable;
#   * an invalid destination (missing cwd / missing binary) fails that client
#     honestly without poisoning the channel for the others;
#   * closing the console while commands are active produces honest failures
#     for every active client (never a fake success) and never hangs;
#   * concurrent same-path writers are shown for what the VM layer guarantees
#     (whole-process writes; coordination is the runtime mutation lease's job).
#
# The harness compiles the *production* channel file (extracted verbatim from
# FloeExecution/Linux/LinuxGuestCommandChannel.swift together with its real
# supporting declarations, including FloeCore's ExecutionBreadcrumbs) and runs
# the real actor — not a reimplementation.
#
# Usage:
#   bash FloeAgent/Qualification/TinyEMULinux/multiclient/multiclient_host_check.sh
# Env:
#   FLOE_MC_SCRATCH   scratch dir (default: mktemp -d under $TMPDIR)
#   FLOE_MC_KEEP      1 = keep the scratch dir (artifacts stay)
#   FLOE_MC_JSON      explicit JSON result path (default: <scratch>/multiclient-result.json)
#   FLOE_MC_RUNNER    runner binary override: a real-guest console bridge
#                     (mc_guest_bridge) instead of the host floe-exec build
#   FLOE_MC_GUEST_WORK_ROOT guest-visible work root for FLOE_MC_RUNNER
#                     (e.g. /floe/mc-work); requires FLOE_MC_HOST_WORK_ROOT
#   FLOE_MC_HOST_WORK_ROOT  host directory backing that guest root (the 9p
#                     share exported to the bridge)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qual_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$qual_root/../../.." && pwd)"

runner_src="$repo_root/FloeAgent/LinuxGuest/runner/floe_exec.c"
channel_src="$repo_root/FloeAgent/Sources/FloeExecution/Linux/LinuxGuestCommandChannel.swift"
service_src="$repo_root/FloeAgent/Sources/FloeExecution/Linux/LinuxGuestService.swift"
error_src="$repo_root/FloeAgent/Sources/FloeCore/FloeError.swift"
token_src="$repo_root/FloeAgent/Sources/FloeTools/ToolContext.swift"
result_src="$repo_root/FloeAgent/Sources/FloeExecution/Packages/LinuxCommandService.swift"
breadcrumbs_src="$repo_root/FloeAgent/Sources/FloeCore/ExecutionBreadcrumbs.swift"
logger_src="$repo_root/FloeAgent/Sources/FloeCore/FloeLogger.swift"
redactor_src="$repo_root/FloeAgent/Sources/FloeCore/SecretRedactor.swift"

for source in "$runner_src" "$channel_src" "$service_src" "$error_src" "$token_src" "$result_src" "$breadcrumbs_src" "$logger_src" "$redactor_src"; do
  if [ ! -f "$source" ]; then
    echo "missing source: $source" >&2
    exit 2
  fi
done

if [ -n "${FLOE_MC_SCRATCH:-}" ]; then
  scratch="$FLOE_MC_SCRATCH"
  mkdir -p "$scratch"
else
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/floe-multiclient.XXXXXX")"
  trap 'if [ "${FLOE_MC_KEEP:-0}" != "1" ]; then rm -rf "$scratch"; fi' EXIT
fi

json_out="${FLOE_MC_JSON:-$scratch/multiclient-result.json}"
cc_bin="${CC:-cc}"

echo "==> building the guest runner for this host with $cc_bin"
"$cc_bin" -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
  -o "$scratch/floe-exec" "$runner_src"

echo "==> extracting the production channel module"
{
  echo "import Foundation"
  sed -n '/^public enum FloeError/,/^}$/p' "$error_src"
  sed -n '/^public final class CancellationToken/,/^}$/p' "$token_src"
  sed -n '/^public struct LinuxCommandResult/,/^}$/p' "$result_src"
  sed -n '/^public enum LinuxGuestError/,/^}$/p' "$service_src"
  sed -n '/^public struct LinuxGuestLimits/,/^}$/p' "$service_src"
  sed -n '/^public protocol LinuxGuestConsoleTransport/,/^}$/p' "$service_src"
  sed -n '/^public final class ExecutionBreadcrumbs/,/^}$/p' "$breadcrumbs_src"
  grep -v '^import FloeCore$' "$logger_src" | grep -v '^import FloeTools$'
  grep -v '^import FloeCore$' "$redactor_src" | grep -v '^import FloeTools$'
  grep -v '^import FloeCore$' "$channel_src" | grep -v '^import FloeTools$'
} > "$scratch/GuestChannelModule.swift"
for symbol in "public actor LinuxGuestCommandChannel" "public actor LinuxGuestInteractiveSession" "public final class ExecutionBreadcrumbs"; do
  if ! grep -q "$symbol" "$scratch/GuestChannelModule.swift"; then
    echo "failed to extract $symbol (source moved?)" >&2
    exit 2
  fi
done

echo "==> strict typecheck (swift-version 6) of the production channel module"
swiftc -swift-version 6 -typecheck "$scratch/GuestChannelModule.swift"

echo "==> compiling the multi-client harness (swift-version 6, whole-module)"
swiftc -O -swift-version 6 -parse-as-library -o "$scratch/multiclient-check" \
  "$here/MultiClientChannelCheck.swift" "$scratch/GuestChannelModule.swift"

echo "==> running the multi-client checks against the real runner"
runner="${FLOE_MC_RUNNER:-$scratch/floe-exec}"
guest_work="${FLOE_MC_GUEST_WORK_ROOT:-}"
host_work="${FLOE_MC_HOST_WORK_ROOT:-}"
if [ -n "$guest_work" ] && [ -n "$host_work" ]; then
  "$scratch/multiclient-check" "$runner" "$guest_work" "$json_out" "$host_work"
else
  "$scratch/multiclient-check" "$runner" "$scratch/mc-work" "$json_out"
fi

echo "==> multi-client host check passed; JSON: $json_out"
