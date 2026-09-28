# Build 233 — local-model tool invocation repair (diagnosis handoff)

Status: **candidate + diagnostics ready; real-weight verification NOT yet run.**
No cloud dispatch, commit, tag or iPad claim was made for this change set.
Source SHA at time of writing: `1c4b6af2` (main) plus the reviewed dirty
candidate; the local-model audit commits `9fcea8a3` / `1d3e5fff` / `916779a3` /
`5f2bfa52` / `669cd067` on `codex/build233-local-search-audit` are the current
real-weight evidence.

## What the existing evidence proves (and does not)

| Evidence | Result | What it shows |
| --- | --- | --- |
| Device Build 232, `Local/Private/build233/cloud232-events.json` 01:33–01:35 | Tool turn: `localFallbackToolNameDropped emitted=bochaWeb offered=13`, repair pass output 67 chars, `parsed=0`, then `missingToolInvocation` validation failure | The device model emitted a **non-offered tool name** in both the first attempt and the old full-envelope repair. That is the only device tool-shape proof. |
| v1 `run36382135717` (`9fcea8a3`) | First and second file-tool rounds passed; first search receipt answer failed (code 34) | Forced re-invocation on a receipt continuation; fixed by the `request.toolResults.isEmpty` guard. |
| v3 `run36384179346` (`916779a3`) | First file round passed; second file turn failed (code 16, no raw shape logged) | The second-user-turn gate rejected the parsed result. Shape unknown. |
| v5 `run36389561490` (`669cd067`) | **First** file round failed (code 11, no raw shape logged) | Host guard `calls.count == 1 && path == fixture` rejected the parsed result. Shape unknown. |

Both code 11 and code 16 are qualification-host guards, not App or iPad
evidence, and not proof of an empty-arguments object. A missing invocation
would instead surface as `Qualification.Tool` code 10 (adapter
`validationFailed`), which did not happen in v5/v3. So the parsed result was
non-empty but not exactly one correct fixture call — i.e. one of: several
calls, one call with a wrong/missing `path`, or a repaired call with those
shapes. **The exact shape has never been retained**; the changes below make it
observable on the next real-weight run without relaxing any gate.

## Changes

### 1. Qualification observations (no gate change)
`FloeAgent/Qualification/LocalInference/Sources/Qualification.swift`
- `tool-first-turn-observed` and `tool-second-turn-observed`: completed flag,
  stream error, bounded synthetic answer prefix, every parsed call
  (id/name/arguments JSON).
- `search-greeting-observed`, `search-call-observed` and
  `search-followup-observed` carry the same call projection; the existing
  `search-reply-observed` for turns 2 and 3 now also carries the stream error
  and diagnostics.
- Each observation also carries `adapterDiagnostics`, a bounded (80-entry)
  projection of the production adapter's own `FloeLogger` provider entries:
  `localToolInvocationRepairStarted reason=…` /
  `localToolInvocationRepairFinished parsed=…` /
  `localFallbackToolNameDropped emitted=…` / `localToolCallsIncompleteArguments`
  / `localToolGapBegan` / `localStreamEnded`. This is how the next run reveals
  whether the bounded repair ran and what name/arguments the model actually
  emitted. The ring buffer already redacts secrets and the host runs synthetic
  fixtures only.
- Stream `.error` events are now recorded **before** the matching gate throws,
  so a zero-call shape is retained instead of collapsing into "code 10".

### 2. Bounded tools-only diagnostic scope
- `Qualification` accepts `--tools-only`: skips only the unchanged lifecycle
  profiles; download, tool roundtrips, search roundtrips and every tool/search
  gate still run. `qualification-scope` records `toolsOnly` and profile count.
- `.github/workflows/local-inference-qualification.yml` gains a `scope`
  input (`full` default, `tools-only`). Full keeps every profile + shutdown +
  multi-chunk gate; tools-only asserts `qualification-scope toolsOnly:true`
  instead of the profile gates and keeps all tool/search/compile-policy gates.
  A local synthetic gate-selection check lives in
  `Local/Private/build233-model/workflow-gate-check.sh` (both scopes pass).
  **tools-only is a diagnosis accelerator, never a release gate.**

### 3. Adapter: candidate bounded recovery for incomplete arguments
`FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift`
- `toolCallsSatisfyRequiredArguments`: a parsed call that misses a field its
  offered schema declares as `required` is treated as an unusable invocation
  and earns the **same single bounded repair** as a missing invocation.
  Schemas with no `required` fields and unknown/unparsable schemas stay
  admissible, so legitimate zero-argument calls are untouched. This is a
  bounded recovery for an unconfirmed failure shape, not a diagnosed cause.
- `minimalRepairInstructions` is now schema-conditioned: a tool with required
  fields gets an unparsable fill-this placeholder plus `Required: <keys>`;
  a zero-argument tool keeps the valid `"arguments":{}` example. The bound
  (8 192-char channel, 4 096-token prefill) is unchanged.
- The generic documented envelope keeps its proven valid-JSON example, and the
  guidance now says: fill every required argument declared by the called
  tool's schema; only a tool with no required fields may use an empty
  arguments object. No successful-call semantics were replaced.
- `localToolInvocationRepairStarted` now logs `reason=missingInvocation` vs
  `reason=incompleteArguments`, and a post-repair
  `localToolCallsIncompleteArguments` warning records a still-incomplete
  repaired call (the normal runtime validation then denies/retries honestly).

Cloud-provider behavior is untouched: all changes are inside
`LocalProviderAdapter` / `PromptBuild`, and the existing
"cloud wire protocols never route to the local repair adapter" test still
passes.

## Verification performed

- `swift test --package-path FloeAgent --disable-automatic-resolution -j 2
  --filter '^FloeLocalModelsTests\.'` → **199 tests, 30 suites, 1 failure**:
  the pre-existing baseline `Local streamed delivery / Consumer cancellation
  stays a cancellation and reaches the engine`
  (`LocalStreamDeliveryTests.swift:450`), already isolated by the primary as a
  baseline failure. Log: `Local/Private/build233-model/focused-localmodels-full-run2.log`.
- Focused protocol/tool suites (`LocalSearchRepairRegressionTests`,
  `LocalMultiTurnToolTests`, `LocalModelCatalogTests`) → **76/76 pass**
  including new tests for empty-arguments repair, zero-argument repair
  guidance, honest failure when the repair stays prose, and required-argument
  admission. Log: `Local/Private/build233-model/focused-localmodels-run2.log`.
- Qualification host compiled with the shared scratch:
  `swift build --package-path FloeAgent/Qualification/LocalInference
  --scratch-path FloeAgent/.build --disable-automatic-resolution -j 2` →
  `Build complete! (198.60秒)`. Logs:
  `qualification-build.log` (195.84s) and `qualification-build-run2.log`.
- `git diff --check` clean. `FloeAgent/Package.swift` and
  `Qualification/LocalInference/Package.swift` were already dirty before this
  task; **no `Package.resolved` was modified**.

## Exact next cloud step (primary-owned; not performed here)

The qualification changes and workflow change must be in the dispatched
revision. Create the next immutable audit snapshot (private alternate index,
main HEAD/index untouched) that includes at least:

- `FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift`
- `FloeAgent/Tests/FloeLocalModelsTests/*` (regression tests)
- `FloeAgent/Qualification/LocalInference/Sources/Qualification.swift`
- `.github/workflows/local-inference-qualification.yml`

Then dispatch **once**, bounded scope first (diagnosis, no profile rerun):

```
gh workflow run local-inference-qualification.yml \
  --repo <origin> \
  --ref <new immutable audit branch or SHA> \
  -f dependency_profile=current \
  -f scope=tools-only
```

Read `tool-first-turn-observed` / `search-*-observed` →
`calls[].name`, `calls[].syntheticArguments`, `error`, and
`adapterDiagnostics` to classify the actual shape (zero calls vs several calls
vs wrong arguments vs dropped emitted name). Do not click through to a full
run until that shape is recorded. Full qualification remains the only
acceptance run:

```
gh workflow run local-inference-qualification.yml \
  --ref <same frozen source> -f dependency_profile=current -f scope=full
```

## Unverified / limits

- No real-weight run has consumed these changes; the empty-arguments shape is
  a **candidate hypothesis**, not a confirmed cause.
- The device proof remains the `bochaWeb` name drop; no raw first-call output
  exists for v3/v5.
- `runActualToolRoundtrip`/`runActualSearchRoundtrip` on this macOS host are
  not iPad acceptance; search receipts are labelled synthetic fixtures.
- The known baseline cancellation failure in `FloeLocalModelsTests` is not
  fixed here and must not be claimed as green.
