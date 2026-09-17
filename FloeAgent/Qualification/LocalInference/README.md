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

## Limits

This is a macOS host diagnostic. It has more memory and no
`os_proc_available_memory` pressure compared with iPadOS, so a pass here is not
iPad jetsam, iOS memory-allowance, Apple Pencil or physical-device acceptance.
A failure supplies an independent reproduction, not proof that it caused the
original device crash. Preserve the original uploaded report; it lacked
complete termination metadata.

The chunk count is an estimate from the pinned `prepare` loop: `(inputTokens - 1) / batchSize`, excluding its final decode block. `mlxProcessPeakIncreaseBytes` is growth of the process-wide high-water mark, not an independently reset per-profile peak. The reload question is self-contained because the inference engine does not preserve conversation history.
