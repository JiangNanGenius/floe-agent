/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* fvgpu_trace.h — bounded, opt-in lifetime tracing for the GPU backend.
 *
 * Disabled unless FLOE_GPU_TRACE is set to a non-empty value other than "0".
 * FLOE_GPU_TRACE_LIMIT caps emitted lines (default 4096, clamped 16..65536).
 * Only object ids, byte counts, refcounts and lifecycle states are emitted;
 * never guest payload, file paths, environment values or credentials.
 * Writes are line-buffered stdio under flockfile: output is bounded, but as
 * with any trace, a stalled stderr consumer can block the caller. Enable only
 * while a host reader is draining diagnostics. */
#ifndef FVGPU_TRACE_H
#define FVGPU_TRACE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

int fvgpu_trace_enabled(void);
#if defined(__GNUC__)
void fvgpu_trace(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#else
void fvgpu_trace(const char *fmt, ...);
#endif

#ifdef __cplusplus
}
#endif
#endif /* FVGPU_TRACE_H */
