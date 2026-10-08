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

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "shortcuts.cadence.type_name")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .once: DisplayRepresentation(title: "shortcuts.cadence.once"),
        .daily: DisplayRepresentation(title: "shortcuts.cadence.daily"),
        .weekly: DisplayRepresentation(title: "shortcuts.cadence.weekly")
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
    static var title: LocalizedStringResource { "shortcuts.intent.send_to_floe.title" }
    static var description: IntentDescription {
        IntentDescription("shortcuts.intent.send_to_floe.description")
    }

    @Parameter(title: "shortcuts.intent.send_to_floe.param_text")
    var text: String

    @Parameter(title: "shortcuts.intent.send_to_floe.param_prompt",
               default: "Summarize this text")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        // The static template (with %@ per parameter) is the catalog key.
        Summary("shortcuts.intent.send_to_floe.summary \(\.$text) \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let task = "\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(text)"
        FloeShortcutInbox.enqueue(task)
        return .result(value: FloeL10n.l("shortcuts.intent.send_to_floe.result_placed"))
    }
}

/// Creates a new task in Floe Agent.
struct CreateFloeTaskIntent: AppIntent {
    static var openAppWhenRun: Bool { true }
    static var title: LocalizedStringResource { "shortcuts.intent.create_task.title" }
    static var description: IntentDescription {
        IntentDescription("shortcuts.intent.create_task.description")
    }

    @Parameter(title: "shortcuts.intent.create_task.param_description")
    var taskDescription: String

    static var parameterSummary: some ParameterSummary {
        Summary("shortcuts.intent.create_task.summary \(\.$taskDescription)")
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
    static var title: LocalizedStringResource { "shortcuts.intent.run_task.title" }
    static var description: IntentDescription {
        IntentDescription("shortcuts.intent.run_task.description")
    }

    @Parameter(title: "shortcuts.intent.run_task.param_task")
    var task: String

    @Parameter(title: "shortcuts.intent.run_task.param_title")
    var taskTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("shortcuts.intent.run_task.summary \(\.$task)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try await FloeShortcutsRuntime.shared.run(prompt: task, title: taskTitle)
        return .result(value: FloeL10n.l("shortcuts.intent.run_task.result_started", id.uuidString))
    }
}

/// Persists a Floe schedule from Shortcuts. iOS background refresh remains a
/// best-effort system facility, while users who need an exact trigger can put
/// `RunFloeTaskIntent` directly in a Shortcuts personal automation.
struct ScheduleFloeTaskIntent: AppIntent {
    static var openAppWhenRun: Bool { false }
    static var title: LocalizedStringResource { "shortcuts.intent.schedule_task.title" }
    static var description: IntentDescription {
        IntentDescription("shortcuts.intent.schedule_task.description")
    }

    @Parameter(title: "shortcuts.intent.schedule_task.param_task")
    var task: String

    @Parameter(title: "shortcuts.intent.schedule_task.param_title")
    var taskTitle: String?

    @Parameter(title: "shortcuts.intent.schedule_task.param_time")
    var scheduledAt: Date

    @Parameter(title: "shortcuts.intent.schedule_task.param_repeat",
               default: .once)
    var cadence: FloeShortcutCadence

    static var parameterSummary: some ParameterSummary {
        Summary("shortcuts.intent.schedule_task.summary \(\.$scheduledAt) \(\.$task) \(\.$cadence)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = try await FloeShortcutsRuntime.shared.schedule(
            prompt: task,
            title: taskTitle,
            at: scheduledAt,
            cadence: cadence
        )
        return .result(value: FloeL10n.l("shortcuts.intent.schedule_task.result_saved", id.uuidString))
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
                "\(.applicationName) 处理这段文字",
                "Send text to \(.applicationName)",
                "Summarize with \(.applicationName)",
                "Ask \(.applicationName) to process this text"
            ],
            shortTitle: "shortcuts.app_shortcut.send_to_floe",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: CreateFloeTaskIntent(),
            phrases: [
                "新建 \(.applicationName) 任务",
                "用 \(.applicationName) 创建任务",
                "Create a \(.applicationName) task",
                "New task with \(.applicationName)"
            ],
            shortTitle: "workbench.new_task",
            systemImageName: "plus"
        )
        AppShortcut(
            intent: RunFloeTaskIntent(),
            phrases: [
                "让 \(.applicationName) 立即运行任务",
                "运行 \(.applicationName) 自动任务",
                "Run a task with \(.applicationName) now",
                "Run \(.applicationName) automation"
            ],
            shortTitle: "shortcuts.app_shortcut.run_task_now",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ScheduleFloeTaskIntent(),
            phrases: [
                "用 \(.applicationName) 安排任务",
                "安排 \(.applicationName) 自动任务",
                "Schedule a task with \(.applicationName)",
                "Schedule \(.applicationName) automation"
            ],
            shortTitle: "shortcuts.app_shortcut.schedule_automation",
            systemImageName: "calendar.badge.clock"
        )
    }
}
#endif
