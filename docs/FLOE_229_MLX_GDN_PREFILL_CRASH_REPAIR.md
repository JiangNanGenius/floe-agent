# Build229 Qwen MLX GDN prefill crash — diagnosis and repair (2026-09-26)

Status: code fix committed on `codex/mlx-gdn-prefill-crash-repair` (`dc528428`).
Host-verified on macOS; cloud real-weight qualification and physical-iPad
acceptance remain separate, as noted below. Raw device logs stay in the
ignored private directory and are not copied here.

## Symptom (physical device, TestFlight Build229, iPad16,10)

- `EXC_BREAKPOINT` / `SIGABRT` ~54 s into an ordinary text prefill.
- Faulting stack (app binary, symbolicated by the crash reporter):
  `getItemND(src:operations:stream:)` ← `MLXArray.subscript.getter` ←
  `Qwen35GatedDeltaNet.generalConv(convState:qkv:)` ← `forward` ← decoder ←
  `Qwen35TextModel.callAsFunction` ← `LLMModel.prepare` windowed prefill.
- `abort()` was called by the FloeOfficeNative signal handler **after** the
  underlying Swift trap; Office is not the cause.
- Conditions at prepare: `qwen3.8-4b-heretic-mlx4`, 5,314 input tokens,
  constrained tier, `batch=8` (GDN chunk ceiling), `kvBits=4`, context 8,192,
  MLX active 2.21 GiB vs 2.47 GiB available (~280 MB headroom), second
  inference on a reused engine, no tool request.
- Build227 crashed twice in `gatedDeltaUpdate` (fused GDN kernel path —
  addressed by vendored patch 0001); Build228 crashed once in
  `gatedDeltaUpdate` (`_assertionFailure`) and once in
  `FloeLogger.RingBuffer.writeImmediately` while logging an already-handled
  MLX generation failure.

## Root cause (proven, not inferred from the stack)

1. The vendored windowed prefill (`Libraries/MLXLLM/LLMModel.swift`,
   default `LLMModel.prepare`) never checked the MLX error handler between
   its hundreds of prefill windows.
2. MLX reports C++ errors through a handler and then returns **degenerate
   0-dim arrays**; with the app’s task-local `withError` box installed, the
   error is captured (not thrown) and graph construction continues on those
   arrays. The first `errors.check()` only runs after the whole prefill.
3. Slicing a degenerate rank-0 array with three slice operations reaches
   `getItemND`’s slice loop with empty `starts`/`ends` arrays, and
   `starts[axis] = …` traps with Swift **Index out of range**
   (`ContiguousArrayBuffer.swift`, observed at `MLXArray+Indexing.swift:695`
   under lldb).
4. Host reproduction (scratch package, exact Qwen3.8-4B shapes B=1, S=8,
   convDim=3072, bf16): inject an MLX error → it is captured → the next
   three-slice subscript on the degenerate result traps at the identical
   site. Removing the per-window check turns a thrown `MLXError.caught`
   back into the same trap.

The probable device trigger for the first MLX error is the measured memory
margin: the macOS two-tool-turn run peaked at ~2.97 GiB MLX while the iPad
had ~2.47 GiB available, so a transient Metal allocation/command-buffer
failure mid-prefill is expected there. The exact Metal error string was not
captured on device; the repair below is trigger-agnostic.

The negative tail slice in `generalConv`
(`convInput[0..., (-(convKernelSize - 1))..., 0...]`) was investigated as
suspected and **exonerated**: exact-shape host tests (S = 8/48/96, bf16,
chunk boundaries, cache round trip) prove the conv/recurrent state shapes
and chunk handoff are correct; the trap requires a degenerate array that
only appears after an MLX error.

## Repair (vendored patch 0002)

`LLMModel.prepare` now runs the windowed prefill under a scoped
`MLX.withError` and checks the box **between every window** and once after
the final `eval(cache)`. The first MLX error throws as `MLXError.caught`
with the original message (e.g. “[METAL] Command buffer execution
failed…”), which `MLXTextEngine.generateGuarded` already maps to the
retryable `LocalInferenceError.decodeFailed` (one transparent
unload/recreate/retry exists at the adapter). Successful prefills are
unchanged — a clean box is a no-op check.

Provenance updated: `FLOE_SHA256SUMS` (510 files), `FLOE_VENDOR.md`,
`patches/0002-llmmodel-prefill-window-error-fail-fast.patch`. The vendor
audit (`floe_vendor_check.sh`) passes: tree digests match, and the patch
series replays byte-for-byte onto pristine upstream `d5d8b290`.

## Tests

Vendored `MLXLMTests` (new):

- `LLMModelPrepareFailFastTests` — un-poisoned prepare completes unchanged;
  a mid-prefill MLX error throws with the original message at the poisoned
  window instead of trapping one window later; a lazily-enqueued cache error
  is caught by the final flush check.
- `Qwen35GDNPrefillShapeTests` — production conv/recurrent state shapes at
  S = 8/48/96 bf16 through `generalConv`, `forward`, and the `MambaCache`
  round trip; `generalConv` chunk boundary is bitwise; `forward` chunk
  boundary tracks the whole prompt.

App tests: `LocalModelLifecycleTests.prefillMLXErrorSurfacesAsDecodeFailure`
locks the adapter contract (post-mapping `decodeFailed` earns exactly one
transparent retry and recovers).

Host results (macOS, Xcode-beta toolchain, FoundationModels trait
disabled): 8/8 new vendored tests, 15/15 GDN-related vendored tests
(existing `GatedDelta*`, `Qwen35*` decode/lifecycle tests), and 24/24
`LocalModelLifecycleTests` pass.

## Verification boundaries (explicit)

- macOS host evidence (above) validates code behavior only. It is **not**
  device acceptance.
- Cloud real-weight two-tool-turn qualification with this patch is tracked
  under the `local-inference-qualification` workflow on this branch; the
  earlier two-turn evidence (source SHA 11471d41, run 36245411220) predates
  this patch and does not clear the iPad crash.
- Physical iPad acceptance remains with the user. Expected post-fix device
  behavior if the memory margin is still exceeded: the turn fails with a
  logged, bounded diagnostic and one automatic retry instead of an app
  abort; prefill throughput and model output are unchanged on success.

## iPad-simulator feasibility (recorded blocker)

An iPad-simulator executable was assessed and is not a useful gate for this
repair, for two concrete reasons:

- The device trigger is memory margin. The iOS Simulator runs on the Mac's
  GPU and shares the Mac's unified memory, so the ~280 MB-headroom Metal
  allocation/command-buffer failure that precedes the crash cannot be
  reproduced there; a simulator run can only re-prove the throw-vs-trap
  behavior already covered by the macOS host tests above.
- Building an App simulator test host locally requires the full committed
  Xcode project's package-graph resolve and a multi-GB DerivedData build —
  the heavy App build this machine avoids per the repo rules; the vendored
  `MLXLMTests` are SPM-only and are not wired into the app project's
  simulator test targets, and no existing cloud workflow runs them on an
  iPad simulator. The cloud App build compiles the iOS slice, and the
  macOS-host real-weight qualification run covers behavior.

If a future slice wants simulator coverage of the vendored tests, the cheap
path is a small `Package.swift` qualification host built with
`-destination 'generic/platform=iOS Simulator'` in cloud CI, reusing the
office-simulator-stage boot/run pattern.

## Remaining risks / follow-ups

- If the device prefill still cannot fit its transient footprint in the
  constrained-tier headroom, the turn may still fail (gracefully) on very
  long prompts; a measured follow-up could synchronize per window or tune
  the MLX cache limit on that tier. That is a latency/reliability trade-off
  to decide with device data, not part of this repair.
- The same “continue after a captured error” hazard exists in principle for
  decode-time graph work; decode already checks the box per streamed event,
  and no decode-side trap has been observed.
