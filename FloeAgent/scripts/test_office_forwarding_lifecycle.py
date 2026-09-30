#!/usr/bin/env python3
"""Original-vs-patched regression for the iOS HULLO forwarding loop lifecycle.

Compiles the REAL pinned net/FakeSocket.cpp plus the byte-faithful extracted
HULLO forwarding block of two variants and runs the deterministic scenario
matrix from fixtures/office_forwarding:

  original := pinned 27b21dc1 + embedding overlay (the shipped Build 237
              source; the embedding overlay did not touch the HULLO block)
  patched  := original + forwardingLifecycleOverlay (the repair)

Crash scenarios must kill the original child with SIGABRT (std::length_error
terminate marker) while the patched child exits 0; lifecycle scenarios assert
fd retirement state (zero-timeout poll: POLLNVAL means closed), the ownership
flag, delivery counts and spin counts inside the binaries.

Requires macOS (Foundation). Not a UIKit/Collabora/render/device test; the
JS side and the engine are the fixture's labeled mocks.

Usage: test_office_forwarding_lifecycle.py (--source ROOT | --bundle DIR)
  --source ROOT  root of the pinned upstream tree (ios/Mobile/..., net/...)
  --bundle DIR   extracted format-2 Office bundle (its source/ tree is used)
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

BASE = Path(__file__).resolve().parent.parent / "ThirdParty/Collabora"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "office_forwarding"
DEFAULT_LOCK = BASE / "engine.lock.json"
CONTROLLER = "ios/Mobile/DocumentViewController.mm"

HULLO_START = '        if ([message.body isEqualToString:@"HULLO"]) {'
HULLO_END = '        } else if ([message.body isEqualToString:@"BYE"]) {'
HELPER_START = 'static NSURL *FloeDocumentHandshakeURL(NSURL *fileURL, BOOL readOnly) {'
HELPER_END = '// FLOE_READONLY_HANDSHAKE_END'

# scenario -> expectation per variant
MATRIX = {
    "double_hullo_race": {"original": "abort_length_error", "patched": "exit0"},
    # Duplicate HULLO after BYE, inside the window where pipe end 0 was
    # already closed/reset but the consumer is alive (primary-review case).
    "after_bye_race": {"original": "abort_length_error", "patched": "exit0"},
    "after_bye_second_forwarder": {"original": "exit0", "patched": "exit0"},
    "read_race": {"original": "abort_length_error", "patched": "exit0"},
    "peer_shutdown": {"original": "exit0", "patched": "exit0"},
    "normal_delivery": {"original": "exit0", "patched": "exit0"},
    "close_notification": {"original": "exit0", "patched": "exit0"},
    # Non-deterministic on the original (deliver/spin/crash by scheduling);
    # the deterministic original failure is proven by double_hullo_race.
    "duplicate_hullo_single_delivery": {"original": "skip", "patched": "exit0"},
    "connect_failure": {"original": "exit0", "patched": "exit0"},
    "invalid_client_fd": {"original": "exit0", "patched": "exit0"},
}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def extract(lines, start_marker, end_marker, include_end=False):
    start = next(i for i, line in enumerate(lines) if line.rstrip("\n") == start_marker)
    end = next(i for i, line in enumerate(lines) if line.rstrip("\n") == end_marker and i > start)
    stop = end + 1 if include_end else end
    return lines[start:stop]


def lock_sections():
    lock = json.loads(DEFAULT_LOCK.read_text())
    problems = []
    embedding = lock["embeddingOverlay"]
    forwarding = lock.get("forwardingLifecycleOverlay")
    if forwarding is None:
        problems.append("forwardingLifecycleOverlay section missing")
        return lock, None, problems
    if sha256(BASE / forwarding["patch"]) != forwarding["sha256"]:
        problems.append("forwarding lifecycle patch digest differs from the lock")
    for name, spec in forwarding["files"].items():
        embedded = embedding["files"].get(name)
        if embedded is None:
            problems.append(f"forwarding overlay input is not an embedding file: {name}")
        elif embedded["preparedSHA256"] != spec["originalSHA256"]:
            problems.append(
                f"forwarding overlay input for {name} is not the embedding-prepared state")
    return lock, forwarding, problems


def stage_variants(source_root, lock, forwarding, stage):
    """Build the two source states and extract the loop/helper includes."""
    embedding = lock["embeddingOverlay"]
    embed_spec = embedding["files"][CONTROLLER]
    forward_spec = forwarding["files"][CONTROLLER]
    pinned = source_root / CONTROLLER
    if sha256(pinned) != embed_spec["originalSHA256"]:
        raise ValueError("pinned DocumentViewController.mm differs from the lock's embedding input")
    original_dir = stage / "original" / "ios/Mobile"
    patched_dir = stage / "patched" / "ios/Mobile"
    for directory in (original_dir, patched_dir):
        directory.mkdir(parents=True)
        shutil.copyfile(pinned, directory / Path(CONTROLLER).name)
    patch = BASE / embedding["patch"]
    # Apply only the DocumentViewController.mm portion of the embedding
    # overlay (the other files are irrelevant to this fixture).
    full = patch.read_text()
    parts, current = [], []
    for line in full.splitlines(keepends=True):
        if line.startswith("--- a/") and current:
            parts.append("".join(current))
            current = [line]
        else:
            current.append(line)
    parts.append("".join(current))
    embed_dvc = next(part for part in parts if part.startswith(f"--- a/{CONTROLLER}"))
    embed_patch = stage / "embedding-dvc.patch"
    embed_patch.write_text(embed_dvc)
    for variant in ("original", "patched"):
        root = stage / variant
        subprocess.run(["git", "apply", "-p1", str(embed_patch)], cwd=root, check=True,
                       capture_output=True)
        staged = root / CONTROLLER
        if sha256(staged) != embed_spec["preparedSHA256"]:
            raise ValueError(f"{variant}: embedding overlay output differs from the lock")
    subprocess.run(["git", "apply", "-p1", str(BASE / forwarding["patch"])],
                   cwd=stage / "patched", check=True, capture_output=True)
    if sha256(stage / "patched" / CONTROLLER) != forward_spec["preparedSHA256"]:
        raise ValueError("patched: forwarding overlay output differs from the lock")

    extracts = stage / "extracts"
    extracts.mkdir()
    base_lines = (stage / "original" / CONTROLLER).read_text().splitlines(keepends=True)
    helper = extract(base_lines, HELPER_START, HELPER_END, include_end=True)
    (extracts / "helper.inc.h").write_text("// Mechanical extraction by the test; do not edit.\n"
                                           + "".join(helper))
    for variant in ("original", "patched"):
        lines = (stage / variant / CONTROLLER).read_text().splitlines(keepends=True)
        body = extract(lines, HULLO_START, HULLO_END) + ["        }\n"]
        (extracts / f"loop_{variant}.inc.h").write_text(
            "// Mechanical extraction by the test; do not edit.\n" + "".join(body))
    return extracts


def build_variants(source_root, extracts, build):
    flags = ["-std=c++17", "-DNDEBUG", "-O1", "-g0",
             "-I", str(FIXTURES / "shim"), "-I", str(source_root / "net"),
             "-I", str(FIXTURES), "-I", str(build)]
    compile_steps = [
        ["clang++", *flags, "-c", str(source_root / "net/FakeSocket.cpp"),
         "-o", str(build / "fakesocket.o")],
        ["clang++", *flags, "-c", str(FIXTURES / "gates.cpp"),
         "-o", str(build / "gates.o")],
    ]
    for variant in ("original", "patched"):
        macro = "-DFLOE_VARIANT_ORIGINAL" if variant == "original" else "-DFLOE_VARIANT_PATCHED"
        compile_steps.append(["clang++", *flags, macro, "-fobjc-arc", "-fobjc-abi-version=3",
                              "-x", "objective-c++", "-c", str(FIXTURES / "driver.mm"),
                              "-o", str(build / f"driver-{variant}.o")])
    # The fixture driver includes the extracted loops from this directory.
    (build / "extracted").mkdir(exist_ok=True)
    for name in ("helper.inc.h", "loop_original.inc.h", "loop_patched.inc.h"):
        shutil.copyfile(extracts / name, build / "extracted" / name)
    for command in compile_steps:
        compiled = subprocess.run(command, capture_output=True, text=True)
        if compiled.returncode:
            raise RuntimeError("compile failed:\n" + compiled.stderr)
    for variant in ("original", "patched"):
        linked = subprocess.run(
            ["clang++", str(build / "fakesocket.o"), str(build / "gates.o"),
             str(build / f"driver-{variant}.o"), "-framework", "Foundation",
             "-o", str(build / f"harness-{variant}")],
            capture_output=True, text=True)
        if linked.returncode:
            raise RuntimeError("link failed:\n" + linked.stderr)


def run_matrix(build):
    failures = []
    rows = []
    for scenario, per_variant in MATRIX.items():
        for variant in ("original", "patched"):
            expectation = per_variant[variant]
            if expectation == "skip":
                rows.append({"scenario": scenario, "variant": variant, "verdict": "skip",
                             "detail": "non-deterministic on original; covered by double_hullo_race"})
                continue
            binary = build / f"harness-{variant}"
            try:
                ran = subprocess.run([str(binary), "--scenario", scenario],
                                     capture_output=True, text=True, timeout=60)
            except subprocess.TimeoutExpired:
                rows.append({"scenario": scenario, "variant": variant, "verdict": "FAIL",
                             "detail": "timeout"})
                failures.append(f"{scenario}/{variant}: timeout")
                continue
            detail = ""
            ok = True
            if expectation == "abort_length_error":
                if ran.returncode != -signal.SIGABRT:
                    ok, detail = False, f"expected SIGABRT, got {ran.returncode}"
                elif "FLOE_TERMINATE type=std::length_error" not in ran.stderr:
                    ok, detail = False, "SIGABRT without std::length_error marker"
                else:
                    detail = "died with SIGABRT via std::length_error"
            elif expectation == "exit0":
                if ran.returncode != 0:
                    ok, detail = False, f"expected exit 0, got {ran.returncode}: " + "\\n".join(
                        (ran.stdout + ran.stderr).splitlines()[-3:])
                else:
                    detail = "exit 0"
            rows.append({"scenario": scenario, "variant": variant,
                         "verdict": "pass" if ok else "FAIL", "detail": detail})
            if not ok:
                failures.append(f"{scenario}/{variant}: {detail}")
    return rows, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, help="root of the pinned upstream tree")
    parser.add_argument("--bundle", type=Path,
        help="extracted format-2 Office bundle (its source/ tree is used)")
    args = parser.parse_args()
    if not args.source and not args.bundle:
        parser.error("one of --source or --bundle is required")
    source_root = (args.source if args.source else args.bundle / "source").resolve()
    if not (source_root / CONTROLLER).is_file():
        parser.error(f"no {CONTROLLER} under {source_root}")
    if not (source_root / "net/FakeSocket.cpp").is_file():
        parser.error(f"no net/FakeSocket.cpp under {source_root}")
    if os.uname().sysname != "Darwin":
        parser.error("requires macOS (Foundation)")

    lock, forwarding, problems = lock_sections()
    summary = {"lockConsistency": {"lockChecked": not problems, "problems": problems},
               "kind": "app-side forwarding lifecycle; mock JS/engine, not a device reproduction"}
    errors = list(problems)
    if forwarding is not None:
        with tempfile.TemporaryDirectory(prefix="floe-forwarding-lifecycle-") as folder:
            folder = Path(folder)
            try:
                extracts = stage_variants(source_root, lock, forwarding, folder)
                build = folder / "build"
                build.mkdir()
                build_variants(source_root, extracts, build)
                rows, failures = run_matrix(build)
                summary["matrix"] = rows
                errors.extend(failures)
            except (RuntimeError, ValueError) as error:
                errors.append(str(error))
    summary["passed"] = not errors
    summary["errors"] = errors
    print(json.dumps(summary, indent=2))
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
