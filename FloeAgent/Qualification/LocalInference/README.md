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

The manual dispatch and the `workflow_call` trigger both accept a
`dependency_profile` input, defaulting to `current`.

| Profile | Root `FloeAgent/Package.swift` |
| --- | --- |
| `current` (default) | Committed pins. No dependency file is modified. |
| `gpu-fix-candidate` | Only in the CI working copy, an isolated two-declaration patch is applied. |

`gpu-fix-candidate` pins the MLX runtime `mlx-swift` to
`ab924c82ead3b970caaa1c0ac11171de23f0305a` (the upstream GPU error-handling
fix) and `mlx-swift-lm` to
`d5d8b290e601ac1bf11f24635f8f811a83b98bf8`, which keeps the existing
prefill-parameter behavior and contains upstream #389/#381/#488. The patch is
applied by `FloeAgent/scripts/qualify_mlx_candidate.py apply-patch`, which first
proves the two original declarations match the committed pins exactly and then
refuses unless only those two lines change. The product `Package.swift` and
every committed `Package.resolved` are never edited in the repository; the
default `current` profile does not run the patch step at all.

After the patch (or no patch for `current`) the workflow runs a real
`swift package --package-path Qualification/LocalInference --scratch-path .build
resolve` and verifies the frozen lock: the two target revisions must be exact
and every other pin must be byte-identical to the committed baseline lock. A
new, removed or drifted pin fails the run explicitly and is retained for
evaluation, so a candidate is never silently upgraded. Compilation still uses
`--force-resolved-versions` and inference reuses the existing single-download
48/96 flow; no full-App CI runs.

### Evidence

Everything is written under `LocalInferenceEvidence` and uploaded as
`local-inference-diagnostic-<dependency_profile>-<sha>` even when resolve fails:
`SOURCE-SHA.txt`, `dependency-profile.txt`, `FloeAgent-Package.swift.original`
and `.candidate`, `candidate-manifest.diff`, `candidate-apply.json`,
`LocalInference-Package.resolved.original.json` and `.resolved.json`,
`resolve.log`, `resolve-exit-code.txt`, `lock-evaluation.json`,
`lock-verify-exit-code.txt`, `build.log`, `run.log` and `toolchain.txt`.

Important: this evidence is a commit SHA **plus a candidate patch applied in
the CI working copy**; it is not a build of the original commit exactly as
committed. A `gpu-fix-candidate` result says whether that patched dependency
set resolves, compiles and runs, and does not change or certify the product
pins.

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
