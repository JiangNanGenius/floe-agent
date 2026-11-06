# Floe Canvas Templates — predevelopment

A single mixed canvas with optional starting workflows. Categories help find a
workflow; they do not restrict the canvas or create separate editor types.

一个混合画布，可从空白开始，也可加入预置或个人流程。音乐、图像、视频、影视等
分类只帮助选择起点，不限制混合创作。此包供下一步 App 整合，当前不替换 App 入口。

## Products

- `FloeCanvasTemplates`: ten presets, template extraction/instantiation, versioned
  personal library, workspace coordination, editor/ownership bridges, result
  projection and working-position persistence.
- `FloeCanvasTemplatesUI`: optional in-canvas starting aid, workflow picker and a
  compiled picker host that appends through the actual workspace service.

Dependencies are the sibling `FloeCanvasKit` and its existing sibling
`FloeDiagramKit`/vendored ZIPFoundation. The source bundle includes these local
dependencies and their original licenses; no remote package install is needed.

## Host integration / 接入

1. Supply the existing App document authority as `TemplateDocumentStore`. The
   included `FileCanvasRepository` conformance is for isolated predevelopment.
2. Bind `TemplateEditorHostBridge` to existing editor create/open/apply/fork
   services and the current file ownership registry. Editor creation inside a
   canvas explicitly owns the child by that canvas. Browsing does not rebind it.
3. Use `workspace.create` for a blank canvas, then `activate`. Optionally append
   a preset with `CanvasWorkflowPickerHost`. Each document mutation returns a
   revision; activate a fresh session before the next edit.
4. Use `saveWorkflow` for a whole canvas or a selection. Personal definitions are
   saved by CAS with immutable version history; existing instances do not follow
   subsequent template edits. Mutable child editors become input slots.
5. Connect the host's real `CanvasStepExecutor` through
   `TemplateStepExecutorAdapter`. Map `TemplateOperation` to existing capabilities;
   the adapter does not implement providers, create jobs or produce fake results.
   `prepareFlow` exposes missing boundary ports. Canvas-bound required inputs are
   resolved from the frozen document revision, not substituted with examples.
6. `startFlow` uses the existing `FlowRuntimeService`. On a completed run,
   `applyRunResult` persists visible output nodes in one CAS/undo unit. Branching
   is the default. Replacement is explicit. A host projector can translate its
   own validated result envelope to an editor reference; the default shows
   structured output as JSON without interpreting it as executable content.
7. Store/restore `TemplateWorkingPosition` with `TemplateNavigationStore` or the
   host's existing scene persistence. Navigation does not add document undo.

### Files, moves and ownership / 文件与归属

The existing file service owns physical moves/copies/references. Move a complete
project folder including its manifest, child projects and relative assets; do not
convert or flatten the canvas just because its folder leaves the creative library.
The portable owner metadata is a hint; the live registry supplied through
`TemplateOwnershipResolving` takes precedence. Old sessions reject changed owners.
An editor's return route is resolved from its current owner, not the entry path.

When a used editable work moves out, call `retainEditorVersionBeforeMove` as an
internal file-service step. It asks the existing fork gateway for an independent
copy of the adopted revision and attaches that copy to the canvas. Move the
unchanged original only after `retained.attached == true`. A failed/late attachment
returns the actual created project for recovery. Immutable asset bytes and native
editor revision retention remain the existing host asset/editor services' duty.
This package does not migrate App data or replace those file services.

### Film properties / 影视属性

`CreativePurpose` is metadata on an ordinary text/image/video/audio node.
`CreativeRecords` stores one authoritative set of character/scene/shot records,
including order, timing and dialogue, through the same document CAS/undo pipeline.
`upsertRecord` also works on a blank canvas without choosing a template.
Generic editing/preview stays in existing editors; the host may show film fields
in a collapsed inspector. Source/reference associations never become ownership.

## Checks / 验证边界

Xcode 27.1, Swift 6 actual compilation, including generic arm64 iOS component
objects and the SwiftUI product. Seventeen focused tests cover reuse/isolation,
library CAS/history, selection boundaries, folder relocation, current ownership,
late callbacks, native-editor gateway calls and runtime-result persistence.
The runtime test uses an explicit recording qualification executor. It is not a
real provider generation or a production native editor run.

No full App build, Simulator/device run, production data migration or publication
is included. See the delivery `HANDOFF.md` and retained evidence logs.
