# ARM64 CPU state isolation — 2026-11-06

> Current evidence entry / 当前证据入口:
> [ARM64 runtime performance](ARM64_RUNTIME_PERFORMANCE.md), reviewed 2026-11-10.
> This report contains the later accepted separation change: **3.79×** host
> component scaling and **2.31×** physical M4 Build 319 sysbench scaling.
> Current main retains the change; no new M1 measurement is implied.

Build 315's formal App Store review remains fixed. Follow-up App delivery is
internal and external TestFlight only. Native component measurements on the
M5 Pro host and the separately verified physical M4 iPad results are identified
below; neither is a universal performance guarantee.

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

## Physical M4 iPad — delivered Build 319

The actual installed TestFlight App was independently read back as 1.7.78
(319), source `c0aea38a8beda63bb6dcca32f6b4a84fe5dc7663`. The same M4
iPad Air 13-inch/iPadOS 27.2 ran the unchanged sysbench 1.0.20 CPU fixture
with four online guest CPUs, 1 GiB RAM, affinity 0–3 and no CPU quota. Each
trial completed exactly 1,000 total events at max-prime 10,000 without a time
limit. There were three counterbalanced repetitions at each thread count;
all nine raw results and unchanged executable/script hashes were checked.

| App build | 1-thread median events/s | 2-thread median events/s | 4-thread median events/s |
| --- | ---: | ---: | ---: |
| 315 | 121.69 | 208.01 | 182.80 |
| 316 | 128.66 | 208.91 | 186.54 |
| 317 | 128.62 | 215.57 | 188.40 |
| 319 | 127.49 | 232.76 | 294.24 |

Build 319's four-thread throughput was 2.31× its single-thread throughput,
and 56.18% above Build 317's four-thread result. The single-thread median was
0.88% lower than 317, effectively unchanged in these separate device runs.
This confirms useful concurrent execution, not linear fourfold scaling.
Temperature and physical-core placement were not controlled. The earlier
host-only register test and Linux five-process pair remain distinct evidence.
Build 320 retains exactly the same pinned runtime source; it cannot count
this improvement as a second performance gain.

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

A SHA256-helper acceleration experiment also passed 20,480 decoded-state
comparisons, scalar-fallback comparison and sanitizer checks. Its SHA-specific
native instruction workload improved approximately 17% at one worker, but the
actual Linux crypto workload regressed 26.5% and compression regressed 3.4%
against the unchanged, verified separated-CPU baseline. It was rejected; the
production source retains the original SHA implementation. An initial archive
replacement used the wrong object member name and was explicitly invalidated;
the corrected run and the original failure are both retained. Neither
microbenchmark gain is presented as a general interpreter improvement.

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
