# Floe 1.7.0 / Build 186 / beta.43 candidate

Status: **final: qualification failed; no upload; not signed, not installable.**

Tag `v1.7.0-beta.43` was created and pushed on 2026-09-18 and resolves to the
immutable source `d421fea260523d063270e2d21d623bd011acd9ea`. Release run
[35306551280](https://github.com/JiangNanGenius/floe-agent/actions/runs/35306551280)
started at 2026-09-18 04:19:57 UTC; `prepare-release` passed, then the NativeNotes
development component, the SDK 27 build/verify job and the accepted-SDK job ran in
parallel under the frozen SHA. The run finished as a failure on 2026-09-18; the
upload job was skipped, and the expedited/direct/recovery TestFlight entries were
not selected. No upload, Apple processing or installability exists for this build.

## Final gate results

| Gate | Final result |
| --- | --- |
| SDK 27 build/verify (`build-verify-release`) | **Failed** in "Run Swift tests when exact-source CI cannot be reused": FloeCore `LocalizationCompletenessTests.Keys follow the dotted-namespacing convention` found the bare key `返回手记` (`LocalizationCompletenessTests.swift:91`). The SDK 27 line compiled and the module tests ran; this was a localization-completeness assertion failure, not a compile failure. |
| NativeNotes development component | **Failed**: iPad 83/84 (one strict Excel Quick Look case failed at its 45.679 s request deadline while the same render returned a real labelled content summary); iPhone 84/84 passed. Both device xcresults and logs are retained. |
| Accepted-SDK App | Focused app regression **204/204 passed, including all 23 IDE cases**. The Notes UI legs failed on **both** devices: 5 executed, 3 passed, 1 failed, 1 skipped (the device-only native Office case). Failure was `NotesWorkspaceImportUITests.swift:294` (`openedDocumentBackControl`): no `notes.back`/`office.editor.back` matched within 45 s. The retained accessibility hierarchy shows the real back button existed, but its identifier had been overwritten by the parent `notes.office.header` identifier — an accessibility-identifier collision, not a missing navigation control. |

Because the gates failed, the upload job did not run: build 186 is not on
TestFlight and no beta-testing availability is claimed.

## Retained recovery and evidence

- [Device recovery record](qualification/build186-release/device-recovery.json):
  unsigned recoverable device build, artifact 10532236731, 811474118 bytes, sha256
  `903e4be627b78781cbbeb92ccfef315d308404f5637fc2f8a3d8550e944ae93f`, bundle
  identifiers and 1.7.0 (186) versions verified against the source SHA. This is
  **not a signed IPA** and was not uploaded.
- [Accepted-SDK regression summary](qualification/build186-release/accepted-app-regression.json):
  204/204 including `IDEGitHubActionsTests` 23, with the machine-readable
  [run result](qualification/build186-release/result.json) (conclusion failure,
  `uploaded: false`).
- [App UI covers](qualification/build186-release/app-ui/README.md): real Word,
  Excel and PowerPoint card content on both simulator families, plus the renamed
  Word revision 2; the release owner visually verified the unmodified exports. The
  cover cold-relaunch phase was **not reached** after the back-control failure, so
  no cold-relaunch result exists for build 186.
- [Preflight record](qualification/build186-release/preflight.json) and
  [Office previews](NOTES_OFFICE_PREVIEWS.md).
- Full logs, raw xcresults and the failure accessibility hierarchy remain under
  `Local/Artifacts/build186-release` and `Local/Private/build186-release`
  (internal, intentionally not linked from public docs).

## Candidate changes as tagged

- Office summary reads the same extension-carrying staged resource as Quick Look.
- The unavailable native Office editor retains Notes navigation.
- Shared Office resource operations begin before queueing/staging. Timeout does
  not restart an outstanding system request; late callbacks settle at most once.
- RTF unsupported-format fixture creates its scratch directory before writing.
- Scanned OCR fixtures use the same original pixels on both devices. The single
  functional OCR/search case uses the existing 180-second ceiling and records
  elapsed time, after correct output arrived at 138 seconds beyond the earlier
  120-second effective allowance. This is not a product performance-fix claim.
- The six Office cover sample tests (`b06b3082`) import each generated sample
  through `NoteFileImporter` → `NotesStore` CAS and render through the real
  `NotesDocumentCoverService`. This run was their first live execution: all passed
  on iPhone; on iPad the strict Excel sample failed at 45.679 s by requiring
  `.quickLookThumbnail` although a real `.officeContentSummary` was returned. That
  strict assertion now lives in the separate build 187 diagnostics (see the
  [acceptance policy](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md)).
- Component qualification attempts both device families and preserves failures.
- App-owned GitHub build persistence and foreground recovery remain included;
  see [IDE cloud builds](IDE_GITHUB_ACTIONS.md).

App and all versioned extension targets were configured for 1.7.0 (186), the
checked-in Xcode project was regenerated, and metadata checks passed. Passing
metadata never substituted for the gates above.

## Fixes made after the failed run (not in the 186 binaries)

- `0d11957e03f278fb2ed508d8fb89629e30340d19` namespaced the bare `返回手记` key to
  `notes.navigation.backToNotes` and added the standard-library-only preflight
  [`validate_localization_catalog.py`](../FloeAgent/scripts/validate_localization_catalog.py),
  called by [`release_preflight.sh`](../FloeAgent/scripts/release_preflight.sh) and
  CI before any build, so a non-namespaced or incomplete bilingual entry fails
  before a full compile instead of in module tests.
- The Office header identifier collision (`.accessibilityElement(children: .contain)`
  on the `notes.office.header` container) was committed as
  `3dc4a2f81ac4b67800b70fd57f8f350debea66c9` after the failed run. It has not been
  built, run or qualified by build 186, and no 187 qualification has executed it.
- The progressive two-tier Office cover source is also a working-tree change; see
  [beta.44 preparation](RELEASE_1.7.0_BETA_44.md) and
  [Office previews](NOTES_OFFICE_PREVIEWS.md). It has no runtime evidence yet.

## Next gates

- [Build 187 / beta.44 preparation](RELEASE_1.7.0_BETA_44.md) is versioned but
  untagged, unrun and unuploaded.
- Historical failures remain preserved: build 185 / beta.42 failed Notes UI
  qualification with both SDK App regressions at 204/204
  ([run 35292395886](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886));
  build 184 failed each App regression at 203/204 on a Lua install/run failure.
- Physical iPad local-model and native Office/Pencil acceptance remain user-owned;
  RDP is not declared a usable App feature.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_186.md) remain as prepared;
they were never uploaded.

## 简体中文摘要

Build 186 / beta.43 **最终失败，未上传、不可安装**。三项并行验收结果：SDK 27
模块测试因本地化键 `返回手记` 未命名空间而失败；NativeNotes 组件 iPad 83/84
（单条 Excel 严格 Quick Look 用例 45.679 秒超时，但真实内容摘要已返回），
iPhone 84/84；accepted SDK 的 App 回归 204/204（含 23 条 IDE 用例）通过，但两端
手记 UI 腿均 3 通过、1 失败、1 跳过，失败是返回按钮的辅助功能标识被父级
`notes.office.header` 覆盖（真实按钮存在，并非导航缺失）。失败后未进入上传。
未签名真机恢复包与源校验、App 封面截图均已留存；封面冷启动阶段未执行。运行后的修复
（本地化键命名空间与纯 Python 预检 `0d11957e`、返回标识符容器修复、渐进封面源码）
均未进入 186 二进制，也尚无 187 运行时证据。
