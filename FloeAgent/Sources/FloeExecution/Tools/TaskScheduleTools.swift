// FloeExecution — `task.schedule` service interface.
//
// One tool group owns the scheduled-task lifecycle for the model:
// list / create / update / enable / disable / delete / runNow / history /
// finishCurrent.
// It is a THIN service over the existing durable `SQLiteTaskScheduleStore`
// (the same store Shortcuts, the Apple automation tools and the Home sheet
// use — no second manager), so the atomic occurrence ledger, the stable
// logical occurrence ids and the after-success bindings are shared truth.
//
// `finishCurrent` is the model's explicit "the whole recurring goal is done"
// action: it resolves the plan that owns THIS run through the actual
// occurrence ledger (`run_id`), never from a model-supplied id, and disables
// that plan while keeping its record and history. A successful run by itself
// never disables a recurring plan — only this deliberate call or the user does.
//
// Approval stays with the shared runtime policy: the descriptor is mutating
// with persisted-personal-data / agent-behavior risk labels, so the ordinary
// approval path applies and the temporary-chat read-only ceiling excludes it
// automatically (it is not in `verifiedActionPolicies`). The tool never mints
// permissions or grants for the spawned task; a scheduled run executes under
// the permission binding stored on its record (`permissionJSON`) or the app
// default, revalidated at execution.
//
// Registration is central (AppEnvironment); `registerTaskScheduleTools`
// mirrors `registerBackgroundJobTools`. `onScheduleDue` lets the app trigger
// an immediate pass after runNow/enable when it can (the coordinator owns
// execution); nil keeps the next-wakeup semantics.

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

/// Trusted bindings frozen onto a schedule at creation. The APP resolves
/// them from the ACTUAL run context — the submitting task's policy, workspace,
/// environment and model — never from model arguments. A build without a
/// resolver refuses `create` rather than freezing empty bindings.
public struct TaskScheduleBinding: Sendable {
    public var workspaceID: UUID?
    public var environmentID: String?
    public var modelID: UUID?
    /// Encoded `DraftTaskPolicy` derived from the parent task's actual policy.
    public var permissionJSON: String?
    /// Calendar anchor for daily/weekly cadences (defaults to the current
    /// timezone when nil).
    public var anchorTimezone: String?
    /// The ordinary conversation the submitting task belongs to. The tool
    /// falls back to the trusted `ToolContext.conversationID` when the
    /// resolver leaves it nil, so a plan created from a chat is linked to that
    /// chat by its real origin rather than by a title or a later occurrence.
    public var originConversationID: UUID?

    public init(
        workspaceID: UUID? = nil,
        environmentID: String? = nil,
        modelID: UUID? = nil,
        permissionJSON: String? = nil,
        anchorTimezone: String? = nil,
        originConversationID: UUID? = nil
    ) {
        self.workspaceID = workspaceID
        self.environmentID = environmentID
        self.modelID = modelID
        self.permissionJSON = permissionJSON
        self.anchorTimezone = anchorTimezone
        self.originConversationID = originConversationID
    }
}

/// App-injected resolver for trusted schedule bindings. Called with the
/// submitting tool context; returns nil when no trusted binding can be
/// established (the tool then refuses to create).
public typealias TaskScheduleBindingResolver = @Sendable (ToolContext) async -> TaskScheduleBinding?

public struct TaskScheduleTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var id: String?
        public var title: String?
        public var prompt: String?
        public var cadence: String?
        public var scheduledAt: String?
        public var intervalHours: Int?
        public var intervalSeconds: Int?
        /// For afterSuccess: the CONCRETE upstream run whose successful
        /// completion fires this schedule exactly once.
        public var upstreamRunID: String?
        public var enable: Bool?
        public var limit: Int?

        public init(
            action: String,
            id: String? = nil,
            title: String? = nil,
            prompt: String? = nil,
            cadence: String? = nil,
            scheduledAt: String? = nil,
            intervalHours: Int? = nil,
            intervalSeconds: Int? = nil,
            upstreamRunID: String? = nil,
            enable: Bool? = nil,
            limit: Int? = nil
        ) {
            self.action = action
            self.id = id
            self.title = title
            self.prompt = prompt
            self.cadence = cadence
            self.scheduledAt = scheduledAt
            self.intervalHours = intervalHours
            self.intervalSeconds = intervalSeconds
            self.upstreamRunID = upstreamRunID
            self.enable = enable
            self.limit = limit
        }
    }

    public static let name = "task.schedule"
    public static let toolDescription = """
    Manage this app's scheduled tasks (the same store the user sees on Home). \
    Actions: list, create, update, enable, disable, delete, runNow, history, \
    finishCurrent. \
    Cadences: once, daily, weekly, interval (fixed absolute duration; pass \
    intervalHours or intervalSeconds), afterSuccess (fires exactly once after \
    the selected upstream task's run completes SUCCESSFULLY; it is bound to \
    that concrete upstream run, never to every future round and never to a \
    delegated child's completion). Daily/weekly times are anchored to the \
    device calendar/timezone at save time. Missed occurrences coalesce to the \
    most recent one. runNow adds an independent manual occurrence and never \
    consumes or advances the planned next run. finishCurrent disables the plan \
    that owns the CURRENT run (resolved from the actual execution ledger, no id \
    needed); use it only when the whole recurring goal is genuinely complete — \
    an ordinary successful run does not end a recurring plan. A schedule with \
    no permission binding runs under the app default; this tool never grants \
    permissions. iOS schedules are best-effort: a due task may run late or be \
    reported as pending.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["list","create","update","enable","disable","delete","runNow","history","finishCurrent"]},"id":{"type":"string","description":"Schedule UUID (required for update/enable/disable/delete/runNow/history)"},"title":{"type":"string","maxLength":200},"prompt":{"type":"string","maxLength":8000,"description":"The task instruction that will run (required on create)"},"cadence":{"type":"string","enum":["once","daily","weekly","interval","afterSuccess"]},"scheduledAt":{"type":"string","description":"ISO-8601 start/anchor time"},"intervalHours":{"type":"integer","minimum":1,"maximum":8760},"intervalSeconds":{"type":"integer","minimum":60},"upstreamRunID":{"type":"string","description":"For afterSuccess: the concrete upstream run UUID whose SUCCESSFUL completion triggers this schedule exactly once (select the current run from the task you want to follow)"},"enable":{"type":"boolean"},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["action"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .changesAgentBehavior]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let store: SQLiteTaskScheduleStore
    private let onScheduleDue: (@Sendable () async -> Void)?
    private let bindingResolver: TaskScheduleBindingResolver?

    public init(
        store: SQLiteTaskScheduleStore,
        onScheduleDue: (@Sendable () async -> Void)? = nil,
        bindingResolver: TaskScheduleBindingResolver? = nil
    ) {
        self.store = store
        self.onScheduleDue = onScheduleDue
        self.bindingResolver = bindingResolver
    }

    public func validate(_ args: Arguments) throws {
        let actions: Set<String> = [
            "list", "create", "update", "enable", "disable", "delete",
            "runNow", "history", "finishCurrent",
        ]
        guard actions.contains(args.action) else {
            throw FloeError.validationFailed("Unsupported task.schedule action '\(args.action)'")
        }
        let needsID: Set<String> = ["update", "enable", "disable", "delete", "runNow", "history"]
        if needsID.contains(args.action) {
            guard let raw = args.id, UUID(uuidString: raw) != nil else {
                throw FloeError.validationFailed("A valid schedule id is required for \(args.action)")
            }
        }
        if args.action == "create" {
            let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else { throw FloeError.validationFailed("prompt is required for create") }
        }
        if let cadence = args.cadence, TaskScheduleCadence(rawValue: cadence) == nil {
            throw FloeError.validationFailed("Unknown cadence '\(cadence)'")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        switch args.action {
        case "list":
            let schedules = try await store.schedules()
            let owning = try? await store.occurrence(runID: context.runID)
            let ownerLine = owning.map {
                "owningSchedule=\($0.scheduleID.uuidString)"
                    + " owningOccurrence=\($0.id.uuidString)\n"
            } ?? ""
            return output(ownerLine + schedules.prefix(200).map(describe).joined(separator: "\n"))
        case "finishCurrent":
            // The plan is resolved from THIS run's actual occurrence row, not
            // from a model-supplied id, so a model can only end the plan that
            // really owns the current scheduled task. Disabling keeps the
            // record and every history row; a currently running instance keeps
            // its own Stop.
            guard let occurrence = try await store.occurrence(runID: context.runID) else {
                throw FloeError.validationFailed(
                    "This run is not a scheduled occurrence; there is no owning plan to finish.")
            }
            try await store.setEnabled(id: occurrence.scheduleID, enabled: false, at: Date())
            await onScheduleDue?()
            return output(
                "status=ok action=finishCurrent id=\(occurrence.scheduleID.uuidString)"
                    + " occurrence=\(occurrence.id.uuidString)"
                    + " enabled=false note=history is retained; an ordinary successful run does not end a plan")
        case "history":
            guard let id = UUID(uuidString: args.id ?? "") else {
                throw FloeError.validationFailed("A valid schedule id is required")
            }
            let occurrences = try await store.occurrences(
                scheduleID: id, limit: max(1, min(args.limit ?? 20, 100)))
            let lines = occurrences.map { occurrence in
                "id=\(occurrence.id.uuidString) state=\(occurrence.state.rawValue)"
                    + " scheduledFor=\(ISO8601DateFormatter().string(from: occurrence.scheduledFor))"
                    + (occurrence.runID.map { " run=\($0.uuidString)" } ?? "")
                    + (occurrence.summary.map { " summary=\(String($0.prefix(160)))" } ?? "")
                    + (occurrence.errorText.map { " error=\(String($0.prefix(160)))" } ?? "")
            }
            return output("status=ok count=\(lines.count)\n" + lines.joined(separator: "\n"))
        case "delete":
            guard let id = UUID(uuidString: args.id ?? "") else {
                throw FloeError.validationFailed("A valid schedule id is required")
            }
            try await store.delete(id: id)
            // The shared pass reconciles the insurance-reminder set (a
            // deleted schedule must not keep a pre-registered reminder).
            await onScheduleDue?()
            return output("status=ok action=delete id=\(id.uuidString) note=run history is retained")
        case "enable", "disable":
            guard let id = UUID(uuidString: args.id ?? "") else {
                throw FloeError.validationFailed("A valid schedule id is required")
            }
            let enable = args.action == "enable" ? true : (args.enable ?? false)
            try await store.setEnabled(id: id, enabled: enable, at: Date())
            // Both directions run the shared pass: enable registers/refreshes
            // the reminder set and executes a genuinely due instance; disable
            // removes the stale reminder of a schedule that can no longer run.
            await onScheduleDue?()
            let record = try await store.schedule(id: id)
            return output("status=ok action=\(args.action) id=\(id.uuidString) enabled=\(record?.isEnabled ?? enable) next=\(record?.nextExpectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")")
        case "runNow":
            guard let id = UUID(uuidString: args.id ?? ""),
                  let occurrence = try await store.runNow(id: id, at: Date()) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            await onScheduleDue?()
            return output("status=ok action=runNow id=\(id.uuidString) occurrence=\(occurrence.id.uuidString) state=\(occurrence.state.rawValue)")
        case "create", "update":
            return try await createOrUpdate(args, context: context)
        default:
            throw FloeError.validationFailed("Unsupported task.schedule action '\(args.action)'")
        }
    }

    private func createOrUpdate(
        _ args: Arguments,
        context: ToolContext?
    ) async throws -> ToolExecutionOutput {
        var record: TaskScheduleRecord
        if args.action == "update" {
            guard let id = UUID(uuidString: args.id ?? ""),
                  let current = try await store.schedule(id: id) else {
                throw FloeError.validationFailed("No schedule with that id")
            }
            record = current
        } else {
            let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) ?? .once
            let anchor = try Self.parseDate(args.scheduledAt) ?? Date().addingTimeInterval(300)
            // Bindings are frozen at creation from the APP's trusted resolver
            // (the actual run's task policy, workspace, environment and
            // model). The model cannot choose them; a build without the
            // resolver refuses to create a schedule rather than freezing
            // empty bindings that would silently run under later defaults.
            guard let resolver = bindingResolver, let context,
                  let binding = await resolver(context) else {
                throw FloeError.validationFailed(
                    "Scheduled tasks require the app's trusted binding resolver; no schedule was created.")
            }
            record = TaskScheduleRecord(
                title: args.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? String(prompt.prefix(40)),
                prompt: prompt,
                workspaceID: binding.workspaceID,
                cadence: cadence,
                scheduledAt: anchor,
                weekday: cadence == .weekly ? Calendar.current.component(.weekday, from: anchor) : nil,
                isEnabled: args.enable ?? true,
                intervalSeconds: args.intervalSeconds ?? args.intervalHours.map { $0 * 3_600 },
                anchorTimezone: binding.anchorTimezone ?? TimeZone.current.identifier,
                upstreamRunID: args.upstreamRunID.flatMap(UUID.init(uuidString:)),
                modelID: binding.modelID,
                environmentID: binding.environmentID,
                permissionJSON: binding.permissionJSON,
                // TRUSTED origin only: the app resolver's value, or the
                // submitting run's own conversation from the runtime context.
                // Never a model argument, title guess or later occurrence.
                originConversationID: binding.originConversationID ?? context.conversationID
            )
        }
        if let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            record.title = title
        }
        if let prompt = args.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            record.prompt = prompt
        }
        if let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)) {
            record.cadence = cadence
        }
        if let anchor = try Self.parseDate(args.scheduledAt) {
            record.scheduledAt = anchor
            record.nextExpectedAt = anchor
        }
        if let seconds = args.intervalSeconds {
            record.intervalSeconds = seconds
        } else if let hours = args.intervalHours {
            record.intervalSeconds = hours * 3_600
        }
        if let upstream = args.upstreamRunID.flatMap(UUID.init(uuidString:)) {
            record.upstreamRunID = upstream
        }
        if let enable = args.enable { record.isEnabled = enable }
        // Stale-binding cleanup: a schedule that no longer uses after-success
        // cadence must not keep an upstream_run_id (the store's completion
        // path additionally filters by cadence, so an edit can never fire a
        // regular cadence from an unrelated run).
        if record.cadence != .afterSuccess {
            record.upstreamRunID = nil
        }
        record.weekday = record.cadence == .weekly
            ? Calendar.current.component(.weekday, from: record.scheduledAt)
            : nil
        if record.cadence == .interval,
           (record.intervalSeconds ?? 0) < 60 {
            throw FloeError.validationFailed("interval cadence requires intervalSeconds >= 60")
        }
        if record.cadence == .afterSuccess, record.upstreamRunID == nil {
            throw FloeError.validationFailed("afterSuccess cadence requires upstreamRunID")
        }
        record.updatedAt = Date()
        record.nextExpectedAt = record.cadence == .afterSuccess
            ? nil
            : (TaskSchedulePlanner.nextFireTime(after: Date(), record: record) ?? record.scheduledAt)
        try await store.save(record)
        if record.isEnabled, record.nextExpectedAt != nil {
            await onScheduleDue?()
        }
        return output(
            "status=ok action=\(args.action) id=\(record.id.uuidString) cadence=\(record.cadence.rawValue)"
                + " enabled=\(record.isEnabled)"
                + " next=\(record.nextExpectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"
                + " boundModel=\(record.modelID?.uuidString ?? "creation-time default")"
                + " boundEnvironment=\(record.environmentID ?? "creation-time resolution")"
                + " upstreamRun=\(record.upstreamRunID?.uuidString ?? "none")"
                + " bestEffort=true")
    }

    private func describe(_ record: TaskScheduleRecord) -> String {
        "id=\(record.id.uuidString) enabled=\(record.isEnabled) cadence=\(record.cadence.rawValue)"
            + " next=\(record.nextExpectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"
            + " last=\(record.lastStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")"
            + " upstreamRun=\(record.upstreamRunID?.uuidString ?? "none")"
            + " originConversation=\(record.originConversationID?.uuidString ?? "none")"
            + " model=\(record.modelID?.uuidString ?? "default")"
            + " title=\(String(record.title.prefix(120)))"
    }

    private static func parseDate(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        throw FloeError.validationFailed("scheduledAt must be an ISO-8601 timestamp")
    }

    private func output(_ summary: String) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8))
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Registers the `task.schedule` tool. Call from the central tool-registration
/// site (`AppEnvironment.registerAllAgentTools`) after the database is
/// available. `onScheduleDue` should trigger the app's schedule pass (the
/// coordinator owns execution); nil keeps next-wakeup semantics.
@discardableResult
public func registerTaskScheduleTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    onScheduleDue: (@Sendable () async -> Void)? = nil,
    bindingResolver: TaskScheduleBindingResolver? = nil
) -> TaskScheduleTool {
    let tool = TaskScheduleTool(
        store: SQLiteTaskScheduleStore(database: database),
        onScheduleDue: onScheduleDue,
        bindingResolver: bindingResolver)
    ToolCatalog.register(TaskScheduleTool.self)
    registry.register(tool)
    return tool
}
