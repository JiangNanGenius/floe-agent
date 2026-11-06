import Foundation

/// Bilingual user-facing strings for the canvas editor.
///
/// The qualification host and the kit UI share one vocabulary. Labels stay
/// concise (per UI_BRIEF); internal identities never appear in labels and
/// belong in opened details instead. The UI module never reaches for
/// host-localization bundles: it carries its own English + Simplified
/// Chinese table so the qualification App renders correctly standalone.
public struct CanvasStrings: Sendable {
    public enum Language: String, Codable, Hashable, Sendable, CaseIterable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"
    }

    /// Resolved once per editor session from the host locale. Hosts may pin
    /// a language through `CanvasEditorConfiguration.preferredLanguage`.
    public static func resolve(
        preferred: Language? = nil,
        locale: Locale = .current
    ) -> Language {
        if let preferred { return preferred }
        let code = locale.language.languageCode?.identifier ?? "en"
        return code.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    private let table: KeyTable

    public init(language: Language) {
        switch language {
        case .english: self.table = KeyTable.english
        case .simplifiedChinese: self.table = KeyTable.simplifiedChinese
        }
    }

    public subscript(key: Key) -> String {
        table.values[key] ?? key.rawValue
    }

    public enum Key: String, Codable, Hashable, Sendable, CaseIterable {
        // Toolbar / chrome
        case canvasTitleUntitled
        case toolbarNew
        case toolbarMore
        case toolbarEdit, toolbarNavigate
        case toolbarInsert
        case toolbarUndo
        case toolbarRedo
        case toolbarDelete
        case toolbarDuplicate
        case toolbarSelectAll
        case toolbarGroup
        case toolbarUngroup
        case toolbarRegion
        case toolbarCollapseRegion
        case toolbarExpandRegion
        case toolbarScene
        case toolbarArrange
        case toolbarArrangeHorizontal
        case toolbarArrangeVertical
        case toolbarSearch
        case searchClear
        case savingStatus
        case toolbarFit
        case toolbarZoomIn
        case toolbarZoomOut
        case zoomActualSize
        case toolbarLab
        case toolbarInspector
        case toolbarPages
        case toolbarDone
        case toolbarRun
        case toolbarStop
        case toolbarPause
        case toolbarStep
        case toolbarResume
        case toolbarBypass
        // Tools
        case toolSelect
        case toolHand
        case toolPencil
        case toolLasso
        case toolEraser
        case toolConnector
        // Insert menu
        case insertText
        case insertRichText
        case insertMarkdown
        case insertTable
        case insertFormula
        case insertCode
        case insertShapeRectangle
        case insertShapeRounded
        case insertShapeEllipse
        case insertShapeDiamond
        case insertShapeLine
        case insertShapeArrow
        case insertWebReference
        case insertSourceReference
        case insertMedia
        case insertPDF
        case insertEditorPreview
        case insertFlowStep
        // New scene sheet
        case newSceneTitle
        case newSceneNamePlaceholder
        case templateResearch
        case templateResearchSubtitle
        case templateCompare
        case templateCompareSubtitle
        case templateBlank
        case templateBlankSubtitle
        case templateLab
        case templateLabSubtitle
        case createButton
        case cancelButton
        case saveButton
        case keepInk
        case convertToObject
        case inkRecognizedShapes
        // Inspector
        case inspectorTitle
        case inspectorNoSelection
        case inspectorNodeTitle
        case inspectorNodeContent
        case inspectorStyle
        case inspectorResources
        case inspectorFillColor
        case inspectorStrokeColor
        case inspectorStrokeWidth
        case inspectorTextColor
        case inspectorLocked
        case inspectorFlowBinding
        case inspectorOpenEditor
        case inspectorApplyEditorResult
        case inspectorRefreshSource
        case inspectorRefreshSourceReplace
        case inspectorRefreshSourceBranch
        case inspectorSourceUsedRevision
        case inspectorOpenOriginal
        // Flow inspector
        case flowKindSource
        case flowKindTransform
        case flowKindCondition
        case flowKindLoop
        case flowKindBatch
        case flowKindSubgraph
        case flowKindCustomScript
        case flowKindCustomAPI
        case flowKindOutput
        case flowMaxIterations
        case flowConditionBranches
        case flowVariables
        case flowScriptMissingEnvironment
        case flowAPIConfiguration
        case flowAddInputPort
        case flowAddOutputPort
        case flowPortName
        case flowPortType
        case flowValidationIssues
        case flowDefinitionTitle
        case flowDefinitionHelp
        case flowDefinitionInvalid
        case flowDefinitionSelectAll
        case flowGraphChooser
        case flowGraphEntry
        // Debugger
        case debuggerTitle
        case debuggerInputsOutputs
        case debuggerRunning
        case debuggerPaused
        case debuggerWaitingReconcile
        case debuggerCompleted
        case debuggerFailed
        case debuggerCancelled
        case debuggerInputs
        case debuggerOutputs
        case debuggerFailures
        case debuggerLateDeliveries
        case debuggerEmpty
        case debuggerBreakpoint
        case debuggerLoopIteration
        case debuggerBatchProgress
        case debuggerPlaceOutputs
        case debuggerOutputsPlacedTitle
        case debuggerOutputsPlaced
        case debuggerCheckpointFailed
        case debuggerRunNotCompleted
        case debuggerRunPageMismatch
        case debuggerRunStale
        case debuggerRunUnavailable
        case debuggerRunBatchTooLarge
        // Errors / alerts
        case alertSaveFailedTitle
        case alertSaveFailedMessage
        case alertSaveFailedKeepEditing
        case alertSaveFailedDiscard
        case alertConflictTitle
        case alertReload
        case alertSourceUnavailable
        case alertMissingResourceTitle
        case alertMissingResourceMessage
        case alertAssistantUnavailable
        case alertEnvironmentRequired
        case alertEnvironmentRequiredMessage
        case alertInvalidFlowTitle
        case alertDraftRecovered
        // Accessibility (labels announced by VoiceOver)
        case a11yBoard
        case a11ySidebar
        case a11yInspector
        case a11ySelectionCount
        case a11yOpenInspector
        // Media / resources
        case mediaMissingPreview
        case mediaOpenEditor
        case mediaTapToResolve
        case pdfMissingDocument
        case pdfPageRangeCaption
        case contentTruncated
        case editorProjectMissing
    }

    private struct KeyTable: Sendable {
        var values: [Key: String]
        static let english = KeyTable(values: [
            .canvasTitleUntitled: "Untitled Canvas",
            .toolbarNew: "New",
            .toolbarMore: "More",
            .toolbarEdit: "Edit",
            .toolbarNavigate: "Navigate",
            .toolbarInsert: "Insert",
            .toolbarUndo: "Undo",
            .toolbarRedo: "Redo",
            .toolbarDelete: "Delete",
            .toolbarDuplicate: "Duplicate",
            .toolbarSelectAll: "Select All",
            .toolbarGroup: "Group",
            .toolbarUngroup: "Ungroup",
            .toolbarRegion: "Region",
            .toolbarCollapseRegion: "Collapse Region",
            .toolbarExpandRegion: "Expand Region",
            .toolbarScene: "Scene",
            .toolbarArrange: "Arrange",
            .toolbarArrangeHorizontal: "Arrange Horizontally",
            .toolbarArrangeVertical: "Arrange Vertically",
            .toolbarSearch: "Search",
            .searchClear: "Clear",
            .savingStatus: "Saving…",
            .toolbarFit: "Fit",
            .toolbarZoomIn: "Zoom In",
            .toolbarZoomOut: "Zoom Out",
            .zoomActualSize: "Actual Size",
            .toolbarLab: "Lab",
            .toolbarInspector: "Inspector",
            .toolbarPages: "Pages",
            .toolbarDone: "Done",
            .toolbarRun: "Run",
            .toolbarStop: "Stop",
            .toolbarPause: "Pause",
            .toolbarStep: "Step",
            .toolbarResume: "Resume",
            .toolbarBypass: "Bypass",
            .toolSelect: "Select",
            .toolHand: "Hand",
            .toolPencil: "Pencil",
            .toolLasso: "Lasso",
            .toolEraser: "Eraser",
            .toolConnector: "Connect",
            .insertText: "Text",
            .insertRichText: "Rich Text",
            .insertMarkdown: "Markdown",
            .insertTable: "Table",
            .insertFormula: "Formula",
            .insertCode: "Code",
            .insertShapeRectangle: "Rectangle",
            .insertShapeRounded: "Rounded Rectangle",
            .insertShapeEllipse: "Ellipse",
            .insertShapeDiamond: "Diamond",
            .insertShapeLine: "Line",
            .insertShapeArrow: "Arrow",
            .insertWebReference: "Web Reference",
            .insertSourceReference: "Source Reference",
            .insertMedia: "Media",
            .insertPDF: "PDF",
            .insertEditorPreview: "Editor Preview",
            .insertFlowStep: "Flow Step",
            .newSceneTitle: "New Scene",
            .newSceneNamePlaceholder: "Scene name",
            .templateResearch: "Research",
            .templateResearchSubtitle: "Collect sources and notes",
            .templateCompare: "Compare Proposals",
            .templateCompareSubtitle: "Branch candidate versions",
            .templateBlank: "Blank",
            .templateBlankSubtitle: "Start from an empty board",
            .templateLab: "Lab Sample",
            .templateLabSubtitle: "Deterministic sample — no model involved",
            .createButton: "Create",
            .cancelButton: "Cancel",
            .saveButton: "Save",
            .keepInk: "Keep Ink",
            .convertToObject: "Convert to Object",
            .inkRecognizedShapes: "Recognized %d shape(s) — keep the original ink?",
            .inspectorTitle: "Inspector",
            .inspectorNoSelection: "Nothing selected",
            .inspectorNodeTitle: "Title",
            .inspectorNodeContent: "Content",
            .inspectorStyle: "Style",
            .inspectorResources: "Resources",
            .inspectorFillColor: "Fill",
            .inspectorStrokeColor: "Stroke",
            .inspectorStrokeWidth: "Stroke Width",
            .inspectorTextColor: "Text Color",
            .inspectorLocked: "Locked",
            .inspectorFlowBinding: "Flow Step",
            .inspectorOpenEditor: "Open Editor",
            .inspectorApplyEditorResult: "Apply Changes",
            .inspectorRefreshSource: "Refresh Source",
            .inspectorRefreshSourceReplace: "Refresh (Replace)",
            .inspectorRefreshSourceBranch: "Refresh (Branch)",
            .inspectorSourceUsedRevision: "Used revision",
            .inspectorOpenOriginal: "Open Original",
            .flowKindSource: "Source",
            .flowKindTransform: "Transform",
            .flowKindCondition: "Condition",
            .flowKindLoop: "Loop",
            .flowKindBatch: "Batch",
            .flowKindSubgraph: "Subgraph",
            .flowKindCustomScript: "Script",
            .flowKindCustomAPI: "API",
            .flowKindOutput: "Output",
            .flowMaxIterations: "Max iterations",
            .flowConditionBranches: "Branches",
            .flowVariables: "Variables",
            .flowScriptMissingEnvironment: "No execution environment configured",
            .flowAPIConfiguration: "API configuration",
            .flowAddInputPort: "Add Input Port",
            .flowAddOutputPort: "Add Output Port",
            .flowPortName: "Port name",
            .flowPortType: "Port type",
            .flowValidationIssues: "Flow issues",
            .flowDefinitionTitle: "Edit Flow Definition",
            .flowDefinitionHelp: "Configure ports, conditions, loop bodies, variables and custom steps. Credentials and execution access come from the host.",
            .flowDefinitionInvalid: "Check the definition and try again.",
            .flowDefinitionSelectAll: "Select All",
            .flowGraphChooser: "Flow Graph",
            .flowGraphEntry: "Graph %d",
            .debuggerTitle: "Flow Debugger",
            .debuggerInputsOutputs: "Inputs and Outputs",
            .debuggerRunning: "Running",
            .debuggerPaused: "Paused",
            .debuggerWaitingReconcile: "Waiting for reconciliation",
            .debuggerCompleted: "Completed",
            .debuggerFailed: "Failed",
            .debuggerCancelled: "Cancelled",
            .debuggerInputs: "Inputs",
            .debuggerOutputs: "Outputs",
            .debuggerFailures: "Failures",
            .debuggerLateDeliveries: "Late deliveries",
            .debuggerEmpty: "No run events yet",
            .debuggerBreakpoint: "Breakpoint",
            .debuggerLoopIteration: "Iteration",
            .debuggerBatchProgress: "Items",
            .debuggerPlaceOutputs: "Place run outputs on the page",
            .debuggerOutputsPlacedTitle: "Outputs Placed",
            .debuggerOutputsPlaced: "%d placed · %d already present · %d unsupported",
            .debuggerCheckpointFailed: "Run save failed",
            .debuggerRunNotCompleted: "Wait for the run to complete before placing its outputs.",
            .debuggerRunPageMismatch: "Switch to the page this run started on to place its outputs.",
            .debuggerRunStale: "This run’s results are stale. Rerun the flow, then place the new outputs.",
            .debuggerRunUnavailable: "The run is no longer available in this runtime.",
            .debuggerRunBatchTooLarge: "The batch output is too large or too deeply nested to place as cards (%@). Export the run result to keep every value.",
            .alertSaveFailedTitle: "Couldn’t Save",
            .alertSaveFailedMessage: "Your edit is kept on this device. Retry or discard it.",
            .alertSaveFailedKeepEditing: "Keep Editing",
            .alertSaveFailedDiscard: "Discard",
            .alertConflictTitle: "This canvas changed elsewhere",
            .alertReload: "Reload",
            .alertSourceUnavailable: "The source is unavailable.",
            .alertMissingResourceTitle: "Resource Missing",
            .alertMissingResourceMessage: "This reference can’t be resolved. Re-link it in the inspector.",
            .alertAssistantUnavailable: "The assistant is unavailable in this host.",
            .alertEnvironmentRequired: "Environment Required",
            .alertEnvironmentRequiredMessage: "Pick an execution environment before running this step.",
            .alertInvalidFlowTitle: "Flow Invalid",
            .alertDraftRecovered: "An unsaved edit was recovered.",
            .a11yBoard: "Canvas board",
            .a11ySidebar: "Pages and scenes",
            .a11yInspector: "Inspector",
            .a11ySelectionCount: "%d items selected",
            .a11yOpenInspector: "Open Inspector",
            .mediaMissingPreview: "Preview unavailable",
            .mediaOpenEditor: "Open in editor",
            .mediaTapToResolve: "Resource unresolved",
            .pdfMissingDocument: "PDF not resolved",
            .pdfPageRangeCaption: "Pages %d–%d",
            .contentTruncated: "More…",
            .editorProjectMissing: "Project unavailable",
        ])
        static let simplifiedChinese = KeyTable(values: [
            .canvasTitleUntitled: "未命名画布",
            .toolbarNew: "新建",
            .toolbarMore: "更多",
            .toolbarEdit: "编辑",
            .toolbarNavigate: "导航",
            .toolbarInsert: "插入",
            .toolbarUndo: "撤销",
            .toolbarRedo: "重做",
            .toolbarDelete: "删除",
            .toolbarDuplicate: "拷贝",
            .toolbarSelectAll: "全选",
            .toolbarGroup: "成组",
            .toolbarUngroup: "取消成组",
            .toolbarRegion: "区域",
            .toolbarCollapseRegion: "折叠区域",
            .toolbarExpandRegion: "展开区域",
            .toolbarScene: "场景",
            .toolbarArrange: "整理",
            .toolbarArrangeHorizontal: "横向整理",
            .toolbarArrangeVertical: "纵向整理",
            .toolbarSearch: "搜索",
            .searchClear: "清除",
            .savingStatus: "正在保存…",
            .toolbarFit: "适配",
            .toolbarZoomIn: "放大",
            .toolbarZoomOut: "缩小",
            .zoomActualSize: "实际大小",
            .toolbarLab: "实验",
            .toolbarInspector: "检查器",
            .toolbarPages: "页面",
            .toolbarDone: "完成",
            .toolbarRun: "运行",
            .toolbarStop: "停止",
            .toolbarPause: "暂停",
            .toolbarStep: "单步",
            .toolbarResume: "继续",
            .toolbarBypass: "绕过",
            .toolSelect: "选择",
            .toolHand: "抓手",
            .toolPencil: "铅笔",
            .toolLasso: "套索",
            .toolEraser: "橡皮",
            .toolConnector: "连接",
            .insertText: "文本",
            .insertRichText: "富文本",
            .insertMarkdown: "Markdown",
            .insertTable: "表格",
            .insertFormula: "公式",
            .insertCode: "代码",
            .insertShapeRectangle: "矩形",
            .insertShapeRounded: "圆角矩形",
            .insertShapeEllipse: "椭圆",
            .insertShapeDiamond: "菱形",
            .insertShapeLine: "直线",
            .insertShapeArrow: "箭头",
            .insertWebReference: "网页引用",
            .insertSourceReference: "来源引用",
            .insertMedia: "媒体",
            .insertPDF: "PDF",
            .insertEditorPreview: "编辑器预览",
            .insertFlowStep: "流程步骤",
            .newSceneTitle: "新建场景",
            .newSceneNamePlaceholder: "场景名称",
            .templateResearch: "研究",
            .templateResearchSubtitle: "收集来源与笔记",
            .templateCompare: "方案对比",
            .templateCompareSubtitle: "为候选版本建立分支",
            .templateBlank: "空白",
            .templateBlankSubtitle: "从空白画板开始",
            .templateLab: "实验样本",
            .templateLabSubtitle: "确定性样本——未调用模型",
            .createButton: "创建",
            .cancelButton: "取消",
            .saveButton: "保存",
            .keepInk: "保留笔迹",
            .convertToObject: "转换为对象",
            .inkRecognizedShapes: "识别到 %d 个图形——是否保留原笔迹？",
            .inspectorTitle: "检查器",
            .inspectorNoSelection: "未选中内容",
            .inspectorNodeTitle: "标题",
            .inspectorNodeContent: "内容",
            .inspectorStyle: "样式",
            .inspectorResources: "资源",
            .inspectorFillColor: "填充",
            .inspectorStrokeColor: "描边",
            .inspectorStrokeWidth: "描边宽度",
            .inspectorTextColor: "文字颜色",
            .inspectorLocked: "已锁定",
            .inspectorFlowBinding: "流程步骤",
            .inspectorOpenEditor: "打开编辑器",
            .inspectorApplyEditorResult: "应用修改",
            .inspectorRefreshSource: "刷新来源",
            .inspectorRefreshSourceReplace: "刷新（替换）",
            .inspectorRefreshSourceBranch: "刷新（分支）",
            .inspectorSourceUsedRevision: "已用修订",
            .inspectorOpenOriginal: "打开原件",
            .flowKindSource: "来源",
            .flowKindTransform: "变换",
            .flowKindCondition: "条件",
            .flowKindLoop: "循环",
            .flowKindBatch: "批处理",
            .flowKindSubgraph: "子图",
            .flowKindCustomScript: "脚本",
            .flowKindCustomAPI: "API",
            .flowKindOutput: "输出",
            .flowMaxIterations: "最大迭代",
            .flowConditionBranches: "分支",
            .flowVariables: "变量",
            .flowScriptMissingEnvironment: "未配置执行环境",
            .flowAPIConfiguration: "API 配置",
            .flowAddInputPort: "添加输入端口",
            .flowAddOutputPort: "添加输出端口",
            .flowPortName: "端口名称",
            .flowPortType: "端口类型",
            .flowValidationIssues: "流程问题",
            .flowDefinitionTitle: "编辑流程定义",
            .flowDefinitionHelp: "配置端口、条件、循环体、变量和自定义步骤。凭据与执行权限由宿主提供。",
            .flowDefinitionInvalid: "请检查流程定义后重试。",
            .flowDefinitionSelectAll: "全选",
            .flowGraphChooser: "流程图",
            .flowGraphEntry: "图 %d",
            .debuggerTitle: "流程调试器",
            .debuggerInputsOutputs: "输入与输出",
            .debuggerRunning: "运行中",
            .debuggerPaused: "已暂停",
            .debuggerWaitingReconcile: "等待核对",
            .debuggerCompleted: "已完成",
            .debuggerFailed: "失败",
            .debuggerCancelled: "已取消",
            .debuggerInputs: "输入",
            .debuggerOutputs: "输出",
            .debuggerFailures: "失败",
            .debuggerLateDeliveries: "迟到回调",
            .debuggerEmpty: "尚无运行事件",
            .debuggerBreakpoint: "断点",
            .debuggerLoopIteration: "迭代",
            .debuggerBatchProgress: "条目",
            .debuggerPlaceOutputs: "将运行输出放到页面",
            .debuggerOutputsPlacedTitle: "已放置输出",
            .debuggerOutputsPlaced: "已放置 %d 项 · %d 项已存在 · %d 项不支持",
            .debuggerCheckpointFailed: "运行保存失败",
            .debuggerRunNotCompleted: "请等待运行完成后再放置其输出。",
            .debuggerRunPageMismatch: "请切换到该运行起始页面后再放置其输出。",
            .debuggerRunStale: "该运行的结果已过期。请重新运行流程后再放置新输出。",
            .debuggerRunUnavailable: "该运行在当前运行时中已不可用。",
            .debuggerRunBatchTooLarge: "批量输出过大或嵌套过深，无法放置为卡片（%@）。请导出运行结果以保留全部内容。",
            .alertSaveFailedTitle: "无法保存",
            .alertSaveFailedMessage: "修改已保留在本机，可重试或放弃。",
            .alertSaveFailedKeepEditing: "继续编辑",
            .alertSaveFailedDiscard: "放弃",
            .alertConflictTitle: "画布已在别处修改",
            .alertReload: "重新载入",
            .alertSourceUnavailable: "来源不可用。",
            .alertMissingResourceTitle: "资源缺失",
            .alertMissingResourceMessage: "无法解析此引用，请在检查器中重新关联。",
            .alertAssistantUnavailable: "当前宿主不支持助手。",
            .alertEnvironmentRequired: "需要执行环境",
            .alertEnvironmentRequiredMessage: "运行该步骤前请选择执行环境。",
            .alertInvalidFlowTitle: "流程无效",
            .alertDraftRecovered: "已恢复一条未保存的修改。",
            .a11yBoard: "画布区",
            .a11ySidebar: "页面与场景",
            .a11yInspector: "检查器",
            .a11ySelectionCount: "已选中 %d 项",
            .a11yOpenInspector: "打开检查器",
            .mediaMissingPreview: "预览不可用",
            .mediaOpenEditor: "在编辑器中打开",
            .mediaTapToResolve: "资源未解析",
            .pdfMissingDocument: "PDF 未解析",
            .pdfPageRangeCaption: "第 %d–%d 页",
            .contentTruncated: "更多…",
            .editorProjectMissing: "项目不可用",
        ])
    }
}

public extension CanvasStrings {
    /// Number-aware lookup for strings with substitutions (`%d`).
    func formatted(_ key: Key, _ arguments: CVarArg...) -> String {
        String(format: self[key], arguments: arguments)
    }
}
