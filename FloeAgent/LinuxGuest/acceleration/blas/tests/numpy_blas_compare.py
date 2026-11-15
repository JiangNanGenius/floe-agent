#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Real same-process NumPy float32 GEMM vs float64 CPU reference check.

Run inside the resolved Linux guest through the normal entry:

    floe-blas-run -- python3 tests/numpy_blas_compare.py --size 512

The float32 ``A @ B`` is expected to call the preloaded provider's
``cblas_sgemm``; the float64 reference uses the untouched dgemm path.  The
script reads the provider's actual counters through the optional C stats API,
so a CPU-only execution cannot pass.  It reports transfers/readback by timing
the whole provider call after a separate warmup; it makes no OpenBLAS speed
claim.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import time

LIBRARY = "/usr/local/lib/floe-acceleration/libfloe_blas.so"


class Stats(ctypes.Structure):
    _fields_ = [
        ("struct_size", ctypes.c_uint32),
        ("api_version", ctypes.c_uint32),
        ("calls_total", ctypes.c_uint64),
        ("gemm_calls", ctypes.c_uint64),
        ("gemv_calls", ctypes.c_uint64),
        ("gpu_submitted", ctypes.c_uint64),
        ("gpu_completed", ctypes.c_uint64),
        ("gpu_failed", ctypes.c_uint64),
        ("gpu_dispatches", ctypes.c_uint64),
        ("fallback_cpu", ctypes.c_uint64),
        ("fallback_reference", ctypes.c_uint64),
        ("cpu_shortcuts", ctypes.c_uint64),
        ("invalid_args", ctypes.c_uint64),
        ("threshold_skipped", ctypes.c_uint64),
        ("budget_skipped", ctypes.c_uint64),
        ("nonfinite_skipped", ctypes.c_uint64),
        ("device_unavailable", ctypes.c_uint64),
        ("device_lost", ctypes.c_uint64),
        ("alias_copies", ctypes.c_uint64),
        ("gpu_floats_uploaded", ctypes.c_uint64),
        ("gpu_floats_downloaded", ctypes.c_uint64),
        ("gpu_present", ctypes.c_uint32),
        ("policy", ctypes.c_uint32),
        ("device_name_size", ctypes.c_uint32),
        ("last_error_size", ctypes.c_uint32),
        ("device_name", ctypes.c_char * 128),
        ("last_error", ctypes.c_char * 160),
    ]


def fail(message: str, code: int = 3) -> "NoReturn":
    print(json.dumps({"ok": False, "error": message}, separators=(",", ":")))
    raise SystemExit(code)


def load_provider():
    if LIBRARY not in os.environ.get("LD_PRELOAD", ""):
        fail("provider-not-preloaded: " + LIBRARY)
    for candidate in (None, LIBRARY):
        try:
            library = ctypes.CDLL(candidate) if candidate else ctypes.CDLL(None)
            getter = library.floe_blas_stats_get
            resetter = library.floe_blas_stats_reset
            warmup = library.floe_blas_warmup
            break
        except (OSError, AttributeError):
            continue
    else:
        fail("provider-stats-symbol-missing")
    getter.argtypes = [ctypes.POINTER(Stats)]
    getter.restype = ctypes.c_int
    resetter.argtypes = []
    resetter.restype = ctypes.c_int
    warmup.argtypes = []
    warmup.restype = ctypes.c_int

    def snapshot() -> Stats:
        value = Stats()
        value.struct_size = ctypes.sizeof(Stats)
        if getter(ctypes.byref(value)) != 0:
            fail("provider-stats-get-failed")
        return value

    return snapshot, resetter, warmup


def delta(after: Stats, before: Stats, field: str) -> int:
    return int(getattr(after, field)) - int(getattr(before, field))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--tolerance", type=float, default=2e-4)
    arguments = parser.parse_args()
    if arguments.size < 16 or arguments.size > 4096:
        fail("size must be in 16..4096", 2)
    try:
        import numpy as np
    except Exception as error:  # noqa: BLE001 - report the real import failure
        fail("numpy-import-failed: %s" % error)

    snapshot, reset, warmup = load_provider()
    if warmup() != 0:
        fail("provider-warmup-failed")
    before = snapshot()
    if before.device_name_size == 0:
        fail("provider-device-name-missing")

    rng = np.random.default_rng(20261112)
    size = arguments.size
    a32 = rng.standard_normal((size, size), dtype=np.float32)
    b32 = rng.standard_normal((size, size), dtype=np.float32)
    a64 = a32.astype(np.float64)
    b64 = b32.astype(np.float64)
    reference = a64 @ b64

    # Small float32 work must stay on the original CPU BLAS by default.
    reset()
    small_before = snapshot()
    _ = a32[:4, :4] @ b32[:4, :4]
    small_after = snapshot()

    # Float64 must not be cast to float32 and must not enter the GPU path.
    reset()
    float64_before = snapshot()
    float64_result = a64 @ b64
    float64_after = snapshot()
    float64_gpu = delta(float64_after, float64_before, "gpu_completed")
    float64_error = float(np.max(np.abs(float64_result - reference)))

    reset()
    gpu_before = snapshot()
    start = time.perf_counter_ns()
    result32 = a32 @ b32
    elapsed_ns = time.perf_counter_ns() - start
    gpu_after = snapshot()

    submitted = delta(gpu_after, gpu_before, "gpu_submitted")
    completed = delta(gpu_after, gpu_before, "gpu_completed")
    dispatches = delta(gpu_after, gpu_before, "gpu_dispatches")
    fallback_cpu = delta(gpu_after, gpu_before, "fallback_cpu")
    fallback_reference = delta(gpu_after, gpu_before, "fallback_reference")
    small_gpu = delta(small_after, small_before, "gpu_completed")
    maximum_error = float(np.max(np.abs(result32.astype(np.float64) - reference)))
    scale = float(np.max(np.abs(reference)))
    relative_error = maximum_error / max(1.0, scale)
    accepted = (submitted >= 1 and completed >= 1 and dispatches >= 1 and
                small_gpu == 0 and float64_gpu == 0 and
                relative_error <= arguments.tolerance)
    output = {
        "ok": accepted,
        "kind": "numpy-blas-compare",
        "numpyVersion": np.__version__,
        "size": size,
        "device": gpu_after.device_name.decode("utf-8", "replace"),
        "gpuSubmittedDelta": submitted,
        "gpuCompletedDelta": completed,
        "gpuDispatchDelta": dispatches,
        "fallbackCpuDelta": fallback_cpu,
        "fallbackReferenceDelta": fallback_reference,
        "smallFloat32GpuDelta": small_gpu,
        "float64GpuDelta": float64_gpu,
        "float64ReferenceError": float64_error,
        "maxAbsError": maximum_error,
        "relativeError": relative_error,
        "tolerance": arguments.tolerance,
        "elapsedNsIncludingTransfers": elapsed_ns,
        "gpuFloatsUploadedDelta": delta(gpu_after, gpu_before,
                                        "gpu_floats_uploaded"),
        "gpuFloatsDownloadedDelta": delta(gpu_after, gpu_before,
                                          "gpu_floats_downloaded"),
        "note": "Float32 GEMM only; float64 uses dgemm untouched. "
                "No OpenBLAS speedup claim.",
    }
    print(json.dumps(output, separators=(",", ":")))
    if not accepted:
        if submitted == 0 or completed == 0:
            print("NumPy did not reach the provider's cblas_sgemm; inspect "
                  "NumPy's BLAS linkage and preload.", file=sys.stderr)
        elif small_gpu != 0:
            print("A small float32 call incorrectly reached the GPU "
                  "threshold path.", file=sys.stderr)
        elif float64_gpu != 0:
            print("Float64 entered the GPU path; precision policy is broken.",
                  file=sys.stderr)
        else:
            print("Numerical error exceeded tolerance.", file=sys.stderr)
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
