# Build229 follow-up: local prompt budget repair (2026-09-27)

Status: fix committed on `codex/mlx-gdn-prefill-crash-repair`
(`d60a86d4`, on top of the fail-fast repair `dc528428`). Host-verified on
macOS with focused module tests; cloud real-weight re-qualification and
physical-iPad acceptance are recorded separately below. This doc is the
prompt-budget companion to
[FLOE_229_MLX_GDN_PREFILL_CRASH_REPAIR](FLOE_229_MLX_GDN_PREFILL_CRASH_REPAIR.md),
which covers the crash itself and stays authoritative for the vendored
fail-fast patch.

## Symptom (physical device, TestFlight Build229, iPad16,10)

Device logs (kept in the ignored private diagnostics store) show one
ordinary chat turn:

```
localPromptPrepared model=qwen3.8-4b-heretic-mlx4 messages=2
  sourceCharacters=12296 promptCharacters=12 estimatedPromptTokens=6196
  windowPromptTokens=7168 offeredTools=13 selectedTools=6
  systemCharacters=15276
localInferencePrepareStarted promptCharacters=15289 tools=0 batchSize=8
  contextSize=8192 kvBits=4 availableMemoryBytes=2653269744
  mlxActiveBytes=2367530912
localInferencePrepared inputTokens=5314 ... tokensShape=[5314]
```

A **12-character user message** (`promptCharacters=12`) became a
**15,289-character** prepared prompt (**5,314 real tokens**, tokenizer
count from the engine). The turn then exhausted the ~280 MB memory margin
mid-prefill and crashed inside the GDN prefill graph — the crash itself is
repaired by the fail-fast patch; this doc repairs the prompt size that put
the turn inside the memory margin in the first place.

## Root cause (measured, not inferred)

`sourceCharacters=12,296` = one system message of 12,284 characters + the
12-character user line. Decomposition of the system message:

1. The runtime envelope (`ConversationRunService.buildContextMessage`,
   `compactForLocal: true`) injected every workspace data section **verbatim**
   on every local turn: project instructions (FLOE.md/AGENTS.md of the
   active workspace — this repository's own AGENTS.md is ~11 KB), the
   workspace listing, workspace links, workflow guides, remembered context,
   interaction style (SOUL.md), user profile, plan and goal state.
2. The adapter's own constant protocol text (identity paragraph, tool
   directory, offered-tool index, bounded JSON tool-call instructions) adds
   ~3.5 KB on top (`systemCharacters 15,276 − 12,284 ≈ 3.0 KB`).

The adapter's `LocalPromptPressure.sectionTokenBudgets` already computes a
`runtimeInstructions` allowance (26% of the usable window) for (1), but no
code path ever applied it: the envelope was preserved verbatim by design
(Build 222 eliminated *silent adapter-side clipping* after it dropped the
memory context, the live clock and in-request user corrections). The gap:
nothing bounded the envelope **at its source**, so the runtime composed a
~12 KB envelope for a 12-character greeting and the adapter faithfully
shipped it.

The offered-tool side was audited and is **not** the bloat: the stable
base file-tool set (`LocalModelToolPolicy.admissionOrder`, 8 schemas
budgeted by `selectTools`) renders only as a short name+description index
(the full schemas are intentionally not repeated in prose), and the Qwen
bounded path hands the chat template zero native schemas (`tools=0` in the
device log). The tool set and the receipt round-trip schema are preserved
unchanged by this repair.

## Repair (narrowest, source-side)

`ConversationRunService.buildContextMessage` gains an optional
`localContextTokens` window (wired at all three composition call sites from
`configuration.model.limits.contextTokens` for local providers only). When
set on a compact local run:

- **Essential identity lines stay verbatim**: run clock/time zone,
  workspace name, selected file, execution target, attachment trust notes,
  and the adapter-handoff sentence — the state Build 222 was about.
- **Each data section** (workspace links, listing, project instructions,
  workflow guides, remembered context, interaction style, profile, plan,
  goal) is head/tail-clipped to an equal share of the envelope budget
  (`LocalEnvelopeBounds`: ~20% of the model window, capped at 2,048
  heuristic tokens, per-section share capped at 640) with an explicit
  `[local envelope: section clipped]` marker. Sections stay present —
  bounded, never dropped silently.
- **Cloud runs and callers that omit the window keep verbatim behaviour**
  (parameter defaults to `nil`; the three call sites pass it only for
  `provider.kind == .local`).
- The adapter is untouched: `exceedsContextWindow` honest refusal, the
  stable base tool set, and the receipt replay rules are unchanged, and
  every Build 222 pinned test still passes unmodified.

The vendored fail-fast patch (0002), its provenance and the vendor audit
are untouched by this commit.

## Measured effect (macOS host, Xcode-beta toolchain)

Synthetic workspace state reproducing the device envelope (an ~11 KB
project instruction file plus memory/style/profile/links/listing, the same
shape the device carried):

| Path | Characters | Heuristic tokens |
| --- | --- | --- |
| Runtime envelope, unbounded (base commit) | 11,737 | 3,949 |
| Runtime envelope, bounded @ 8K window | 4,498 | 1,501 |
| Adapter total first chat, unbounded | 13,824 | 4,658 |
| **Adapter total first chat, bounded** | **6,585** | **2,211** |
| Adapter two-tool-turn (bounded, receipts retained) | — | 2,360 |

Device-calibrated projection (device tokenizer measured 5,314 tokens for
the 15,289-character Build229 prompt, ≈0.35 tokens/char on this mostly
ASCII prompt): the bounded first chat ≈ 6,600 characters → **≈2,300 real
prefill tokens vs 5,314** (−57%), before counting the KV/transient savings
of a 2.3× shorter prefill at batch 8. This is an analytical projection from
device-calibrated ratios, **not** a device measurement.

Memory-policy inspection (accepted alternative levers, not taken):
per-window eval/sync inside the vendored prefill and a tighter MLX cache
limit are unchanged — the crash-repair doc records them as latency
trade-offs that need device data; the token-budget lever above is the
measured, output-preserving one.

## Tests

New `FloeAgentRuntimeTests/LocalEnvelopeBoundsTests` (6): the synthetic
workspace reproduces the Build229 envelope scale at base; the bounded
envelope keeps every section (head/tail + marker) within the 8K window
share; a 12-char first chat with a real-sized AGENTS.md stays small; the
no-optional-state floor is ~850 heuristic tokens; cloud envelopes stay
verbatim; plan/goal state survives bounding.

New `FloeLocalModelsTests/LocalFirstChatBudgetTests` (3), end-to-end
through the production `LocalProviderAdapter.buildPrompt`: the 12-character
first greeting stays far below the Build229 prompt size
(systemCharacters 6,585 vs 15,276; estimated 2,211 vs 6,196;
`!exceedsContextWindow`) with the base file-tool set still offered; the
unbounded envelope reproduces the Build229 scale (proving the test
exercises the real failure mode); two distinct `workspace.readFile` turns
keep both receipts (`TOOL RESULT call-turn-1/2`, earlier-work replay for
turn 1) and the offered schema under budget on every turn.

Host results (macOS, Xcode-beta, FoundationModels-dependent paths
compiled, real weights not mapped): FloeLocalModelsTests **131/131 pass**
(all 22 suites, including every pinned Build 222 adapter contract);
FloeAgentRuntimeTests 345 tests with the **same 13 pre-existing failures**
as the base commit (ConversationTools JSON segmentation, HybridContextEngine
compaction, one skill-activation assertion, one reasoning-bound assertion —
all reproduced identically at `HEAD~1`, none touching the changed code).

## Cloud verification (recorded per run)

- `local-inference-qualification` real-weight run on this branch:
  recorded below once complete. It re-exercises the vendored fail-fast
  patch and the production adapter with actual Qwen3.8-4B weights
  (multi-chunk prefill plus two consecutive `workspace.readFile` turns).
  Evidence limit: the diagnostic host composes its own minimal system
  envelope (it does not depend on `FloeAgentRuntime`), so real-weight
  evidence covers the engine+adapter+patch stack; the new runtime bounding
  is covered by the unit tests above and by the cloud App compile.
- `ci.yml` build-test on this branch: recorded below once complete;
  compiles `FloeAgentRuntime` for the cloud iOS/macOS slices.

## Boundaries and remaining risks

- macOS host evidence validates code behaviour only; it is not device
  acceptance. Physical-iPad acceptance remains with the user: expected
  post-fix first-chat prefill ≈2.3k tokens (projection) with ~2.65 GB
  available, plus the fail-fast bounded failure if a future prompt still
  exceeds the margin.
- The per-section budget uses the runtime's conservative byte/3 heuristic;
  the adapter's real-tokenizer prepared guard remains the final admission
  decision, exactly as before.
- If a future runtime change composes an oversized envelope again, the
  honest-refusal path (`exceedsContextWindow` + one compaction retry) still
  applies; there is intentionally no adapter-side silent rewrite.
