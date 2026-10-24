# Voice, search and result-return repair — 1.7.54 (295)

## Source and delivered changes

Immutable annotated tag `v1.7.54` binds source `78909c8d8f66079243eb83fb6544f7c5a6094bb7`. Subsequent delivery records and feed commits do not change that binary.

- Voice separates synthesis waits from actual playback stalls, bounds failed sources, and preserves the entering conversation mode on exit.
- Read-aloud accepts long Markdown with complete-sentence input and separate local semantic blocks and online-service budgets.
- Tool discovery refreshes scoped readiness and removes misleading guidance. The originally reported main-run discovery denial was not reproduced; existing metadata dispatch already admitted it. Provider selection and routing remain unchanged.
- Search defaults to five results with bounded structured output; professional datasets are exposed under search.
- Kimi Code has a native image-provider entry and an adapter based on the upstream protocol, without invented available model IDs.
- Generated QR image receipts survive later scanning and feed the bounded inline image/open/share path.
- Plugins provide global Check Updates and Update All, with per-item Update and preserved existing grants.
- Update Management removes Pin and offers Restore only for a usable retained older package, without immediately undoing a chosen rollback.

## Local qualification

| Boundary | Observed result |
| --- | --- |
| Swift 6 App and AppTests object compilation | Passed on Xcode 27.1 (27A9275), SDK 27.1 |
| 33 related App test suites on the reused iPad Simulator | 372 logical tests accepted after the targeted fixture repair described below |
| Native UI | Plugin global actions, unavailable Update All, absent invalid Pin/Restore, Kimi Code picker/form and cancel inspected |
| Exact-source Release iPhoneOS build and archive | Passed; arm64 device App and four extensions all 1.7.54 (295) |
| Bilingual catalog and generated project | 5,749 complete English/Chinese entries; 13 catalog-validator tests passed; generated project matched |

The initial unified batch passed 370 of 372 logical tests, with no skips. Two existing temporary-chat tests dispatched a child before its parent was active; a fixture-only repair preserves the original policy assertions and exercises a live parent lifecycle. Its four-test suite then passed. The other 370 results are reused, not described as a newly executed full batch. Initial failed compile attempts and both failed tests remain in the evidence. The final App/test object build and device archive used exact tagged source. Native UI used the immediately preceding source, whose sole difference is that test fixture.

Audio/HTTP fixtures and real SQLite/PNG tests do not prove microphone or audible output. QR transport and decoding passed, but a complete rendered-chat QR round was not exercised. No physical device, paid Kimi/cloud inference, live installed-plugin upgrade or live rollback was used for this qualification.

## Known issue reopened after delivery

The user tested **295 with Volcengine speech output** and reports that a completed conversational answer remains silent and immediately returns to listening. They neither spoke nor recorded microphone activity during that interval. Continuous spoken replies therefore remain **open**, despite passing isolated coordinator and bridge tests. Investigation now targets the actual final-answer/store/driver/synthesis/output lifecycle; this record does not claim a device-verified repair or assume genuine user interruption. Any correction will use a new build, preserving 295 and its tag.

## Distribution readback

- Internal TestFlight: Apple `VALID`, unexpired, `IN_BETA_TESTING`, existing Floe QA; English and Chinese notes verified.
- Public TestFlight: submitted once to existing publictest1. Reopening the iOS builds list showed **Waiting for Review**, 90 days until expiry, and both Floe QA and publictest1. External installability awaits Apple approval.
- GitHub: stable, latest Release; canonical unsigned IPA/checksum plus minimal provenance only. Independent verification binds the actual annotated tag/source, remote digest, downloaded bytes and arm64 iPhoneOS executable.
- Feather: the awaited reusable downstream job succeeded. Direct live-feed readback matches version, build, URL, size, source and hash.

[Unsigned install package](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.54) · [Feather source](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)

IPA: `Floe-Agent-1.7.54-build295-unsigned.ipa`, 812,215,177 bytes. SHA-256: `8e4cb8c5799c112d9b1a6c0370bed6d704a21f8f054b54472aa574abfe3c84b5`.

[Signing/internal delivery](https://github.com/JiangNanGenius/floe-agent/actions/runs/40127383537) · [Unsigned publication and awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/40128653347)

## Integration and cleanup

This delivery record and the repair source are integrated into `main`; the task-owned branch is removed only after remote ancestry readback. The reopened speech issue continues separately.

Finished compiler directories were removed after saving recovery artifacts and matching symbols. Final duplicate-product cleanup removed the archive, unpacked App, redundant raw/prequalification ZIPs and transfer staging: 7.21 GiB of allocated entries, with 3.40 GiB measured net free-space increase on the shared volume. Earlier compiler/cache cleanup receipts are retained separately; allocated sizes are not equated to reclaimed APFS space. The private transport draft and its temporary ref were independently read back absent after both consumers finished.

Retained: verified unsigned IPA/checksum, exact-source normalized recovery transport, all 14 matching symbols, prior rollback artifacts, original failures and final evidence. Shared dependency caches remain for the continuing voice repair. The reused Simulator is shut down, its data preserved. No production App Store release, website/content deployment or follow-up timer changed.
