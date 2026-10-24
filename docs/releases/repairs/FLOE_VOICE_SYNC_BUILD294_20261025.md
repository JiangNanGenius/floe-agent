# Voice and saved-credential repair — 1.7.53 (294)

## Scope and source

Immutable tag `v1.7.53` binds source `3b9fb7bcb4d5f93e75ca8f1ce343e809666a0218`. Feed and delivery-record commits do not change that source or its binaries.

- Continuous voice fences stale recognition and played-text echoes; tentative interruption pauses are bounded and false interruptions resume at the actual playback position.
- Speech output selects the source before its voice. Online services and installed voice packs are separate; selecting a configured service does not open its editor. Per-source voice selections and speed/pitch controls remain available.
- Read-aloud, previews and continuous voice use whole-sentence model input. Newlines, semicolons and arbitrary character limits no longer force fragments.
- Credential migration handles locally missing records individually, verifies destination writes before committing storage metadata, and preserves recoverable data on real storage failures. Missing credentials and failed writes receive distinct actionable outcomes; the same error is not displayed twice.

## Verification

| Boundary | Result |
| --- | --- |
| Swift 6 full App and AppTests compilation | Passed on Xcode 27.1 (27A9275) |
| Reused canonical iPad Simulator App tests | 201 passed, zero failed or skipped |
| Native settings UI | Source/voice selection, separate online services, retained controls and sync UI inspected |
| Final-source iPhoneOS archive | Passed; arm64 device executable; App and four extensions all 1.7.53 (294) |

The 201-test and UI run used `e5ac4999`. Final source adds only two missing Chinese singular translations, release notes and version stamps; program and test sources and non-version compiler settings were checked unchanged. The final device archive compiled the exact tagged source. Original failures are retained: the first test run exposed obsolete fragment expectations and an installed-pack publication issue; the frozen 293 preflight caught missing translations. Tag `v1.7.52` remains immutable and was not uploaded or published.

No physical device was used for patched acceptance. Audible quality, acoustic echo handling and real microphone performance remain device observations, not conclusions of these Simulator tests.

## Delivery readback

- Internal TestFlight: Apple `VALID`, unexpired, `IN_BETA_TESTING`, existing Floe QA; bilingual notes verified.
- Public TestFlight: submitted once to existing publictest1; independent App Store Connect readback shows **Waiting for Review** with Floe QA and publictest1 attached. External availability awaits Apple approval.
- GitHub: stable, latest Release with the unsigned IPA, checksum and minimal provenance. Independent publication verification binds the tag/source, remote digest and actual arm64 iPhoneOS binary.
- Feather: awaited downstream publication succeeded; direct live feed readback matches the release URL, version, build, source, size and SHA-256.

[Unsigned install package](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.53) · [Feather source](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)

IPA: `Floe-Agent-1.7.53-build294-unsigned.ipa`, 812,111,249 bytes. SHA-256: `51fa2c31f3d23603d41d4738da7506bfab59940687f6b1d44b9c30067816cb62`.

[Signing/internal delivery](https://github.com/JiangNanGenius/floe-agent/actions/runs/40109654963) · [Unsigned publication and awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/40111171633)

## Integration and cleanup

The repair and this delivery record are integrated into `main`; the task-owned merged branch is removed after remote readback. Unrelated worktrees, branches and modifications are preserved.

Removed only completed Simulator/device compiler directories, the duplicate archive, unpacked App and raw App ZIP after exporting and verifying recovery artifacts. Their allocated sizes total 14,572,097,536 bytes; APFS shared storage means this is not a claim of equal reclaimed space. The final duplicate-product cleanup increased measured free space by 813,731,840 bytes. The private transfer draft was deleted and both its release and temporary ref read back absent.

Retained the public unsigned IPA/checksum, verified normalized recovery transport, all matching symbols, prior rollback artifacts, provenance, original failures and final verification evidence. Shared pinned dependency caches remain for ongoing development. Simulator data is preserved and no Simulator is left booted by this task. No production App Store release, website deployment or follow-up timer was changed.
