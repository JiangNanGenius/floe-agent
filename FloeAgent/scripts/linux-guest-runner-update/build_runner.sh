#!/usr/bin/env bash
# build_runner.sh — cross-build the static riscv64 Floe guest runner from the
# exact checked-out commit, plus the LGPL-2.1 §6 relink object and the
# toolchain evidence the distribution needs.
#
# Usage (Linux CI with gcc-riscv64-linux-gnu installed):
#   bash build_runner.sh --repo DIR --out DIR
#
# Outputs in --out:
#   floe-exec-riscv64        static riscv64 runner (installed into the image)
#   floe-exec-riscv64.o      relocatable object (relink material)
#   runner-sha256.txt        sha256 of the shipped binary
#   runner-source-sha256.txt sha256 of floe_exec.c / floe_clock.h / Makefile
#   runner-constants.txt     protocol/version/limit constants as JSON
#   toolchain.txt            compiler, exact cross packages, link command, hashes
#   toolchain-versions.txt   owning packages + source versions for the actual
#                            compiler / libc.a / libgcc.a / cross libc
#                            (same resolution as collect-toolchain-sources.sh,
#                            so it can be compared with the base bundle)
#   runner-build.log / runner-object-build.log
#
# Hard gates: the binary is statically linked, carries its version string and
# really speaks protocol 3 (FLOE-CAPS) with enough concurrency for the focused
# guest check; the runner sources carry the protocol-3 constants.
set -euo pipefail

die() { printf 'build_runner: ERROR: %s\n' "$*" >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=""
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$repo" ] && [ -n "$out" ] || die "--repo and --out are required"
runner_dir="$repo/FloeAgent/LinuxGuest/runner"
[ -f "$runner_dir/floe_exec.c" ] || die "missing $runner_dir/floe_exec.c"
command -v riscv64-linux-gnu-gcc >/dev/null 2>&1 || die "missing riscv64-linux-gnu-gcc"
command -v python3 >/dev/null 2>&1 || die "missing python3"
mkdir -p "$out"

# Honest protocol gate: an old (protocol 2) runner ref must fail here, not in
# the guest boot 30 minutes later.
grep -q 'FLOE_PROTOCOL_VERSION 3' "$runner_dir/floe_exec.c" \
    || die "runner source is not protocol 3 (FLOE_PROTOCOL_VERSION 3 missing)"
grep -q 'FLOE-CAPS' "$runner_dir/floe_exec.c" \
    || die "runner source lacks FLOE-CAPS negotiation"
python3 - "$runner_dir/floe_exec.c" "$out/runner-constants.txt" "$script_dir" <<'CONSTANTS_PY'
import json
import sys

sys.path.insert(0, sys.argv[3])
import pipeline_contract

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    source = handle.read()
constants = pipeline_contract.parse_runner_constants(source)
problems = []
if constants["protocol"] != 3:
    problems.append("protocol is %d, not 3" % constants["protocol"])
if constants["max_commands"] < 4:
    problems.append("maxCommands=%d cannot run the 4-way overlap check" % constants["max_commands"])
if constants["max_sessions"] < 2:
    problems.append("maxSessions=%d cannot open the 2 PTY sessions" % constants["max_sessions"])
if problems:
    raise SystemExit("build_runner: " + "; ".join(problems))
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(constants, handle, indent=2)
    handle.write("\n")
print("runner constants: %s" % json.dumps(constants, sort_keys=True))
CONSTANTS_PY
runner_version="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["runner_version"])' \
    "$out/runner-constants.txt")"

make -C "$runner_dir" riscv64 >"$out/runner-build.log" 2>&1
cp "$runner_dir/floe-exec-riscv64" "$out/floe-exec-riscv64"
riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE \
    -static -I"$runner_dir" \
    -c -o "$out/floe-exec-riscv64.o" "$runner_dir/floe_exec.c" \
    >"$out/runner-object-build.log" 2>&1

file "$out/floe-exec-riscv64" | grep -q 'statically linked' \
    || die "runner is not statically linked"
grep -aq 'FLOE-CAPS' "$out/floe-exec-riscv64" \
    || die "runner binary does not contain the FLOE-CAPS marker"
grep -aq "$runner_version" "$out/floe-exec-riscv64" \
    || die "runner binary does not carry its version string $runner_version"
file "$out/floe-exec-riscv64.o" | grep -q 'relocatable' \
    || die "runner object is not relocatable"

# Resolve the *owning* packages of the actual cross compiler and static libs
# (same logic as FloeAgent/LinuxGuest/image/collect-toolchain-sources.sh), so
# the record compares directly with the base toolchain-source bundle.
compiler_binary="$(command -v riscv64-linux-gnu-gcc 2>/dev/null || true)"
compiler_pkg=""
[ -n "$compiler_binary" ] && compiler_pkg="$(dpkg -S "$compiler_binary" 2>/dev/null | cut -d: -f1 | head -1 || true)"
libc_dev_pkg="$(dpkg -S "$(riscv64-linux-gnu-gcc -print-file-name=libc.a 2>/dev/null)" 2>/dev/null | cut -d: -f1 | head -1 || true)"
libgcc_pkg="$(dpkg -S "$(riscv64-linux-gnu-gcc -print-file-name=libgcc.a 2>/dev/null)" 2>/dev/null | cut -d: -f1 | head -1 || true)"
libc_cross_pkg="$(dpkg-query -W -f='${binary:Package}\n' 'libc6-*-cross' 2>/dev/null \
    | grep -E '^libc6-[^-]+-cross$' | grep -v -- '-dev-' | head -1 || true)"
{
    for binary in gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu \
                   "$compiler_pkg" "$libc_dev_pkg" "$libgcc_pkg" "$libc_cross_pkg"; do
        [ -n "$binary" ] || continue
        dpkg-query -W -f='binary ${binary:Package} ${Version} source ${source:Package} ${source:Version}\n' \
            "$binary" 2>/dev/null || true
    done
    riscv64-linux-gnu-gcc --version 2>/dev/null | head -1 || true
    printf 'libc.a=%s\n' "$(riscv64-linux-gnu-gcc -print-file-name=libc.a 2>/dev/null || true)"
    printf 'libgcc.a=%s\n' "$(riscv64-linux-gnu-gcc -print-file-name=libgcc.a 2>/dev/null || true)"
} >"$out/toolchain-versions.txt"
grep -q '^binary ' "$out/toolchain-versions.txt" \
    || die "toolchain-versions.txt resolved no owning packages"

sha256sum "$out/floe-exec-riscv64" | tee "$out/runner-sha256.txt"
sha256sum "$runner_dir/floe_exec.c" "$runner_dir/floe_clock.h" "$runner_dir/Makefile" \
    >"$out/runner-source-sha256.txt"

{
    printf 'source_commit=%s\n' "$(git -C "$repo" rev-parse HEAD)"
    printf 'cross_cc=%s\n' "$(riscv64-linux-gnu-gcc --version | head -1)"
    printf 'link_command=riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE -static -o floe-exec-riscv64 floe_exec.c\n'
    printf 'object_command=riscv64-linux-gnu-gcc -std=gnu11 -O2 -Wall -Wextra -Werror -D_GNU_SOURCE -static -c -o floe-exec-riscv64.o floe_exec.c\n'
    dpkg-query -W -f='toolchain_package ${binary:Package} ${Version}\n' \
        gcc-riscv64-linux-gnu libc6-dev-riscv64-cross binutils-riscv64-linux-gnu \
        libc6-riscv64-cross libgcc-13-dev-riscv64-cross 2>/dev/null \
        | grep -v 'no packages found' || true
    file "$out/floe-exec-riscv64"
    sha256sum "$out/floe-exec-riscv64" "$out/floe-exec-riscv64.o"
} >"$out/toolchain.txt"

printf 'build_runner: %s (%s bytes, sha256 %s, constants %s)\n' "$out/floe-exec-riscv64" \
    "$(stat -c %s "$out/floe-exec-riscv64")" "$(cut -d' ' -f1 "$out/runner-sha256.txt")" \
    "$(tr -d '\n ' < "$out/runner-constants.txt")"
