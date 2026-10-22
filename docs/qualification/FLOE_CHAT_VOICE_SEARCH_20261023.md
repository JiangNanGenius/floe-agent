# Chat, voice and search qualification — 2026-10-23

Candidate: **1.7.47 (288)**. Qualified implementation: `49b76bfccf7dddc0061f3e77377d6437a6ff1444`.
Distribution status is recorded separately; compilation does not imply Apple processing or beta availability.

## Scope

- Conversation-local Chat mode and thinking levels, with public search and attachment-only reads; editing and execution require Agent mode. Mode and thinking changes merge atomically and survive thread recreation.
- Continuous voice, final-answer-only read-aloud, tentative interruption and resume, played-audio progress, and one recoverable dictation-start rebuild.
- Enhanced on-device speech, nine named voices, editable live multilingual auditions, model installation safeguards, and four independently configured online speech services.
- Add-only search provider instances, independent credentials, legacy migration, test searches, and the signed `floe.search.providers` catalog.
- English and Simplified Chinese product labels; model source names and licenses remain available in opened details.

## Actual verification

| Boundary | Result |
| --- | --- |
| Full App, arm64 iOS device target | PASS, Xcode 27.1 (27A9275), Swift 6.4, SDK 27.1, iOS 26 deployment target |
| Full App and test-target Simulator object compilation | PASS, arm64 only |
| Focused App-hosted tests | **207 passed, 0 failed, 0 skipped** |
| Regular and compact interface inspection | PASS on one reused iPad mini Simulator; installed executable and localization resources matched the qualified build |
| Native TTS provider slice | 61 tests and Debug/Release object builds passed; unchanged evidence reused |
| Continuous-voice kernel | 468 assertions passed; the pre-fix control reproduced three playback-state failures |
| Search catalog and content | 66 catalog probe assertions and 10 content-hub tests passed; official signature and staged-feed checks passed |
| Local speech host qualification | 39 generated auditions, all nine enhanced voices and mixed-language cases; bounded 12-unit generation peaked near 4.35 GB on the Mac host |
| Source hygiene | Full-history credential scan and subsequent staged-change scans passed; original failures retained |

The device Debug recovery bundle was exported immediately after the successful build. All five App/extension version stamps were checked. The reused Simulator was shut down after inspection; its apps and data were retained.

## Failures found and closed

- Chat discovery was narrowing the already-frozen ceiling again; public tools could disappear from the first request. The projected set now stays discoverable, with dispatch and attachment boundaries retained.
- A final-only model completion could leave continuous voice in `waitingModel` even while confirmed audio played. Model completion and actual played-frame events now advance the presentation state; false-start resume keeps the same round and position.
- Migration 51 omitted its SQLite version marker. New databases now record it, and already-applied development databases receive a metadata-only repair that preserves preferences and never replays table creation.
- The bundled enhanced-model ID contains an interior decimal point, which directory validation rejected. Safe interior dots are accepted while hidden/traversal names remain rejected. App-hosted tests now read the actual bundled nine-voice catalog.
- Several new fixtures assumed the wrong discovery, active-parent, provider-clamp or JSON-encoding contract. Those fixtures now exercise the established contracts with meaningful assertions; none were skipped. The unsigned Simulator credential fixture uses the existing credential-store interface, while the production default remains Keychain.

## Evidence limits

Simulator and fake-I/O tests do not prove physical microphone, AEC, interruptions or device memory behavior. The native synthesis and memory measurements above are Mac-host results. Online adapters were checked through deterministic protocol fixtures; no paid service credentials were consumed. Compact-layout inspection used the same iPad Simulator, not a second iPhone device.

Original logs, test result bundles, source fingerprints, generated auditions, screenshots and recovery artifacts remain in the repository-owned private evidence/artifact directories. Public releases contain only their allowlisted installation and provenance files.
