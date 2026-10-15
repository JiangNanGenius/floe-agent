#!/usr/bin/env python3
"""guest_bench.py — the fixed Floe Linux guest benchmark (contract-defined).

This workload is intentionally fixed: identical byte-for-byte before and after
any optimization attempt, identified by its sha256. It runs INSIDE the guest
(TinyEMU, interpreted RISC-V) and prints structured `BENCH key=value` lines
plus one `BENCH_JSON {...}` line and a `BENCH_DONE` marker.

Workloads (contract):
  * lcg2m             — integer LCG, 2,000,000 iterations
  * sha128m           — sha256 over 128 MiB (generation excluded: prebuilt buffer)
  * mem64m_pages32    — 64 MiB bytearray touched as 32 x 2 MiB pages
  * fs_write32m_fsync — 32 MiB written + fsync in a fresh subdir
  * fs_read32m        — the same file read back pure (no hash)
  * fs_readhash32m    — the same file read back and hashed
  * files300x4k       — 300 x 4 KiB files created
  * cleanup           — the fresh subdir removed

Usage: guest_bench.py <shared-root> <run-id>
"""

import hashlib
import json
import os
import platform
import shutil
import ssl
import sys
import time

ROOT = sys.argv[1] if len(sys.argv) > 1 else "/mnt/bench"
RUN_ID = sys.argv[2] if len(sys.argv) > 2 else "run"
WORK = os.path.join(ROOT, f"work-{RUN_ID}")

results = {}
notes = {}


def emit(name, seconds, **extra):
    results[name] = seconds
    fields = " ".join(f"{key}={value}" for key, value in extra.items())
    print(f"BENCH {name} seconds={seconds:.6f} {fields}".rstrip(), flush=True)


def identity():
    notes["machine"] = platform.machine()
    notes["platform"] = platform.platform()
    notes["python"] = sys.version.split()[0]
    notes["openssl"] = ssl.OPENSSL_VERSION
    notes["hashlib_sha256"] = "sha256" in hashlib.algorithms_available
    notes["cpu_model"] = "unknown"
    try:
        with open("/proc/cpuinfo", "r", errors="replace") as handle:
            for line in handle:
                if line.lower().startswith(("model name", "hardware", "processor")):
                    notes["cpu_model"] = line.strip().split(":", 1)[-1].strip()
                    break
    except OSError:
        pass
    try:
        stat = os.statvfs(WORK)
        notes["work_fs_free_mb"] = round(stat.f_bavail * stat.f_frsize / 1048576, 1)
        notes["work_fs_block"] = stat.f_bsize
    except OSError:
        pass
    try:
        with open("/proc/meminfo", "r", errors="replace") as handle:
            for line in handle:
                if line.startswith("MemTotal"):
                    notes["mem_total_kb"] = int(line.split()[1])
                    break
    except OSError:
        pass
    notes["cwd"] = os.getcwd()
    notes["work"] = WORK
    print("BENCH_IDENTITY " + json.dumps(notes, sort_keys=True), flush=True)


def lcg2m():
    start = time.perf_counter()
    state = 123456789
    acc = 0
    for _ in range(2_000_000):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        acc ^= state
    elapsed = time.perf_counter() - start
    emit("lcg2m", elapsed, checksum=acc)


def sha128m():
    block = bytes(range(256)) * 4096  # 1 MiB deterministic buffer
    start = time.perf_counter()
    digest = hashlib.sha256()
    for _ in range(128):
        digest.update(block)
    elapsed = time.perf_counter() - start
    emit("sha128m", elapsed, digest=digest.hexdigest()[:16])


def mem64m_pages32():
    start = time.perf_counter()
    buffer = bytearray(64 * 1024 * 1024)
    page = 2 * 1024 * 1024
    checksum = 0
    for index in range(32):
        offset = index * page
        buffer[offset:offset + page] = b"\xa5" * page
        checksum = (checksum + buffer[offset]) & 0xFF
    elapsed = time.perf_counter() - start
    emit("mem64m_pages32", elapsed, checksum=checksum)
    del buffer


def file_paths():
    return os.path.join(WORK, "stream.bin")


def fs_write32m_fsync():
    chunk = b"\x5a" * (1024 * 1024)
    path = file_paths()
    start = time.perf_counter()
    with open(path, "wb") as handle:
        for _ in range(32):
            handle.write(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    elapsed = time.perf_counter() - start
    emit("fs_write32m_fsync", elapsed, bytes=32 * 1024 * 1024)


def fs_read32m():
    path = file_paths()
    start = time.perf_counter()
    total = 0
    with open(path, "rb") as handle:
        while True:
            data = handle.read(1024 * 1024)
            if not data:
                break
            total += len(data)
    elapsed = time.perf_counter() - start
    emit("fs_read32m", elapsed, bytes=total)


def fs_readhash32m():
    path = file_paths()
    start = time.perf_counter()
    digest = hashlib.sha256()
    total = 0
    with open(path, "rb") as handle:
        while True:
            data = handle.read(1024 * 1024)
            if not data:
                break
            total += len(data)
            digest.update(data)
    elapsed = time.perf_counter() - start
    emit("fs_readhash32m", elapsed, bytes=total, digest=digest.hexdigest()[:16])


def files300x4k():
    directory = os.path.join(WORK, "files")
    os.makedirs(directory, exist_ok=True)
    payload = b"\x33" * 4096
    start = time.perf_counter()
    for index in range(300):
        with open(os.path.join(directory, f"f{index:04d}.dat"), "wb") as handle:
            handle.write(payload)
    elapsed = time.perf_counter() - start
    emit("files300x4k", elapsed, files=300)


def cleanup():
    start = time.perf_counter()
    shutil.rmtree(WORK, ignore_errors=True)
    elapsed = time.perf_counter() - start
    emit("cleanup", elapsed)


def main():
    os.makedirs(ROOT, exist_ok=True)
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    identity()
    lcg2m()
    sha128m()
    mem64m_pages32()
    fs_write32m_fsync()
    fs_read32m()
    fs_readhash32m()
    files300x4k()
    cleanup()
    print("BENCH_JSON " + json.dumps({"run": RUN_ID, "results": results, "identity": notes}, sort_keys=True), flush=True)
    print("BENCH_DONE", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
