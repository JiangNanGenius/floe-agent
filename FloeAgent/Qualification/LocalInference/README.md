# Qwen real-weight 48/96 diagnostic

Manual cloud workflow `local-inference-qualification.yml` loads the exact
catalog-pinned Qwen3.8 snapshot through production `LocalModelStore` and
`MLXTextEngine` and exercises the two resource profiles observed in the Build
178 iPad crash:

| Case label | Tier | Context | Prefill batch | Derived kvBits | gpuLayers |
| --- | --- | --- | --- | --- | --- |
| `constrained-batch48` | constrained | 8,192 | 48 | 4 | 16 |
| `balanced-batch96` | balanced | 12,288 | 96 | 8 | 24 |

These literals mirror `LocalInferenceResourcePolicy.profile(mappedBytes:
physicalMemoryBytes:)`; the product policy and engine are not modified. The
`batchSize` becomes `GenerateParameters.prefillStepSize` and the tier selects
`kvBits` 4/8 inside the unchanged engine.

## What one run does

1. Downloads the pinned snapshot once into one `LocalModelStore` root on the
   ephemeral runner and reuses that directory for both profiles.
2. For each profile, one engine is alive at a time:
   - a short benchmark-style prompt;
   - a chat turn whose SYSTEM message is a synthetic ~12,000-character document
     with a 15-character user prompt, matching the shape of the App's
     `sourceCharacters=12015 promptCharacters=15` turn. The prepared prompt must
     span at least 3 prefill chunks or the run throws and records
     `multi-chunk-failed` with the actual token/chunk counts;
   - `engine.shutdown()`, then one reload and a short follow-up question, to
     cover per-turn teardown and a cold reload at the same profile.
3. The optional original baseline (batch 32) is **not** run by default. Pass
   `--include-baseline` to add the first cloud run's three prompts once.

Per-profile JSON events carry `profile`, `tier`, `batchSize`, `contextSize`,
`kvBits`, `model`, MLX active/peak/cache bytes, `mlxProcessPeakIncreaseBytes`
and process footprint. `generation-complete` additionally records
`inputTokens`, `outputTokens`, `estimatedPrefillChunks`, `elapsedSeconds`,
`generationDurationMs` and `timeToFirstTokenMs`. Output text is synthetic model
output and contains no user content.

Failure handling: `generation-failed`, `load-failed`, `multi-chunk-failed` and
the top-level `qualification-failed` record domain/code/message before the
process exits non-zero. The workflow still uploads `run.log` (`if: always()`)
and asserts `multi-chunk-verified` twice, one per profile. The engine was not
changed to make any assertion pass.

## Dependency profiles

Both triggers accept `dependency_profile`, defaulting to `current`.

| Profile | Root `FloeAgent/Package.swift` |
| --- | --- |
| `current` | Committed production pins; no patch. |
| `historical-baseline` | In the CI working copy only, restore the two frozen pre-adoption declarations. |

Current pins are `mlx-swift` `ab924c82ead3b970caaa1c0ac11171de23f0305a`
and `mlx-swift-lm` `d5d8b290e601ac1bf11f24635f8f811a83b98bf8`.
The historical pair is mlx-swift 0.31.4 (`dc43e62d7055353c7f99fa071a4e71d29dfddc44`)
and mlx-swift-lm `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`.
The patch guard verifies the original declarations and allows exactly those
two lines to change. The real SwiftPM resolver then runs; lock verification
rejects additional, removed or drifted dependencies except the documented
app-only omission below. Compilation uses `--force-resolved-versions`.

The production engine disables compiled traces once, before model loading.
The workflow clears `MLX_DISABLE_COMPILE` and checks emitted policy metadata,
so a pass must exercise the API policy itself. Both dependency profiles use
this policy: the historical profile restores dependency pins, not every aspect
of the older executable. Reproducing the earlier compile-enabled comparison
requires its original immutable source/workflow.

### Evidence

Artifacts are named `local-inference-diagnostic-<dependency_profile>-<sha>`.
They retain source SHA, toolchain, original manifest and lock, resolved lock,
resolver/verification logs, build log and runtime log even on failure. A
historical-baseline run additionally retains `.baseline`,
`baseline-manifest.diff` and `baseline-apply.json`. Its identity is the source
SHA plus that isolated patch; a current run uses the committed manifest.

See [the feedback evidence](../../../docs/FLOE_BUILD178_FEEDBACK_REPAIR.md)
for the original compile-enabled failure and environment-disabled control.
Neither replaces testing the production API policy or the reported iPad crash.

## Limits

This is a macOS host diagnostic. It has more memory and no
`os_proc_available_memory` pressure compared with iPadOS, so a pass here is not
iPad jetsam, iOS memory-allowance, Apple Pencil or physical-device acceptance.
A failure supplies an independent reproduction, not proof that it caused the
original device crash. Preserve the original uploaded report; it lacked
complete termination metadata.

The chunk count is an estimate from the pinned `prepare` loop: `(inputTokens - 1) / batchSize`, excluding its final decode block. `mlxProcessPeakIncreaseBytes` is growth of the process-wide high-water mark, not an independently reset per-profile peak. The reload question is self-contained because the inference engine does not preserve conversation history.

The shared committed lock also contains the app-only WhisperKit dependency.
The host resolver may omit it only when its immutable pin exactly matches
`project.yml`; this omission is recorded separately. Other removed, added or
drifted dependencies still fail verification.
