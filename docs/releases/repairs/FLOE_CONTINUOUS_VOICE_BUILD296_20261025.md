# Floe 1.7.55 (296): continuous voice and enhanced read-aloud repair

## Scope

Two reopened build 295 issues: a completed voice answer could return to Listening without speech, and a valid enhanced-voice utterance could exhaust the character-derived generation allowance and be reported as too long. Standalone cloud playback was reported working by the user.

## Changes

- Final-answer observers publish their terminal fence only after resolving durable answer rows and events. An observer ending without a terminal no longer cancels the other finalization paths.
- A completed run without a confirmed final answer is visibly retryable. Intermediate tool, reasoning and joined display text remain excluded from speech.
- Enhanced speech reserves actual remaining decoder context after measuring its tokenized prompt. Sentence boundaries, native context guards, bounded PCM and cancellation remain enforced; online TTS strategy is unchanged.
- Redacted diagnostics distinguish final-read cancellation, context rejection and generation exhaustion without recording text or credentials.

## Verification

The corrected regression fixture forwards one speech-event stream to its logger and bridge. Earlier attempts accidentally used two consumers; their original failures are retained and are not counted as proof. With the corrected fixture, the immutable 295 driver reproduces persisted final text followed by zero speech units and premature Listening (4 failing cases).

Frozen source `cab5d33c6ddbaafab6db74209913ae147df82ed7`, annotated tag `v1.7.55` (object `e19cd9cf3552959673aed15abf8eddfd35802307`): full-App Swift 6 object compilation passed with Xcode 27.1 / 27A9275. All 115 related App-host tests across 11 suites passed, 0 failed and 0 skipped, on the existing canonical iPad Simulator (iOS 27.0, SDK 27.1). A single local Release iphoneos 27.1 archive also succeeded; all five bundles are 1.7.55/build 296 with 14 matching symbols. The regression asserts that the exact persisted final body reaches synthesis once, actual PCM waits for played-frame receipts before Listening, synthesis failure is actionable, missing final text is not silently successful, and manual interrupt still cancels.

A native Mac CoreML counterexample with the same numeric utterance and seed exhausted the old 49-frame allowance; using measured prompt rows and 913 frames of legal headroom ended naturally after 81 frames. This is an actual inference regression, not an audible iPad test. Earlier long-Markdown probes completed on the Mac and are preserved as negative evidence; the original user-device event has not been rerun.

No physical device, microphone or audible-output acceptance is claimed for this round. Existing 295 UI and unchanged native Office/browser components are reused; no layout or production App Store 275 change is included.

## Delivery

- Internal TestFlight: [sign/upload run 40136686716](https://github.com/JiangNanGenius/floe-agent/actions/runs/40136686716) succeeded; Apple `VALID`, unexpired, existing Floe QA `IN_BETA_TESTING`, both What-to-Test languages verified.
- Publictest1: submitted once through App Store Connect. The exact 296 build was reopened and its list reread: `WAITING_FOR_REVIEW`, 90 days remaining, Floe QA and publictest1 both present. Submission is not external approval.
- [Stable latest unsigned Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.55): [publication run 40137473943](https://github.com/JiangNanGenius/floe-agent/actions/runs/40137473943) and its awaited Feather reusable job both succeeded. Independent download/readback accepted the tag-object/source binding, canonical IPA+sidecar, actual arm64 iPhoneOS executable and latest pointer. IPA: `Floe-Agent-1.7.55-build296-unsigned.ipa`, `812214863` bytes, SHA-256 `e4900758640d920f79153c0ac84d47eb17304eef5349ad144dfc0c6568102084`. Live Feather points to the same exact asset, source, digest and size.
- Private transport draft/ref were removed only after both consumers completed; both reread absent. The public tag remains immutable. Exact recovery transport, 14 matching symbols, canonical unsigned IPA and original failures/evidence remain locally retained.
- Cleanup removed the finished task-owned Simulator/Release DerivedData, duplicate xcarchive/App/rawzip and transfer staging. Allocated deleted space: 15.87 GiB; measured net free increase across volumes: 12.02 GiB (cloned/shared files explain the difference). The canonical Simulator is shut down; apps/data, shared pinned dependencies and protected earlier deliveries remain.
- Delivery documentation is separate from the immutable App tag. Source and records are integrated to main; only the merged task-owned branch is removed. No production App Store 275, website/content deployment or follow-up timer was changed.
