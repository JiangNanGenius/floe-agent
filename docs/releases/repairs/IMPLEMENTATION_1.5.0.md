# Floe 1.5.0 execution and context reliability

Status: implementation, CI, signed upload and internal TestFlight delivery verified on 2026-09-08. Physical-iPad acceptance remains open; external Beta is not enabled.

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
8. Bump all targets to 1.5.0, build 131. Remove redundant Debug build-only CI steps; reuse exact-SHA trusted CI in release with fallback tests, keeping stable-SDK and binary gates.

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
- [x] Tracked diff secret scan (redacted output), pinned dependency check (32 dependencies), workflow YAML and embedded shell syntax checks. Tag release preflight passed for `v1.5.0`.
- [x] [Pre-release Apple discovery](https://github.com/JiangNanGenius/floe-agent/actions/runs/34187081652) confirmed build 131 was unused before upload.
- [x] Commit/push; [exact-source CI green](https://github.com/JiangNanGenius/floe-agent/actions/runs/34160050948) for `a55fa2bc2572a9ec7917d6a8c2e004acc057a7cd`: all three required jobs passed, including actual app regression tests, secret scan, SBOM and license gates.
- [x] Immutable `v1.5.0` tag points to that exact source. [Release 34187111578](https://github.com/JiangNanGenius/floe-agent/actions/runs/34187111578) passed build verification, accepted-App-Store-SDK regression tests, signing/upload and GitHub asset publication. Transport receipt: `cea230e5-fdae-4222-91c1-8b607b5a60f9`, accepted at 2026-09-08 05:55:50 UTC.
- [x] [Post-upload Apple discovery](https://github.com/JiangNanGenius/floe-agent/actions/runs/34193590371) reports 1.5.0 / 131 `VALID`. [Group verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34193665453) passed at 2026-09-08 06:12:35 UTC: build ID `cea230e5-fdae-4222-91c1-8b607b5a60f9`, exactly one internal Floe QA group (`c09d3f5c-f5b3-485f-9ddb-98c61fa80ad1`), zero unexpected groups, public link not enabled.
- [ ] Physical iPad long-run discovery, compaction, sidebar attention and export UX; no external Beta before acceptance.

## Explicit limitations

- Compaction currently uses Floe's deterministic summarizer. Do not claim an LLM-generated summary or an embeddings-based search engine.
- Export is complete for persisted records through each recorded watermark, not a reconstruction of raw output that older versions never stored. Referenced artifact bytes are not embedded.
- Build 131 is verified for internal TestFlight. This verifies server-side distribution, not a successful installation or acceptance on the user's physical iPad. The GitHub IPA is unsigned and not directly installable. Release evidence updates do not move the immutable source tag.
