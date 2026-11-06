import Foundation

/// Stable accessibility identifiers for the ICH01–12 qualification matrix.
///
/// These IDs are part of the UI contract: the native host and UI tests bind
/// to them. They intentionally never embed document UUIDs — identity-bearing
/// details belong in accessibility *values*, not identifiers, so a rebuilt
/// board keeps the same identifiers.
public enum CanvasAccessibilityID: String, Codable, Hashable, Sendable, CaseIterable {
    // Chrome
    case rootView = "floe.canvas.root"
    case topToolbar = "floe.canvas.toolbar"
    case toolbarButtonNew = "floe.canvas.toolbar.new"
    case toolbarButtonInsert = "floe.canvas.toolbar.insert"
    case toolbarButtonUndo = "floe.canvas.toolbar.undo"
    case toolbarButtonRedo = "floe.canvas.toolbar.redo"
    case toolbarButtonDelete = "floe.canvas.toolbar.delete"
    case toolbarButtonDuplicate = "floe.canvas.toolbar.duplicate"
    case toolbarButtonArrange = "floe.canvas.toolbar.arrange"
    case toolbarButtonSearch = "floe.canvas.toolbar.search"
    case toolbarButtonFit = "floe.canvas.toolbar.fit"
    case toolbarButtonLab = "floe.canvas.toolbar.lab"
    case toolbarButtonInspector = "floe.canvas.toolbar.inspector"
    case toolbarButtonPages = "floe.canvas.toolbar.pages"
    case toolbarToolPicker = "floe.canvas.toolbar.tools"
    case toolbarFlowRun = "floe.canvas.toolbar.run"
    case toolbarFlowGraphChooser = "floe.canvas.toolbar.flowGraph"
    case toolbarFlowStop = "floe.canvas.toolbar.stop"
    case toolbarFlowPause = "floe.canvas.toolbar.pause"
    case toolbarFlowStep = "floe.canvas.toolbar.step"
    case toolbarFlowResume = "floe.canvas.toolbar.resume"
    case toolbarFlowBypass = "floe.canvas.toolbar.bypass"

    case toolbarDone = "floe.canvas.toolbar.done"

    // Board
    case board = "floe.canvas.board"
    case boardContent = "floe.canvas.board.content"
    case boardInk = "floe.canvas.board.ink"
    case boardSelectionMarquee = "floe.canvas.board.marquee"

    // Sidebar
    case sidebar = "floe.canvas.sidebar"
    case sidebarPages = "floe.canvas.sidebar.pages"
    case sidebarScenes = "floe.canvas.sidebar.scenes"
    case sidebarSearchField = "floe.canvas.sidebar.search"

    // Inspector
    case inspector = "floe.canvas.inspector"
    case inspectorTitleField = "floe.canvas.inspector.title"
    case inspectorContentEditor = "floe.canvas.inspector.content"
    case inspectorStyleSection = "floe.canvas.inspector.style"
    case inspectorLockedSwitch = "floe.canvas.inspector.locked"
    case inspectorFlowSection = "floe.canvas.inspector.flow"
    case inspectorSourceSection = "floe.canvas.inspector.source"
    case inspectorResourceSection = "floe.canvas.inspector.resource"
    case inspectorOpenEditorButton = "floe.canvas.inspector.openEditor"
    case inspectorApplyEditorButton = "floe.canvas.inspector.applyEditor"
    case inspectorRefreshSourceButton = "floe.canvas.inspector.refreshSource"

    // New scene sheet
    case newSceneSheet = "floe.canvas.newScene"
    case newSceneNameField = "floe.canvas.newScene.name"
    case newSceneTemplateResearch = "floe.canvas.newScene.template.research"
    case newSceneTemplateCompare = "floe.canvas.newScene.template.compare"
    case newSceneTemplateBlank = "floe.canvas.newScene.template.blank"
    case newSceneTemplateLab = "floe.canvas.newScene.template.lab"
    case newSceneCreateButton = "floe.canvas.newScene.create"
    case newSceneCancelButton = "floe.canvas.newScene.cancel"

    // Content editors (opened from inspector)
    case contentEditorText = "floe.canvas.editor.text"
    case contentEditorRichText = "floe.canvas.editor.richText"
    case contentEditorMarkdown = "floe.canvas.editor.markdown"
    case contentEditorTable = "floe.canvas.editor.table"
    case contentEditorFormula = "floe.canvas.editor.formula"
    case contentEditorCode = "floe.canvas.editor.code"

    // Flow debugger
    case debuggerPanel = "floe.canvas.debugger"
    case debuggerEventList = "floe.canvas.debugger.events"
    case debuggerStatus = "floe.canvas.debugger.status"
    case debuggerInputsOutputs = "floe.canvas.debugger.io"
    case debuggerPlaceOutputsButton = "floe.canvas.debugger.placeOutputs"

    // Ink recognition
    case inkKeepChoice = "floe.canvas.ink.keep"

    // Draft recovery banner
    case draftBanner = "floe.canvas.draft.banner"
    case draftRetryButton = "floe.canvas.draft.retry"
    case draftRebaseButton = "floe.canvas.draft.rebase"
    case draftDiscardButton = "floe.canvas.draft.discard"

    // Alerts
    case alert = "floe.canvas.alert"
    case alertPrimaryAction = "floe.canvas.alert.primary"
    case alertDiscardAction = "floe.canvas.alert.discard"
}

public extension CanvasAccessibilityID {
    var identifier: String { rawValue }
}
