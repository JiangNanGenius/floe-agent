// FloeApp — App Intents for Shortcuts and Siri.
//
// Exposes FloeAgent to iOS Shortcuts and Siri: send text to the agent for
// summarization, create a new task, query task status. App Intents run in
// the app process (no UI required for background execution).

#if canImport(AppIntents)
import AppIntents
import Foundation
import FloeCore
import FloeModels
import FloePersistence

enum FloeShortcutInbox {
    static let suite = "group.org.floeagent.ios"
    static let pendingDraftKey = "shortcuts.pendingDraft"

    static func enqueue(_ draft: String) {
        UserDefaults(suiteName: suite)?.set(draft, forKey: pendingDraftKey)
    }

    static func consume() -> String? {
        let defaults = UserDefaults(suiteName: suite)
        let draft = defaults?.string(forKey: pendingDraftKey)
        defaults?.removeObject(forKey: pendingDraftKey)
        return draft
    }
}

/// App Intents are launched by the system, sometimes without presenting the
/// app. Keep the intent layer thin and route all durable work through the same
/// stores/services used by Floe's UI and background scheduler.
@MainActor
final class FloeShortcutsRuntime {
    static let shared = FloeShortcutsRuntime()

    private weak var environment: AppEnvironment?

    private init() {}

    func install(environment: AppEnvironment) {
        self.environment = environment
    }

    func run(prompt: String, title: String?) async throws -> UUID {
        guard AppleCapabilityPreferences.isEnabled(.shortcuts) else {
            throw FloeError.invalidConfiguration("Shortcuts is disabled in Floe Settings")
        }
        guard let environment else {
            throw FloeError.invalidConfiguration("Floe is still starting; retry the shortcut")
        }
        let center = environment.conversationCenter
        guard let (provider, model) = center.providerAndModel(
            modelID: center.modelPreferences.defaultAgentModelID
        ) else {
            throw FloeError.invalidConfiguration("No default Floe model is configured")
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else {
            throw FloeError.validationFailed("Task must not be empty")
        }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = try await center.startTask(
            goal: cleanPrompt,
            title: cleanTitle?.isEmpty == false ? cleanTitle! : String(cleanPrompt.prefix(40)),
            provider: provider,
            model: model,
            startOrigin: .externalAutomation
        )
        return started.conversationID
    }

    func schedule(
        prompt: String,
        title: String?,
        at date: Date,
        cadence: FloeShortcutCadence
    ) async throws -> UUID {
        guard AppleCapabilityPreferences.isEnabled(.shortcuts),
              AppleCapabilityPreferences.isEnabled(.automation) else {
            throw FloeError.invalidConfiguration("Shortcuts or Automation is disabled in Floe Settings")
        }
        guard let environment else {
            throw FloeError.invalidConfiguration("Floe is still starting; retry the shortcut")
        }
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else {
            throw FloeError.validationFailed("Task must not be empty")
        }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = TaskScheduleRecord(
            title: cleanTitle?.isEmpty == false ? cleanTitle! : String(cleanPrompt.prefix(40)),
            prompt: cleanPrompt,
            cadence: cadence.taskCadence,
            scheduledAt: date,
            weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: date) : nil
        )
        try await SQLiteTaskScheduleStore(database: environment.database).save(record)
        BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: date)
        return record.id
    }
}

enum FloeShortcutCadence: String, AppEnum {
    case once
    case daily
    case weekly

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "重复")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .once: "一次",
        .daily: "每天",
        .weekly: "每周"
    ]

    var taskCadence: TaskScheduleCadence {
        switch self {
        case .once: .once
        case .daily: .daily
        case .weekly: .weekly
        }
    }
}

/// Sends text to the agent for processing (e.g. summarization).
struct SendToFloeIntent: AppIntent {
    static var openAppWhenRun: Bool { true }
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
        let task = "\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(text)"
        FloeShortcutInbox.enqueue(task)
        return .result(value: "已放入 Floe，打开后可检查并发送。")
    }
}

/// Creates a new task in Floe Agent.
struct CreateFloeTaskIntent: AppIntent {
    static var openAppWhenRun: Bool { true }
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
        FloeShortcutInbox.enqueue(taskDescription)
        return .result()
    }
}

/// Starts a durable Floe run without opening the UI. This is the action users
/// place in a Shortcuts personal automation (time of day, focus, arrival,
/// etc.). The intent returns once the conversation/run has been persisted and
/// provider execution has been scheduled.
struct RunFloeTaskIntent: AppIntent {
    static var openAppWhenRun: Bool { false }
    static var title: LocalizedStringResource { "立即运行 Floe 任务" }
    static var description: IntentDescription {
        IntentDescription("在后台创建并开始一个 Floe 任务，适合快捷指令自动化。")
    }

    @Parameter(title: "任务")
    var task: String

    @Parameter(title: "标题")
    var taskTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("运行 Floe 任务：\(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try await FloeShortcutsRuntime.shared.run(prompt: task, title: taskTitle)
        return .result(value: "Floe 任务已开始（\(id.uuidString)）。")
    }
}

/// Persists a Floe schedule from Shortcuts. iOS background refresh remains a
/// best-effort system facility, while users who need an exact trigger can put
/// `RunFloeTaskIntent` directly in a Shortcuts personal automation.
struct ScheduleFloeTaskIntent: AppIntent {
    static var openAppWhenRun: Bool { false }
    static var title: LocalizedStringResource { "安排 Floe 任务" }
    static var description: IntentDescription {
        IntentDescription("把任务加入 Floe 的后台调度；系统唤醒时间由 iOS 决定。")
    }

    @Parameter(title: "任务")
    var task: String

    @Parameter(title: "标题")
    var taskTitle: String?

    @Parameter(title: "时间")
    var scheduledAt: Date

    @Parameter(title: "重复", default: .once)
    var cadence: FloeShortcutCadence

    static var parameterSummary: some ParameterSummary {
        Summary("在 \(\.$scheduledAt) 安排 \(\.$task)，\(\.$cadence)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try await FloeShortcutsRuntime.shared.schedule(
            prompt: task,
            title: taskTitle,
            at: scheduledAt,
            cadence: cadence
        )
        return .result(value: "Floe 已保存该自动任务（\(id.uuidString)）。")
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
        AppShortcut(
            intent: RunFloeTaskIntent(),
            phrases: [
                "让 \(.applicationName) 立即运行任务",
                "运行 \(.applicationName) 自动任务"
            ],
            shortTitle: "立即运行任务",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ScheduleFloeTaskIntent(),
            phrases: [
                "用 \(.applicationName) 安排任务",
                "安排 \(.applicationName) 自动任务"
            ],
            shortTitle: "安排自动任务",
            systemImageName: "calendar.badge.clock"
        )
    }
}
#endif
