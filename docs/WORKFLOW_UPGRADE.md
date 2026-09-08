# Editing and workflow upgrade / 编辑与工作流升级

Status: in development on `codex/office-workflow-upgrade`, based on Floe Agent 1.5.0 (131). This is not a release announcement. 更新范围覆盖完整编辑能力、插件与文件管理、画布和任务反馈；尚未完成全部验收。

[English guide](USER_GUIDE.md) · [中文使用指南](USER_GUIDE.zh-CN.md) · [Architecture](ARCHITECTURE_OVERVIEW.md)

## Scope and implementation status / 更新范围

| Area | Implemented in this branch | Still required |
| --- | --- | --- |
| Office: Word, Excel, PowerPoint | Existing local creation/basic editing; content digest, stale-write rejection, staged save and reopened-field verification | Qualified offline engine, full formatting/layout/backgrounds, charts, embedded attachments, formula recalculation, object positioning, masters and advanced presentation editing; cross-client round trips |
| PDF, separate tool group | Inline reader, shared fullscreen reading session, changed-file reload, password/error handling; corrected JavaScript package loading for forms | Complete editing matrix, large files, real-device fullscreen/reading-position verification |
| Plugin marketplace | Discover/Installed; official installation, persistent uninstall/reinstall, enablement, import and connector entries; version/update controls; verified catalog and expanded-permission review | Broader catalog coverage and live installation/update connectivity matrix |
| Task navigation | Initial bottom positioning, live follow while at bottom, explicit historical-run selection retained | Long-history, search, keyboard and device lifecycle matrix |
| Batch task management | Long-press a task → Select Multiple; initial task selected; filter/select all/archive/delete/restore; per-item errors | Large running batches and remote cleanup recovery on devices |
| Workspace lifecycle | Transactional durable cleanup intent, startup retry, visible retry, shared projects preserved | Offline remote cleanup scenarios and legacy unknown-orphan review |
| All workspaces | Active/archived private and project workspaces; isolated browsing and remote connection registry; existing search/edit/move/export/batch deletion; bounded remote previews | Cross-workspace aggregate file search, space accounting, full remote reconnect validation |
| Canvas editing | Generation task first in creation menus; existing SVG/HTML/Markdown node refinement with bounded source and revision checks; single undo and visible save errors | Real-model repeated editing, partial selections, final layout fidelity |
| iPhone canvas | Compact navigation, viewport-based creation, size-change centering, compact actions, scrollable touch controls and bounded panels; opening a canvas independent of image-model setup | Further landscape overlay spacing, full keyboard and physical-device interaction matrix |
| Live state | Snapshot revision race/coalescing fixes, visible conversation/canvas reconciliation, protection of interactive canvas drafts | Long-running concurrent tasks, reconnect and background/foreground device matrix |
| Picture in Picture | Stage, elapsed time, last activity; reported token speed or explicitly labeled character speed while streaming; fixed percentage removed | Physical-device long-tool, disconnect, multi-task and audio/PiP checks |
| Motion and composer | Stable insertion-only text block animation, subtle tool transitions, reduced-motion support, consistent microphone/send/stop controls | Dynamic Type, VoiceOver, keyboard, high-volume streaming and device polish |
| Tool foundation | Stata `clear` reset semantics, installed versus loaded schemas distinguished, exact tool calls do not require reading an official guide | Full compatibility matrix for public/third-party skills and older tool clients |

## Editing acceptance criteria / 编辑验收标准

Word, Excel and PowerPoint remain together in Office. PDF remains separate. The minimum bar is correct content, formatting and object placement, with deterministic save/reopen behavior; visual polish is secondary. Every supported operation needs model and manual execution coverage, undo where applicable, and durable save/reopen checks. Unchanged content must survive edits. Unsupported operations must be reported explicitly.

Office qualification includes styles, font sizes, paragraph/cell/shape formatting, page/slide backgrounds, charts and data, real embedded attachments, formula recalculation, slide creation and editing, layout/master behavior, precise object geometry, and preservation of unrelated package parts. Use Microsoft Office reopening, structural assertions and rendered comparisons; inspect attachment hashes and chart data. Test concurrent edits, cancellation, restart and insufficient disk space. A successful file write alone is insufficient.

Authorized third-party skills must use the same reliable tool contracts. Correctness and access rules belong to tool/runtime contracts, not only official Skill prose.

## Reuse and engine qualification / 复用与引擎验证

The candidate is [Collabora Office for iOS](https://github.com/CollaboraOnline/online.mirror/tree/27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc/ios), pinned in [engine.lock.json](../FloeAgent/ThirdParty/Collabora/engine.lock.json). The [qualification workflow](../.github/workflows/office-engine-qualification.yml) runs separately from app release workflows. Native build, embedded editor, licensing/resources, physical-device operation and file round trips are separate gates. Full advanced editing is not enabled or advertised as complete by the current basic OpenXML editor.

PDF reuses PDFKit and the existing pdf-lib tool path. File browsing, import/export, task lifecycle, model configuration and signed Skill installation reuse the existing app services. A required paid service or always-online Office server is not the intended baseline.

## Verification evidence / 验证记录

- Source `535902c`: [full CI passed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34210137026), with 999 SwiftPM test executions, 111 app regression tests, Linux build and the App Store SDK compatibility build. This evidence applies to that source revision.
- Source `0f2c7ec`: [full CI passed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34213618033), including the later cleanup, plugin lifecycle and contextual selection changes. Subsequent iPhone and documentation edits still need their own validation.
- Latest local checks: 32 app regression tests across canvas contracts, touch geometry and plugin lifecycle passed; iPhone portrait/landscape canvas and iPad PDF round-trip navigation UI tests passed. The new local-only CloudKit SwiftPM test could not run locally because the Metal compiler is missing; cloud CI installs that toolchain.
- Subsequent focused checks: durable cleanup/ownership, independent network registries, plugin uninstall/reinstall, long-press batch selection, workspace-manager navigation and canvas contracts. Latest source requires its own CI result.
- iPad simulator screenshots below use test data. iPhone portrait/landscape creation and editing also passed the focused UI test; captures were visually inspected. Physical-device verification remains open.
- [Current Office qualification run](https://github.com/JiangNanGenius/floe-agent/actions/runs/34212234638): ongoing at the time of this update; no native embedding or advanced editing pass is claimed.

## Screenshots / 操作截图

Screenshots record the tested interaction state, not a promise that every row above is complete. Capture portrait/landscape canvas creation and editing, contextual task selection, Discover/Installed, all-workspace browsing and inline/fullscreen PDF reading. Keep test data in public screenshots; retain detailed failures and logs in local implementation evidence.

### iPad: plugins and task selection

These simulator captures show Discover after a successful signed online catalog check, with a version-only update action, then the task-selection sheet opened from a long-press menu. Only test tasks are shown.

<img src="images/workflow-upgrade/plugins-ipad.png" width="340" alt="iPad plugin Discover page with versions and an available PDF update">
<img src="images/workflow-upgrade/task-selection-ipad.png" width="340" alt="Task selection opened from a long press, with the starting test task selected">

### iPad: all-workspace entry

The initial navigation check below covers the empty state and filters. A populated workspace and actual file-reading flow require separate screenshots and assertions.

<img src="images/workflow-upgrade/workspaces-empty-ipad.png" width="340" alt="All-workspace manager with project, active chat and archived chat filters, showing an empty state">

### iPad: populated workspace and PDF reading

The two focused iPad UI tests passed on 2026-09-08. They open the test conversation workspace, read an actual two-page PDF inline, expand it, return to the original panel width and go back to the file list. These checks do not yet establish physical-device reading-position fidelity.

<img src="images/workflow-upgrade/workspaces-populated-ipad.png" width="340" alt="All-workspace manager containing a test conversation workspace">
<img src="images/workflow-upgrade/pdf-inline-ipad.png" width="340" alt="Two-page test PDF rendered directly inside the right file panel">
<img src="images/workflow-upgrade/pdf-fullscreen-ipad.png" width="340" alt="The same PDF opened fullscreen">

## Reproducing the screenshots / 复现截图

Use the `FloeAgent` scheme with a configured iOS simulator and the full Xcode developer directory. The UI tests create synthetic local task/PDF fixtures; they do not require personal documents or model credentials. Run these test selectors on the corresponding device:

- iPhone: `FloeAgentUITests/HomeChatVoiceIPhoneUITests/testCanvasCreationRemainsVisibleInPortraitAndLandscape`
- iPad: `FloeAgentUITests/HomeChatVoiceIPadUITests/testPluginMarketplaceAndBatchEntry`
- iPad: `FloeAgentUITests/HomeChatVoiceIPadUITests/testWorkspacePDFInlineAndFullscreen`

Keep the `.xcresult` bundle and export original attachments with `xcrun xcresulttool export attachments --path <result.xcresult> --output-path <directory>`. Retain failed-run screenshots separately. Inspect orientation, keyboard visibility, rendered content and touch targets before adding successful captures to this page. The screenshot helpers use the whole simulator screen to avoid application-frame cropping during rotation.

### iPhone: portrait and landscape canvas

The focused test passed with new SVG nodes inside the visible viewport and the editing completion control reachable in both orientations. Original full-screen captures show rendered SVG content after editing. This is simulator evidence: the landscape selection/zoom/input overlays remain crowded and need further layout refinement before final device acceptance.

<img src="images/workflow-upgrade/iphone-canvas-create-menu-portrait.png" width="280" alt="iPhone canvas creation menu with generation task first">
<img src="images/workflow-upgrade/iphone-canvas-svg-editor-portrait.png" width="280" alt="iPhone portrait SVG source editing with keyboard">
<img src="images/workflow-upgrade/iphone-canvas-portrait.png" width="280" alt="Rendered SVG node inside the portrait canvas viewport">

<img src="images/workflow-upgrade/iphone-canvas-create-menu-landscape.png" width="680" alt="iPhone landscape canvas creation menu">
<img src="images/workflow-upgrade/iphone-canvas-svg-editor-landscape.png" width="680" alt="iPhone landscape SVG source editor with reachable completion action">
<img src="images/workflow-upgrade/iphone-canvas-landscape.png" width="680" alt="Rendered SVG in landscape; remaining crowded overlay spacing is visible">
