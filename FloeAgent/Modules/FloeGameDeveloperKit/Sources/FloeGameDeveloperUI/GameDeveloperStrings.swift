// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameDeveloperCore

public enum GameDeveloperLocale: String, CaseIterable, Sendable {
    case automatic
    case english
    case simplifiedChinese

    public static var resolved: GameDeveloperLocale {
        let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return language.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    public var isChinese: Bool {
        (self == .simplifiedChinese) || (self == .automatic && Self.resolved == .simplifiedChinese)
    }
}

/// All ordinary menu copy in one place. Field/action labels come from the
/// engine bridge (each descriptor carries English and Simplified Chinese).
public struct GameDeveloperStrings: Sendable {
    public let locale: GameDeveloperLocale
    public init(locale: GameDeveloperLocale) { self.locale = locale }

    private func text(_ english: String, _ chinese: String) -> String {
        locale.isChinese ? chinese : english
    }

    public var title: String { text("Developer menu", "开发者菜单") }
    public var subtitle: String { text("Live controls for this test run", "本次运行的实时控制") }
    public var search: String { text("Search fields and actions", "搜索字段和动作") }
    public var quickControls: String { text("Quick controls", "快捷控制") }
    public var state: String { text("Live state", "实时状态") }
    public var actions: String { text("Actions", "动作") }
    public var checkpoints: String { text("Checkpoints", "检查点") }
    public var history: String { text("History", "历史") }
    public var diagnostics: String { text("Diagnostics", "诊断") }
    public var instrumentation: String { text("Instrumentation plan", "接入计划") }
    public var noFields: String { text("This engine has no registered live fields yet.", "此引擎尚未登记实时字段。") }
    public var noActions: String { text("No engine actions are registered for this run.", "本次运行没有登记引擎动作。") }
    public var noSearchResults: String { text("No matching fields or actions.", "没有匹配的字段或动作。") }
    public var notAttached: String { text("Not connected to a running game.", "尚未连接到运行中的游戏。") }
    public var attaching: String { text("Connecting to the game…", "正在连接游戏…") }
    public var ready: String { text("Connected", "已连接") }
    public var reloading: String { text("Restarting the game…", "正在重新启动游戏…") }
    public var failed: String { text("Connection failed", "连接失败") }
    public var paused: String { text("Pause", "暂停") }
    public var resume: String { text("Resume", "继续") }
    public var restart: String { text("Restart", "重新开始") }
    public var speed: String { text("Speed", "速度") }
    public var checkpoint: String { text("Checkpoint", "创建检查点") }
    public var screenshot: String { text("Screenshot", "截图") }
    public var reset: String { text("Reset", "重置") }
    public var resetTitle: String { text("Reset live state?", "重置实时状态？") }
    public var resetBaseline: String { text("Restore session baseline", "恢复会话基线") }
    public var resetRestart: String { text("Restart from boot state", "从启动状态重新开始") }
    public var resetMessage: String {
        text("A game debug snapshot may not be available. Unsaved progress can be lost.",
             "可能没有游戏调试快照；未保存的进度可能丢失。")
    }
    public var cancel: String { text("Cancel", "取消") }
    public var confirm: String { text("Confirm", "确认") }
    public var apply: String { text("Apply", "应用") }
    public var retry: String { text("Retry", "重试") }
    public var close: String { text("Close", "关闭") }
    public var attach: String { text("Connect", "连接") }
    public var detach: String { text("Disconnect", "断开") }
    public var clearError: String { text("Dismiss", "关闭提示") }
    public var noCheckpoints: String { text("No checkpoints yet. One is captured before each change.", "还没有检查点；每次修改前会自动捕获。") }
    public var noHistory: String { text("No actions yet.", "还没有动作记录。") }
    public var revert: String { text("Revert", "恢复") }
    public var baseline: String { text("Baseline", "基线") }
    public var fieldsOnly: String { text("Fields only", "仅字段") }
    public var completeSnapshot: String { text("Game debug snapshot", "游戏调试快照") }
    public var accepted: String { text("Applied", "已应用") }
    public var rejected: String { text("Rejected", "已拒绝") }
    public var unsupported: String { text("Unsupported", "不支持") }
    public var loading: String { text("Working…", "处理中…") }
    public var destructive: String { text("This action may discard progress.", "此动作可能丢弃进度。") }
    public var confirmAction: String { text("Run this action?", "执行此动作？") }
    public var parameters: String { text("Parameters", "参数") }
    public var screenshotTitle: String { text("Game screenshot", "游戏截图") }
    public var fps: String { text("FPS", "FPS") }
    public var frames: String { text("Frames", "帧数") }
    public var viewport: String { text("Viewport", "视口") }
    public var canvases: String { text("Canvases", "画布") }
    public var webAssembly: String { text("WebAssembly", "WebAssembly") }
    public var logs: String { text("Bridge logs", "桥日志") }
    public var details: String { text("Details", "详情") }
    public var missingHook: String { text("Missing hook", "缺少钩子") }
    public var required: String { text("Required", "必填") }
    public var invalidValue: String { text("Enter a valid value for this field.", "请输入该字段的有效值。") }
    public var noSnapshot: String {
        text("This engine exposes fields but no game debug snapshot; reverts restore captured fields only.",
             "此引擎提供字段但没有游戏调试快照；恢复只能还原已捕获的字段。")
    }
    public var checkpointsInMemory: String {
        text("Checkpoints live in memory for this run and disappear when the player closes.",
             "检查点仅保存在本次运行的内存中，关闭播放器后消失。")
    }
    public var attachHint: String {
        text("Open a game run, then connect the menu to its live player.", "请先运行游戏，再把菜单连接到实际播放器。")
    }

    public func error(_ error: GameDeveloperError?) -> String? {
        guard let error else { return nil }
        switch error {
        case .notAttached: return text("The menu is not connected to a game.", "菜单尚未连接到游戏。")
        case .alreadyAttached: return text("The menu is already connected.", "菜单已经连接。")
        case .staleSession: return text("The game run changed. Reopen the menu for the new run.", "游戏运行已变化，请为新运行重新打开菜单。")
        case .contextMismatch(let detail): return text("This control belongs to another project or run. \(detail)", "此控件属于其他工程或运行。\(detail)")
        case .bridgeUnavailable(let detail): return text("The game bridge is unavailable. \(detail)", "游戏桥不可用。\(detail)")
        case .invalidRequest(let detail): return text("Invalid request. \(detail)", "请求无效。\(detail)")
        case .invalidField(let detail): return text("Cannot change that field. \(detail)", "无法修改该字段。\(detail)")
        case .invalidAction(let detail): return text("That action is unavailable. \(detail)", "该动作不可用。\(detail)")
        case .unsupported(let detail): return text("Not supported by this engine route. \(detail)", "此引擎路由不支持。\(detail)")
        case .payloadTooLarge: return text("The value is too large for the game bridge.", "该值超出游戏桥限制。")
        case .snapshotUnavailable(let detail): return text("No game debug snapshot is available. \(detail)", "没有可用的游戏调试快照。\(detail)")
        case .checkpointUnavailable(let detail): return text("A recoverable checkpoint could not be created. \(detail)", "无法创建可恢复的检查点。\(detail)")
        case .checkpointMissing: return text("That checkpoint is no longer available.", "该检查点已不可用。")
        case .confirmationRequired: return text("Confirm this action before running it.", "请先确认再执行此动作。")
        case .busy: return text("Another game action is still running.", "另一个游戏动作仍在执行。")
        case .transport(let detail): return text("The game returned an error. \(detail)", "游戏返回错误。\(detail)")
        case .invalidConfiguration(let detail): return text("The menu configuration is invalid. \(detail)", "菜单配置无效。\(detail)")
        }
    }

    public func fieldLabel(_ field: GameDeveloperFieldDescriptor) -> String {
        locale.isChinese ? field.labelZhHans : field.label
    }

    public func fieldGroup(_ field: GameDeveloperFieldDescriptor) -> String {
        locale.isChinese ? field.groupZhHans : field.group
    }

    public func actionLabel(_ action: GameDeveloperActionDescriptor) -> String {
        locale.isChinese ? action.labelZhHans : action.label
    }

    public func actionGroup(_ action: GameDeveloperActionDescriptor) -> String {
        locale.isChinese ? action.groupZhHans : action.group
    }

    public func parameterLabel(_ parameter: GameDeveloperActionParameterDescriptor) -> String {
        locale.isChinese ? parameter.labelZhHans : parameter.label
    }

    public func optionLabel(_ option: GameDeveloperChoiceOption) -> String {
        locale.isChinese ? option.labelZhHans : option.label
    }

    public func detail(_ field: GameDeveloperFieldDescriptor) -> String? {
        locale.isChinese ? (field.detailZhHans ?? field.detail) : field.detail
    }

    public func detail(_ action: GameDeveloperActionDescriptor) -> String? {
        locale.isChinese ? (action.detailZhHans ?? action.detail) : action.detail
    }

    public func detail(_ parameter: GameDeveloperActionParameterDescriptor) -> String? {
        locale.isChinese ? (parameter.detailZhHans ?? parameter.detail) : parameter.detail
    }

    public func notice(_ notice: GameDeveloperNotice) -> String {
        locale.isChinese ? notice.messageZhHans : notice.message
    }

    public func engineName(_ descriptor: GameDeveloperEngineDescriptor) -> String {
        locale.isChinese ? descriptor.displayNameZhHans : descriptor.displayName
    }

    public func planSummary(_ plan: GameDeveloperInstrumentationPlan) -> String {
        locale.isChinese ? plan.summaryZhHans : plan.summary
    }

    public func planSteps(_ plan: GameDeveloperInstrumentationPlan) -> [String] {
        locale.isChinese ? plan.stepsZhHans : plan.steps
    }

    public func planLimitations(_ plan: GameDeveloperInstrumentationPlan) -> String {
        locale.isChinese ? plan.limitationsZhHans : plan.limitations
    }

    public func status(_ status: GameDeveloperActionStatus) -> String {
        switch status {
        case .applied: return accepted
        case .rejected: return rejected
        case .unsupported: return unsupported
        case .reloading: return reloading
        }
    }

    public func phase(_ phase: GameDeveloperSessionPhase) -> String {
        switch phase {
        case .idle: return notAttached
        case .attaching: return attaching
        case .ready: return ready
        case .reloading: return reloading
        case .failed: return failed
        case .detached: return notAttached
        }
    }
}
