# Floe 1.8.17 (338) delivery

2026-11-13 (Sydney). Frozen source `67d30edb3bcfc9fa674f2762f096de533e13b427`, immutable annotated tag `v1.8.17`, tag object `05501912c0634204cca2888ec3a4f999eb5580ed`.

| Channel | Verified result |
| --- | --- |
| Internal TestFlight | Apple `VALID`, unexpired; existing **Floe QA** group `IN_BETA_TESTING`. A separate Apple GET confirmed availability at 00:24 UTC. |
| GitHub | Normal **stable/latest** release passed strict readback, including source attestation and an actual download of the matching unsigned IPA. |
| Feather | The publication awaited the actual downstream job. That job passed, and independent live-feed readback matched the same installer at 00:32 UTC. |
| Public TestFlight | **Not submitted.** This build is for internal testing. |
| App Store | No formal submission or publication. Build 315 and the withdrawn public Build 331 arrangements remain unchanged. |

[Release and installer](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.17) · [Signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/43333312106) · [Independent Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43336682006) · [Normal publication](https://github.com/JiangNanGenius/floe-agent/actions/runs/43336958821) · [Awaited Feather job](https://github.com/JiangNanGenius/floe-agent/actions/runs/43336958821/job/131597484051).

## Scope and qualification

Repairs cover meeting transcription and playback lifecycle, the recording workbench, authorized execution after plan confirmation, current-run checklist/reset, main/child file-card receipts and large-text reading, native text editing, legacy database/reference inspection, and premature or stale failure notifications. See the [frozen bilingual release notes](../notes/RELEASE_NOTES_1.8.17_BUILD_338.md).

- Full App/test object compilation and linking passed, followed by an arm64 device archive with **Xcode 27.2 (27B52), iPhoneOS 27.2**. The actual device C compile was verified. Original App products and all **19 dSYM bundles** were preserved before packaging.
- **100 distinct affected App test methods have a latest actual PASS, with 0 skips.** Four preserved runs executed 121 cases; repeated executions are not extra methods. Root approved 20 unchanged-test reuses against the final production changes. The original 11 and 5 failed executions remain preserved. Capacity work has **8 separate passing native component tests**, not 8 additional App methods or proof of user-device space reclaimed.
- Actual iPad Simulator UI review covered the full meeting split/deck/material-import entry and a successful TXT card opening the native reader with Chinese/emoji text and continuous-load status. **256KB/410KB full reading and EOF are behavior-test evidence**, rather than a claim that screenshots alone proved EOF. The owned synthetic conversation was deleted through the App; the Simulator and mirror were shut down.

Historical cards without a persisted typed child-file receipt may remain unavailable; ownership, digest or receipt data is not invented to reopen them. This Simulator UI run did not exercise actual audio import/playback, microphone recording, cloud inference or speaker quality. Independent GPU, Game, Interior and Android work was outside this candidate.

## Artifact identity and recovery

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Transport ZIP | 1188263161 | `b8d289a7142c5056727595a301b4f3aed2895de4d94e2a1cbf8dc0f7170151fe` |
| Signed TestFlight IPA | 918112741 | `0c1f06a941ecbdfbdda2f8c264418d1cd873e7f9ec987e4588f74b03ac0a96bd` |
| Public unsigned IPA | 917946884 | `f8ee6087856ec558b7b34432cb37be30b65c10113f904ed54f729859054dab6e` |

Signing and publication reused the same locally archived App; neither rebuilt it. The first packaging attempt correctly refused an outdated private-adapter hash after three release-document paths changed. Its driver, failure and raw validation remain preserved. Only that reviewed helper-hash binding was corrected before packaging the same archive; the frozen App source/tag and product guards stayed unchanged.

## Physical M4 iPad check

Build 338 was installed through TestFlight on the supplied M4 iPad. One actual optimization processed 9 of 13 retained recovery disks: **8 optimized, 1 entered recovery protection, and 4 were not attempted**. The batch ended `recovery-pending`; it is not accepted as complete. The initial unknown-reference blockage no longer occurred. Existing data, installed software and recovery disks were retained; no reset, deletion or re-download was invoked.

Independent device-volume reads measured free space increasing from **73,694,306,304 to 198,542,516,224 bytes**, a real **124,848,209,920-byte (124.85GB)** increase. This is separate from the receipt's 124.91GB file-allocation reduction and its 124.93GB observed free-space change; other device activity can affect the volume. The final App file estimate was 206.32GB. The remaining recovery problem is assigned to 339; it is not dismissed as a display-only discrepancy.

The existing 69-second recording actually played and paused. Dragging reached 00:53, forward 15 seconds reached 01:08, and back returned to 00:53; the player closed normally. A single fresh native Workspace request created/read TXT and HTML. Both opened in the native reader with UTF-8, Chinese/emoji and complete 2/2 and 8/8 lines; the task remained completed. Expand opened the existing full-screen IDE and returned correctly. The same check exposed internal diff metadata incorrectly included in focused-file shortcuts, also assigned to 339. The owned reproduction conversation is retained temporarily to check the same saved receipts after that fix, then removed.

Physical live-microphone quality and cloud speaker attribution remain unverified because device screen control interferes with the microphone. No new recording or transcription was started in this check. The borrowed screen-sharing session and keyboard capture were stopped and verified. These later observations do not change the frozen 338 source, tag or artifacts.
