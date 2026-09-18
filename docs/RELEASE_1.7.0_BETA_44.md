# Floe 1.7.0 / Build 187 / beta.44 qualification

Status: **tagged and qualifying in cloud CI; no upload or installability claim.**

Tag `v1.7.0-beta.44` resolves to source `d77aa11f7b4933b987faf5cf65ebc817d520e15e`. [Release run 35312393708](https://github.com/JiangNanGenius/floe-agent/actions/runs/35312393708) started on 2026-09-18 at 05:50:30 UTC. Source preparation passed; the Notes development component and both SDK App build/verification jobs run in parallel. All three must pass before signing and upload. No expedited gate was selected.

Version metadata was set by `2438fddd`. Product fixes are in `1a52dd31` and `3dc4a2f8`; the tag also contains the candidate documentation. [Local preflight evidence](qualification/build187-release/preflight.json) records 428 script cases (427 passed, one existing platform skip), six focused Swift semantic/object checks, localization and workflow validation. This is not runtime or device acceptance.

## Implemented candidate changes

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
   `3dc4a2f81ac4b67800b70fd57f8f350debea66c9`; focused semantic/object checks passed, while full-App runtime acceptance is pending.
4. **Localization preflight.** `0d11957e03f278fb2ed508d8fb89629e30340d19` namespaces
   the bare `返回手记` key and adds a pure-Python catalog check
   ([`validate_localization_catalog.py`](../FloeAgent/scripts/validate_localization_catalog.py))
   that runs before builds instead of failing in module tests.

## Pending acceptance (not observed)

The cloud run is active. App and component runtime results, full-App UI evidence, signing and upload remain pending. Build186 evidence stays attributed to build186 and must not be relabelled as187 evidence. A source tag or version number does not establish TestFlight availability.

## Historical context

- Build 186 / beta.43: failed; no upload ([final record](RELEASE_1.7.0_BETA_43.md)).
- Build 185 / beta.42: failed Notes UI qualification; both SDK App regressions
  204/204; no upload
  ([run 35292395886](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886)).
- Build 184: each App regression 203/204 (Lua install/run); unsigned device
  recovery retained.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_187.md) and the
[TestFlight text draft](TESTFLIGHT_1.7_WHATS_NEW_BUILD_187.json) accompany the current run; they are not yet published release text.

## 简体中文摘要

Build 187 / beta.44 已固定为 `d77aa11f7b4933b987faf5cf65ebc817d520e15e`，run35312393708 于 2026-09-18 05:50:30 UTC 启动云端验收。候选包含渐进 Office 封面、准确的摘要与系统预览来源标识、返回按钮标识修复、本地化预检，以及 App 自主管理的 GitHub CI 恢复与前台轮询。三个验收作业全部通过后才签名上传；目前不宣称上传或可安装。
