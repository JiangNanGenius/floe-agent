# Build 233 — local-model tool invocation repair (diagnosis handoff)

Status: **candidate under cloud diagnosis; no Build 233 release or iPad acceptance.**
状态：候选代码正在云端诊断，尚未发布 Build 233，也未通过 iPad 验收。

Primary-reviewed audit source `5aa40e52a7534a4a1612f793912692356af3decd`
ran in [diagnostic run 36395580557](https://github.com/JiangNanGenius/floe-agent/actions/runs/36395580557)
and **failed the second file turn with code 16**. This tools-only run retained
both file and search roundtrip gates but skipped lifecycle profiles; it is not
full release qualification.
本次定向检查保留文件和搜索各两轮工具调用门槛，跳过生命周期测试，不能替代完整发布验收。

## R2 fix — explicit named-tool command misclassified as inventory

The retained v6 raw log
(privately retained failed-run evidence) gave the exact
failure shape for the first time:

1. Turn 1 — `workspace.readFile` on `qualification-probe.txt` executed
   (`tool-first-turn-observed`, 1 call) and its receipt was answered
   (`answerContainsReceipt:true`).
2. New user turn: *“Now call workspace.readFile with path
   qualification-probe-2.txt. Report its exact contents only after the tool
   responds.”*
3. The model emitted two completed prose answers quoting the OLD receipt
   (`qualification-probe-2.txt`/old-marker prose, `calls:[]`,
   `completed:true`) and **no second call** — the host guard failed with code
   16. No repair ran.

Root cause was intent classification in
`LocalProviderAdapter.buildPrompt`: `requestsInventory` matches any tool
substring (`"tool"` appears in “after the tool responds”), while
`requestsExplicitToolExecution` recognized only the fuzzy “call one / try one”
phrasing. A direct command that **names an offered tool** therefore had
`inventoryRequested == true` and `explicitToolExecutionRequested == false`, so
`requiredInvocation` was suppressed; with `requiresToolCall == false` the
bounded repair never ran and stale prose was accepted.

The R2 change (additive, local adapter only):

- New `namedExecutionToolNames(in:offeredToolNames:)`: a sentence is a direct
  command only when it contains (a) an imperative cue — strong
  `调用/執行/执行/运行/啟動/启动/call/invoke/execute/run/launch` on word
  boundaries, or weak `使用/use` outside an interrogative sentence — and
  (b) a fully-qualified **offered** tool name with boundary guards
  (`workspace.readFileBackup` cannot satisfy `workspace.readFile`).
- Exclusions keep the forcing narrow: explanatory markers
  (`for example/such as/how to/explain/例如/比如/示例/如何/…`), negations
  (`don't call/without calling/不要调用/別執行/…`) and quoted/fenced example
  spans never count. Quoted spans are blanked before evaluation: a bare quote
  like `“call workspace.readFile”`, `「调用 workspace.readFile」`, a backtick
  span, a fenced block or a quoted `{"tool_call":…}` envelope is a sample;
  conditional blanking (imperative cue, tool-call envelope, or a quoted
  offered name) preserves real commands whose **arguments** are quoted
  (`call workspace.readFile with path "a.txt"`).
- `requiredInvocation = toolResults.isEmpty && (
  (fuzzyAction && (!inventory || fuzzyExplicit)) || namedCommand )`;
  the fuzzy action path also evaluates quote-stripped text and is suppressed
  for an explanatory/negated sentence that names an offered tool
  (`mentionsOfferedToolName`), so a quoted sample or a how-to/“don't call”
  sentence cannot be promoted by the legacy `read`-inside-`readFile` substring.
  The original fuzzy action/inventory branch is otherwise unchanged.
- Tool-result continuations still answer from the receipt (the
  `toolResults.isEmpty` guard is unchanged); ordinary chat, genuine capability
  questions and quoted examples are never forced. Cloud providers are
  untouched (the classifier is private to `LocalProviderAdapter`).
- The one bounded repair, its budgets/schema rules and authority/safety text
  are unchanged; when the second turn is now correctly forced and the model
  still answers with old-receipt prose, the existing single minimal repair
  re-requests the call with the **current** request (`repairPrompt` ends with
  the latest user text, i.e. the new fixture path) — the old receipt is never
  substituted for the new call.

Regression coverage: `LocalNamedToolIntentRegressionTests` (new) — exact v6
second-turn replay at the `PromptBuild` boundary and end-to-end through the
production adapter (first call → stale-receipt prose → one bounded repair →
new call id with the new path), direct Chinese named invocation, English
imperatives, fuzzy list-then-try-one, genuine capability questions, bare
quoted examples (curly/CJK/backtick/fence/envelope), quoted-argument positive
cases, negations, ordinary chat mentioning a tool name, boundary-safe name
matching, and the receipt-continuation negative.

## R3 fix — receipt grounding after a real tool invocation

Diagnostic run
[36405120893](https://github.com/JiangNanGenius/floe-agent/actions/runs/36405120893)
(`767950bdd5`, tools-only) passed the greeting, the real `web.search` call and the
synthetic receipt, then failed code 34: the continuation answered with fabricated
generic "today's news" prose and never repeated the receipt marker. The file-tool
roundtrips (two real `workspace.readFile` calls with distinct ids and paths) passed
in the same run.

A deterministic render of the exact continuation through the production
`LocalProviderAdapter.buildPrompt` (synthetic qualification fixture only, no
weights) showed the receipt was **not** omitted or clipped: the `TOOL RESULT` line
with its marker survived verbatim, the runtime-context sentence ("After a tool
result, answer from that result…") survived, and the prompt fit at 1833/7936
estimated tokens. A candidate cause is phase precedence in the representation:

- the only turn-scoped "answer now" wording sat inside the runtime-context
  envelope, away from generation;
- the still-active offered-tools paragraph kept instructing the model to emit
  JSON `tool_call` objects;
- the original user imperative remained the latest USER line.

The file roundtrips passed because their receipt *is* the requested content and
the prompt said "report its exact contents"; the synthetic news receipt contains no
items, so the model filled the gap from priors. This is a proposed context/representation repair; causality and weight-specific
grounding remain unverified until
the next real-weight run.

The R3 change (additive, local adapter only,
`FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift`):

- `hasPendingReceipts = !isAppleToolFollowUp && !request.toolResults.isEmpty`.
- On such a turn a bounded app-generated section is appended at the **end** of the
  user-side transcript, immediately after the receipt evidence: the `TOOL RESULT`
  lines are the only evidence returned for the request; answer it now from their
  content and relevant conversation context; repeat receipt markers only when requested by the user or runtime; if a result says no live action was
  performed or is a synthetic/fixture result, say so plainly; do not repeat a
  completed call; never invent facts, titles, numbers, sources or events the
  results do not contain. The section is harness text, never tool output, and never
  contains a fixture marker.
- A short clause is added to the system tool paragraph for native/Qwen MLX paths so
  the generic "emit a tool_call" protocol stops competing with the fresh evidence.
- Greeting, fresh-user forcing, bounded one-call repair, budgets, verbatim runtime
  envelope preservation, Apple Foundation path and cloud-provider isolation are
  unchanged; no qualification-specific token enters production.

Regression coverage (new tests in `LocalSearchRepairRegressionTests`): receipt
survives verbatim in the actual continuation prompt; the grounding directive is
placed after the evidence and forbids repetition/fabrication without carrying a
fixture token; ordinary, fresh and replay-only turns never receive it (a fresh
request still requires its own call); and the streaming continuation path delivers
marker + directive to the engine with exactly one generation and no extra tool
request.

Local verification: focused search suite **26/26 pass**; full `FloeLocalModelsTests`
filter **217 tests, 1 issue** — the known timing-flaky baseline
`Consumer cancellation stays a cancellation and reaches the engine`, unchanged and
not touched; adapter object rebuilt; qualification host compiled with the final
wording. No real-weight run has consumed R3 yet.

## What the existing evidence proves (and does not)

| Evidence | Result | What it shows |
| --- | --- | --- |
| Device Build 232, retained, redacted tool-call trace | Tool turn: `localFallbackToolNameDropped emitted=bochaWeb offered=13`, repair pass output 67 chars, `parsed=0`, then `missingToolInvocation` validation failure | The device model emitted a **non-offered tool name** in both the first attempt and the old full-envelope repair. That is the only device tool-shape proof. |
| v1 `run36382135717` (`9fcea8a3`) | First and second file-tool rounds passed; first search receipt answer failed (code 34) | Forced re-invocation on a receipt continuation; fixed by the `request.toolResults.isEmpty` guard. |
| v3 `run36384179346` (`916779a3`) | First file round passed; second file turn failed (code 16, no raw shape logged) | The second-user-turn gate rejected the parsed result. Shape unknown. |
| v5 `run36389561490` (`669cd067`) | **First** file round failed (code 11, no raw shape logged) | Host guard `calls.count == 1 && path == fixture` rejected the parsed result. Shape unknown. Empty-arguments hypothesis stays unconfirmed. |
| v6 `run36395580557` (`5aa40e52`) | First file round and receipt answer passed; **second** file turn failed code 16 with `calls:[]`, `completed:true` and prose quoting the old receipt (`tool-second-turn-observed`) | **Confirmed root cause:** the direct second-turn command naming `workspace.readFile` was classified as capability inventory, so `requiresToolCall` was false and no repair ran. Fixed by R2 (above); cloud assertions were correct and were not relaxed. |

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
  A local synthetic gate-selection check passed both scopes.
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

### R2 verification (intent fix)

- Focused suites
  (`LocalNamedToolIntentRegressionTests`, `LocalSearchRepairRegressionTests`,
  `LocalMultiTurnToolTests`, `LocalBaseToolSchemaTests`, catalog fuzzy
  inventory case) → **58/58 pass**. Log:
  `intent-focused-run2.log`.
- Full `^FloeLocalModelsTests\.` filter → **213 tests, 32 suites, 0 issues**
  (run4). An earlier run (run3, same code) had 1 issue — the known timing-flaky
  baseline `Consumer cancellation stays a cancellation and reaches the engine`
  (`LocalStreamDeliveryTests.swift:450`), previously isolated by the primary;
  it passed on rerun and is unrelated to intent classification. Logs:
  `full-localmodels-run{3,4}.log`.
- Qualification host object build with the shared scratch:
  `swift build --package-path FloeAgent/Qualification/LocalInference
  --scratch-path FloeAgent/.build --disable-automatic-resolution -j 2`
  (Xcode-beta 27.0) → `Build complete! (201.98s)`, 222.83s wall, peak 810 MB.
  Log: `qualification-intent-build.log`; no
  warnings in changed files.
- `git diff --check` clean; no `Package.resolved` modification; no cloud
  provider, workflow, Office or unrelated source changes in this fix.

### Earlier R1 verification

- `swift test --package-path FloeAgent --disable-automatic-resolution -j 2
  --filter '^FloeLocalModelsTests\.'` → **199 tests, 30 suites, 1 failure**:
  the pre-existing baseline `Local streamed delivery / Consumer cancellation
  stays a cancellation and reaches the engine`
  (`LocalStreamDeliveryTests.swift:450`), already isolated by the primary as a
  baseline failure. Log: `focused-localmodels-full-run2.log`.
- Focused protocol/tool suites (`LocalSearchRepairRegressionTests`,
  `LocalMultiTurnToolTests`, `LocalModelCatalogTests`) → **76/76 pass**
  including new tests for empty-arguments repair, zero-argument repair
  guidance, honest failure when the repair stays prose, and required-argument
  admission. Log: `focused-localmodels-run2.log`.
- Qualification host compiled with the shared scratch:
  `swift build --package-path FloeAgent/Qualification/LocalInference
  --scratch-path FloeAgent/.build --disable-automatic-resolution -j 2` →
  `Build complete! (198.60秒)`. Logs:
  `qualification-build.log` (195.84s) and `qualification-build-run2.log`.
- `git diff --check` clean. `FloeAgent/Package.swift` and
  `Qualification/LocalInference/Package.swift` were already dirty before this
  task; **no `Package.resolved` was modified**.

## Exact next cloud step (primary-owned; not performed here)

The R2 intent fix, the R3 receipt-grounding change, their regression tests, the
qualification observations and the workflow change must be in the dispatched
revision. Create the next immutable audit snapshot (private alternate index, main
HEAD/index untouched) that includes at least:

- `FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift`
- `FloeAgent/Tests/FloeLocalModelsTests/*` (including
  `LocalNamedToolIntentRegressionTests.swift` and
  `LocalSearchRepairRegressionTests.swift`)
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
vs wrong arguments vs dropped emitted name). For the receipt continuation, read
`search-reply-observed.answerContainsReceipt` and `syntheticAnswerPrefix`: R3 is
cloud-verified only when both search receipts produce completed answers that
contain their markers and state the synthetic/no-live-search fact. Do not click
through to a full run until that shape is recorded. Full qualification remains
the only acceptance run:

```
gh workflow run local-inference-qualification.yml \
  --ref <same frozen source> -f dependency_profile=current -f scope=full
```

## Unverified / limits

- R2 passed both real file-tool turns in v7; no real-weight run has consumed R3; the rendered-prompt proof, the
  streaming-path regression and object compilation use deterministic engine
  doubles, not qwen3.8 weights. The next tools-only cloud run is expected to
  pass the second file turn (two `workspace.readFile` executions) and to make
  the search continuation answer from the synthetic receipt with its marker;
  until then R3 is not cloud-verified.
- Phase precedence is a candidate explanation for the v7 fabrication in the prompt
  representation; the residual weight-specific grounding sensitivity is a
  hypothesis the next real-weight run will measure, not a proven result.
- The earlier empty-arguments shape (v5 code 11) remains a **candidate
  hypothesis**, not a confirmed cause; its bounded recovery is retained.
- The device proof remains the `bochaWeb` name drop; no raw first-call output
  exists for v3/v5.
- `runActualToolRoundtrip`/`runActualSearchRoundtrip` on this macOS host are
  not iPad acceptance; search receipts are labelled synthetic fixtures.
- The known baseline cancellation failure in `FloeLocalModelsTests` is not
  fixed here and must not be claimed as green.
