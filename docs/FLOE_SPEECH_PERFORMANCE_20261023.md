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
  bounds and useful auto-fit; preview matches print/export. Word stays scoped.
- Office native File panel retains Repair, Properties and Signature; preserve the
  upper-left quick Save and autosave. Other actions use the outer upper-right menu.
- Save As preserves the original and saves another on-device file; Export hands
  the result to external Files/share destinations. Keep distinct labels/actions.
- Search smoke uses actual configured providers and checks returned results.
- Sync verifies actual iPad edits arriving on iPhone and usable credentials;
  enabled toggles alone do not count as synchronization evidence.

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
