#!/usr/bin/env bash
# Build the standalone riscv64 Floe guest runner component.
#
# This is deliberately NOT an image build: it reuses the approved
# FloeAgent/scripts/linux-guest-runner-update/build_runner.sh, produces the
# static runner + relink object + exact-source/toolchain records, and writes a
# small component candidate with the real SHA-512/byte binding. It does not
# download a base image, inject into a disk, boot a guest, publish anything, or
# claim a guest qualification.
#
# Usage:
#   bash FloeAgent/LinuxGuest/runner/build-standalone-runner.sh \
#       --repo DIR --out DIR [--execute]
#
# Default is a read-only plan: validate the source contract and print the exact
# build/toolchain requirements without invoking a compiler.
# --execute runs the approved builder. It requires the cross toolchain and
# record tools the last approved component build used:
#   Ubuntu 24.04, gcc-riscv64-linux-gnu 4:13.2.0-7ubuntu1,
#   binutils-riscv64-linux-gnu 2.42-4ubuntu2.10,
#   libc6-dev-riscv64-cross 2.39-0ubuntu8cross1,
#   libc6-riscv64-cross 2.39-0ubuntu8cross1,
#   libgcc-13-dev-riscv64-cross 13.3.0-6ubuntu2~24.04.1cross1
# plus make, file, dpkg-query, git, sha256sum, sha512sum and python3.
#
# Outputs in --out: floe-exec-riscv64, floe-exec-riscv64.o, runner constants,
# source/toolchain records from the approved builder, runner-sha512.txt, and
# runner-component.json (a manifest candidate fragment; its
# runnerCapabilities value stays null until a real guest boot measures CAPS).
set -euo pipefail

die() { printf 'build-standalone-runner: ERROR: %s\n' "$*" >&2; exit 2; }
note() { printf 'build-standalone-runner: %s\n' "$*"; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_repo="$(cd "$script_dir/../../.." && pwd)"
repo="$default_repo"
out=""
execute=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:-}"; shift 2 ;;
        --out) out="${2:-}"; shift 2 ;;
        --execute) execute=1; shift ;;
        -h|--help)
            awk 'NR > 1 && $0 == "set -euo pipefail" { exit } NR > 1 { print }' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$out" ] || die "--out is required"
[ -d "$repo" ] || die "repository directory not found: $repo"
runner_dir="$repo/FloeAgent/LinuxGuest/runner"
builder="$repo/FloeAgent/scripts/linux-guest-runner-update/build_runner.sh"
[ -f "$runner_dir/floe_exec.c" ] || die "missing $runner_dir/floe_exec.c"
[ -f "$builder" ] || die "missing approved builder: $builder"
command -v python3 >/dev/null 2>&1 || die "missing python3"

# Source contract first: an old runner or one without the additive env=1
# capability must fail here, not in a guest boot or a packaging comparison.
python3 - "$repo" <<'CONTRACT_PY'
import hashlib
import json
import os
import subprocess
import sys

repo = sys.argv[1]
runner_dir = os.path.join(repo, "FloeAgent/LinuxGuest/runner")
sys.path.insert(0, os.path.join(repo, "FloeAgent/scripts/linux-guest-runner-update"))
import pipeline_contract  # noqa: E402

with open(os.path.join(runner_dir, "floe_exec.c"), "r", encoding="utf-8") as handle:
    source = handle.read()
constants = pipeline_contract.parse_runner_constants(source)
problems = []
if constants["protocol"] != 3:
    problems.append("protocol is %d, not 3" % constants["protocol"])
if constants["max_commands"] < 4:
    problems.append("maxCommands=%d cannot run the 4-way overlap check" % constants["max_commands"])
if constants["max_sessions"] < 2:
    problems.append("maxSessions=%d cannot open 2 PTY sessions" % constants["max_sessions"])
caps_line = next(
    (line for line in source.splitlines() if "FLOE-CAPS" in line and "maxSessions" in line),
    "",
)
if "env=1" not in caps_line:
    problems.append("the FLOE-CAPS emission does not advertise env=1")

members = []
for name in pipeline_contract.runner_source_set(source):
    path = os.path.join(runner_dir, name)
    if not os.path.isfile(path):
        problems.append("runner source set names a missing file: %s" % name)
        continue
    with open(path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    members.append({"name": name, "sha256": digest})

def git(*args):
    return subprocess.check_output(["git", "-C", repo] + list(args), text=True).strip()

source_commit = git("rev-parse", "HEAD")
source_status = git("status", "--porcelain", "--", "FloeAgent/LinuxGuest/runner")
print("source_commit=%s" % source_commit)
print("source_dirty=%s" % ("yes" if source_status else "no"))
print("runner_version=%s" % constants["runner_version"])
print("protocol=%d" % constants["protocol"])
print("max_commands=%d" % constants["max_commands"])
print("max_sessions=%d" % constants["max_sessions"])
print("required_capabilities=env=1")
print("source_set=" + ",".join(member["name"] for member in members))
if problems:
    for problem in problems:
        print("problem=%s" % problem, file=sys.stderr)
    raise SystemExit(1)
CONTRACT_PY

missing_toolchain() {
    local missing=""
    for tool in riscv64-linux-gnu-gcc make file dpkg-query git sha256sum sha512sum; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    printf '%s' "$missing"
}

missing="$(missing_toolchain)"
if [ "$execute" -eq 0 ]; then
    note "plan only; no compiler invoked and no files written"
    note "approved builder: bash $builder --repo $repo --out $out"
    note "execute with: bash $script_dir/build-standalone-runner.sh --repo $repo --out $out --execute"
    note "last approved toolchain: Ubuntu 24.04 cross packages (see the script header)"
    if [ -n "$missing" ]; then
        note "toolchain missing:$missing (the pinned component window is required)"
    else
        note "toolchain present (cross compiler and record tools found)"
    fi
    note "required output binding: runnerArtifact.sha512/bytes from the produced bytes, never a source hash or invented value"
    exit 0
fi

[ -z "$missing" ] || die "missing cross-build/toolchain capability:$missing"

mkdir -p "$out"
note "building with the approved runner-update builder"
bash "$builder" --repo "$repo" --out "$out"
for required in floe-exec-riscv64 floe-exec-riscv64.o runner-constants.txt \
                runner-source-sha256.txt runner-sha256.txt toolchain.txt \
                toolchain-versions.txt; do
    [ -f "$out/$required" ] || die "approved builder did not produce $required"
done

( cd "$out" && sha512sum floe-exec-riscv64 > runner-sha512.txt )
python3 - "$repo" "$out" <<'RECORD_PY'
import datetime
import hashlib
import json
import os
import subprocess
import sys

repo, out = sys.argv[1], sys.argv[2]
runner_dir = os.path.join(repo, "FloeAgent/LinuxGuest/runner")
sys.path.insert(0, os.path.join(repo, "FloeAgent/scripts/linux-guest-runner-update"))
import pipeline_contract  # noqa: E402

def read_json(name):
    with open(os.path.join(out, name), "r", encoding="utf-8") as handle:
        return json.load(handle)

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

constants = read_json("runner-constants.txt")
binary = os.path.join(out, "floe-exec-riscv64")
with open(binary, "rb") as handle:
    binary_bytes = handle.read()
binary_sha512 = hashlib.sha512(binary_bytes).hexdigest()
binary_sha256 = hashlib.sha256(binary_bytes).hexdigest()
with open(os.path.join(out, "runner-sha256.txt"), "r", encoding="utf-8") as handle:
    recorded_sha256 = handle.read().split()[0]
if recorded_sha256 != binary_sha256:
    raise SystemExit("runner-sha256.txt does not match the produced binary")

with open(os.path.join(runner_dir, "floe_exec.c"), "r", encoding="utf-8") as handle:
    source = handle.read()
recorded_sources = {}
with open(os.path.join(out, "runner-source-sha256.txt"), "r", encoding="utf-8") as handle:
    for line in handle:
        parts = line.split()
        if len(parts) == 2:
            recorded_sources[parts[1]] = parts[0]
members = []
for name in pipeline_contract.runner_source_set(source):
    path = os.path.join(runner_dir, name)
    digest = sha256(path)
    if recorded_sources.get(name) != digest:
        raise SystemExit("runner-source-sha256.txt drifted for %s" % name)
    members.append({"name": name, "sha256": digest})
source_set_sha256 = hashlib.sha256(
    "".join("%s  %s\n" % (member["sha256"], member["name"]) for member in members).encode()
).hexdigest()

source_commit = subprocess.check_output(
    ["git", "-C", repo, "rev-parse", "HEAD"], text=True
).strip()
source_dirty = bool(subprocess.check_output(
    ["git", "-C", repo, "status", "--porcelain", "--", "FloeAgent/LinuxGuest/runner"],
    text=True,
).strip())

with open(os.path.join(out, "toolchain.txt"), "r", encoding="utf-8") as handle:
    toolchain_lines = handle.read().splitlines()
cross_cc = next((line.split("=", 1)[1] for line in toolchain_lines
                 if line.startswith("cross_cc=")), "")

record = {
    "schema": "floe-linux-guest-runner-component-candidate/v1",
    "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "component": "standalone-riscv64-guest-runner",
    "componentScope": "runner binary only; no rootfs, disk image, boot pair or package data rebuild",
    "sourceCommit": source_commit,
    "sourceDirty": source_dirty,
    "sourceMembers": members,
    "sourceSetSha256": source_set_sha256,
    "runnerVersion": constants["runner_version"],
    "protocol": constants["protocol"],
    "maxCommands": constants["max_commands"],
    "maxSessions": constants["max_sessions"],
    "requiredCapabilities": ["env=1"],
    "expectedCapabilities": (
        "runner=%s protocol=%d maxCommands=%d maxSessions=%d env=1"
        % (constants["runner_version"], constants["protocol"],
           constants["max_commands"], constants["max_sessions"])
    ),
    "runnerArtifact": {
        "role": "runner",
        "path": "floe-exec-riscv64",
        "sha512": binary_sha512,
        "bytes": len(binary_bytes),
    },
    "binarySha256": binary_sha256,
    "installPath": "/usr/local/bin/floe-exec",
    "crossCompiler": cross_cc,
    "toolchainRecord": "toolchain.txt",
    "toolchainVersionsRecord": "toolchain-versions.txt",
    "manifestCandidate": {
        "runnerArtifact": {
            "role": "runner",
            "path": "floe-exec-riscv64",
            "sha512": binary_sha512,
            "bytes": len(binary_bytes),
        },
        "runnerCapabilities": None,
        "runnerCapabilitiesReason": (
            "measure the exact CAPS payload in a real guest boot; do not copy the source "
            "template or the ledger as proof"
        ),
    },
    "qualification": {
        "guestBootProven": False,
        "requiredChecks": [
            "CAPS contains the required env=1 capability",
            "EXECENV delivers one child-only environment and PID 1 stays isolated",
            "OPENENV delivers one PTY-only environment",
            "two concurrent secrets do not cross-contaminate",
            "invalid/oversized/duplicate/NUL environment blocks fail before a child",
        ],
    },
    "delivery": {
        "appCatalog": (
            "add a new LinuxGuestTrustedImage pin (id, archiveURL, archiveSHA512, "
            "provenance) whose manifest carries this runnerArtifact and the measured "
            "runnerCapabilities; existing disks adopt via compatibleOrigins and are "
            "upgraded in place"
        ),
        "imagePackaging": (
            "existing FloeAgent/scripts/linux-guest-runner-update package path; "
            "reuse the pinned base disk/boot pair, never rebuild the rootfs"
        ),
        "sourceOfferProducer": (
            "FloeAgent/scripts/linux-guest-runner-update/package_component.py"
        ),
    },
}
with open(os.path.join(out, "runner-component.json"), "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
with open(os.path.join(out, "runner-component.json"), "rb") as handle:
    record_sha256 = hashlib.sha256(handle.read()).hexdigest()
with open(os.path.join(out, "runner-component.json.sha256"), "w", encoding="utf-8") as handle:
    handle.write("%s  runner-component.json\n" % record_sha256)
print("wrote %s" % os.path.join(out, "runner-component.json"))
print("runner sha512=%s bytes=%d" % (binary_sha512, len(binary_bytes)))
RECORD_PY

note "component candidate: $out/runner-component.json"
note "guest CAPS and EXECENV/OPENENV qualification remain pending; this build does not prove them"
