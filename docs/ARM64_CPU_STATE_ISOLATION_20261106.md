# ARM64 CPU state isolation — 2026-11-06

Build 315's formal App Store review remains fixed. Follow-up App delivery is
internal and external TestFlight only. The results below are native component
measurements on the M5 Pro host; physical M4 iPad acceptance is separate.

## Interpreter comparison and identified bottleneck

The historical TinyEMU interpreter used atomic ordinary RAM reads and an
arm/drain fast-store protocol, with special operations and devices synchronized
separately. Each RISC-V CPU was allocated separately. The ARM64 interpreter has
private decode/MMU caches and guarded shared-memory accesses, but embeds its CPU
states contiguously inside Machine.

The original ARM64 CPU size was 1,456 bytes. Its retired-instruction counter
starts at offset 1,432 and its current-instruction PC at 1,440; the next CPU's
execution context begins only 24 bytes after that counter. These frequently
written and frequently read fields can share a host cache line. This is false
sharing: correctly independent virtual CPUs invalidate each other's host cache
lines without sharing guest data.

The fix adds 128 bytes of trailing separation per CPU, or 640 bytes for all five
possible CPUs. It does not increase CPU alignment, change ordinary allocation,
remove locks, reduce interrupt/stop/TLB checks, change instruction budgets or
generate executable code. All engine translation units must be rebuilt because
CPU and Machine are internal C layouts. The public execution ABI and saved
project/environment formats are unchanged.

`CPUStateIsolationTests.c` checks actual session allocations, separation,
ordinary alignment, destroy and stale-handle behavior. Twelve relevant native
components passed normally and with ThreadSanitizer after rebuilding all 30
translation units for each layout.

## Fixed-work measurements

The unchanged register workload runs 12 million total iterations and validates
retired instructions and register checksums. Baseline/candidate order and worker
counts are counterbalanced, with nine observations per worker count/variant.

| Workers | Baseline median | Separated CPU states | Throughput change |
| --- | ---: | ---: | ---: |
| 1 | 317.751 ms | 316.701 ms | +0.33% |
| 2 | 166.966 ms | 165.023 ms | +1.18% |
| 4 | 151.064 ms | 83.497 ms | +80.92% |

Four-worker scaling in this narrow workload moves from 2.10× to 3.79×.
Single-worker performance is effectively unchanged, rather than an established
single-core improvement. Physical iPad comparison must retain the single-core
case as well as the two/four-core cases; a multicore gain cannot hide a
single-core regression.

A separate actual Linux pair used the existing fixed five-process crypto and
compression fixture, unchanged guest inputs, native libraries, work counts and
result goldens. All five child affinities, results, reap receipts and guest
shutdown/join/destroy checks passed. The resource samples recorded no overlapping
heavy compiler/VM job or memory-pressure event during either run.

| Actual Linux workload | Baseline | Separated CPU states | Throughput change |
| --- | ---: | ---: | ---: |
| PBKDF2-SHA256, 40 total units | 34.252110016 s | 20.823586010 s | +64.49% |
| zlib round trip, 320 total units | 51.861670025 s | 28.386736014 s | +82.70% |

This is one matched host pair, not a universal or statistically established
speed claim. It is not physical iPad evidence, and does not establish the same
gain for every task.

## Further observable interpreter work

Sampling the unchanged native Linux two-worker fixture identified instruction
fetch and ordinary memory access as meaningful costs. Controller waits were
excluded from the interpreter-worker denominator. Samples are stack
observations, not guest opcode counts or physical CPU utilization.

A separate forced-inline/hot-cold instruction-fetch experiment regressed the
fixed register workload by approximately 5.5%, 8.7% and 3.9% at one/two/four
workers. It was rejected and is not in the production source. Subsequent
interpreter-efficiency changes require their own correctness and before/after
measurements; CPU-state separation cannot be counted twice.

The retained historical TinyEMU result is a different three-process `dd`
workload on the Mac host: 1.21/0.68/0.45 seconds at one/two/three harts, or
2.689× three-hart scaling. No retained matched physical-iPad four-hart 3.5×
record was located in the scoped records. Those old timings are not directly
comparable with current iPad sysbench. TinyEMU was neither restored nor run.

Original failures remain in private evidence: an initial four-CPU profile was
rejected by the frozen two-CPU fixture, and the first new layout test used a
version-2 ABI number with the smaller version-1 configuration struct. The
fixture was corrected to provide the real version-2 configuration; production
validation and assertions were retained.
