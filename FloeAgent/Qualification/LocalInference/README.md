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
4. After both profiles have shut down, load the same pinned weights through
   `LocalProviderAdapter`. In the first user turn the model must request
   `workspace.readFile`; the host executes it against a synthetic UTF-8
   fixture, returns the matching call ID and receipt, and checks the answer.
   In a second user turn the model must request a different file with a new
   call ID, then consume that receipt and answer again. Two `tool-executed`
   events and `tool-roundtrip-complete` are separate gates.
   This is a real model/tool-protocol host test, not an iPad simulator or
   physical-device result.

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
| `current` | Committed production declarations; no patch: remote `mlx-swift` revision + the reviewed in-repo `mlx-swift-lm` package. |
| `historical-baseline` | In the CI working copy only, replace those two declarations with the two frozen pre-adoption remote declarations. |

Current declarations are `mlx-swift`
`ab924c82ead3b970caaa1c0ac11171de23f0305a` (remote revision) and `mlx-swift-lm`
`.package(name: "mlx-swift-lm", path: "ThirdParty/MLXSwiftLM")`. The local copy
is the reviewed upstream tree at
`d5d8b290e601ac1bf11f24635f8f811a83b98bf8` plus Floe patch
`patches/0001-gdn-prefill-t1-ops-route.patch`; its provenance notes live in
`ThirdParty/MLXSwiftLM/FLOE_VENDOR.md`. Before the historical step may touch a
working copy, the workflow runs `check --profile current`, which read-only
verifies both declarations and the vendored package (manifest name, recorded
upstream revision, patch file) and records `current-declarations.json`. Byte
level vendored-tree hashes remain owned by the separate read-only audit
`ThirdParty/MLXSwiftLM/floe_vendor_check.sh`.

The historical pair is mlx-swift 0.31.4
(`dc43e62d7055353c7f99fa071a4e71d29dfddc44`) and mlx-swift-lm
`bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`. `apply-patch` may only rewrite the
committed current declarations into those two remote declarations, refuses any
other starting state, may change only those two declaration regions, and is
invoked only in the ephemeral runner checkout. The patched manifest is then
verified independently with `check --profile historical-baseline` and recorded
as `historical-declarations.json`.

Lock comparison: SwiftPM does not lock a `.package(path:)` dependency, so
`verify-lock --profile current` allows the resolved lock to omit the remote
`mlx-swift-lm` pin (reported as `omitted_local_packages`) while still requiring
the exact `mlx-swift` revision and rejecting every other added, removed or
drifted pin. The committed qualification host lock
`Qualification/LocalInference/Package.resolved` no longer carries that pin; the
other `Qualification/*/Package.resolved` host locks are outside this change and
keep the reviewed revision until their next host resolve. Compilation uses
`--force-resolved-versions`.

The production engine disables compiled traces once, before model loading.
The workflow clears `MLX_DISABLE_COMPILE` and checks emitted policy metadata,
so a pass must exercise the API policy itself. Both dependency profiles use
this policy: the historical profile restores dependency pins, not every aspect
of the older executable. Reproducing the earlier compile-enabled comparison
requires its original immutable source/workflow. The historical profile is
wired and unit-tested locally, but it has not been re-run in cloud CI since the
vendored-package switch; a failure there is isolated to the diagnostic fallback
and does not block the `current` profile.

### Evidence

Artifacts are named `local-inference-diagnostic-<dependency_profile>-<sha>`.
They retain source SHA, toolchain, original manifest and lock, resolved lock,
resolver/verification logs, build log, runtime log and the declaration checks
(`current-declarations.json`, plus `historical-declarations.json` for that
profile) even on failure. A historical-baseline run additionally retains
`.baseline`, `baseline-manifest.diff` and `baseline-apply.json`. Its identity is
the source SHA plus that isolated patch; a current run uses the committed
manifest.

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
drifted dependencies still fail verification. The `current` profile separately
allows the local `mlx-swift-lm` package to have no lock pin, exactly as
`omitted_local_packages` records; a lock that pins a different `mlx-swift-lm`
revision fails.

The `check` audit verifies the declaration form, the vendored manifest package
name, the recorded upstream revision and the patch file. It does not hash every
vendored byte (`floe_vendor_check.sh` owns that), does not compile or run the
vendored package, and does not prove that a device build used this exact tree;
the cloud App build and the user's device qualification own those.
