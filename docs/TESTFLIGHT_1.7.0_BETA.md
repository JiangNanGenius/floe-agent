# Floe 1.7 TestFlight delivery

## Current internal delivery: 1.7.0 (230) — available in Floe QA

Immutable tag `v1.7.0-beta.87` binds source `06c15e3511c5c12c52974a1426381968e778d7f6`. [Release run 36256360563](https://github.com/JiangNanGenius/floe-agent/actions/runs/36256360563) built the App with Xcode 26.6, retained the unsigned IPA before signing, uploaded the signed App, and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.87). The unsigned IPA is 739,518,631 bytes (SHA-256 `1dc9a10bdaaf1fd5ea9022cc5ceee9249d196cccf2202258e28e195383bc16b9`). Apple build `462dd279-16ab-4a73-9bd9-97a2e55202b6` was discovered as `VALID`; [prepare run 36259276773](https://github.com/JiangNanGenius/floe-agent/actions/runs/36259276773) read back `en-US` and `zh-Hans` beta notes. [Verify run 36259380555](https://github.com/JiangNanGenius/floe-agent/actions/runs/36259380555) confirmed on 2026-09-26 that the build is unexpired, attached to exactly one private internal `Floe QA` group, and `IN_BETA_TESTING`.

The Build 229 physical iPad MLX crash was captured as an MLX array trap during ordinary Qwen prefill, before any tool call; Build 230 adds bounded local prompt context and checks MLX errors before advancing prefill windows. The [cloud real-weight qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/36254087479) completed two distinct `workspace.readFile` calls, tool receipts and model continuations across two conversation turns. This is macOS-host evidence, **not** an iPad inference result. The App build embedded the pinned Office host, and a simulator checked Office entry paths, but the native PPT engine has no simulator slice, so editable slide paint, save and reopen are still unverified. See [Build 230 release notes](RELEASE_NOTES_1.7.0_BUILD_230.md). The guest remains single-core.

[Gitee mirror run 36256975346](https://github.com/JiangNanGenius/floe-agent/actions/runs/36256975346) verified the source branch and immutable tag. [Release-sync run 36258647317](https://github.com/JiangNanGenius/floe-agent/actions/runs/36258647317) created the [matching Gitee prerelease](https://gitee.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.87) and uploaded six small assets plus a mirror manifest, but could not attach the 705.3 MiB IPA because the repository's 1 GiB attachment quota had only 28.9 MiB free. Get the IPA from GitHub; Gitee IPA delivery remains incomplete. [Feather run 36258640821](https://github.com/JiangNanGenius/floe-agent/actions/runs/36258640821) updated its feed for Build 230 from the verified GitHub artifact.

## Previous internal delivery: 1.7.0 (229) — available in Floe QA

Immutable tag `v1.7.0-beta.86` binds source `b06b0b0e42008e8ea5c6b402ab146c99e2bcf328`. [Release run 36239956371](https://github.com/JiangNanGenius/floe-agent/actions/runs/36239956371) compiled with Xcode 26.6, retained `Floe-Agent-1.7.0-build229-unsigned.ipa` (739,485,403 bytes; SHA-256 `5cd022eb612d89f1d94b91594b747000404cec3f247b8508e89a83e88436124d`) before signing, accepted the signed TestFlight upload, and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.86). Apple build `3aecdb89-1cca-4192-9b32-1493d72ad3fe` is `VALID`, unexpired and audience `APP_STORE_ELIGIBLE`; [prepare run 36242606863](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242606863) read back `en-US` and `zh-Hans` beta notes, while [verify run 36242653374](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242653374) confirmed at 2026-09-26T12:40:28Z that the sole attached group is private internal `Floe QA` (feedback enabled, no public link) and its state is `IN_BETA_TESTING`.

Build 229 repairs Office close/save acknowledgement handling and unhealthy MLX container reuse between turns. Targeted local model tests passed 127/127; focused Office hosts passed their changed contracts. The device payload links the pinned Office host and verified resources, but its own [embedding receipt](https://github.com/JiangNanGenius/floe-agent/actions/runs/36239956371) records `engineOpened=false` and no device-qualified PPT first frame, edit or write-back. These are **not** iPad acceptance. Dual-core remains gated at one guest vCPU; the separately investigated fast-path candidate was rejected for an LR/SC correctness race. See [Build 229 release notes](RELEASE_NOTES_1.7.0_BUILD_229.md) and [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_229.json).

Gitee distribution is a separate gate. [Refs run 36243056531](https://github.com/JiangNanGenius/floe-agent/actions/runs/36243056531) verified its main branch against GitHub main. [Release-sync run 36242058529](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242058529) verified the immutable tag, created the [matching Gitee prerelease](https://gitee.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.86), and hash-verified six small assets. Its only failed asset was the 739,485,403-byte unsigned IPA: the 1 GiB attachment quota had 28.9 MiB free, below the 705.2 MiB required. The GitHub IPA remains the download source.

## Previous internal delivery: 1.7.0 (228) — available in Floe QA

Immutable tag `v1.7.0-beta.85` binds source `ed8f233a432f64df6475d767d82ace2d77b15a63`. [Release run 36009125622](https://github.com/JiangNanGenius/floe-agent/actions/runs/36009125622) compiled with Xcode 26.6, retained `Floe-Agent-1.7.0-build228-unsigned.ipa` (739,478,368 bytes; SHA-256 `1cfe17ba4e95f869bf962d3a1238f333b6525fddfc1dde1b295f78a262d95076`) before signing, accepted the signed TestFlight upload, and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.85). Apple build `d76ae893-c70f-4917-b5cc-2671978d8da4` is `VALID`, unexpired and audience `APP_STORE_ELIGIBLE`; [prepare run 36015637207](https://github.com/JiangNanGenius/floe-agent/actions/runs/36015637207) read back `en-US` and `zh-Hans` beta notes, while [verify run 36015717443](https://github.com/JiangNanGenius/floe-agent/actions/runs/36015717443) confirmed at 2026-09-24T14:50:39Z that the sole attached group is private internal `Floe QA` (feedback enabled, no public link) and its state is `IN_BETA_TESTING`.

Targeted component evidence: the updated Office host is pinned from [run 36000058922](https://github.com/JiangNanGenius/floe-agent/actions/runs/36000058922); a macOS cloud Qwen host completed the same snapshot's long prefill in [run 36007392043](https://github.com/JiangNanGenius/floe-agent/actions/runs/36007392043); TinyEMU S0–S4 checks passed, while corrected S5 equal-work `dd` performance missed the two-core enablement gate in [run 36009075837](https://github.com/JiangNanGenius/floe-agent/actions/runs/36009075837). Dual-core remains disabled for this shipping App. No physical iPad MLX, PPT editable first frame/save, PiP, notification or IDE Office acceptance is claimed. Gitee source and tag match the release SHA, and six small assets synced; its unsigned IPA mirror failed because the 1 GiB repository attachment quota had only 28.9 MiB free for a 705.2 MiB file ([mirror run 36014297722](https://github.com/JiangNanGenius/floe-agent/actions/runs/36014297722)).

## Previous internal delivery: 1.7.0 (227) — available in Floe QA

Immutable tag `v1.7.0-beta.84` binds source `9c756864fa9532d02ba7f7073320f8b48d94dc51`. [Release run 35957256008](https://github.com/JiangNanGenius/floe-agent/actions/runs/35957256008) compiled with Xcode 26.6, retained `Floe-Agent-1.7.0-build227-unsigned.ipa` (739,368,613 bytes; SHA-256 `a77b3b9a120a55dd6737bf1fb89efe7609c8917ca3facab7cd9cbb5c4c66b30c`) before signing, accepted the signed TestFlight upload, and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.84). Apple build `640e39a2-001b-4672-9b17-b4a378d9eb6a` was verified `VALID`, unexpired, audience `APP_STORE_ELIGIBLE`, attached only to the private internal `Floe QA` group (no public link), with `IN_BETA_TESTING` at 2026-09-24T05:42:18Z by [verify run 35961062720](https://github.com/JiangNanGenius/floe-agent/actions/runs/35961062720). [Prepare run 35961014056](https://github.com/JiangNanGenius/floe-agent/actions/runs/35961014056) read back `en-US` and `zh-Hans` beta notes. The bundled Office host and resources passed device-payload pin checks; editable PPT rendering and save/reopen on a physical iPad are still unverified. Local-model loading, PiP, notifications, keyboard/touch input and dual-core Guest operation also remain device acceptance items. See [Build 227 release notes](RELEASE_NOTES_1.7.0_BUILD_227.md) and [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_227.json). Gitee mirrored source and six small release assets; its unsigned IPA mirror exceeded the repository's 1 GiB attachment quota and is not a completed distribution channel for this build.

## Failed candidate: 1.7.0 (226) — immutable tag retained, App compile failed before IPA

Tag `v1.7.0-beta.83` binds source `b2b2fd75ea42a2a569616606d2db8e14870da74c` and remains unchanged. [Release run 35955220518](https://github.com/JiangNanGenius/floe-agent/actions/runs/35955220518) failed in the App target: `FloeApp/Workspace/FileTreeView.swift` used `CancellationToken` without importing `FloeTools`. No IPA or TestFlight upload was produced. Build 227 added the import and compiled successfully; the Build 226 [candidate notes](RELEASE_NOTES_1.7.0_BUILD_226.md) and [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_226.json) remain as evidence.

## Previous internal delivery: 1.7.0 (225) — available in Floe QA

Immutable tag `v1.7.0-beta.82` binds source `fe0852b4559ab2fb14bef671cf73aec3d7370f03`. [Release run 35773856510](https://github.com/JiangNanGenius/floe-agent/actions/runs/35773856510) completed the accepted-SDK App build, retained `Floe-Agent-1.7.0-build225-unsigned.ipa` (746,930,865 bytes; SHA-256 `03892d70d5cb7f379ce1782a2af0fc762f211921cb6f39cd1c5aff26a610487a`) before signing, uploaded the signed App and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.82). Apple build `b53b6e02-a0cb-4eba-8d94-921805ff80e1` was verified `VALID`, unexpired, audience `APP_STORE_ELIGIBLE`, attached only to the private internal `Floe QA` group (no public link) and `IN_BETA_TESTING` at 2026-09-22T20:17:32Z by [verify run 35779297843](https://github.com/JiangNanGenius/floe-agent/actions/runs/35779297843); [prepare run 35779218539](https://github.com/JiangNanGenius/floe-agent/actions/runs/35779218539) read back the `en-US` and `zh-Hans` beta notes. Local evidence remains 23 focused Linux image tests and a Swift 6 iOS-SDK object compile of the repaired source. Physical-device Linux, local-model, PPT and PiP acceptance remains with the user. See [release notes](RELEASE_NOTES_1.7.0_BUILD_225.md) and [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_225.json).

## Failed candidate: 1.7.0 (224) — immutable tag retained, accepted-SDK compile failed, superseded by Build 225

Build 224 was prepared at source `c36b7b24377827de55e8546dfd0de7fb2f20125d`, bound by the immutable tag `v1.7.0-beta.81` (retained; not moved or deleted). [Release run 35767875337](https://github.com/JiangNanGenius/floe-agent/actions/runs/35767875337) (2026-09-22, `lean_release`) bound the tag successfully, but the "Build once with the accepted upload SDK or reuse the retained unsigned IPA / upload" job (106881974925) failed with exit code 65 on Xcode 26.6 / iPhoneOS 26.5 SDK. The sole App-target error was `FloeApp/Execution/LinuxGuestImageDownloader.swift:101:9: error: thrown expression type 'any Error' cannot be converted to error type 'LinuxGuestImageTransferError'` — a non-exhaustive `catch` on the untyped-throws `URLSession.bytes(for:)` seam inside a `throws(LinuxGuestImageTransferError)` function. There was no IPA, no upload and no Apple processing, and all downstream publish jobs were skipped. The Build 224 metadata ([release notes](RELEASE_NOTES_1.7.0_BUILD_224.md), [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_224.json)) and the run record are retained as evidence; the repaired source is Build 225.

## Previous internal delivery: 1.7.0 (223) — available in Floe QA

Immutable tag `v1.7.0-beta.80` binds source `e933305d`. [Release run 35725410528](https://github.com/JiangNanGenius/floe-agent/actions/runs/35725410528) completed the accepted-SDK App build, preserved `Floe-Agent-1.7.0-build223-unsigned.ipa` (746,855,726 bytes; SHA-256 `74a7f7e11de0918889c2a5c76075327dda5c3d6e7adc385829a501bb0a97ebae`) before signing, uploaded the signed App and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.80). Apple build `19f9bebc-88f0-437c-8863-b25d76e6b9be` was verified `VALID`, unexpired, attached only to the private internal `Floe QA` group (no public link) and `IN_BETA_TESTING` at 2026-09-22T13:19:54Z by [verify run 35732736716](https://github.com/JiangNanGenius/floe-agent/actions/runs/35732736716). Build 225 supersedes its source behavior but has separate delivery gates. Physical-device acceptance remains with the user. See the retained [Build 223 release notes](RELEASE_NOTES_1.7.0_BUILD_223.md) and [test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_223.json).

## Previous internal delivery: 1.7.0 (221) — retained in Floe QA history

Build 221 is the App-compile repair of the integrated Build 220 source: all
four shipping targets declare `MARKETING_VERSION 1.7.0` /
`CURRENT_PROJECT_VERSION 221` in `FloeAgent/project.yml`, the regenerated
`FloeAgent.xcodeproj` matches, and the [release notes](RELEASE_NOTES_1.7.0_BUILD_221.md)
plus [bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_221.json) document
the repair (missing `FloeExecution`/`FloeModels` imports in
`BackgroundRunCoordinator.swift`, the `LinuxImageInstallCard` async/import
errors, the `OfficeVisibleRenderGate` property mismatch, and one Swift 6
sendable-payload routing fix) with the same functional slice as Build 220.

Immutable tag `v1.7.0-beta.78` binds source
[`20253e67`](https://github.com/JiangNanGenius/floe-agent/commit/20253e67e71d6b7950915aad60c0b3c18c2299d9).
[Release run 35678610685](https://github.com/JiangNanGenius/floe-agent/actions/runs/35678610685)
completed the accepted-SDK App build, preserved the unsigned IPA and private
symbols before signing, and uploaded the signed package. Apple build
`387e2282-0814-4384-88a8-5a756d46a5ef` is `VALID`, unexpired, attached to
exactly one private internal `Floe QA` group with no public link, and
`IN_BETA_TESTING`; [prepare 35682313921](https://github.com/JiangNanGenius/floe-agent/actions/runs/35682313921)
read back `en-US` and `zh-Hans` notes, and
[verify 35682374446](https://github.com/JiangNanGenius/floe-agent/actions/runs/35682374446)
confirmed the final group and availability state at 2026-09-22T03:13:57Z.

The unsigned-only [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.78)
publishes `Floe-Agent-1.7.0-build221-unsigned.ipa` (sha256
`c9662126b15783cebe3381e11d8355253b78fd94691f995f0668aacd7111072d`,
746,110,508 B) with provenance and validation metadata; no signed IPA is
public. [Feather run 35681097386](https://github.com/JiangNanGenius/floe-agent/actions/runs/35681097386)
updated `feather.json` at commit `ff0969e5` from the same artifact. Simulator/UI
qualification was waived by the user's expedited request; physical-device
acceptance remains with the user.

## Build 220 candidate (1.7.0 (220)) — metadata prepared; cloud device compile failed, superseded by Build 221

Build 220 version and release metadata was prepared from the integrated `main`
source `9e83fcfa` on branch `codex/build220-release-metadata`: all four shipping
targets declared `MARKETING_VERSION 1.7.0` / `CURRENT_PROJECT_VERSION 220` in
`FloeAgent/project.yml`, the regenerated `FloeAgent.xcodeproj` matched, and the
[release notes](RELEASE_NOTES_1.7.0_BUILD_220.md) plus
[bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_220.json) described the
slice (per-environment Linux disks with `/floe/env` caches, the 9P `ls -l`
repair, truthful install state, an explicit background mode with measured-only
metrics, task-completion notifications, the PPTX visible-render/edit-entry
repair and the documentation/sideload-link refresh).

The accepted-SDK Release/device App compile stopped in the App target with 14
diagnostics across `BackgroundRunCoordinator.swift`, `LinuxImageInstallCard.swift`
and `OfficeDocumentEditorView.swift` (rebuild run
[35673428023](https://github.com/JiangNanGenius/floe-agent/actions/runs/35673428023));
no artifact was retained, signed or uploaded. The repair and the 221 version
bump are recorded in the [Build 221 notes](RELEASE_NOTES_1.7.0_BUILD_221.md);
build 220 was never uploaded, processed by Apple, attached to a beta group or
accepted on a device.

## Previous internal delivery: 1.7.0 (219) — available in Floe QA

Apple **VALID**, unexpired, exactly one private internal **Floe QA** group
(`internal=true`, feedback enabled, no public link), and `IN_BETA_TESTING` were
verified at **2026-09-21T22:01:30Z** by
[verify 35660445743](https://github.com/JiangNanGenius/floe-agent/actions/runs/35660445743).
ASC build ID `fe178638-2bf8-449c-a321-54ef5899177c` (uploaded
2026-09-21T21:42:22Z, audience `APP_STORE_ELIGIBLE`).
[Discover 35659785733](https://github.com/JiangNanGenius/floe-agent/actions/runs/35659785733)
listed build 219 as the latest `VALID` upload;
[prepare 35660364957](https://github.com/JiangNanGenius/floe-agent/actions/runs/35660364957)
saved and read back both beta-note locales — readback
`{"buildID":"fe178638-2bf8-449c-a321-54ef5899177c","version":"1.7.0","build":"219","processing":"VALID","group":"Floe QA","betaNotesVerified":["en-US","zh-Hans"]}`.

Immutable tag `v1.7.0-beta.76`, source
[`0b21be93e173167827644f8c434f5d5a0f2070ea`](https://github.com/JiangNanGenius/floe-agent/commit/0b21be93e173167827644f8c434f5d5a0f2070ea).
[Release run 35653989305](https://github.com/JiangNanGenius/floe-agent/actions/runs/35653989305)
completed the accepted-SDK Release/device App build, retained the unsigned IPA
and matching private symbols before signing, then validated and uploaded the
signed package. The unsigned-only GitHub prerelease
[v1.7.0-beta.76](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.76)
publishes `Floe-Agent-1.7.0-build219-unsigned.ipa` (sha256
`ef2006367ab65569210f0b98fc641ba38139608462d548395aca7c219410ca95`,
745,812,559 B) with provenance, checksum and public validation metadata; no
signed IPA is public. [Feather run 35658570911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35658570911)
verified that release and committed `feather.json` at
[`b4922b78`](https://github.com/JiangNanGenius/floe-agent/commit/b4922b78)
with the same digest, size and `sourceCommit`.

Build 219 makes TinyEMU/Linux the primary local runtime with automatic first-use
preparation, a qualified guest network, preserved environment disks and package
state, explicit Settings and Terminal controls, and complete LGPL corresponding
source/relink material for the runner. It adds MLX snapshot and memory checks,
immediate IDE source-control refresh, standalone workspace Office editing, a
bounded Office close/save path and a PPTX load watchdog. The README Feather and
AltStore buttons use the official HTTPS download page because GitHub removes the
custom URL schemes; the website remains the working quick-add surface.

The user requested expedited internal delivery, so simulator/UI repetition was
skipped in favor of focused checks, the qualified Linux component boot and the
cloud accepted-SDK App build. Physical-device behavior, Office fidelity and
Pencil feel remain for the user to accept. This record does not claim a public
TestFlight or production App Store release. [Release notes](RELEASE_NOTES_1.7.0_BUILD_219.md)
and [bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_219.json) describe the
delivered slice.

## Previous internal delivery: 1.7.0 (218) — available in Floe QA

Apple **VALID**, unexpired, exactly one private internal **Floe QA** group
(`internal=true`, feedback enabled, no public link), and `IN_BETA_TESTING` were
verified at **2026-09-21T15:08:27Z** by
[verify 35616870748](https://github.com/JiangNanGenius/floe-agent/actions/runs/35616870748).
ASC build ID `8d636b00-d114-42d6-bc0c-4081317fb38e` (uploaded
2026-09-21T14:59:56Z, audience `APP_STORE_ELIGIBLE`).
[Discover 35616665807](https://github.com/JiangNanGenius/floe-agent/actions/runs/35616665807)
listed build 218 as the latest `VALID` upload;
[prepare 35616732222](https://github.com/JiangNanGenius/floe-agent/actions/runs/35616732222)
saved and read back both beta-note locales — readback
`{"buildID":"8d636b00-d114-42d6-bc0c-4081317fb38e","version":"1.7.0","build":"218","processing":"VALID","group":"Floe QA","betaNotesVerified":["en-US","zh-Hans"]}`.

Immutable tag `v1.7.0-beta.75`, source
[`83eb91a846a6d36e4ffd24eee563ba2d50cc9893`](https://github.com/JiangNanGenius/floe-agent/commit/83eb91a846a6d36e4ffd24eee563ba2d50cc9893).
[Release run 35612529418](https://github.com/JiangNanGenius/floe-agent/actions/runs/35612529418)
completed the accepted-SDK Release/device App build, retained the unsigned IPA
and matching private symbols before signing, and then validated and uploaded the
signed package. The unsigned-only GitHub prerelease
[v1.7.0-beta.75](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.75)
publishes `Floe-Agent-1.7.0-build218-unsigned.ipa` (sha256
`ddc0568beafc4c51c2977dd01548c9deba98546c38bfa8d5b0081945537b04cc`,
745,755,983 B) with provenance, checksum and public validation metadata; no
signed IPA is public. [Feather run 35615816474](https://github.com/JiangNanGenius/floe-agent/actions/runs/35615816474)
verified that release and committed `feather.json` at
[`bd7dbd61`](https://github.com/JiangNanGenius/floe-agent/commit/bd7dbd61fa01d2651623016380737fecee75bd4a)
with the same digest, size and `sourceCommit`.

Build 218 repairs the device-feedback paths for Linux installation, Office CJK
font discovery and Pencil input, workspace-versus-IDE Office routing, IDE source
control and archive browsing, and stable multi-turn local-model tools. Build 217
failed during App compilation before producing or uploading an IPA; the failure
is retained at immutable tag `v1.7.0-beta.74`. The user requested expedited
internal delivery, so only focused checks plus the cloud accepted-SDK App build,
signing and Apple validation were used. Physical-device behavior remains for the
user to accept. This record does not claim a public TestFlight or production App
Store release. [Release notes](RELEASE_NOTES_1.7.0_BUILD_218.md) and
[bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_218.json) describe the slice.

## Previous internal delivery: 1.7.0 (216) — available in Floe QA

Apple **VALID**, unexpired, exactly one private internal **Floe QA** group
(`internal=true`, feedback enabled, no public link), and `IN_BETA_TESTING` were
verified at **2026-09-21T07:55:04Z** by
[verify 35575223221](https://github.com/JiangNanGenius/floe-agent/actions/runs/35575223221).
ASC build ID `c947301c-d7f0-47e2-9dd6-d6fbaac4ca89` (uploaded
2026-09-21T07:40:33Z, audience `APP_STORE_ELIGIBLE`).
[Discover 35575112857](https://github.com/JiangNanGenius/floe-agent/actions/runs/35575112857)
listed build 216 as the latest `VALID` upload;
[prepare 35575161290](https://github.com/JiangNanGenius/floe-agent/actions/runs/35575161290)
saved and read back both beta-note locales — readback
`{"buildID":"c947301c-d7f0-47e2-9dd6-d6fbaac4ca89","version":"1.7.0","build":"216","processing":"VALID","group":"Floe QA","betaNotesVerified":["en-US","zh-Hans"]}`.

Immutable tag `v1.7.0-beta.73`, source
[`c2f20f6e65c26678e6903cda7aa1e5c6dc90aec6`](https://github.com/JiangNanGenius/floe-agent/commit/c2f20f6e65c26678e6903cda7aa1e5c6dc90aec6).
[Release run 35570785184](https://github.com/JiangNanGenius/floe-agent/actions/runs/35570785184)
("TestFlight and Unsigned IPA Release") completed the accepted-SDK App build,
retained the unsigned IPA and matching private symbols before signing, then
validated and uploaded the signed package. The unsigned-only GitHub prerelease
[v1.7.0-beta.73](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.73)
publishes `Floe-Agent-1.7.0-build216-unsigned.ipa` (sha256
`caeed861b7d8b6aba522b00a52ff93523fd5533633b09439ce512089d3350569`,
745,582,944 B) with provenance, checksum and public validation metadata; no
signed IPA is public. [Feather run 35573496016](https://github.com/JiangNanGenius/floe-agent/actions/runs/35573496016)
verified that release and committed `feather.json` at
[`72b21a3e`](https://github.com/JiangNanGenius/floe-agent/commit/72b21a3ea78cdd14c5c032d132138a2d6524e927)
with the same digest, size and `sourceCommit`.

Build 216 preserves the Build 215 device-feedback repairs and adds release-path
compatibility fixes for Office, HTTP qualification and the TinyEMU-era App
regression gate. The user requested expedited internal delivery, so only focused
checks plus the cloud accepted-SDK App build, signing and Apple validation were
used; simulator/UI qualification and physical-device acceptance remain with the
user. This record does not claim a production App Store release.
[Release notes](RELEASE_NOTES_1.7.0_BUILD_216.md) and
[bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_216.json) describe the slice.

## Previous internal delivery: 1.7.0 (215) — available in Floe QA

Apple **VALID**, unexpired, exactly one private internal **Floe QA** group
(`internal=true`, feedback enabled, no public link) and `IN_BETA_TESTING` were
verified at **2026-09-21T01:24:50Z** by
[verify 35550801711](https://github.com/JiangNanGenius/floe-agent/actions/runs/35550801711).
ASC build ID `38cd289e-c4f7-4f6f-95c0-efc4e5f38648` (uploaded 2026-09-21T01:13:54Z,
audience `APP_STORE_ELIGIBLE`).
[Discover 35550702469](https://github.com/JiangNanGenius/floe-agent/actions/runs/35550702469)
listed build 215 as the latest `VALID` upload;
[prepare 35550757711](https://github.com/JiangNanGenius/floe-agent/actions/runs/35550757711)
saved and read back both beta-note locales — readback
`{"buildID":"38cd289e-c4f7-4f6f-95c0-efc4e5f38648","version":"1.7.0","build":"215","processing":"VALID","group":"Floe QA","betaNotesVerified":["en-US","zh-Hans"]}`.

Immutable tag `v1.7.0-beta.72`, source
[`a2f9ea50cd8bbafceac23ff49fe46c9607811271`](https://github.com/JiangNanGenius/floe-agent/commit/a2f9ea50cd8bbafceac23ff49fe46c9607811271).
[Release run 35548088168](https://github.com/JiangNanGenius/floe-agent/actions/runs/35548088168)
("TestFlight and Unsigned IPA Release") built once with the accepted upload SDK
(Xcode 26.6 / 17F113), retained the unsigned IPA
`Floe-Agent-1.7.0-build215-unsigned.ipa` (sha256
`23dd61af1e8eed67631ba5b831f237f450ac05a759fc98260cea174a8c1cd49b`,
745,579,391 B, app UUID `7E1F9712-AFA0-3C06-9180-F2893E2E3C39`) and matching
private symbols `release-symbols-1.7.0-build215` before signing, then signed,
validated and uploaded the same source and attested the unsigned-only asset set
(attestation subject `…build215-unsigned.ipa@sha256:23dd61af…`). The attested
unsigned GitHub prerelease
[v1.7.0-beta.72](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.72)
("Floe Agent 1.7.0 (build 215)", prerelease, published 2026-09-21T01:13:11Z)
carries that IPA plus provenance, checksum and validation metadata; no signed
IPA is published. [Feather run 35550183999](https://github.com/JiangNanGenius/floe-agent/actions/runs/35550183999)
verified the published checksum/provenance and committed `feather.json` at
[`c6cd89fc`](https://github.com/JiangNanGenius/floe-agent/commit/c6cd89fc43042117bf722051abe07407e7d6c542)
with the same sha256, size 745,579,391 and `sourceCommit a2f9ea50…`, dated
2026-09-21T01:13:11Z.

Build 215 is the stability follow-up to the first TinyEMU delivery (build 214):
local-model tool calls through a second continuation with reduced GatedDeltaNet
prefill batching, cross-task history lookup continuing through to a final answer,
per-task concurrent terminals with cancellation/recovery of stuck commands, a
fixed libgit2 runtime path for Git initialization, PDF/Office pinned to IDE tabs
and following task switches, Command-S saving and a save prompt before closing a
changed document, bundled Chinese font metadata, and compact mind-map add icons
with corrected free-position dragging. Native Python, Node, Ruby and other
language payloads remain outside the app and run in the Linux guest.
[Release notes](RELEASE_NOTES_1.7.0_BUILD_215.md) and
[bilingual test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_215.json) describe the slice.

This is a user-requested expedited internal TestFlight: simulator/UI
qualification was skipped by explicit user request
(`simulator_tests=skipped_by_user_request`); only focused checks plus the cloud
accepted-SDK App build, signing and Apple validation were performed. There is no
public TestFlight link and no App Store production release; the unsigned GitHub
prerelease and Feather are separate developer-package routes that require your
own signing identity. **Physical-device installation, Linux guest performance,
real SSH/SCP transfers and foreground-model crash resolution remain user
acceptance; no device installation is claimed by this record.**

## Previous internal delivery: 1.7.0 (214) — available in Floe QA

Apple VALID, unexpired, the existing private Floe QA group and IN_BETA_TESTING
verified at 2026-09-20T21:32:34Z. English and Simplified Chinese beta notes
are saved and verified. App source `33759e44` / `v1.7.0-beta.71`;
packaging recovery `c4dddb79` reused the retained IPA without rebuilding.
[TinyEMU migration, all feedback repairs, artifacts and validation limits](qualification/build214-release/README.md).


## Previous internal delivery: 1.7.0 (211) — available in Floe QA

Immutable tag `v1.7.0-beta.68`, source `cc45d67023814b10f72a57afc562dbbe118ae224`.
[Build/upload 35505655482](https://github.com/JiangNanGenius/floe-agent/actions/runs/35505655482)
passed the accepted-SDK App build (Xcode 26.6 / 17F113), retained unsigned IPA
artifact `10604086426` and matching symbols `10604260760` before signing, then
validated and uploaded the same source. Signed TestFlight evidence is artifact
`10603957238`. Apple transport reported VERIFY SUCCEEDED and UPLOAD SUCCEEDED;
upload receipt `80b1ce7e-5865-488a-b4de-2963115c5c74` names `org.floeagent.ios`,
version 1.7.0, build 211. Upload succeeded at 2026-09-20 11:16:18 UTC.

Apple build `80b1ce7e-5865-488a-b4de-2963115c5c74` is **VALID, unexpired and
IN_BETA_TESTING**, attached to exactly the existing private **Floe QA** group,
verified at **2026-09-20 11:45:30 UTC**. English and Simplified Chinese notes were
saved and read back by [prepare 35508651864](https://github.com/JiangNanGenius/floe-agent/actions/runs/35508651864);
[verify 35508707395](https://github.com/JiangNanGenius/floe-agent/actions/runs/35508707395)
confirmed version, expiration, group identity and internal beta state.
The initial upload PROCESSING delay resolved without a rebuild or re-upload.

This build contains the complete September 20 feedback code set: Office lifecycle
and recovery; PDF/Office in IDE tabs; Git initialization; native free-position
mind maps; Shell gate/session recovery; cross-task history through final replies;
local-model context/recovery; separate Linux/Python/Node/WASM package entries;
and the optional TinyEMU backend shared by Shell, local Python and services.
Settings can download the pinned Linux image; verified boot paths are absolute,
and each environment retains a separate writable disk across restarts.
[Release notes](RELEASE_NOTES_1.7.0_BUILD_211.md) and
[test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_211.json) describe device acceptance.

The [Linux component](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260920.1)
is publicly downloadable with corresponding sources, package license notices and
LGPL relink materials. It is separate from this internal App delivery. No public
App GitHub/Feather or App Store production release was requested or performed.
Only focused checks plus cloud App compilation/signing/Apple validation were
required. Simulator/UI regression and the full test matrix were waived; physical
acceptance belongs to the user. Kernel 4.15/Debian13 guest performance, real SSH/SCP
transfers and all device interactions remain unverified on iPad.

Build209 failed compilation; build210 was cancelled before upload to finish the
settings download action. Their immutable sources and failure/cancellation
records remain preserved; neither is an installable release.

## Previous internal delivery: 1.7.0 (207) — available in Floe QA

Immutable tag `v1.7.0-beta.64`, source `41b03ad516c454f6d05bf9f9fa4e31733b4a9340`.
[Build/upload 35497153478](https://github.com/JiangNanGenius/floe-agent/actions/runs/35497153478)
passed the accepted-SDK App build (Xcode 26.6 / 17F113), retained the unsigned
IPA artifact `10601633343` and matching private symbols `10601593620` before
signing, then validated and uploaded the same source. Signed TestFlight evidence
is retained as artifact `10601950027`. No public GitHub or Feather release was
requested for this repair slice.

Apple build `a4a8416b-b8c4-4a64-acae-37434620585a` is `VALID`, unexpired,
attached to the sole existing private **Floe QA** group and `IN_BETA_TESTING`,
verified at **2026-09-20 08:51:56 UTC**. Both English and Chinese test notes were
saved and read back in [prepare 35500625761](https://github.com/JiangNanGenius/floe-agent/actions/runs/35500625761).
The first verification read reported no group immediately after preparation
([35500656677](https://github.com/JiangNanGenius/floe-agent/actions/runs/35500656677));
a later read after propagation confirmed the exact group and installability
([35500722350](https://github.com/JiangNanGenius/floe-agent/actions/runs/35500722350)).
No build, upload or group mutation was repeated to fix that stale read.

This slice contains Office lifecycle recovery, native PDF/Office in IDE tabs,
Git initialization/lifetime fixes, native freely positioned mind maps and Shell
session/gate repairs. **It does not contain the later local-model, cross-task,
package-entry or Linux backend increments.** [Test notes](TESTFLIGHT_1.7_WHATS_NEW_BUILD_207.json)
and [ongoing repair status](FLOE_FEEDBACK_2026_09_20.md) keep those separate.
Simulator/UI regression was waived by the user; physical acceptance is theirs.

Build 208 (`v1.7.0-beta.65`, `37fe9864`) was cancelled before upload after a
Linux Python/Node package-ownership gap was discovered. It produced no device
artifact or TestFlight upload. That correction is intended for build 209; the
208 source and run remain immutable evidence.

## Previous internal delivery: 1.7.0 (204) — available in Floe QA

Immutable tag `v1.7.0-beta.61`, source `1f654c3e59ba18856006ea0c778986bf37072feb`.
[Run 35478308349](https://github.com/JiangNanGenius/floe-agent/actions/runs/35478308349)
completed the single accepted-SDK App build (Xcode 26.6 / 17F113), retained the
unsigned IPA `Floe-Agent-1.7.0-build204-unsigned.ipa` (sha256
`b093af32d0e34d7ee31350877af2f6e0713cabce1ce83999f1d827cf1e9a7af5`, 811,588,405 B,
app UUID `20DD1CBB-D91B-3834-8356-5FBE35A28575`) with matching private symbols before
signing, and TestFlight accepted the upload. `lean-publish` attested the retained
artifact and published the **normal non-prerelease Latest** GitHub release
`v1.7.0-beta.61` (unsigned-only asset set, attestation source digest `1f654c3e…`);
[Feather run 35480212487](https://github.com/JiangNanGenius/floe-agent/actions/runs/35480212487)
committed `feather.json` with the same sha256 and `sourceCommit 1f654c3e…`. Apple
build ID `5bbc54a5-a0af-4a16-933f-0be0aa790d74` was verified `VALID`, unexpired,
exactly one private Floe QA group and `IN_BETA_TESTING` at 2026-09-20 01:32:54 UTC
([discover 35481554699](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481554699),
[prepare 35481609531](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481609531),
[verify 35481660694](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481660694));
both English and Simplified Chinese test notes were saved and read back. Build 204
is the replacement attempt after the failed build 203 (frozen below); the only source
change is the one-line `@escaping` repair of the sole accepted-SDK compile error plus
the version increment. Simulator/UI qualification was skipped by explicit user
request, so this is internal device testing, not full acceptance; the CodeBlitz
error-95 toast still needs your on-device verification. Full evidence:
[build 204 delivery](qualification/build204-release/build204-delivery.md).

## Failed candidate: 1.7.0 (203)

Immutable tag `v1.7.0-beta.60` at `9e64d2a3cb96b9388994ac163bb0d3cba024d3ac`,
created by [run 35476640882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882)
(the single authorized lean dispatch for Build 203, dispatched at the metadata
commit `f6dfe287` plus the pre-dispatch bilingual notes repair `9e64d2a3`) and
preserved unmoved. That run failed in the accepted-SDK App build
([job 105986924093](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882/job/105986924093),
step "Rebuild the exact tag with the accepted App Store SDK", `xcodebuild` exit 65,
3 frontend failures): `OfficeDocumentEditorView.swift:1153` — the escaping
`Task { @MainActor in … }` closure captured the implicitly non-escaping
`timeoutError: @autoclosure () -> NSError` parameter. The complete rebuild log and
`FloeRebuild.xcresult` are retained in `rebuild-diagnostics-run35476640882`. Nothing
was retained, signed, uploaded or published; `lean-publish` never ran and no Apple
build ID exists for build 203. Full evidence:
[build 203 lean-build failure](qualification/build203-release/build203-lean-build-failure.md).

## Previous internal delivery: 1.7.0 (201) — available in Floe QA

Immutable tag `v1.7.0-beta.58`, source `be06cece8646d5ce53a12c6bf7fcd68ce728c0b3`.
[Run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806)
completed the single accepted-SDK App build (Xcode 26.6 / 17F113), retained the
unsigned IPA `Floe-Agent-1.7.0-build201-unsigned.ipa` (sha256
`e80ff0c56d4af35b7717b98cc704f1cb1131e67f8a0f15ebeaa12ec09286dec3`, 811,524,833 B,
app UUID `69627670-F83E-3B29-BCF9-57EBC5771426`) with matching private symbols
(artifact `release-symbols-1.7.0-build201`) before signing, and TestFlight accepted
the upload. That run's `lean-publish` job then failed because
`docs/RELEASE_NOTES_1.7.0_BUILD_201.md` was absent from the frozen tag checkout, so
nothing was attested, published or sent to Feather. Publication was recovered from
the same retained artifact — no rebuild and no re-upload, tag unmoved: the attested
unsigned GitHub prerelease `v1.7.0-beta.58` was published 2026-09-19 17:42 UTC with
the exact unsigned-only asset set (attestation source digest `be06cece…` signed by
`release-unsigned-ipa.yml`), and Feather
[run 35458914062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458914062)
verified the published checksum and provenance and committed `feather.json`
(`e7f75620`, sha256 `e80ff0c5…`, sourceCommit `be06cece…`). Apple `buildID`
`ea0f0b12-6fad-4a55-b1f2-ac2033328c74` was verified `VALID`, unexpired, exactly one
private Floe QA group and `IN_BETA_TESTING` at 2026-09-19 17:44 UTC
([discover 35457644985](https://github.com/JiangNanGenius/floe-agent/actions/runs/35457644985),
[prepare 35458929498](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458929498),
[verify 35459030591](https://github.com/JiangNanGenius/floe-agent/actions/runs/35459030591));
both English and Chinese test notes were saved and read back. A rebuild-free retry
(`reuse_direct_run=35453588806`,
[run 35458919065](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458919065))
failed in `testflight-direct.yml`'s reuse step on the same bare metadata-only verifier
call defect recorded for build 194 (only the lean publish job had been repaired); the
frozen tag's nested workflow cannot be fixed and re-run, so the step was repaired on
`main` with a regression test and its fixed commands were validated locally against
the real run payload (`testflightAccepted=true` → `upload_required=false`, no repeated
upload). Build 199 was never uploaded and build 200 stopped inside the accepted-SDK
App build, so build 201 is the first uploaded build since 198. Simulator/UI
qualification was skipped by explicit user request, so this is internal device
testing, not full acceptance. Device acceptance remains with the user, and the build
191 foreground Qwen GatedDeltaNet abort is still not proven fixed.

## Failed candidate: 1.7.0 (202)

Immutable tag `v1.7.0-beta.59` at `0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49`,
created by [run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
(the single authorized lean dispatch for Build 202) and preserved unmoved. That run
failed in the accepted-SDK App build ([job 105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911),
step "Rebuild the exact tag with the accepted App Store SDK", `xcodebuild` exit 65,
3 frontend failures): `SourceControlView.swift:293:90` passes the non-optional
`\.children` keypath where the SDK 26 `OutlineGroup` requires
`[SourceControlChangeTreeNode]?`. Nothing was retained, signed, uploaded or
published; `lean-publish` never ran and no Apple build ID exists for build 202. Full
evidence: [build 202 lean-build failure](qualification/build202-release/build202-lean-build-failure.md).

## Previous internal delivery: 1.7.0 (198) — available in Floe QA

Immutable tag `v1.7.0-beta.55`, source `ce3574f36f954bb64c100754ff17295cead7c238`.
[Run 35428858014](https://github.com/JiangNanGenius/floe-agent/actions/runs/35428858014)
completed the single accepted-SDK App build (Xcode 26.6 / 17F113), retained the
unsigned IPA `Floe-Agent-1.7.0-build198-unsigned.ipa` (sha256
`92af2a99d99daa1d5962e8e783be6d3bab49971360340a0d039d83eba881ec9a`, 811,481,871 B)
with matching private symbols before signing, and TestFlight accepted
the upload. Attestation source digest `ce3574f3…` signed by
`release-unsigned-ipa.yml`; the attested unsigned GitHub prerelease
`v1.7.0-beta.55` and the Feather source were published from the same artifact
(Feather run 35430911661; `feather.json` sha256 `92af2a99…`, sourceCommit
`ce3574f3…`). Apple `buildID` `efbad369-6908-4c7a-950b-597c03716e5b` was verified
`VALID`, unexpired, exactly one private Floe QA group and `IN_BETA_TESTING` at
2026-09-19 08:32 UTC ([discover 35432143491](https://github.com/JiangNanGenius/floe-agent/actions/runs/35432143491),
[prepare 35432200199](https://github.com/JiangNanGenius/floe-agent/actions/runs/35432200199),
[verify 35432243630](https://github.com/JiangNanGenius/floe-agent/actions/runs/35432243630));
both English and Chinese test notes were saved and read back. Simulator/UI
qualification was skipped by explicit user request, so this is internal device
testing, not full acceptance. Builds 194 and 195 were also uploaded to Apple
(`VALID`) but never published, and builds 192/193 never compiled; see their
records. Device acceptance remains with the user, and the build 191 foreground
Qwen GatedDeltaNet abort is still not proven fixed.

## Previous internal delivery: 1.7.0 (196) — available in Floe QA

Immutable tag `v1.7.0-beta.53`, source `0771aee5f4c3a5495b828084081c47f128b0462f`.
[Run 35411629062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35411629062)
completed the single accepted-SDK App build (Xcode 26.6 / 17F113), retained the
unsigned IPA `Floe-Agent-1.7.0-build196-unsigned.ipa` (sha256
`bd080ba7dae8acc3e7483c73c855a219c07956c27482032599e1b6d18bed80c4`, 811,292,228 B)
with matching private symbols (app UUID `66F46B44-2C38-3904-9C60-78D433A707E5`,
artifact `release-symbols-1.7.0-build196`) before signing, and TestFlight accepted
the upload. Attestation source digest `0771aee5…` signed by
`release-unsigned-ipa.yml`; the attested unsigned GitHub prerelease
`v1.7.0-beta.53` and the Feather source were published from the same artifact
(Feather run 35413736446; `feather.json` sha256 `bd080ba7…`, sourceCommit
`0771aee5…`). Apple `buildID` `27355e88-2f37-4c60-8b6e-713db546773b` was verified
`VALID`, unexpired, exactly one private Floe QA group and `IN_BETA_TESTING` at
2026-09-19 02:24 UTC ([discover 35415385318](https://github.com/JiangNanGenius/floe-agent/actions/runs/35415385318),
[notes 35415460626](https://github.com/JiangNanGenius/floe-agent/actions/runs/35415460626),
[verify 35415530334](https://github.com/JiangNanGenius/floe-agent/actions/runs/35415530334));
both English and Chinese test notes were saved and read back. Simulator/UI
qualification was skipped by explicit user request, so this is internal device
testing, not full acceptance. Builds 194 and 195 were also uploaded to Apple
(`VALID`) but never published, and builds 192/193 never compiled; see their
records. Device acceptance remains with the user, and the build 191 foreground
Qwen GatedDeltaNet abort is still not proven fixed.

## Previous internal delivery: 1.7.0 (191) — available in Floe QA

Immutable tag `v1.7.0-beta.48`, source `715cbc42e9402cf5ca691291fed5c201e61cf222`.
User explicitly authorized internal delivery despite the two SDK27 UI failures:
iPad body-search result tap query and iPhone New-button readiness query.
Both SDK App suites passed204/204; NativeNotes101/101 each. These results and
the waiver do not constitute full acceptance. [Qualification evidence](qualification/build191-release/README.md).
[Upload run35343019320](https://github.com/JiangNanGenius/floe-agent/actions/runs/35343019320)
stopped before signing: accepted-SDK iPhone initial assistant restart-button
readiness failed in addition to the two previously waived SDK27 UI cases.
The user subsequently waived this additional failure. Recovery run35346684753
stopped before signing on a producer/verifier stage-record format mismatch.
Controller6f6df7a3 fixes that parser and preserves executable permissions;
the real saved artifact was verified locally and its disposable extraction
removed. Retry35347141494 successfully signed and uploaded source-run35337960392's
saved device artifact without an App rebuild. Discovery35350326982 at
2026-09-18 13:27UTC confirmed191 PROCESSING. Discovery35351702764 subsequently
returned VALID. Preparation35351790012 saved and read back both test-note
languages and Floe QA. Verification35351900047 at13:43UTC confirmed VALID,
unexpired, exactly one private Floe QA group and IN_BETA_TESTING. Build191 is
available to internal testers. See
[delivery metadata](qualification/build191-release/testflight-delivery.json). Builds188–190 did not upload; their failures and recovery packages are
retained in their qualification records. No public Beta submission is included.


## Failed candidate: 1.7.0 (192)

Tag `v1.7.0-beta.49` is fixed at `1dc6577a9975519af292d2a871706a663f25026e`.
[Run 35400024357](https://github.com/JiangNanGenius/floe-agent/actions/runs/35400024357)
created the tag and stopped in the accepted-SDK App build: the
`FloeLocalModels/MLXTextEngine.swift` tokenizer call passed a task-isolated chat
input as a `consuming sending` parameter and the Swift 6 region pass rejected it
("sending 'input' risks causing data races"). No App artifact, signing or upload
occurred; the immutable tag is retained as the failed-freeze record and the
reserved build number 192 is retired.

## Preparing: 1.7.0 (193)

Build 193 constructs the chat input in the same region as the tokenizer transfer
and carries the rest of the build 192 freeze. The single accepted-SDK App build
and internal TestFlight upload are performed by the release workflow at the
frozen commit; Apple processing and Floe QA visibility are verified separately
before this build is called installable.

## Failed candidate: 1.7.0 (193)

Tag `v1.7.0-beta.50` is fixed at `e0b4c8cafb971c5b5ea8bd2bc0f35b6989ade80c`.
[Run 35402430509](https://github.com/JiangNanGenius/floe-agent/actions/runs/35402430509)
created the tag and stopped in the accepted-SDK App build after the build-192
region-isolation fix, with seven App-target errors that the earlier compile never
reached: two missing media-polling symbols in `BackgroundRunCoordinator`, a
non-exhaustive `ShellRunOutcome` switch in `FloeShellCommands`, an isolated
`Identifiable` conformance in `IDEWorkspaceTabs`, an optional `Bool?` permission
probe and two invalid `CocoaError` codes in `OfficeDocumentEditorView`. No App
artifact, signing or upload occurred; the immutable tag is retained as the
failed-freeze record and build number 193 is retired.

## Preparing: 1.7.0 (194)

Build 194 carries the build-191 feedback repair plus the compile fixes for the
two failed freezes (192: local-model tokenizer transfer region; 193: media
polling, shell outcome mapping, isolated conformance, Office permission probe and
error codes). The single accepted-SDK App build and internal TestFlight upload
are performed by the release workflow at the frozen commit; Apple processing and
Floe QA visibility are verified separately before this build is called
installable.

## Uploaded but unpublished: 1.7.0 (194)

Tag `v1.7.0-beta.51` is fixed at `b1e1bbdd81c9a04654c531fcaf95a12b74194b0f`.
[Run 35405286912](https://github.com/JiangNanGenius/floe-agent/actions/runs/35405286912)
completed the single accepted-SDK App compile, retained the unsigned IPA and its
matching private symbols before signing, and TestFlight accepted the upload. The
`lean-publish` job then failed on a release-workflow defect: the retained-artifact
verifier was invoked without the artifact zip or explicit extracted paths, which
it always rejects, so no attestation, GitHub prerelease or Feather publication
exists for this tag. The build was not prepared for the Floe QA group and is not
the deliverable; the immutable tag is retained as the uploaded-but-unpublished
record.

## Preparing: 1.7.0 (195)

Build 195 carries the same App source as build 194 plus the release-workflow
publish fix (artifact id resolved from GitHub's payload; the single verifier call
passes the artifact zip and extraction directory) and a regression test for the
step. The single accepted-SDK App build and internal TestFlight upload are
performed by the release workflow at the frozen commit; Apple processing and Floe
QA visibility are verified separately before this build is called installable.

## Uploaded but unpublished: 1.7.0 (195)

Tag `v1.7.0-beta.52` is fixed at `575211e9b820adec7fb38b480504a0adbd37d522`.
[Run 35408690013](https://github.com/JiangNanGenius/floe-agent/actions/runs/35408690013)
completed the single accepted-SDK App compile, retained the unsigned IPA and its
matching private symbols before signing, and TestFlight accepted the upload ("No
errors uploading archive"). The evidence-upload step then failed on a transient
GitHub incident (`Failed to CreateArtifact: Unable to make request: ENOTFOUND`),
so the publish gate could not verify the accepted upload and nothing was
attested or published. The build was not prepared for the Floe QA group and is
not the deliverable; the immutable tag is retained as the uploaded-but-unpublished
record.

## Preparing: 1.7.0 (196)

Build 196 carries identical App source to builds 194 and 195 with the fixed
release pipeline. The single accepted-SDK App build and internal TestFlight
upload are performed by the release workflow at the frozen commit; Apple
processing and Floe QA visibility are verified separately before this build is
called installable.

## Failed candidate: 1.7.0 (197)

Tag `v1.7.0-beta.54` is fixed at `f05b02acd8f98a2d3cadd9eda6e6408a5f44935f`.
[Run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884)
created the tag and stopped in the accepted-SDK App build's "Rebuild the exact tag
with the accepted App Store SDK" step (2026-09-19 06:52 UTC) with five diagnostics
and two distinct errors: `ExecutionEnvironmentView.swift:82/105/124/147` could not
find `RuntimeInventoryEntry` in scope (the defining `FloeExecution` module was not
imported), and `FileInspectorView.swift:132:24` conditionally bound the
already-unwrapped `previewPath` ("initializer for conditional binding must have
Optional type, not 'String'"). Every step after the compile was skipped: no App
artifact, signing or upload occurred, so build 197 / beta.54 was never uploaded.
The immutable tag is retained as the failed-freeze record and build number 197 is
retired.

## Preparing: 1.7.0 (188)

Build188 keeps the IDE service-owned CI recovery/polling work and repairs Notes
cover accessibility queries and bounded WebKit screenshot qualification. Cloud
validation and upload are pending; see the [preflight](qualification/build188-release/README.md).

## Blocked candidate: 1.7.0 (187)

Tag `v1.7.0-beta.44` is fixed at `d77aa11f7b4933b987faf5cf65ebc817d520e15e`.
[Run35312393708](https://github.com/JiangNanGenius/floe-agent/actions/runs/35312393708)
has failed the SDK27 Notes UI gate and the original component fixture. SDK27 App
regression passed204/204 including23IDE cases. A separately corrected component
run passed iPhone101/101 but failed one iPad mind-map WebKit timeout; it does not
qualify the original release. The narrow artifact-recovery controller was not
run. The exact-source device recovery archive is saved, unsigned; no TestFlight
upload is claimed. [Fixture/results](qualification/build187-release/notes-fixture-repair.md).

## Failed candidate: 1.7.0 (186)

Tag `v1.7.0-beta.43`, source `d421fea260523d063270e2d21d623bd011acd9ea`.
[Run 35306551280](https://github.com/JiangNanGenius/floe-agent/actions/runs/35306551280) finished with qualification failures; signing/upload were skipped. Accepted-SDK App regression passed 204/204, including all 23 IDE cases. Each Notes UI leg passed 3, failed 1 at the Office back-control identifier, and skipped the device-only native Office case. The component passed iPhone 84/84 and iPad 83/84 (one Excel Quick Look timeout with a working content summary). SDK 27 module tests rejected the non-namespaced back-navigation key.

The source-verified unsigned device recovery archive was preserved before UI qualification. It is not a signed IPA. [Result](qualification/build186-release/result.json), [recovery identity](qualification/build186-release/device-recovery.json), [real App screenshots](qualification/build186-release/app-ui/README.md). Build 178 remains the last historically confirmed internal delivery; live Apple availability has not been re-queried here.

## Previous candidate: 1.7.0 (185)

Tag `v1.7.0-beta.42`, source `42ecc4527fdbeb171dd0aed1d0776375770f1572`.
[Cloud run 35292395886](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886)
finished with UI qualification failures; signing and upload were skipped. Both SDK App regressions passed 204/204. Office covers and the unavailable-editor return path remain open. Durable IDE GitHub Actions jobs,
Lua environment limits and Office/CAD content covers are covered in the
[candidate record](RELEASE_1.7.0_BETA_42.md).

## Failed candidate: 1.7.0 (184)

Tag `v1.7.0-beta.41`, source `8e0cf69f6387333e768b90d56372e587eb297375`.
[Run 35287358993](https://github.com/JiangNanGenius/floe-agent/actions/runs/35287358993)
compiled the App on both SDK lines. Both App regression runs passed 203/204 tests,
with the same Lua environment-limit failure. An unsigned device recovery archive
was retained; UI gates, signing and upload were skipped.
[Original candidate record](RELEASE_1.7.0_BETA_41.md).

## Failed candidate: 1.7.0 (183)

Tagged `v1.7.0-beta.40`, source `0b7f7903c9fd851b9d9e278249766c39d5069cf1`.
[Run 35284117684](https://github.com/JiangNanGenius/floe-agent/actions/runs/35284117684)
failed App compilation on the CAD cover bridge's non-Sendable continuation value.
Dependency and module gates passed; packaging/upload did not start. See [candidate record](RELEASE_1.7.0_BETA_40.md).

## Failed candidate: 1.7.0 (182)

Tagged `v1.7.0-beta.39`, source `4f8cce1bbb42dbefbe59c3418c63043ae966896f`.
[Run 35248979573](https://github.com/JiangNanGenius/floe-agent/actions/runs/35248979573)
failed before packaging/upload: SDK 27 dependency resolution and accepted-SDK
IDE integration compilation. Module checks passed; App/UI gates did not. See [candidate record](RELEASE_1.7.0_BETA_39.md).

## Cancelled candidate: 1.7.0 (181)

Tagged `v1.7.0-beta.38`, source `69bb48df398afe520943356b061d2cff80139306`.
[Run 35247156362](https://github.com/JiangNanGenius/floe-agent/actions/runs/35247156362)
was cancelled before upload to correct stale recovery diagnostics and direct
association of a known GitHub run. See [candidate record](RELEASE_1.7.0_BETA_38.md).
Build 180 / `v1.7.0-beta.37`, source `5e7a609e8c289572679507cd52a49fd4a21efc9e`,
was cancelled in [run 35244918975](https://github.com/JiangNanGenius/floe-agent/actions/runs/35244918975)
after real-network checks found query URLs lost their domain. No signing or
upload occurred. Build 179 retained an unsigned artifact but never entered
upload after its accepted-SDK Notes gate timed out. Apple discovery returned
build 178 VALID; a new candidate is not an upload or availability claim.

## Current delivery: 1.7.0 (178)

**Available in the existing internal Floe QA group.** Apple `VALID`, unexpired, exactly one private internal group (`Floe QA`, feedback enabled, no public link) and `IN_BETA_TESTING` were verified at 2026-09-16 16:25 UTC by [run 35121747998](https://github.com/JiangNanGenius/floe-agent/actions/runs/35121747998). ASC build ID `6e8cd002-e620-438a-ad10-c87c2bf33f27`.

Source: `32acddd41f0f5735ac7f1cec2eb14feb1da28623` / `v1.7.0-beta.35` (build 178). [Release run 35106710878](https://github.com/JiangNanGenius/floe-agent/actions/runs/35106710878) rebuilt the immutable tag on the SDK 27 and the App Store accepted SDK, passed 178/178 focused App regressions plus iPad and iPhone Notes UI on both SDKs, then signed, validated and uploaded the same source. [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.35) carries the separately qualified unsigned IPA and evidence; the [Feather source](FEATHER_SOURCE.md) was republished with digest-verified provenance in [run 35120804344](https://github.com/JiangNanGenius/floe-agent/actions/runs/35120804344).

The same app source also passed complete CI [35083821490](https://github.com/JiangNanGenius/floe-agent/actions/runs/35083821490). Native Office remains device-only; RDP App integration, Qwen iPad acceptance, the full native npm/WASI/APT catalog, media-model acceptance and log-service deployment remain open. Physical-device checks belong to the user. No public App Store review or production release is part of this delivery.

## Previous delivery: 1.7.0 (172)

**Available in the existing internal Floe QA group.** Apple `VALID`, unexpired, one private internal group and `IN_BETA_TESTING` were verified at 2026-09-14 17:52:18 UTC. English and Simplified Chinese notes were written and read back. [Availability evidence](evidence/floe-1.7/release-172/TESTFLIGHT_AVAILABLE.json).

Source: `fb86fef896d41871fa98c8871237606f56c5ff39` / `v1.7.0-beta.29`. Direct packaging policy: `9c741b0`; [successful build/upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34870170373), [group/notes preparation](https://github.com/JiangNanGenius/floe-agent/actions/runs/34877274179), [availability verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34877319188).

SDK 27 source qualification passed 1,270 Swift executions, 159 full-App regressions and the Notes UI case on iPad and iPhone. The direct Xcode 26.6 / SDK 26.5 uploader built, validated and signed the same app source; simulator qualification was explicitly waived for this expedited delivery. Original accepted-SDK selector failure and earlier attempts remain recorded. Physical-device checks belong to the user. Full package/model capability delivery remains incomplete. Public/external TestFlight review and production App Store release are not part of this delivery.

[GitHub Beta 29](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.29) supplies a separately qualified SDK 27 unsigned IPA; [Feather instructions](FEATHER_SOURCE.md) describe that developer-signed installation route.

Main was fast-forwarded to the delivered integration. Task-owned merged branches were removed; the independent Office and occupied shell branches remain. [Branch cleanup](evidence/floe-1.7/release-172/branch-cleanup.json). The public [Feather feed check](evidence/floe-1.7/release-172/feather-published.json) returned HTTP 200 for the source, icon and IPA.

## September 15 repair candidates — superseded by build 178

Builds 173–177 / tags beta.30–beta.34 did not complete upload; each stopped at a
real qualification finding rather than bypassing it. Their original results and
immutable tags remain. Build 178 above delivers the repair series: dedicated
Notes assistant isolation and live refresh, Soul/profile next-request
activation, full-screen IDE with conflict-aware saving, DXF/DWG editing and AI
review, and the loaded-runner UI qualification repairs.

Build 175 / `v1.7.0-beta.32` / `8958d8f1482c3236f73172076b76adc83da86f5f`
passed 172/172 App regressions and its iPhone Notes case. The iPad case exceeded
its 180-second allowance. The release was cancelled before upload to include
the owner's additional document-assistant requirements. The accepted-SDK device
artifact `10388835194` remains in [run 34945701373](https://github.com/JiangNanGenius/floe-agent/actions/runs/34945701373).
[Original results](evidence/floe-1.7/build172-repair/app-build175.json).

Build 174 / `v1.7.0-beta.31` / `aa8e42708157a54aa9cbc083a484c00a882a10b3`
was deliberately stopped before upload after the real Agent demonstration exposed
empty continuation IDs overwriting a valid tool identity. Its accepted-SDK device
build was preserved as `accepted-sdk-device-recovery-1.7.0-build174`, artifact
`10386910401`, in [run 34941785251](https://github.com/JiangNanGenius/floe-agent/actions/runs/34941785251).
This is a recovery artifact, not a delivered TestFlight build. The tag remains immutable.

Build 173 / `v1.7.0-beta.30` / `316251adcba91c94bd96ab9accf9cba72da59f95`
was not uploaded. Its SDK 27 localization suite rejected the bare key
`Floe 助手与思维导图`; the accepted-SDK build was then cancelled to avoid
finishing an obsolete candidate. Build 174 gives the same bilingual label the
namespaced key `notes.office.assistantAndMindMaps`, with no weakened assertion.
The original [failed run](https://github.com/JiangNanGenius/floe-agent/actions/runs/34939310493)
and immutable tag remain available. Local checks passed all 903 bilingual keys
and six release version/test-host contracts; final cloud validation is separate.

## Earlier checkpoints (historical states)


## Build 172 direct-upload candidate

The user requested a new TestFlight build for personal device testing and waived iPad/iPhone simulator qualification as an upload gate. [Direct build and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34870170373) uses immutable tag `v1.7.0-beta.29`, source `fb86fef896d41871fa98c8871237606f56c5ff39`. It retains the unsigned device artifact before signing and still requires bundle/profile validation and Apple's upload validation. Availability below stays at build 156 until actual Apple processing and Floe QA visibility are verified.

The same build 172 source separately passed 1,270 Swift test executions and 159 SDK 27 App regressions. Its original SDK 26 device and simulator builds passed, but a duplicate simulator-name selection error stopped tests before execution and prevented that workflow from retaining the device package. These outcomes remain distinct from the direct uploader.

Build 172 upload succeeded at 2026-09-14 17:25:50 UTC. Apple initially reported `PROCESSING`; [upload receipt](evidence/floe-1.7/release-172/testflight-upload.json). This is not yet an installability claim.

## Feedback repair — uploaded, processing pending

The `codex/floe-156-feedback-repair` branch contains the September 14 fixes and subsequent content-search/workspace-import additions. Build 156 below is still the last verified delivery. New source builds, component tests and screenshots do not establish a new TestFlight release. Current gates and evidence are tracked in [the feedback repair record](FLOE_156_FEEDBACK_REPAIR.md); physical-device checks remain with the user.

## Internal delivery — 2026-09-14 (Australia/Sydney)

**Available: 1.7.0 (156), internal Floe QA TestFlight.** Apple `VALID`, unexpired, exactly one existing private internal group, and `IN_BETA_TESTING` were confirmed at 2026-09-13 15:15:02 UTC. English and Simplified Chinese beta notes were written and read back. [Availability evidence](evidence/floe-1.7/release-156/TESTFLIGHT_AVAILABLE.json).

- App source: `65969b8f04e67269a92b899a55620ff469d96322`, immutable tag `v1.7.0-beta.13`.
- Distribution policy: `52312222565c7cec7b8036dc2bb4ed6da077b6a9`; actual Xcode 26.6 (17F113), SDK 26.5.
- [Upload 34762764702](https://github.com/JiangNanGenius/floe-agent/actions/runs/34762764702), [notes/group 34764956759](https://github.com/JiangNanGenius/floe-agent/actions/runs/34764956759), [availability 34765022410](https://github.com/JiangNanGenius/floe-agent/actions/runs/34765022410).
- Build ID: `a75a56dc-6e83-4616-9739-966b72dbccd3`; signed IPA SHA-256: `5cd7ed2a7d98347bed15d9c2b363faad9092d088253ef841fc1ba2e3338180ff`.

SDK 27 source qualification passed 1244 Swift executions and 135 App regressions. The same source also passed the accepted-SDK build and 135 App regressions. Distribution recovery retained those exact-source tests and binaries, verified their provenance and changed only reviewed bundle packaging before signing. All 148 executable files remained unchanged before resigning; 16 packaging/guard tests passed. The beta-group reader additionally passed four targeted tests and actual API readback. [Recovery history](evidence/floe-1.7/release-156/distribution-recovery.md) retains the initial pnpm/libssh2 validation failure and subsequent dash processing failure.

This is an internal beta, not completion of every item in the 1.7 plan. Physical iPad/iPhone checks belong to the user after installation. Full package/model delivery and long-media/device acceptance remain open. No production App Store or public GitHub release was published.

Build 155 was cancelled during dependency preparation after a local reproduction found its test expected data depended on the mutable working lock. Build 156 reads the committed test expectation. All eight tests, pin checking and license generation pass for the combined lock, actual cloud host lock and its legacy serialization (24 test executions, byte-identical inventories). No upload occurred for 155.

Build 156 now supersedes the earlier build 152 source qualification: both SDK paths passed their App gates. The latest Notes component screenshots and SDK 27/26 iPad/iPhone evidence are from [`4550b6d`](https://github.com/JiangNanGenius/floe-agent/actions/runs/34742130370); component qualification is distinct from full-App and physical-device acceptance. Final TestFlight text and checks are tracked in [the release description](RELEASE_NOTES_1.7.0.md).

Apple processing, beta notes, the existing internal Floe QA group and `IN_BETA_TESTING` have now been verified for build 156. Physical-device checks belong to the user after installation. After verified delivery, the integration was fast-forwarded into `main` and pushed. Four fully merged local/remote branches were removed; the two branches with independent work and the occupied shell qualification worktree were preserved. See [cleanup evidence](evidence/floe-1.7/release-156/branch-cleanup.json). No public App Store release is included.

## Build 154 — beta.11

Build 153 / `1ae0364` / run `34751318198` failed the early generated-project check because the checked-in Xcode project retained build 152. Build 154 regenerates the project to match all four version declarations. No application upload occurred for 153.

## Build 153 — beta.10

Candidate 153 fixes release tooling after build 152 passed 1244 Swift test executions, the SDK 27 simulator Release build and 135 App regressions. Run [34748849626](https://github.com/JiangNanGenius/floe-agent/actions/runs/34748849626) then failed in lock-file parsing during license inventory generation; no upload occurred. The new parser supports SwiftPM v1/v2/v3 and checks normalized pins against the committed lock. Five parser regressions pass. Existing candidate tags remain immutable.

## Earlier candidates

This is an internal beta candidate, not completion of the full 1.7 upgrade plan.

- Immutable source: `d587a0e7eef1f4bb831e42e7a28d452d41eba79b`.
- Tag: `v1.7.0-beta.1`; local tag/version/extension/build preflight passed.
- Cloud archive/upload workflow: [34707145277](https://github.com/JiangNanGenius/floe-agent/actions/runs/34707145277).
- Audience to verify after Apple processing: existing internal **Floe QA** group.
- Build 144 candidate was cancelled before upload: full-App CI 34706721636 found a missing `await` in the actor-isolated font import adapter. Build 145 / beta.2 includes the fix; cloud verification remains required. No uploaded build or TestFlight visibility is claimed yet.
- Beta tags do not automatically publish a public GitHub release. No production App Store release is requested.

## Included changes

- Workspace-owned environment creation, settings inventory and measured storage; session/project ownership, rebuild checks, CAS durability, template copies and journaled package promotion.
- Persistent Node worker host with cwd/environment/stdin routing, output bounds, timeout and cancellation; pinned runtime and npm/pnpm/yarn inputs.
- Real basic video/audio processing; workspace video workbench with trim, crop, rotation, speed and manual timed subtitles through pinned MIT VideoEditorKit. Edit parameters persist; exported files are reopened and checked.
- Lower-left sidebar contains the settings button without the account label/avatar.
- Bilingual introduction and user guides include retained, clearly labelled development screenshots.

## Recorded qualification

- 42 focused host tests: 15 environment, 16 package, 9 media, 1 job persistence and 1 signed Skill catalog.
- 9 native iOS Simulator Node bridge cases plus 4 Swift adapter checks; 4 host Node tests.
- Native editor model save/reopen and output smoke; Chinese caption export verified before/during/after its interval with pixel evidence.
- Repeat promotion of the same package tested separately after the 42-test checkpoint.

These do not replace the full application tests or physical-device checks.

## Still open

- All 15 model capability classes need actual runners/weights and per-device output, latency and memory qualification; 33 candidate reviews are not runnable-model evidence.
- Official package-pool production versions, complete dependency promotion/rollback/concurrent installation and recovery UI remain incomplete.
- Shared Agent/workbench task queue, chat-attachment handoff, full environment dependency migration/rebuild and complete long-media/background/device acceptance remain incomplete.
- Source qualification, signed distribution, Apple processing and internal availability have passed; physical-device acceptance remains with the user.

See [implementation status](FLOE_1_7_IMPLEMENTATION_STATUS.md), [compatibility matrix](FLOE_1_7_QUALIFICATION_MATRIX.md), [migration and recovery](FLOE_1_7_MIGRATION.md), and [screenshots](evidence/floe-1.7/SCREENSHOTS.md).

Build 145 / beta.2 was also cancelled before upload after expanded native shell
qualification reproduced unsafe cancellation of an infinite loop. Build 146 /
beta.3 uses cooperative interpreter-thread cancellation. Nine commands plus
interactive input/close pass in both Debug and Release minimal native Apps,
including worker termination, unknown command, three-stage pipe, timeout and
execution after cancel. Full application qualification remains separate.

Build 146 / beta.3 was cancelled before upload to complete the exposed audio
editing and frame-utility paths. The next candidate adds bounded audio editing,
real per-input mix gains, verified PNG/JPEG batches, aspect-preserving proxies,
source-preserving thumbnails and accepted-SDK directory-iteration compatibility.
No previous candidate has reached TestFlight upload.

## Build 147 / beta.4 candidate

Includes the audio/frame fixes plus General appearance selection, project/session
container and package management, refined reasoning/tool frames and persistent
batch folding. Forty-nine module tests and two native component UI tests pass;
[interface evidence](evidence/floe-1.7/interface/README.md) records the fixture
boundary. Final native component compilation also passes after adding conversation
titles to container rows. Full-App cloud builds and Apple processing remain pending.
Production apt provisioning, the complete model capability matrix and physical
device acceptance remain open; this is an internal beta, not full-plan acceptance.

- Fixed source: `2cd030c2121ef48214da312ad310c74ae1c72324`.
- Immutable tag: `v1.7.0-beta.4`; tag/version/build preflight passed.
- Cloud run: [34711460906](https://github.com/JiangNanGenius/floe-agent/actions/runs/34711460906).
- Cancelled before upload after the Swift regression stage stopped producing
  output for approximately 14 minutes. Complete logs reveal an SVG inspection
  approval regression and an execution-test stall; no App build or upload passed.
  The SVG inspection exemption is restored in the next source revision, while
  the execution stall requires reproduction and qualification before another tag.

## Build 148 / beta.5 candidate

Restores the existing read-only SVG inspection approval rule that was lost during
tool consolidation. Focused host tests pass: 83 security-policy tests and 147
execution tests, with the two JavaScript deadline suites kept separate as in the
release workflow. The temporary test harness links production sources and the
PDF fixtures; these results do not replace the complete cloud suite.

The cloud stall has not reproduced in this focused run. Release tests now retain
their complete output, sample owned Swift test processes after 90 seconds without
test output, and fail after 180 seconds without output or the overall deadline.
The wrapper preserves test exit codes and terminates its own process group on a
deadline. Three subprocess checks cover output/exit propagation, timeout and
child cleanup. No tests are skipped beyond the pre-existing isolated JavaScript
suites, which still run separately. Fresh cloud verification remains required.

## Build 149 / beta.6 preparation

Includes independent Notes, dynamic illustrated maps and PDF windows, Office and Whisper integration, and confirmed permanent deletion with shared-resource protection. SDK 27/26 iPad/iPhone native qualification passed at `4550b6d` in run `34742130370`; subsequent lifecycle code passed 15 host tests and native component compilation. The release workflow must verify the final tagged source before signed upload. Physical-device acceptance follows TestFlight installation and is performed by the user.

The package/model qualification matrix remains explicit; unbuilt resources are not offered as installed capabilities. Upload, Apple processing and tester availability are pending until verified.

## Build 150 / beta.7 preparation

Build 149 failed its automated Swift gate and was not uploaded. Cloud sampling confirmed cooperative workers blocked while draining WASM output; its network timeout also failed under contention. Build 150 separates blocking WASM/DNS work from Swift task scheduling, tests task cancellation, parallel commands and lookup deadlines, and updates the explicit Canvas tool-set assertion for the four scoped Notes tools.

All release gates remain required. The next fixed candidate is `v1.7.0-beta.7`; upload and Apple processing are still pending. Device testing follows internal TestFlight availability and belongs to the user.

## Build 151 / beta.8 preparation

Build 150 completed the full concurrent Swift run without the earlier WASM stall. Only `FloeCoreTests` failed, because 21 appearance/environment catalog keys lacked the required namespace. The next candidate renames those keys and their UI references, preserves English and Chinese translations, and explicitly localizes the dynamic hold/unhold label. The original completeness rules remain intact. No TestFlight upload occurred for 150.

## Build 152 / beta.9 preparation

151 passed 1,244 Swift test executions, the SDK 27 simulator Release build, and all 135 App regressions (zero failures/skips). It then stopped on a scanner false positive: the public OpenAI tokenizer commit identifier in the Whisper manifest. The exact historical fingerprint is documented; the unused metadata label is renamed `textAssetsRevision`, preserving all download URLs, hashes, model identity and runtime-decoded fields.

The source-history scan now runs before expensive tests/builds, and App regression bundles are retained even if a later release step fails. All verification requirements remain. No 151 upload took place; 152 is the next candidate.
