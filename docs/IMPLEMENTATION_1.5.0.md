# Floe 1.5.0 execution and context reliability

Status: implementation and local verification in progress; no release or TestFlight delivery claimed.

## Evidence and scope

- User screenshots show cumulative provider event-limit failure, repeated discovery, missing DeepSeek reasoning fields, and incomplete status/export UX.
- Code inspection confirmed the cumulative 20,000-event / payload accounting and missing native `skill.search` registration. These findings do not require guessing a vector-search failure: this discovery path is deterministic lexical matching.
- The Apple-query screenshot was corrected by the user as a typo; it is not used as proof of an approval-policy defect.
- Current server-uploaded diagnostic logs have not been retrieved in this round. Do not describe this work as a complete uploaded-log audit.
- Preserve existing VNC/PiP and official immutable Skill Hub packages. Python and SSH Executor remain runtime substrates; interactive Terminal remains separate.

## Implemented changes

1. Register `skill.search`; bilingual workflow discovery, exact-tool fallback, bounded individual description results, truthful schema loading/deferred results.
2. Remove cumulative provider event count and Canvas's arbitrary 12-tool-step cap. Reset byte accounting per response, retaining runaway-response memory protection and existing no-progress safeguards.
3. Preserve reasoning in provider history, checkpoints and persisted message parts, separately from bounded UI previews. Missing legacy fields become explicitly labeled historical context rather than fabricated reasoning.
4. Execute idle `/compact` immediately, protect concurrent launch/history changes, persist replayable manual snapshots and retain original evidence. Replace prior summaries on subsequent compactions and send an explicit model-facing continuation notice.
5. Count Goal model requests from structured attempt events. Exclude discovery from accomplishment evidence and reset repeated blockers after new evidence.
6. Add JSONL export of persisted messages/parts, native events, usage/errors, per-run watermarks and a completion footer; redact secrets and disclose raw-output/artifact limitations.
7. Add sidebar/list attention indicators and terminal-state precedence. Add compact/continuation transitions respecting Reduce Motion.
8. Bump all targets to 1.5.0, provisional build 131. Remove redundant Debug build-only CI steps; reuse exact-SHA trusted CI in release with fallback tests, keeping stable-SDK and binary gates.

## Reference implementations

- [Codex summary handoff](https://github.com/openai/codex/blob/main/codex-rs/prompts/templates/compact/summary_prefix.md) tells the next model to use prior work and avoid duplication.
- [Codex compaction implementation](https://github.com/openai/codex/blob/main/codex-rs/core/src/compact.rs) separates compaction/context initialization and events.
- [DeepSeek Harness manual compact command](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/compaction/command-compact/src/index.ts) invokes compaction immediately and reports busy/changed/cancelled/persistence outcomes.
- [Kimi Code configuration](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/config.py) separates turn-step policy from context reservation and compaction settings. This is not evidence that any reference project has literally no limits.
- [Kimi Code compaction](https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/soul/compaction.py) explicitly prefixes its replacement history with a notice that the previous context was compacted.
- [DeepSeek thinking-mode protocol](https://api-docs.deepseek.com/guides/thinking_mode/) requires previous reasoning fields with tool-bearing requests, including non-tool assistant turns.

## Verification / release checklist

- [x] Initial focused discovery/runtime/provider tests and initial full SwiftPM pass (before final follow-up test additions).
- [x] Initial arm64 iOS Simulator Debug build.
- [x] Workflow YAML parse and whitespace diff check.
- [x] SwiftPM main regression: 972 tests. JavaScript execution/deadline groups: 24 tests. Focused provider replay: 17 tests; recovery/discovery: 14 tests. iPad Simulator timeline/status regression: 20 tests.
- [x] Tracked diff secret scan (redacted output), pinned dependency check (32 dependencies), workflow YAML and embedded shell syntax checks. Tag release preflight still runs before release.
- [x] [Apple discovery](https://github.com/JiangNanGenius/floe-agent/actions/runs/34159236167) reports latest upload 1.4.99/130; candidate 1.5.0/131 is unused in that snapshot.
- [ ] Commit/push; new exact-source CI green.
- [ ] Tag and internal TestFlight upload; separately record receipt, Apple VALID and Floe QA visibility.
- [ ] Physical iPad long-run discovery, compaction, sidebar attention and export UX; no external Beta before acceptance.

## Explicit limitations

- Compaction currently uses Floe's deterministic summarizer. Do not claim an LLM-generated summary or an embeddings-based search engine.
- Export is complete for persisted records through each recorded watermark, not a reconstruction of raw output that older versions never stored. Referenced artifact bytes are not embedded.
- Build 131 is provisional until live App Store Connect discovery confirms availability. Local compile/tests are not TestFlight delivery or device acceptance.
