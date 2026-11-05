# ARM64 interpreter follow-up — 2026-11-06

This increment retains the existing ARM64 engine, resident Linux environment,
native-JIT prohibition and synchronization model. It does not change the frozen
Build 315 App Store submission. Subsequent App delivery is TestFlight only.

## Changes

- Already-bound per-hart MMU banks avoid an out-of-line binding call on each
  instruction/data access. Cold allocation and failure handling remain intact.
- Stack memory instructions use existing predecoded handlers when the live stack
  pointer is aligned. Misaligned stacks use the original decoder, retaining
  alignment/FP exception order. The cached entry remains 16 bytes and contains
  instruction metadata, never a saved stack or CPU state.
- Stop, IRQ, TLBI, shared-memory synchronization, total instruction budgets and
  the existing 16K maximum ticket remain unchanged.
- Hart padding was measured and rejected; it is not part of this change.

## Evidence and limits

Actual macOS arm64 object builds passed 1,056 stack/alignment/FP comparisons and
192 MMU/fault comparisons against the decoder. Ten normal components passed.
All 30 translation units were rebuilt with ThreadSanitizer; twelve components,
including those comparisons and real concurrent memory/worker tests, passed.

The fixed-total-work native stack workload improved throughput by approximately
28%, 38% and 55% at one, two and four workers. This is a narrow synthetic result.
The combined candidate's ordinary register workload improved approximately 4%,
6% and 3%, respectively.

One actual Linux pair using unchanged crypto/compression inputs and result
goldens improved PBKDF2 throughput by **4.14%** and zlib by **1.74%**. These are
shared-host observations, not statistically established universal gains or
physical iPad performance. The local component results do not establish that
four-core scaling is solved.

A second actual Linux/Python pair used 16 fixed units of 24,000 integer-loop
iterations, unchanged inputs/checksums, and three counterbalanced repetitions
per process count. Median runtime changed from 6.296274003 to 5.528852003 seconds
with one process, and from 5.029819002 to 4.616245002 seconds with two processes:
throughput improved **13.9%** and **9.0%**. Both variants used the same explicit
shared-memory mount before timing and passed boot, result, reaping and original
crypto/compression/lifecycle checks. The initial missing-shared-memory fixture
failure remains recorded. These host measurements do not replace the smaller
crypto/compression results or establish physical-iPad/four-core gains.

The integrated Swift 6 App and test bundle compiled with Xcode 27.1 (27A9275).
The canonical iPad simulator passed 52 audio/CAD-observation tests with no skips.
This proves those service/contracts on Simulator, not physical audio output or
the model provider's receipt of a CAD screenshot.

Original failures remain recorded: an obsolete single-CPU fixture fails the
same old control hook on the unchanged baseline, and the first audio test
selector executed zero cases. Neither is reported as a pass. Current console
readiness-pipe descriptors were accounted for in private compatibility fixtures
without relaxing final leak checks or architectural assertions.

The audio regression observed a backend gain of 0.6 at resume after the
saved preference changed to 0 or 0.25. Both parameter cases failed on the frozen
315 host and passed after applying gain before resume; zero-gain playback
continues running. CAD observation now also accepts named standard views and
returns actionable validation for unknown names.

## Follow-up scheduler candidate

Apple worker threads now explicitly carry their owner's public QoS class;
interactive owners are capped at user-initiated, while utility/background
owners retain their lower class. The persistent Swift VM owner is marked
user-initiated before starting. Idle parking, worker counts, cancellation and
architectural synchronization remain unchanged.

A new native contract executes real guest instructions on twelve workers across
utility, user-initiated and interactive owners. The unchanged 316 archive fails
the QoS contract while still executing and joining correctly; the candidate
passes all twelve observations. The existing parallel-worker, budget-gap and
fast-poll components also pass, both normally and with ThreadSanitizer. These
results establish scheduling and lifecycle behavior, not physical-iPad speed.

ThinLTO was separately measured on one unchanged Linux crypto/compression pair
and rejected: both throughput changes were approximately -0.1%. No ThinLTO
build flag is included. Physical-device comparison of the released 316 build
and qualification of this newer scheduling candidate remain separate work.

The local Linux graphical-program startup/display/input chain is still absent;
the existing text terminal and remote VNC support do not establish that feature.

## Physical M4 iPad follow-up

The installed TestFlight 315 and 316 builds were compared on the same M4 iPad,
using the unchanged sysbench 1.0.20 binary and fixture, four online guest CPUs,
1 GiB RAM, and three counterbalanced trials of 1,000 total events per thread
count. Median events/s for one/two/four threads were 121.69/208.01/182.80 on
315 and 128.66/208.91/186.54 on 316: approximately +5.7%/+0.4%/+2.0%.
Four-thread trials varied within each build; the small multicore differences
do not establish a broad improvement. Four-thread scaling on 316 remains
approximately 1.45x single-thread performance. This is not evidence of efficient
four-core saturation or a thermal measurement.

The actual 316 native terminal independently displayed all 120 flushed mixed
Chinese/ASCII lines across two idle gaps, then the final completion marker and
shell prompt, with no key or touch input after the successful start. Guest
output checksums and the observed final marker were retained separately. This
single real-device path did not reproduce the old keypress-gated output defect;
background/reconnection variants remain outside that observation.
