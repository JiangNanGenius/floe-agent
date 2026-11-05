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
four-core scaling is solved. A fixed-work Python/Linux pair is tracked
separately, without replacing these smaller results.

The integrated Swift 6 App and test bundle compiled with Xcode 27.1 (27A9275).
The canonical iPad simulator passed 52 audio/CAD-observation tests with no skips.
This proves those service/contracts on Simulator, not physical audio output or
the model provider's receipt of a CAD screenshot.

Original failures remain recorded: an obsolete single-CPU fixture fails the
same old control hook on the unchanged baseline, and the first audio test
selector executed zero cases. Neither is reported as a pass. Current console
readiness-pipe descriptors were accounted for in private compatibility fixtures
without relaxing final leak checks or architectural assertions.

The audio regression reproduced an audible gain of 0.6 at resume after the
saved preference changed to 0 or 0.25. Both parameter cases failed on the frozen
315 host and passed after applying gain before resume; zero-gain playback
continues running. CAD observation now also accepts named standard views and
returns actionable validation for unknown names.
