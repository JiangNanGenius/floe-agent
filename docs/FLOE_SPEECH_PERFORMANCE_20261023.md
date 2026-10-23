# Enhanced speech performance short fix — 2026-10-23

Baseline: build290 / immutable v1.7.49; working branch starts at main51187759.
Scope: enhanced speech stalls/residency/playback; Excel print/grid/preview and
content fitting; Office File menu and separate on-device Save As/external Export;
bounded search and cross-device settings verification. No unrelated expansion.

## Current outcomes

| Outcome | Acceptance |
| --- | --- |
| Foreground model reuse | First successful small-model load survives ordinary utterance completion/stop/replay; genuine pressure and lifecycle retirement remain safe |
| First audio and sustained playback | No endless loading state; bounded generation and playback buffers, correct cancellation/progress, smooth same-text multi-voice playback |
| Qualification and delivery | Actual M4 comparison plus changed-path tests and Swift6 object compilation; immutable new-build release and scoped cleanup |

## Actual-device boundary

The human explicitly connected an unused M4 iPad and authorized testing for this
round, overriding Simulator-only for this iPad. The human subsequently connected
and explicitly authorized their iPhone for this round, including iPad-to-iPhone
settings synchronization. Primary owns all device operations and credential entry;
workers own bounded source/tests.
The human subsequently withdrew iPhone access; no further iPhone operations or
unlock requests are permitted. The iPad remains temporarily authorized.
No existing Floe data is erased for testing. Existing corresponding service keys
may be configured on the authorized iPad; values never enter source or evidence.

Actual connected device: physical iPad Air13 M4, iPadOS27.0.1, installed Floe290.
The enhanced voice page initially showed Serena with the multilingual preview
preset and a spinner persisting for minutes without audio. The human separately
reports another voice can play but stutters. These are distinct cases, and no
single successful sample closes both. A21.16sec TimeProfiler App-only sample
observed0.279sampledCPU-seconds; GPU/ANE services and async waits were not measured.
This inherited in-flight observation is not a measured cold-start duration.

## Implementation boundary

Separate playback/session cancellation from cached-model lifetime. Keep the new
small model warm after first foreground use; do not preload on launch or retain
obsolete giant packs unnecessarily. Preserve service-owned downloads, model leases,
true played progress, memory protection, final-body speech, temporary-chat rules
and no automatic paid fallback. No unrelated voice UI or capability expansion.

Preserve original failures and capture exact source/target/build evidence. Finished
work is removed from the active table; source integration, release artifacts,
private transport and task-owned cache cleanup follow existing repository policy.

## Additional acceptance

- Excel: real gridline controls, automatic embedded preview, cell/ink/drawing union
  bounds and useful auto-fit; preview matches print/export. Word and PowerPoint
  use the same upper-right entry, automatic preview and handwriting option.
- Office native File panel retains Repair, Properties and Signature; preserve the
  upper-left quick Save and autosave. Other actions use the outer upper-right menu.
- Save As preserves the original and saves another on-device file; Export hands
  the result to external Files/share destinations. Keep distinct labels/actions.
- Search smoke uses actual configured providers and checks returned results.
- Sync records the iPad edits already observed on iPhone. Further iPhone testing
  is deferred after access was withdrawn; enabled toggles alone do not count as
  synchronization evidence.

## Focused native M4 evidence

The isolated native host used the production pinned Core ML package, weights and
reference JSONs; it does not exercise Floe playback or establish full-App acceptance.
Same synthetic multilingual text and seed; two syntheses reuse the loaded instance.

| Backend / voice | Mount | First chunk (first / warm) | Generation / audio duration | Sampled peak footprint |
| --- | --- | --- | --- | --- |
| CPU + GPU / Serena | 2.33 s | 15.14 / 0.34 s | 6.30 / 5.84 s (warm) | 279 MB |
| CPU / Serena | 0.90 s | 0.36 / 0.33 s | 3.79 / 6.16 s (warm) | 87 MB |
| CPU / Vivian | 0.03 s | 0.39 / 0.33 s | 4.37 / 7.20 s (warm) | 90 MB |

Core ML device caches were not controlled across launches; the third mount is not
a cold-device claim. The GPU steady generation was slower than real time, while
both CPU voices generated faster than playback. All returned samples were finite.
The production small-model load and validation now request CPU only; this choice
is based on actual M4 results, not processor branding. Full-App playback remains
pending. Original build/signing failures and actual reports are retained privately.

## Current checks and bounded follow-ups

- On both connected devices, the existing DeepSeek connection check succeeded
  without re-entering a secret. The iPad public-search smoke completed with real
  search results and fetched official support pages. This does not qualify every
  search provider or cloud speech output.
- A conversation-provider endpoint edited on iPad appeared on iPhone. CloudKit
  configuration metadata and iCloud Keychain secrets remain separate checks.
  Device-bound credentials must not block the cloud-secret delivery status.
- The iPad currently has no configured online speech profile. Cloud speech
  acceptance is pending the selected service and its corresponding credential;
  a conversation-plan key is not assumed to authorize speech synthesis.
- The installed-skills list currently labels every source as Update, including
  rows without a newer catalog version. Opening the Office entry correctly
  refused an older catalog package and preserved the installed version. The
  bounded repair makes the action truthful while retaining downgrade and
  permission-expansion protection.

## Speech integration checks — 2026-10-24

- Source `fb7ee70ac482f6706e626158693ef9ff4f6e049d`: complete App and test host
  compiled with Swift 6 / Xcode 27.1 (27A9275) for arm64 Simulator. All 19 focused
  speech-settings tests passed, including credential fencing after endpoint changes.
- One real Agent Plan request through the corrected production Volcengine speech
  adapter completed normally: first audio 1.38 s, 124,690 PCM bytes at 24 kHz mono,
  2.60 s of non-silent audio. This is a macOS module-host check, not iPad App playback.
- Native Excel preview regenerated after changing the scaling option. Its test
  still failed the original-file hash assertion; the failure is retained and being
  investigated before this path is accepted.
- The task's diagnostic iPad app was removed after exporting its measurements.
  The installed Floe app and user data were preserved. The canonical Simulator
  was shut down after the checks.

## Original-file protection follow-up — 2026-10-24

The ownerless editable preview path previously saved even an unchanged working
copy. It now skips that write only when the working copy and engine both report
clean, and separately verifies the current original against the committed digest
under file coordination. An external change refuses export; cancellation and
editor identity are rechecked before any conflict state is changed.

Four focused macOS Core tests passed with Swift 6 object compilation: repeated
read-only proof, a same-size external rewrite with restored timestamp, closed or
foreign sessions, and missing/substituted originals. The complete App and test host
subsequently compiled at `0d40e141` with Xcode 27.1 / Swift 6. Actual native preview
attachments retained the original workbook before and after the operation; both
were 18,421 bytes with the exact original digest. The original hash failure remains
retained rather than replacing its expected value.

## Office integration results — 2026-10-24

- Three real pinned-engine Word/PowerPoint tests passed: physical paper and
  orientation, whole-page fit with text preservation, and explicit overflow
  reporting. The source packages remained unchanged.
- The actual workbook handwriting check passed at `10b18c7b`: six engine exports
  verified 51 omitted ink shapes, one retained ordinary object, zero yellow
  highlighter pixels in omitted output, identical typed numbers, reduced automatic
  page extent, an honored explicit range and an unchanged source digest.
- Shared export contract and PDF text tests initially failed incorrect test
  expectations (drawing replacement characters, literal hyphens and Excel defaults
  applied to Word). The original failures were retained; the four corrected cases
  passed without changing runtime code or weakening source preservation.
- The native automatic-preview check correctly changed the real scaling picker
  and started generation 2 without a manual Update action. The isolated engine
  then failed to produce the second PDF; the old preview remained visibly stale
  with a retry action. This is an outstanding runtime failure, not an accepted
  preview or a claim that the queue failed to re-arm.
- Only the existing canonical iPad Simulator was used and it was shut down after
  testing. Build 291 is a local candidate; no new tag, upload or publication is
  implied by these compile/test results. Full-App M4 playback remains pending.

## Final source integration — 2026-10-24

Source `ff2150c5e06dc5d4ba7ab88281ff93e96e068e54` passed full App and test-host
Swift 6 object compilation with Xcode 27.1 (27A9275), arm64 Simulator.

- 38 XCTest cases and two Swift Testing cases passed: search catalog/title
  ownership, the dedicated provider editor, bounded readiness cancellation and
  silent/late replies, plus real Word/PowerPoint export paths.
- Preset supplier names now adopt the catalog title automatically. Name-only
  changes no longer appear as a manual update; genuine user names survive.
  Account keys, endpoints, switches and ordering remain unchanged by title sync.
- The earlier second-preview failure is resolved in this source: the native
  scaling menu was changed from Fit Width to Fit on One Page, and generation 2
  was accepted automatically without tapping Update. The real engine produced
  a one-page PDF and the options sheet remained mounted without stale state.
- Export readiness now requires the engine's actual document-loaded facts under
  bounded cancellation-aware probes for spreadsheets/documents. Presentations
  retain the acknowledged visible-render gate. The original failed run remains
  recorded above; no timeout increase or expected-hash replacement was used.
- Both independently exported pristine/final workbook attachments were 18,421
  bytes with the original digest. Only the existing canonical iPad Simulator
  was used and it was shut down afterward. These are Simulator results; full
  App playback on the authorized M4 iPad and build 291 distribution remain pending.


## Build 291 delivery readback — 2026-10-24

- Immutable `v1.7.50` binds source `5bad82a68c26e9032bda1a82316804c675f75f5c`; the final delta from qualified `ff2150c5` is documentation only. All 41 focused cases and the local full Swift 6 App build passed before packaging.
- Signing/upload run `40025195492` succeeded. Apple reports build 291 VALID, unexpired and available to Floe QA; the actual TestFlight build was installed on the authorized M4 iPad. Public group `publictest1` was submitted once and independently read back as waiting for review. This is not public beta approval.
- Stable/latest unsigned [Release v1.7.50](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.50) and the awaited Feather downstream completed in run `40028688394`. The canonical IPA is 812,005,690 bytes, SHA-256 `d8dfd6272e035a0bfbc5df672106f8f215df954457dcc5e2570cde293648b5bd`. Primary post-publication verification passed, including immutable tag/source binding, remote digest, actual arm64 iOS device executable, latest pointer and the live feed's exact URL/source/hash. The consumed private transport draft was removed.
- Actual build 291 search settings automatically refreshed the four official preset titles, preserving their enabled state and order. No name-only update badges or duplicate official subtitles remained; no configuration was renamed for testing.
- M4 voice UI observation reached preparation, active playback and stopped states for the enhanced default voice; a separate Vivian preview returned to idle, preserving the selected Serena voice. These observations do not establish audible continuity or precise latency. Full-App cloud audition was not completed; production-adapter host evidence above remains distinct.
- Main was pushed and the merged task branch removed. Canonical Simulator cleanup removed only generated wallpaper snapshot caches, symbolication and thumbnail caches: 38,174,179,328 allocated bytes, with 37,203,427,328 bytes measured free-space increase. Wallpaper settings/originals, all App data and the protected Promo environment remain intact. All Simulators remain shut down. Current installable artifacts, symbols, rollback material and original failures are retained; finished duplicate builds are removed after verified export.
