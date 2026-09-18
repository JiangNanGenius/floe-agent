# Floe 1.7.0 / Build 187 / beta.44 preparation

Status: **preparation only: no tag, no release workflow run, no upload, not installable.**

Source `2438fdddc9a613a94d938c62148f9ca90bc440be` set the app and all versioned
extension targets to 1.7.0 (187) and regenerated the checked-in Xcode project
(`FloeAgent/project.yml`, `FloeAgent/FloeAgent.xcodeproj/project.pbxproj`). No
`v1.7.0-beta.44` tag exists, no release workflow has been dispatched for build 187,
and no TestFlight upload, Apple processing or installability is claimed. Build 186
remains the latest attempted release and it [failed](RELEASE_1.7.0_BETA_43.md).

## Implemented candidate changes (not tagged)

1. **Progressive two-tier Office covers.** For modern docx/xlsx/pptx within 48 MiB,
   the cover service publishes a visible, labelled native content summary as the
   first paint, then runs the unchanged bounded Quick Look request on a fresh
   staged copy; Quick Look success upgrades the card, while failure, timeout or a
   generic icon or later staging failure keeps the explicitly labelled summary. Legacy/binary/OpenDocument
   formats and modern OOXML above 48 MiB keep the original Quick Look-first path.
   The summary is bounded (≤240 fields, Excel first sheet only) and is not an
   original-layout render. The source is committed as `1a52dd31cbb5a1b293b525b25124cb12519bb623` and
   has local type-check/object/fixture results only; see
   [Office previews](NOTES_OFFICE_PREVIEWS.md).
2. **Acceptance-policy change.** Functional Office cover acceptance is now "real
   content: system Quick Look content **or** an explicitly labelled content summary
   proven by independent fixture assertions", with displayed icons, missing images and
   `unsupported` rejected. Summary content assertions do not prove Quick Look
   semantic or layout fidelity. The seven strict Quick Look-only cases run as a separate,
   non-gating diagnostic step; only a complete 7/7 run whose failures all carry the
   fixed Quick-Look-unavailable markers is non-gating. Missing, partial, skipped,
   crashed or unmarked results still block. This is a deliberate policy change,
   recorded in [thumbnail acceptance](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md); it is
   not a claim the previous tests always behaved this way.
3. **Office header accessibility identifier fix.** The `notes.office.header`
   identifier now stays on a real accessibility container so child controls keep
   their own identifiers (`notes.back`); build 186 failed exactly on that
   identifier collision (`NotesWorkspaceImportUITests.swift:294`). Committed as
   `3dc4a2f81ac4b67800b70fd57f8f350debea66c9`; it has not been built or run.
4. **Localization preflight.** `0d11957e03f278fb2ed508d8fb89629e30340d19` namespaces
   the bare `返回手记` key and adds a pure-Python catalog check
   ([`validate_localization_catalog.py`](../FloeAgent/scripts/validate_localization_catalog.py))
   that runs before builds instead of failing in module tests.

## Pending acceptance (not observed)

No 187 App build, component run, Full-App UI run, CI run, tag, signing or upload has
been executed. Local preparation checks are recorded in [preflight evidence](qualification/build187-release/preflight.json); runtime and delivery gates remain pending.
Build 186 evidence is retained and must not be relabelled as 187 evidence. The 187
version metadata alone does not constitute qualification.

## Historical context

- Build 186 / beta.43: failed; no upload ([final record](RELEASE_1.7.0_BETA_43.md)).
- Build 185 / beta.42: failed Notes UI qualification; both SDK App regressions
  204/204; no upload
  ([run 35292395886](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886)).
- Build 184: each App regression 203/204 (Lua install/run); unsigned device
  recovery retained.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_187.md) and the
[TestFlight text draft](TESTFLIGHT_1.7_WHATS_NEW_BUILD_187.json) are prepared for a
future run; they are not published release text.

## 简体中文摘要

Build 187 / beta.44 **仅准备**：版号已由 `2438fddd` 设为 1.7.0 (187)，但**没有
beta.44 标签、没有新的发布 CI、没有上传**，不可安装。已提交的候选变更包括：现代
OOXML 渐进封面（先显示带 Summary 标注的真实摘要，再升级系统 Quick Look；老格式与
超过 48 MiB 的文件路径不变）、功能验收口径改为“真实内容（Quick Look 或明确标注
摘要）+ 独立内容断言”，7 条严格 Quick Look 用例移入独立非阻断诊断且只有完整执行、
失败均为固定标记时才可能非阻断；返回按钮标识符容器修复；本地化纯 Python 预检。
以上均无 187 运行时证据，本地定向检查已留证，云端运行及分发结果仍待验证。
