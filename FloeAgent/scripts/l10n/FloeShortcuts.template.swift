// FloeApp — App Intents for Shortcuts and Siri.
//
// Exposes FloeAgent to iOS Shortcuts and Siri: send text to the agent for
// summarization, create a new task, query task status. App Intents run in
// the app process (no UI required for background execution).

/// Machine-readable readiness rejections surfaced to the App Intent layer.
/// The display strings keep the legacy Shortcuts copy; no internal identifier
/// reaches the user. Shared with `AppEnvironment.ensureReadyForExternalAutomation`.
enum FloeShortcutRunError: Error, Equatable, Sendable, LocalizedError {
    case shortcutsCapabilityDisabled
    case applicationStillStarting
    case durableStorageUnavailable
    case modelConfigurationUnavailable
    case emptyTaskPrompt
    case noDefaultModelConfigured

    var errorDescription: String? {
        switch self {
        case .shortcutsCapabilityDisabled:
            "Shortcuts is disabled in Floe Settings"
        case .applicationStillStarting:
            "Floe is still starting; retry the shortcut"
        case .durableStorageUnavailable:
            "Durable storage is unavailable. Retry after Floe finishes launching"
        case .modelConfigurationUnavailable:
            "Floe could not read the saved model configuration. Check Floe Settings"
        case .emptyTaskPrompt:
            "Task must not be empty"
        case .noDefaultModelConfigured:
            "No default Floe model is configured"
        }
    }
}

#if canImport(AppIntents)
import AppIntents
import Foundation
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence

/// Durable FIFO inbox for the draft-style Shortcuts actions
/// (`SendToFloe` / `CreateFloeTask`).
///
/// The legacy implementation stored ONE string in
/// `UserDefaults("group.org.floeagent.ios").shortcuts.pendingDraft`; two
/// consecutive submissions overwrote the first, and consumption deleted the
/// draft before anything durable accepted it. The queue now lives in
/// FloePersistence (`shortcut_draft_inbox`) with atomic claim/ack handoff;
/// the legacy key is read exactly once by the migration below.
enum FloeShortcutInbox {
    static let suite = "group.org.floeagent.ios"
    /// Legacy single-slot key. Owned only by the one-time migration; new
    /// drafts never write it.
    static let legacyPendingDraftKey = "shortcuts.pendingDraft"
    /// Stable migration identity for ONE exact captured legacy value: a
    /// crash/retry between "durable enqueue" and "legacy key deletion"
    /// re-enqueues the SAME row and proceeds to delete the key, while a
    /// DIFFERENT value written later is a distinct entry instead of being
    /// swallowed by the old row or tombstone.
    static func legacyMigrationIdentity(for raw: String) -> String {
        "pendingDraft:" + FloeDigest.sha256Hex(Data(raw.utf8))
    }
    /// Posted after a draft is durably enqueued so an open Home surface can
    /// update its count and take the draft when the composer is free.
    static let didEnqueue = Notification.Name("floe.shortcuts.draftEnqueued")

    /// Enqueues one draft for later review in Home. Throws (and reports no
    /// success) when the Shortcuts capability is off, the draft is empty, or
    /// the app's durable stores are not reachable yet.
    static func enqueue(_ draft: String, source: ShortcutDraftInboxSource) async throws {
        try await FloeShortcutsRuntime.shared.enqueueDraft(draft, source: source)
    }

    /// Moves the legacy single-slot draft into the durable queue once. An
    /// existing draft is never overwritten: the migration lands as its own
    /// FIFO entry, identified by the exact bytes captured here. Removal of
    /// the legacy key happens only after the enqueue is durable, and only
    /// while the key still holds those same bytes; a whitespace-only legacy
    /// value carries no content and is simply cleared.
    @MainActor
    static func migrateLegacyDraft(
        into store: any ShortcutDraftInboxStore,
        defaults: UserDefaults? = nil
    ) async throws {
        let defaults = defaults ?? UserDefaults(suiteName: suite)
        guard let defaults,
              let raw = defaults.string(forKey: legacyPendingDraftKey) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            _ = try await store.enqueue(
                text: text, source: .legacyMigration,
                migrationKey: legacyMigrationIdentity(for: raw)
            )
        }
        // Remove ONLY the exact value this call migrated. If a concurrent
        // legacy writer replaced the key while the enqueue awaited, that newer
        // value is not ours to delete; a later migration call queues it.
        if defaults.string(forKey: legacyPendingDraftKey) == raw {
            defaults.removeObject(forKey: legacyPendingDraftKey)
        }
    }
}

#if DEBUG
/// Hosted-test persistence context for the ACTUAL draft intents.
///
/// It lets `SendToFloeIntent` / `CreateFloeTaskIntent` run their real
/// `perform()` → runtime → readiness → queue path against an isolated inbox,
/// throwaway legacy defaults and a private NotificationCenter. It never
/// changes the real capability preferences, the app-owned queue, App Group
/// defaults, Home's draft or the default NotificationCenter, and the whole
/// seam (including this type) is compiled out of Release builds.
///
/// Scoping is per TASK (`@TaskLocal` below), never process-global: an
/// unrelated concurrent Send/Create cannot be routed into fixture storage
/// while a test awaits, and the test's `perform()` sequence cannot capture
/// concurrent real input. The value is only read/written from `@MainActor`
/// code, so it carries no cross-isolation use despite its test-only fields.
struct FloeDraftEnqueueDebugContext: @unchecked Sendable {
    let inbox: any ShortcutDraftInboxStore
    let legacyDefaults: UserDefaults
    let notifications: NotificationCenter
    let shortcutsEnabled: () -> Bool
}
#endif

/// App Intents are launched by the system, sometimes without presenting the
/// app. Keep the intent layer thin and route all durable work through the same
/// stores/services used by Floe's UI and background scheduler.
@MainActor
final class FloeShortcutsRuntime {
    static let shared = FloeShortcutsRuntime()

    #if DEBUG
    /// Task-scoped by one hosted test via `$debugDraftEnqueueContext
    /// .withValue`; there is deliberately no process-global install path.
    @TaskLocal static var debugDraftEnqueueContext: FloeDraftEnqueueDebugContext?
    #endif

    private weak var environment: AppEnvironment?

    private init() {}

    func install(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Durable FIFO enqueue shared by the draft-style intents. Every failure
    /// throws — the Shortcuts run then honestly shows failure and the user
    /// can retry; nothing is acknowledged that was not persisted.
    ///
    /// A draft needs durable storage, not a configured model: joining the ONE
    /// shared launch migration makes the queue table reachable on a cold
    /// App-Intent entry without requiring provider readiness. The same
    /// single-flight bootstrap used by `run`/`schedule` runs at most once per
    /// process; no second environment or store graph is created here.
    func enqueueDraft(_ draft: String, source: ShortcutDraftInboxSource) async throws {
        #if DEBUG
        let debugContext = Self.debugDraftEnqueueContext
        let shortcutsEnabled = debugContext?.shortcutsEnabled()
            ?? AppleCapabilityPreferences.isEnabled(.shortcuts)
        #else
        let shortcutsEnabled = AppleCapabilityPreferences.isEnabled(.shortcuts)
        #endif
        guard shortcutsEnabled else {
            throw FloeError.invalidConfiguration("Shortcuts is disabled in Floe Settings")
        }
        guard let environment else {
            throw FloeError.invalidConfiguration("Floe is still starting; retry the shortcut")
        }
        let cleanDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDraft.isEmpty else {
            throw FloeError.validationFailed("Task must not be empty")
        }
        try Task.checkCancellation()
        await environment.bootstrap()
        try Task.checkCancellation()
        guard !environment.isEphemeral,
              environment.persistenceReady,
              environment.bootstrapError == nil else {
            throw FloeShortcutRunError.durableStorageUnavailable
        }
        #if DEBUG
        if let debugContext {
            // The real readiness path above already ran on the launched App
            // graph; only the durable destination is task-scoped.
            try await FloeShortcutInbox.migrateLegacyDraft(
                into: debugContext.inbox, defaults: debugContext.legacyDefaults
            )
            try Task.checkCancellation()
            _ = try await debugContext.inbox.enqueue(
                text: cleanDraft, source: source, migrationKey: nil
            )
            debugContext.notifications.post(name: FloeShortcutInbox.didEnqueue, object: nil)
            return
        }
        #endif
        let store = SQLiteShortcutDraftInboxStore(database: environment.database)
        try await FloeShortcutInbox.migrateLegacyDraft(into: store)
        // The legacy migration awaited a durable write: re-check the caller
        // before appending THIS new draft. A cancelled Shortcuts run must not
        // enqueue after its awaited work, while the migrated legacy draft
        // (already durable) stays safely queued.
        try Task.checkCancellation()
        _ = try await store.enqueue(text: cleanDraft, source: source, migrationKey: nil)
        NotificationCenter.default.post(name: FloeShortcutInbox.didEnqueue, object: nil)
    }

    func run(prompt: String, title: String?) async throws -> UUID {
        guard AppleCapabilityPreferences.isEnabled(.shortcuts) else {
            throw FloeError.invalidConfiguration("Shortcuts is disabled in Floe Settings")
        }
        guard let environment else {
            throw FloeError.invalidConfiguration("Floe is still starting; retry the shortcut")
        }
        // Headless App-Intent launches have no RootView: join the ONE shared
        // launch/readiness task instead of assuming the UI already ran
        // bootstrap. Concurrent triggers join the same work; durable failures
        // stay honest, configuration failures are retried on the next call,
        // and a cancelled caller stops before creating any run.
        try await environment.ensureReadyForExternalAutomation()
        try Task.checkCancellation()
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
        // Same shared readiness as `run`: scheduling freezes the CURRENT
        // default model/permission binding, so it must observe the fully
        // loaded configuration even when launched headlessly.
        try await environment.ensureReadyForExternalAutomation()
        try Task.checkCancellation()
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else {
            throw FloeError.validationFailed("Task must not be empty")
        }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The SAME trusted creation-time factory as the model-facing
        // `task.schedule`/`apple.automation.update` tools: the schedule freezes
        // the current default model and approval policy instead of leaving nil
        // bindings that a later settings change could silently redefine.
        guard let binding = environment.appDefaultTaskScheduleBinding() else {
            throw FloeError.invalidConfiguration("No default Floe model is configured")
        }
        let record = TaskScheduleRecord(
            title: cleanTitle?.isEmpty == false ? cleanTitle! : String(cleanPrompt.prefix(40)),
            prompt: cleanPrompt,
            workspaceID: binding.workspaceID,
            cadence: cadence.taskCadence,
            scheduledAt: date,
            weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: date) : nil,
            anchorTimezone: binding.anchorTimezone,
            modelID: binding.modelID,
            environmentID: binding.environmentID,
            permissionJSON: binding.permissionJSON
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
    static let supportedModes: IntentModes = .foreground
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
        try await FloeShortcutInbox.enqueue(task, source: .intentSend)
        return .result(value: FloeL10n.l("shortcuts.intent.send_to_floe.result_placed"))
    }
}

/// Creates a new task in Floe Agent.
struct CreateFloeTaskIntent: AppIntent {
    static let supportedModes: IntentModes = .foreground
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
        try await FloeShortcutInbox.enqueue(taskDescription, source: .intentCreate)
        return .result()
    }
}

/// Starts a durable Floe run without opening the UI. This is the action users
/// place in a Shortcuts personal automation (time of day, focus, arrival,
/// etc.). The intent returns once the conversation/run has been persisted and
/// provider execution has been scheduled.
struct RunFloeTaskIntent: AppIntent {
    static let supportedModes: IntentModes = .background
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
    static let supportedModes: IntentModes = .background
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
        AppShortcut(
            intent: RunScheduledTaskIntent(),
            phrases: [
                "运行 \(.applicationName) 定时任务",
                "执行 \(.applicationName) 日程",
                "Run a scheduled task with \(.applicationName)",
                "Run \(.applicationName) schedule now"
            ],
            shortTitle: "shortcuts.app_shortcut.run_scheduled_task",
            systemImageName: "calendar.badge.checkmark"
        )
    }
}
#endif
