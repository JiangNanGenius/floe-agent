// FloeApp — App Intents for Shortcuts and Siri.
//
// Exposes FloeAgent to iOS Shortcuts and Siri: send text to the agent for
// summarization, create a new task, query task status. App Intents run in
// the app process (no UI required for background execution).

#if canImport(AppIntents)
import AppIntents
import Foundation

/// Sends text to the agent for processing (e.g. summarization).
struct SendToFloeIntent: AppIntent {
    static var title: LocalizedStringResource { "发送给 Floe 处理" }
    static var description: IntentDescription {
        IntentDescription("把文字发给 Floe Agent 处理（总结、分析等）")
    }

    @Parameter(title: "文字内容")
    var text: String

    @Parameter(title: "指令", default: "总结这段文字")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 发给 Floe，指令：\(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // Note: This intent runs in the app process but cannot directly use
        // @EnvironmentObject AppEnvironment. For now, return a placeholder
        // indicating the app should be opened to complete the action.
        // Full headless execution requires decoupling AppEnvironment.
        return .result(value: "请打开 Floe Agent 完成：\(prompt)")
    }
}

/// Creates a new task in Floe Agent.
struct CreateFloeTaskIntent: AppIntent {
    static var title: LocalizedStringResource { "新建 Floe 任务" }
    static var description: IntentDescription {
        IntentDescription("在 Floe Agent 中新建一个任务")
    }

    @Parameter(title: "任务描述")
    var taskDescription: String

    static var parameterSummary: some ParameterSummary {
        Summary("新建任务：\(\.$taskDescription)")
    }

    func perform() async throws -> some IntentResult {
        // Placeholder: full implementation requires opening the app with the
        // task description pre-filled.
        return .result()
    }
}

/// App Shortcuts provider: exposes intents to Shortcuts and Siri.
struct FloeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendToFloeIntent(),
            phrases: [
                "把文字发给 \(.applicationName)",
                "用 \(.applicationName) 总结",
                "\(.applicationName) 处理这段文字"
            ],
            shortTitle: "发给 Floe",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: CreateFloeTaskIntent(),
            phrases: [
                "新建 \(.applicationName) 任务",
                "用 \(.applicationName) 创建任务"
            ],
            shortTitle: "新建任务",
            systemImageName: "plus"
        )
    }
}
#endif
