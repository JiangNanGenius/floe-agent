#!/usr/bin/env python3
"""Original-vs-patched regression for the iOS kit callback push lifetime.

Extracts the pinned kit/Kit.cpp KitSocketPoll::pushToMainThread (two variants)
and the pinned net/Socket.hpp SocketPoll::addCallback, compiles them against
the labeled mocks in fixtures/office_kit_lifecycle and runs the deterministic
scenario matrix:

  original := pinned 27b21dc1 kit/Kit.cpp
  patched  := original + kitCallbackLifecycleOverlay
              (patches/ios-kit-callback-lifecycle.patch)

The original binary must demonstrate the defect: a null mainPoll with a live
sibling poll, callback bodies executed inline on the app-main/VCL thread and
on a creator thread, and unsynchronized overlap with kit-thread document work.
The patched binary must verify the repair: exactly-once delivery on the kit
servicing thread, own-document queueing, pending callbacks dying with their
poll, orphan-document drop, no foreign-thread inline execution across the
unserviced-owner case, the first-service race and reentrancy.

Boundary: this is not a UIKit/Collabora/engine/render/device test. The two
callback entry points, the session work and the poll scheduling are labeled
mocks; only the push decision and the poll queue are production-extracted.
Passing here is source-defect evidence, not a device PPT result.

Usage: test_office_kit_lifecycle.py (--source ROOT | --bundle DIR)
  --source ROOT  root of the pinned upstream tree (kit/Kit.cpp, net/Socket.hpp)
  --bundle DIR   extracted format-2 Office bundle (its source/ tree is used)
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

BASE = Path(__file__).resolve().parent.parent / "ThirdParty/Collabora"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "office_kit_lifecycle"
DEFAULT_LOCK = BASE / "engine.lock.json"
KIT_CPP = "kit/Kit.cpp"
KIT_HPP = "kit/Kit.hpp"
SOCKET_HPP = "net/Socket.hpp"

PUSH_START = "bool KitSocketPoll::pushToMainThread(COKitCallback callback, COKitCallbackType eType,"
PUSH_END = "KitSocketPoll *KitSocketPoll::mainPoll = nullptr;"
ADD_CALLBACK_START = "    bool addCallback(CallbackFn fn)"
IDENTITY_STORE = "KitSocketPoll::kitThreadId.store("

# Required PASS lines per variant: the defect demonstration on the original,
# the repair verification on the patched extraction.
# Deterministic completion-discipline markers (S9), emitted identically by
# both variants: a forced (gated) delayed first service must defeat a fixed
# window read, and the strict bounded rendezvous must observe every queued
# body exactly once across >=3 distinct drain batches. mainPoll is live there
# in both extractions, so S9 guards the harness rather than the defect.
DELAYED_DRAIN_MARKERS = [
    "PASS S9 batch A queued while first service is gated off",
    "PASS S9 old fixed-window stop before first service loses queued work",
    "PASS S9 corrected first service drains the held batch in its own turn",
    "PASS S9 batch B drained in a second service turn",
    "PASS S9 batch C drained in a third service turn",
    "PASS S9 strict rendezvous drains all batches exactly once on the kit thread",
    "PASS S9 queued work crossed multiple drain batches",
]
ORIGINAL_MARKERS = [
    "PASS S1 DEFECT null mainPoll with live sibling poll",
    "PASS S2 DEFECT callback body executed inline on app-main thread",
    "PASS S2 DEFECT no callback reached the kit thread",
    "PASS S2 DEFECT handshake-proven overlap with kit-thread document work",
    "PASS S6 DEFECT orphan-document callbacks ran inline on a foreign thread",
    "PASS S7 DEFECT creator-owner authorized inline execution on a foreign thread",
] + DELAYED_DRAIN_MARKERS
PATCHED_MARKERS = [
    "PASS S1 sibling poll survives first-document teardown",
    "PASS S2 all callback bodies executed, on the kit thread",
    "PASS S2 no inline execution on app-main while a poll is live",
    "PASS S2 no unsynchronized overlap",
    "PASS S3 live-poll callback body ran exactly once, on the kit thread",
    "PASS S4 callback invoked on kit thread executed exactly once, no requeue",
    "PASS S5 pending callbacks die with their poll, never executed",
    "PASS S5 reentrant queueing executed exactly once, no deadlock",
    "PASS S6 orphan-document callbacks dropped, never run unsynchronized",
    "PASS S6 no inline execution for orphan document",
    "PASS S7 creator-owner not mistaken for the kit thread",
    "PASS S7 no foreign-thread inline execution from unserviced owner",
    "PASS S8 exactly-once on kit thread across first-service race",
    "PASS S8 no inline execution during first-service window",
] + DELAYED_DRAIN_MARKERS
EVIDENCE_RACE = re.compile(
    r"S\d+ evidence bodies=(?P<bodies>\d+) kit=(?P<kit>\d+) foreign=(?P<foreign>\d+)"
    r" inlineAppMain=(?P<inline>\d+) overlaps=(?P<overlaps>\d+) dropped=(?P<dropped>\d+)")
EVIDENCE_FIRST_SERVICE = re.compile(
    r"S\d+ evidence bodies=(?P<bodies>\d+) kit=(?P<kit>\d+) inlineAppMain=(?P<inline>\d+)")
# S9 prints bodies/kit/foreign/inlineAppMain/drains (no overlap/dropped fields).
EVIDENCE_DELAYED_DRAIN = re.compile(
    r"S9 evidence bodies=(?P<bodies>\d+) kit=(?P<kit>\d+) foreign=(?P<foreign>\d+)"
    r" inlineAppMain=(?P<inline>\d+) drains=(?P<drains>\d+)")


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def extract(lines, start_marker, end_marker, include_end=False):
    start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == start_marker)
    end = next(i for i in range(start + 1, len(lines))
               if lines[i].rstrip("\n") == end_marker)
    stop = end + 1 if include_end else end
    return lines[start:stop]


def extract_function(lines, start_marker):
    """The function whose declaration line is start_marker, up to its closing
    brace at the declaration's indentation."""
    start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == start_marker)
    indent = start_marker[:len(start_marker) - len(start_marker.lstrip())]
    closing = indent + "}"
    end = next(i for i in range(start + 1, len(lines)) if lines[i].rstrip("\n") == closing)
    return lines[start:end + 1]


def lock_section():
    lock = json.loads(DEFAULT_LOCK.read_text())
    section = lock.get("kitCallbackLifecycleOverlay")
    problems = []
    if section is None:
        problems.append("kitCallbackLifecycleOverlay section missing")
        return lock, None, problems
    if sha256(BASE / section["patch"]) != section["sha256"]:
        problems.append("kit callback lifecycle patch digest differs from the lock")
    for name in (KIT_CPP, KIT_HPP):
        spec = section["files"].get(name)
        if spec is None:
            problems.append(f"kit callback lifecycle overlay omits {name}")
        elif not all(len(spec.get(key, "")) == 64 for key in ("originalSHA256", "preparedSHA256")):
            problems.append(f"kit callback lifecycle overlay has no exact hashes for {name}")
    return lock, section, problems


def stage_variants(source_root, section, stage):
    """Build both source states and the mechanical extractions."""
    for name in (KIT_CPP, KIT_HPP):
        pinned = source_root / name
        if not pinned.is_file():
            raise ValueError(f"no {name} under {source_root}")
        if sha256(pinned) != section["files"][name]["originalSHA256"]:
            raise ValueError(f"pinned {name} differs from the lock's overlay input")
    for variant in ("original", "patched"):
        for name in (KIT_CPP, KIT_HPP):
            target = stage / variant / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_root / name, target)
    subprocess.run(["git", "apply", "-p1", str(BASE / section["patch"])],
                   cwd=stage / "patched", check=True, capture_output=True)
    for name in (KIT_CPP, KIT_HPP):
        if sha256(stage / "patched" / name) != section["files"][name]["preparedSHA256"]:
            raise ValueError(f"patched {name} differs from the lock's prepared hash")

    socket = source_root / SOCKET_HPP
    if not socket.is_file():
        raise ValueError(f"no {SOCKET_HPP} under {source_root}")
    add_callback = extract_function(socket.read_text().splitlines(keepends=True),
                                    ADD_CALLBACK_START)
    for production in ("const bool alive = isAlive();",
                       "_newCallbacks.emplace_back(std::move(fn));",
                       "return alive;"):
        if not any(production in line for line in add_callback):
            raise ValueError("net/Socket.hpp addCallback shape changed")

    for variant in ("original", "patched"):
        build = stage / "build" / variant
        build.mkdir(parents=True)
        lines = (stage / variant / KIT_CPP).read_text().splitlines(keepends=True)
        body = extract(lines, PUSH_START, PUSH_END)
        if variant == "original":
            if not any("if (mainPoll && mainPoll->getThreadOwner() != ProcUtil::getThreadId())" in line
                       for line in body):
                raise ValueError("original extraction does not carry the pinned fallback")
            identity = ["// The pinned original has no shared kit-thread identity store."]
        else:
            for production in ("if (kitThreadId.load(std::memory_order_acquire) == ProcUtil::getThreadId())",
                               "if (callback == &Document::GlobalCallback)",
                               "if (callback == &Document::ViewCallback)",
                               "if (poll->getDocument().get() != doc)"):
                if not any(production in line for line in body):
                    raise ValueError("patched extraction does not carry the repair")
            identity = [line for line in lines if line.strip().startswith(IDENTITY_STORE)]
            if len(identity) != 1:
                raise ValueError("patched Kit.cpp does not carry exactly one kitThreadId store")
        banner = ("// Mechanical extraction by scripts/test_office_kit_lifecycle.py; do not edit.\n")
        (build / "push.inc.h").write_text(banner + "".join(body))
        (build / "kit_identity.inc.h").write_text(banner + "".join(identity))
        (build / "add_callback.inc.h").write_text(banner + "".join(add_callback))


def build_variants(stage):
    binaries = {}
    for variant in ("original", "patched"):
        build = stage / "build" / variant
        binary = build / "harness"
        command = ["clang++", "-std=c++17", "-DNDEBUG", "-O1", "-g0", "-pthread",
                   "-Wall", "-Wextra", "-Werror", "-DDOCS_SHARE_PROCESS=1",
                   f"-DFLOE_KIT_VARIANT={0 if variant == 'original' else 1}",
                   "-I", str(build), "-I", str(FIXTURES),
                   str(FIXTURES / "driver.cpp"), "-o", str(binary)]
        compiled = subprocess.run(command, capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError(f"{variant} harness compile failed:\n" + compiled.stderr[-4000:])
        binaries[variant] = binary
    return binaries


def _write_raw(raw_dir, variant, tag, content):
    """Persist the variant's synthetic raw output so a cloud failure is
    diagnosable even when stdout was redirected to the JSON summary."""
    if raw_dir is None:
        return None
    raw_dir.mkdir(parents=True, exist_ok=True)
    path = raw_dir / f"kit-lifecycle-{variant}-{tag}.txt"
    path.write_text(content)
    return str(path)


def run_variant(binary, variant, errors, raw_dir=None):
    """Run one variant and check its marker set and evidence counters.

    The raw stdout/stderr, exit code and any timeout are captured into the
    matrix row (and, when raw_dir is given, to disk) on EVERY outcome, so a
    cloud failure never loses the synthetic output that explains it.
    """
    prior = len(errors)
    timeout_seconds = 300
    stdout = ""
    stderr = ""
    returncode = None
    timed_out = False
    try:
        ran = subprocess.run([str(binary)], capture_output=True, text=True,
                             timeout=timeout_seconds)
        stdout = ran.stdout or ""
        stderr = ran.stderr or ""
        returncode = ran.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        stdout = exc.stdout.decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode() if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        errors.append(f"{variant}: timeout after {timeout_seconds}s")
        _write_raw(raw_dir, variant, "timeout-stdout", stdout)
        _write_raw(raw_dir, variant, "timeout-stderr", stderr)

    output = stdout
    failures = [line for line in output.splitlines() if line.startswith("FAIL ")]

    row = {
        "variant": variant,
        "returnCode": None if timed_out else returncode,
        "timedOut": timed_out,
        "rawStdoutChars": len(stdout),
        "rawStderrChars": len(stderr),
        "rawStdoutFile": _write_raw(raw_dir, variant, "stdout", stdout),
        "rawStderrFile": _write_raw(raw_dir, variant, "stderr", stderr),
        # Keep a bounded inline tail so the evidence is useful even if the
        # uploaded raw files are unavailable; full output goes to the files.
        "rawStdoutTail": "\n".join(output.splitlines()[-40:]),
    }
    if stderr.strip():
        row["rawStderrTail"] = "\n".join(stderr.splitlines()[-20:])

    if timed_out or returncode != 0 or failures:
        errors.extend(f"{variant}: {line}" for line in failures)
        if not timed_out:
            errors.append(f"{variant}: exit {returncode}")
        row["verdict"] = "FAIL"
        row["detail"] = ("timeout" if timed_out
                         else "; ".join(failures) or f"exit {returncode}")
        return row

    markers = ORIGINAL_MARKERS if variant == "original" else PATCHED_MARKERS
    missing = [marker for marker in markers if marker not in output]
    if missing:
        errors.extend(f"{variant}: missing marker {marker}" for marker in missing)
    expected_result = "DEFECT-DEMONSTRATED" if variant == "original" else "REPAIR-VERIFIED"
    result_line = next((line for line in output.splitlines()
                        if line.startswith("result=")), "")
    if f"result={expected_result} failures=0" not in result_line:
        errors.append(f"{variant}: unexpected result line {result_line!r}")

    race = [match.groupdict() for match in EVIDENCE_RACE.finditer(output)]
    first_service = [match.groupdict() for match in EVIDENCE_FIRST_SERVICE.finditer(output)]
    delayed = [match.groupdict() for match in EVIDENCE_DELAYED_DRAIN.finditer(output)]
    for label, rows in (("S2", race), ("S8", first_service), ("S9", delayed)):
        if len(rows) != 1:
            errors.append(f"{variant}: expected exactly one {label} evidence row, got {len(rows)}")
    for rowdata in race:  # S2 carries the race counters
        numbers = {key: int(value) for key, value in rowdata.items()}
        if variant == "original":
            if not (numbers["inline"] > 0 and numbers["kit"] == 0
                    and numbers["overlaps"] > 0 and numbers["dropped"] == 0):
                errors.append(f"original S2 evidence does not show the defect: {numbers}")
        elif not (numbers["bodies"] == 20 and numbers["kit"] > 0
                  and numbers["foreign"] == 0 and numbers["inline"] == 0
                  and numbers["overlaps"] == 0 and numbers["dropped"] == 0):
            errors.append(f"patched S2 evidence does not show exactly-once kit delivery: {numbers}")
    for rowdata in first_service:  # S8 carries the first-service race counters
        numbers = {key: int(value) for key, value in rowdata.items()}
        if not (numbers["bodies"] == 30 and numbers["kit"] == 30 and numbers["inline"] == 0):
            errors.append(f"S8 evidence is not exactly-once on the kit thread: {numbers}")
    for rowdata in delayed:  # S9 forced delayed first service, both variants
        numbers = {key: int(value) for key, value in rowdata.items()}
        if not (numbers["bodies"] == 20 and numbers["kit"] == 20
                and numbers["foreign"] == 0 and numbers["inline"] == 0
                and numbers["drains"] >= 3):
            errors.append(f"S9 evidence is not exactly-once across multiple drains: {numbers}")
    detail = (f"{len(markers) - len(missing)}/{len(markers)} markers; "
              f"{len(race) + len(first_service) + len(delayed)} evidence rows")
    row["detail"] = detail
    row["verdict"] = "pass" if len(errors) == prior else "FAIL"
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, help="root of the pinned upstream tree")
    parser.add_argument("--bundle", type=Path,
        help="extracted format-2 Office bundle (its source/ tree is used)")
    parser.add_argument("--raw-dir", type=Path, default=None,
        help=("directory to persist each variant's raw stdout/stderr on every "
              "outcome (pass/fail/timeout), so a cloud failure keeps its "
              "synthetic output next to the JSON summary"))
    args = parser.parse_args()
    if not args.source and not args.bundle:
        parser.error("one of --source or --bundle is required")
    source_root = (args.source if args.source else args.bundle / "source").resolve()
    raw_dir = args.raw_dir.resolve() if args.raw_dir else None
    if raw_dir is not None:
        raw_dir.mkdir(parents=True, exist_ok=True)
    if os.uname().sysname != "Darwin":
        parser.error("requires macOS (clang++), like the other native host regressions")

    lock, section, problems = lock_section()
    summary = {"lockConsistency": {"lockChecked": not problems, "problems": problems},
               "kind": ("kit callback push lifetime; byte-faithful extracted function + "
                        "mocked ownership lifecycle, not a device PPT reproduction"),
               "patchSHA256": section["sha256"] if section else None,
               "sourceRoot": str(source_root)}
    errors = list(problems)
    if section is not None:
        if not (source_root / KIT_CPP).is_file():
            errors.append(f"no {KIT_CPP} under {source_root}")
        else:
            with tempfile.TemporaryDirectory(prefix="floe-kit-lifecycle-") as folder:
                folder = Path(folder)
                try:
                    stage_variants(source_root, section, folder)
                    binaries = build_variants(folder)
                    matrix = [run_variant(binaries[variant], variant, errors, raw_dir)
                              for variant in ("original", "patched")]
                    summary["matrix"] = matrix
                except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
                    errors.append(str(error))
    summary["passed"] = not errors
    summary["errors"] = errors
    print(json.dumps(summary, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
