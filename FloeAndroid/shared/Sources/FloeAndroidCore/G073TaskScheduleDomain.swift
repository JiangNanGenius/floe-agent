// SPDX-License-Identifier: MPL-2.0
//
// G07.3B — REAL independent scheduled Agent tasks (Android App).
//
// This is the ONE scheduling authority above the already-linked
// `TaskScheduleRecord` / `TaskSchedulePlanner` / `SQLiteTaskScheduleStore`
// model (once/daily/weekly/interval/afterSuccess, occurrence ledger,
// claim/reconcile/recordRunCompletion). There is no second scheduler DB and
// no notification-timer substitute:
//
//   * every occurrence starts a NEW ordinary conversation through the
//     normal `RunLaunchRequest`/`SQLiteRunLaunchStore` admission (never a
//     fake send-message, UI click or parallel engine);
//   * the conversation and run identities are DERIVED deterministically
//     from the durable occurrence id, so a crash between claim and launch
//     cannot mint a second identity silently;
//   * the claim CAS is the wake-dedupe gate. Unknown in-flight outcomes are
//     reconciled as interrupted, never auto-replayed;
//   * `.afterSuccess` occurrences are created only by the store's
//     successful-upstream-run completion path (exactly once per upstream
//     run), and only a clean success triggers them;
//   * each dispatch re-resolves the frozen model and environment and
//     refuses rather than substituting a default when either disappeared.
//
// The platform layer (Android WorkManager/AlarmManager) is a transport: it
// asks this service to dispatch a due schedule and re-arms from the exact
// `nextFireAt` this planner returns. Exact wall-clock time is the default;
// a denied exact-alarm permission is a visible waiting state and only an
// explicit user choice enables flexible WorkManager (policy lives in the
// platform, the service never silently degrades).
import Foundation
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Bounds

public enum G073ScheduleLimits {
    public static let maximumPromptBytes = 16_384
    public static let maximumTitleBytes = 160
    public static let maximumPolicyJSONBytes = 4_096
    public static let maximumTimezoneBytes = 64
    public static let maximumScheduleList = 50
    public static let maximumHistoryItems = 50
    public static let maximumPendingDispatch = 3
    /// Bounded after-success upstream-run picker. The host projects at most
    /// this many recent TOP-LEVEL durable runs from the SAME run store the
    /// scheduler already uses; no second database is introduced.
    public static let maximumRunChoices = 20
    public static let maximumOnceRetries = 3
    public static let occurrenceTextBytes = 240
    public static let maximumRunReference = 64
}

// MARK: - Policy binding (DraftTaskPolicy ONLY)

/// The schedule's permission binding is EXACTLY the existing
/// `DraftTaskPolicy` triple (approval mode, recovery policy, notification
/// policy). It is NOT a per-tool grant snapshot and never widens any tool
/// ceiling: dispatch re-enters the normal run admission, whose permission
/// system remains authoritative. Unknown keys are refused so a stored
/// object can never masquerade as a wider grant set.
public enum G073SchedulePolicyCodec {
    public static let allowedKeys: Set<String> = [
        "approvalMode", "recoveryPolicy", "notificationPolicy",
    ]

    public static func encode(_ policy: DraftTaskPolicy) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(policy),
              data.count <= G073ScheduleLimits.maximumPolicyJSONBytes else {
            return #"{"approvalMode":"ask","notificationPolicy":"stages","recoveryPolicy":"safePoint"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `nil` keeps the ordinary settings default at execution (the historical
    /// meaning of an unbound policy). A malformed or widened object is a
    /// typed refusal, never a silent default.
    public static func decode(_ raw: String?) -> DraftTaskPolicy? {
        guard let raw, !raw.isEmpty else { return DraftTaskPolicy() }
        guard raw.utf8.count <= G073ScheduleLimits.maximumPolicyJSONBytes,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == allowedKeys else { return nil }
        func rawValue(_ key: String) -> String? {
            guard let value = object[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        guard let approvalRaw = rawValue("approvalMode"),
              let approval = TaskApprovalMode(rawValue: approvalRaw),
              let recoveryRaw = rawValue("recoveryPolicy"),
              let recovery = TaskRecoveryPolicy(rawValue: recoveryRaw),
              let notificationRaw = rawValue("notificationPolicy"),
              let notification = TaskNotificationPolicy(rawValue: notificationRaw)
        else { return nil }
        return DraftTaskPolicy(approvalMode: approval,
                               recoveryPolicy: recovery,
                               notificationPolicy: notification)
    }
}

// MARK: - Trusted display/binding values

public struct G073WorkspaceSummary: Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: WorkspaceKind
    public init(id: UUID, name: String, kind: WorkspaceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct G073ModelSummary: Sendable, Equatable {
    public var id: UUID
    public var providerID: UUID
    public var displayName: String
    public var providerName: String
    public var supportsChat: Bool
    public init(id: UUID, providerID: UUID, displayName: String,
                providerName: String, supportsChat: Bool) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.providerName = providerName
        self.supportsChat = supportsChat
    }
}

/// One durable TOP-LEVEL ordinary run as the host's EXISTING run store
/// projected it. This is metadata only: it carries no prompt, output or
/// credential content, and a delegated child run never appears here (children
/// live in their own store). The after-success picker lists only rows whose
/// state can still reach a successful terminal.
public struct G073ScheduleRecentRun: Sendable, Equatable {
    public var id: UUID
    public var conversationID: UUID
    public var conversationTitle: String
    public var state: String
    public var startedAt: Date

    public init(id: UUID, conversationID: UUID, conversationTitle: String,
                state: String, startedAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.conversationTitle = conversationTitle
        self.state = state
        self.startedAt = startedAt
    }
}

/// The closed run-state vocabulary that can still precede a successful
/// completion. Both the picker projection and `validateDraft` use this ONE
/// predicate so the UI can never offer a binding the service will refuse.
public enum G073ScheduleRunSelection {
    /// Terminal or already-settled outcomes: an after-success schedule bound
    /// to one of these could never fire.
    public static let unsatisfiableStates: Set<String> = [
        "completed", "failed", "cancelled", "interrupted",
        "checkpointed", "idle",
    ]

    public static func canStillSucceed(_ state: String) -> Bool {
        !unsatisfiableStates.contains(state)
    }
}


/// Deterministic occurrence-derived identities. One logical occurrence can
/// only ever address one conversation/run pair, so a crash-recovery retry
/// cannot silently launch a second independent task under the same wake.
public enum G073ScheduleIdentity {
    public static func digestUUID(_ text: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(Data(text.utf8)).prefix(32))
        guard hex.count == 32 else { return UUID() }
        let value = String(hex)
        let formatted = [
            value.prefix(8),
            value.dropFirst(8).prefix(4),
            value.dropFirst(12).prefix(4),
            value.dropFirst(16).prefix(4),
            value.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }

    public static func conversationID(occurrenceID: UUID) -> UUID {
        digestUUID("floe.schedule.conversation:\(occurrenceID.uuidString.lowercased())")
    }

    public static func runID(occurrenceID: UUID) -> UUID {
        digestUUID("floe.schedule.run:\(occurrenceID.uuidString.lowercased())")
    }
}

/// The internal-only scheduled launch identity. The ordinary wire grammar
/// never accepts caller-chosen conversation/run ids; this value is built by
/// `FacadeRunDomain.startScheduled` from the durable occurrence identity.
public struct RunScheduledLaunchIdentity: Sendable, Equatable {
    public var occurrenceID: UUID
    public var conversationID: UUID
    public var runID: UUID
    /// nil = mint a new independent private workspace in the launch txn.
    public var workspaceID: UUID?
    public var conversationTitle: String
    public var environmentMetadata: G073EnvironmentMetadata?

    public init(occurrenceID: UUID, conversationID: UUID, runID: UUID,
                workspaceID: UUID?, conversationTitle: String,
                environmentMetadata: G073EnvironmentMetadata?) {
        self.occurrenceID = occurrenceID
        self.conversationID = conversationID
        self.runID = runID
        self.workspaceID = workspaceID
        self.conversationTitle = conversationTitle
        self.environmentMetadata = environmentMetadata
    }
}

/// Stable CAS token for one schedule row. Uses the canonical record encoding
/// (sorted keys, millisecond dates) so the App can refuse a stale edit
/// instead of overwriting a concurrent change.
public enum G073ScheduleRevision {
    /// ONE canonical encoding, shared with the persistence CAS so the store can
    /// compare the expected revision inside the same writer transaction
    /// (`TaskScheduleRevisionDigest` in FloePersistence).
    public static func digest(_ record: TaskScheduleRecord) -> String {
        TaskScheduleRevisionDigest.digest(record)
    }

    public static func resourceID(scheduleID: UUID) -> String {
        "schedule.\(scheduleID.uuidString.uppercased())"
    }
}

// MARK: - Launch seam (the real run domain)

/// One scheduled launch request. `conversationID`/`runID` are already the
/// deterministic occurrence identities; `workspaceID` is the frozen project
/// workspace this schedule always uses (the launch transaction then mints the
/// canonical workspace policy/ownership). `environmentMetadata` is the exact
/// host-read authority row for this dispatch, when an environment is bound.
public struct G073ScheduledLaunchRequest: Sendable {
    public var occurrenceID: UUID
    public var conversationID: UUID
    public var runID: UUID
    /// nil means the launch transaction mints a NEW independent private
    /// workspace for this occurrence (never a reused private task).
    public var workspaceID: UUID?
    public var title: String
    public var prompt: String
    public var providerID: UUID
    public var modelID: UUID
    public var environmentID: String?
    public var environmentMetadata: G073EnvironmentMetadata?
    public var policy: DraftTaskPolicy

    public init(occurrenceID: UUID, conversationID: UUID, runID: UUID,
                workspaceID: UUID?, title: String, prompt: String,
                providerID: UUID, modelID: UUID, environmentID: String?,
                environmentMetadata: G073EnvironmentMetadata?,
                policy: DraftTaskPolicy) {
        self.occurrenceID = occurrenceID
        self.conversationID = conversationID
        self.runID = runID
        self.workspaceID = workspaceID
        self.title = title
        self.prompt = prompt
        self.providerID = providerID
        self.modelID = modelID
        self.environmentID = environmentID
        self.environmentMetadata = environmentMetadata
        self.policy = policy
    }
}

public struct G073ScheduledLaunchResult: Sendable {
    public var accepted: Bool
    public var code: String
    public var reason: String
    public init(accepted: Bool, code: String = "", reason: String = "") {
        self.accepted = accepted
        self.code = code
        self.reason = reason
    }
    public static func accepted() -> G073ScheduledLaunchResult {
        G073ScheduledLaunchResult(accepted: true)
    }
    public static func refused(code: String, reason: String) -> G073ScheduledLaunchResult {
        G073ScheduledLaunchResult(accepted: false, code: code, reason: reason)
    }
}

/// Implemented once, in `G02DomainServices`, over the accepted
/// `FacadeRunDomain.startScheduled` entry.
public protocol G073ScheduledRunLaunching: Sendable {
    func launchScheduled(_ request: G073ScheduledLaunchRequest) async -> G073ScheduledLaunchResult
}

/// Terminal completion hook bound into `RunDomainComponents`. Only real
/// top-level ordinary run retirement calls it; child/future conversation
/// rounds cannot.
public protocol G073ScheduleCompletionRecording: Sendable {
    func runTerminal(runID: UUID, succeeded: Bool, cancelled: Bool,
                     summary: String?, at date: Date) async
}

// MARK: - Dependencies (all trusted, host-bound)

public struct G073TaskScheduleDependencies: Sendable {
    public var launch: any G073ScheduledRunLaunching
    /// Conversation → canonical workspace owner (existing conversation proof).
    public var workspaceForConversation: @Sendable (UUID) async -> UUID?
    /// Only `.project` workspaces can be frozen on a schedule.
    public var workspace: @Sendable (UUID) async -> G073WorkspaceSummary?
    public var workspaces: @Sendable () async -> [G073WorkspaceSummary]
    public var model: @Sendable (UUID) async -> G073ModelSummary?
    public var models: @Sendable () async -> [G073ModelSummary]
    public var defaultModelID: @Sendable () async -> UUID?
    /// Durable run state by run id (completion truth for recovery).
    public var runState: @Sendable (UUID) async -> String?
    /// Last durable terminal stop reason, or nil when absent/unreadable.
    public var terminalStopReason: @Sendable (UUID) async -> String?
    /// Claimed/running occurrence rows for cold-settlement (bounded).
    public var claimedOccurrences: @Sendable () async -> [G073ClaimedOccurrence]
    /// The host's environment authority metadata source (runtime IPC
    /// `environment.list`). Unbound keeps environment selection unavailable,
    /// never substituted.
    public var environmentSource: (any G073EnvironmentMetadataSource)?
    public var environmentOwnership: G073ScheduleEnvironmentOwnership
    public var now: @Sendable () -> Date
    /// Trusted recent TOP-LEVEL run projection, newest first, bounded by the
    /// requested limit. Bound by the composition to the EXISTING
    /// `SQLiteRunStore.recentRunSummaries` read (the same durable database the
    /// scheduler already owns). Unbound yields no choices: the UI must never
    /// invent runs, and the native validator still refuses an unavailable run.
    public var recentRunChoices: @Sendable (Int) async -> [G073ScheduleRecentRun]
    /// Durable ordinary-run → conversation binding. Only top-level runs exist
    /// in the run store; delegated children are stored separately. Used to
    /// prove an after-success upstream run belongs to the schedule's bound
    /// project. Unbound keeps the project-binding proof fail-closed.
    public var runConversation: @Sendable (UUID) async -> UUID?

    public init(launch: any G073ScheduledRunLaunching,
                workspaceForConversation: @escaping @Sendable (UUID) async -> UUID?,
                workspace: @escaping @Sendable (UUID) async -> G073WorkspaceSummary?,
                workspaces: @escaping @Sendable () async -> [G073WorkspaceSummary],
                model: @escaping @Sendable (UUID) async -> G073ModelSummary?,
                models: @escaping @Sendable () async -> [G073ModelSummary],
                defaultModelID: @escaping @Sendable () async -> UUID?,
                runState: @escaping @Sendable (UUID) async -> String?,
                terminalStopReason: @escaping @Sendable (UUID) async -> String?,
                claimedOccurrences: @escaping @Sendable () async -> [G073ClaimedOccurrence],
                environmentSource: (any G073EnvironmentMetadataSource)?,
                environmentOwnership: G073ScheduleEnvironmentOwnership,
                now: @escaping @Sendable () -> Date = { Date() },
                recentRunChoices: @escaping @Sendable (Int) async
                    -> [G073ScheduleRecentRun] = { _ in [] },
                runConversation: @escaping @Sendable (UUID) async -> UUID? = { _ in nil }) {
        self.launch = launch
        self.workspaceForConversation = workspaceForConversation
        self.workspace = workspace
        self.workspaces = workspaces
        self.model = model
        self.models = models
        self.defaultModelID = defaultModelID
        self.runState = runState
        self.terminalStopReason = terminalStopReason
        self.claimedOccurrences = claimedOccurrences
        self.environmentSource = environmentSource
        self.environmentOwnership = environmentOwnership
        self.now = now
        self.recentRunChoices = recentRunChoices
        self.runConversation = runConversation
    }
}

public struct G073ClaimedOccurrence: Sendable, Equatable {
    public var id: UUID
    public var scheduleID: UUID
    public var scheduledFor: Date
    public var runID: UUID?
    public init(id: UUID, scheduleID: UUID, scheduledFor: Date, runID: UUID?) {
        self.id = id
        self.scheduleID = scheduleID
        self.scheduledFor = scheduledFor
        self.runID = runID
    }
}

// MARK: - Read projections

public struct G073ScheduleOccurrenceSummary: Sendable, Equatable {
    public var id: UUID
    public var state: TaskScheduleOccurrenceState
    public var scheduledFor: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var runID: UUID?
    public var conversationID: UUID?
    public var summary: String?
    public var errorText: String?

    public init(_ occurrence: TaskScheduleOccurrence) {
        id = occurrence.id
        state = occurrence.state
        scheduledFor = occurrence.scheduledFor
        startedAt = occurrence.startedAt
        finishedAt = occurrence.finishedAt
        runID = occurrence.runID
        conversationID = occurrence.conversationID
        summary = occurrence.summary.map { G073ScheduleText.truncated($0) }
        errorText = occurrence.errorText.map { G073ScheduleText.truncated($0) }
    }
}

enum G073ScheduleText {
    static func truncated(_ raw: String,
                          limit: Int = G073ScheduleLimits.occurrenceTextBytes) -> String {
        guard raw.utf8.count > limit else { return raw }
        var result = ""
        var count = 0
        for character in raw {
            let bytes = String(character).utf8.count
            if count + bytes > limit { break }
            result.append(character)
            count += bytes
        }
        return result
    }
}

public struct G073ScheduleSummary: Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var promptPreview: String
    public var cadence: TaskScheduleCadence
    public var isEnabled: Bool
    public var scheduledAt: Date
    public var weekday: Int?
    public var intervalSeconds: Int?
    public var anchorTimezone: String?
    /// The exact next planner-produced wake; nil for `.afterSuccess`
    /// (event-armed) and paused schedules.
    public var nextFireAt: Date?
    public var lastStartedAt: Date?
    public var modelID: UUID?
    public var modelName: String?
    public var environmentID: String?
    public var environmentName: String?
    public var workspaceID: UUID?
    public var workspaceName: String?
    public var policy: DraftTaskPolicy
    public var upstreamRunID: UUID?
    public var revision: String
    public var lastOccurrence: G073ScheduleOccurrenceSummary?
    /// True when the last real occurrence failed/interrupted, or the frozen
    /// workspace/model/environment no longer validates. The UI surfaces this
    /// as an actionable "needs attention" state.
    public var needsAttention: Bool
}

public struct G073ScheduleDetail: Sendable, Equatable {
    public var summary: G073ScheduleSummary
    public var prompt: String
    public var createdAt: Date
    public var updatedAt: Date
    public var policyJSON: String
}

public struct G073ScheduleOptions: Sendable, Equatable {
    public struct Workspace: Sendable, Equatable {
        public var id: UUID
        public var name: String
    }
    public struct Model: Sendable, Equatable {
        public var id: UUID
        public var providerID: UUID
        public var displayName: String
        public var providerName: String
    }
    public struct Environment: Sendable, Equatable {
        public var id: String
        public var name: String
    }
    /// One REAL top-level run the after-success trigger can follow. `label`
    /// is the owning conversation's durable title (bounded), never a model or
    /// UI invention; `workspaceID` is the run's canonical project owner when
    /// it resolves, so the App can present a matching project.
    public struct RunChoice: Sendable, Equatable {
        public var runID: UUID
        public var conversationID: UUID
        public var label: String
        public var state: String
        public var startedAt: Date
        public var workspaceID: UUID?

        public init(runID: UUID, conversationID: UUID, label: String,
                    state: String, startedAt: Date, workspaceID: UUID?) {
            self.runID = runID
            self.conversationID = conversationID
            self.label = label
            self.state = state
            self.startedAt = startedAt
            self.workspaceID = workspaceID
        }
    }
    public var workspaces: [Workspace]
    public var models: [Model]
    public var environments: [Environment]
    public var upstreamRunChoices: [RunChoice]
    public var defaultModelID: UUID?
    public var currentTimezone: String
    /// False when the host has not bound the runtime environment authority
    /// listing; the UI must then be explicit that environment selection is
    /// unavailable instead of offering an invented choice.
    public var environmentSelectionAvailable: Bool
}

public struct G073ScheduleArmPlan: Sendable, Equatable {
    public var scheduleID: UUID
    public var nextFireAt: Date?
    public var cadence: TaskScheduleCadence
    public var eventDriven: Bool
    public var isEnabled: Bool
}

public enum G073ScheduleErrorCode: String, Sendable {
    case notFound
    case invalidPayload
    case titleInvalid
    case promptInvalid
    case cadenceInvalid
    case intervalInvalid
    case scheduledAtInvalid
    case timezoneInvalid
    case workspaceUnavailable
    case workspaceNotProject
    case modelUnavailable
    case environmentUnavailable
    case environmentNotProject
    case environmentSnapshotMissing
    case policyInvalid
    /// The durable record is valid but its command VALUE cannot be encoded
    /// inside the bounded bridge frame without truncating the business record
    /// (for example a prompt/control-character-heavy stored instruction). The
    /// App shows an actionable message; nothing is silently shortened.
    case payloadTooLarge
    case revisionMismatch
    case upstreamRunRequired
    case upstreamRunUnavailable
    case retryLimit
    case disabled
    case exactAlarmPermission
    case flexibleNotChosen
    case occurrenceInFlight
    case storeUnavailable
    case launchRefused
    case waitingForUpstream
    case ignored
}

public struct G073ScheduleMutationResult: Sendable {
    public var accepted: Bool
    public var code: G073ScheduleErrorCode?
    public var reason: String?
    public var detail: G073ScheduleDetail?
    public var revision: String?

    public init(accepted: Bool, code: G073ScheduleErrorCode? = nil,
                reason: String? = nil, detail: G073ScheduleDetail? = nil,
                revision: String? = nil) {
        self.accepted = accepted
        self.code = code
        self.reason = reason
        self.detail = detail
        self.revision = revision
    }

    static func refused(_ code: G073ScheduleErrorCode, _ reason: String) -> Self {
        G073ScheduleMutationResult(accepted: false, code: code, reason: reason)
    }
}

public enum G073ScheduleDispatchState: String, Sendable {
    /// The occurrence was durably queued; it starts only when the App-owned
    /// foreground-admitted dispatcher claims it. No Agent launch happens in
    /// the command that requested the run.
    case queued
    /// An explicit Stop cancelled the intended pending occurrence before any
    /// dispatcher could claim it. No Agent launch happens.
    case cancelled
    case launched
    case alreadyHandled
    case disabled
    case waiting
    case failed
}

public struct G073ScheduleDispatchOutcome: Sendable {
    public var state: G073ScheduleDispatchState
    public var scheduleID: UUID
    public var occurrenceID: UUID?
    public var runID: UUID?
    public var conversationID: UUID?
    public var nextFireAt: Date?
    public var code: G073ScheduleErrorCode?
    public var reason: String?

    public init(state: G073ScheduleDispatchState, scheduleID: UUID,
                occurrenceID: UUID? = nil, runID: UUID? = nil,
                conversationID: UUID? = nil, nextFireAt: Date? = nil,
                code: G073ScheduleErrorCode? = nil, reason: String? = nil) {
        self.state = state
        self.scheduleID = scheduleID
        self.occurrenceID = occurrenceID
        self.runID = runID
        self.conversationID = conversationID
        self.nextFireAt = nextFireAt
        self.code = code
        self.reason = reason
    }
}

// MARK: - Draft (create/update)

public struct G073ScheduleDraft: Sendable, Equatable {
    public var title: String
    public var prompt: String
    public var cadence: TaskScheduleCadence
    public var scheduledAt: Date
    public var weekday: Int?
    public var intervalSeconds: Int?
    public var anchorTimezone: String?
    public var upstreamRunID: UUID?
    /// nil means a NEW independent workspace is minted for every occurrence.
    /// A non-nil workspace must be an existing `.project` workspace; a
    /// previous private task workspace is never silently reused.
    public var workspaceID: UUID?
    public var modelID: UUID?
    /// nil resolves through the frozen project workspace at execution.
    public var environmentID: String?
    public var policy: DraftTaskPolicy

    public init(title: String, prompt: String, cadence: TaskScheduleCadence,
                scheduledAt: Date, weekday: Int? = nil,
                intervalSeconds: Int? = nil, anchorTimezone: String? = nil,
                upstreamRunID: UUID? = nil, workspaceID: UUID? = nil,
                modelID: UUID? = nil, environmentID: String? = nil,
                policy: DraftTaskPolicy = DraftTaskPolicy()) {
        self.title = title
        self.prompt = prompt
        self.cadence = cadence
        self.scheduledAt = scheduledAt
        self.weekday = weekday
        self.intervalSeconds = intervalSeconds
        self.anchorTimezone = anchorTimezone
        self.upstreamRunID = upstreamRunID
        self.workspaceID = workspaceID
        self.modelID = modelID
        self.environmentID = environmentID
        self.policy = policy
    }
}

// MARK: - Service

/// One epoch-owned scheduling service. Every command is actor-serialized;
/// the durable store remains the cross-process/cold-start authority.
public actor G073TaskScheduleService: G073ScheduleCompletionRecording {
    public nonisolated let epoch: UInt64
    private let store: any TaskScheduleStore
    private let dependencies: G073TaskScheduleDependencies

    public init(epoch: UInt64, store: any TaskScheduleStore,
                dependencies: G073TaskScheduleDependencies) {
        self.epoch = epoch
        self.store = store
        self.dependencies = dependencies
    }

    // MARK: Host environment snapshot

    /// Registers the EXACT authority rows the host just read from the
    /// runtime `environment.list` operation. Called immediately before a
    /// dispatch so admission validates a fresh row; never a second registry.
    public func registerEnvironmentMetadata(_ records: [G073EnvironmentMetadata],
                                            at date: Date? = nil) {
        dependencies.environmentOwnership.registerHostMetadata(
            records, at: date ?? dependencies.now())
    }

    // MARK: Read

    public struct G073SchedulePage: Sendable {
        public var schedules: [G073ScheduleSummary]
        /// TRUE number of schedules in the durable store (not just this page).
        public var totalCount: Int
        public init(schedules: [G073ScheduleSummary], totalCount: Int) {
            self.schedules = schedules
            self.totalCount = totalCount
        }
    }

    public func list(limit: Int = G073ScheduleLimits.maximumScheduleList) async
        -> [G073ScheduleSummary] {
        await listPage(limit: limit, offset: 0).schedules
    }

    /// One bounded page plus the true total. The platform/UI walks pages so a
    /// worst-case escape-heavy summary list never forces an oversized single
    /// command value; identifiers and records are never split across pages.
    public func listPage(limit: Int = G073ScheduleLimits.maximumScheduleList,
                         offset: Int = 0) async -> G073SchedulePage {
        let bounded = max(1, min(limit, G073ScheduleLimits.maximumScheduleList))
        let boundedOffset = max(0, min(offset, 10_000))
        let records: [TaskScheduleRecord]
        let recent: [TaskScheduleOccurrence]
        do {
            records = try await store.schedules()
            recent = try await store.recentOccurrences(limit: 200)
        } catch {
            return G073SchedulePage(schedules: [], totalCount: 0)
        }
        let now = dependencies.now()
        var lastBySchedule: [UUID: TaskScheduleOccurrence] = [:]
        for occurrence in recent where lastBySchedule[occurrence.scheduleID] == nil {
            lastBySchedule[occurrence.scheduleID] = occurrence
        }
        var result: [G073ScheduleSummary] = []
        let page = records.dropFirst(boundedOffset).prefix(bounded)
        result.reserveCapacity(page.count)
        for record in page {
            result.append(await summary(record, now: now,
                                        lastOccurrence: lastBySchedule[record.id]))
        }
        return G073SchedulePage(schedules: result, totalCount: records.count)
    }

    public func detail(id: UUID) async -> G073ScheduleDetail? {
        guard let record = try? await store.schedule(id: id) else { return nil }
        let now = dependencies.now()
        let last = (try? await store.occurrences(scheduleID: id, limit: 1))?.first
        let summary = await summary(record, now: now, lastOccurrence: last)
        return G073ScheduleDetail(
            summary: summary,
            prompt: record.prompt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            policyJSON: record.permissionJSON
                ?? G073SchedulePolicyCodec.encode(DraftTaskPolicy()))
    }

    public func history(id: UUID, limit: Int = 20) async
        -> [G073ScheduleOccurrenceSummary] {
        let bounded = max(1, min(limit, G073ScheduleLimits.maximumHistoryItems))
        guard let occurrences = try? await store.occurrences(scheduleID: id,
                                                             limit: bounded)
        else { return [] }
        return occurrences.map(G073ScheduleOccurrenceSummary.init)
    }

    public func options() async -> G073ScheduleOptions {
        let now = dependencies.now()
        let workspaceRows = await dependencies.workspaces()
        let workspaces = workspaceRows
            .filter { $0.kind == .project }
            .prefix(G073ScheduleLimits.maximumScheduleList)
            .map { G073ScheduleOptions.Workspace(id: $0.id, name: $0.name) }
        let modelRows = await dependencies.models()
        let models = modelRows
            .filter(\.supportsChat)
            .prefix(100)
            .map {
                G073ScheduleOptions.Model(id: $0.id, providerID: $0.providerID,
                                          displayName: $0.displayName,
                                          providerName: $0.providerName)
            }
        var environments: [G073ScheduleOptions.Environment] = []
        var available = false
        if let source = dependencies.environmentSource {
            let rows = await source.allEnvironmentMetadata()
            available = true
            environments = rows
                .filter { $0.kind == .project && $0.state == "active"
                    && !$0.requiresRebuild
                    && $0.executionBackend == G073EnvironmentMetadata.requiredExecutionBackend }
                .prefix(G073ScheduleLimits.maximumScheduleList)
                .map { G073ScheduleOptions.Environment(id: $0.id,
                                                       name: $0.name ?? $0.id) }
        } else {
            let rows = dependencies.environmentOwnership.allMetadata(now: now)
            if !rows.isEmpty {
                available = true
                environments = rows
                    .filter { $0.kind == .project && $0.state == "active"
                        && !$0.requiresRebuild
                        && $0.executionBackend == G073EnvironmentMetadata.requiredExecutionBackend }
                    .prefix(G073ScheduleLimits.maximumScheduleList)
                    .map { G073ScheduleOptions.Environment(id: $0.id,
                                                           name: $0.name ?? $0.id) }
            }
        }
        return G073ScheduleOptions(
            workspaces: Array(workspaces),
            models: Array(models),
            environments: Array(environments),
            upstreamRunChoices: await runChoices(),
            defaultModelID: await dependencies.defaultModelID(),
            currentTimezone: TimeZone.current.identifier,
            environmentSelectionAvailable: available)
    }

    /// Bounded after-success candidates from the REAL run store projection.
    /// Only top-level ordinary runs that can still reach a successful
    /// terminal are offered; the schedule's bound project (when any) is
    /// pre-resolved so the App can present only matching runs. Nothing here
    /// creates, mutates or replays a run.
    private func runChoices() async -> [G073ScheduleOptions.RunChoice] {
        let recent = await dependencies.recentRunChoices(
            G073ScheduleLimits.maximumRunChoices * 2)
        var seen = Set<UUID>()
        var choices: [G073ScheduleOptions.RunChoice] = []
        for row in recent.prefix(G073ScheduleLimits.maximumRunChoices * 2) {
            guard G073ScheduleRunSelection.canStillSucceed(row.state),
                  seen.insert(row.id).inserted else { continue }
            let workspaceID = await dependencies.workspaceForConversation(
                row.conversationID)
            choices.append(G073ScheduleOptions.RunChoice(
                runID: row.id,
                conversationID: row.conversationID,
                label: G073ScheduleText.truncated(row.conversationTitle, limit: 160),
                state: row.state,
                startedAt: row.startedAt,
                workspaceID: workspaceID))
            if choices.count >= G073ScheduleLimits.maximumRunChoices { break }
        }
        return choices
    }

    // MARK: Mutations

    public func create(_ draft: G073ScheduleDraft) async -> G073ScheduleMutationResult {
        let now = dependencies.now()
        guard let validated = await validateDraft(draft, now: now) else {
            return .refused(.invalidPayload, "The schedule request could not be validated.")
        }
        var record = TaskScheduleRecord(
            title: validated.title,
            prompt: validated.prompt,
            workspaceID: validated.workspaceID,
            cadence: validated.cadence,
            scheduledAt: validated.scheduledAt,
            weekday: validated.weekday,
            isEnabled: true,
            policyJSON: "{}",
            createdAt: now,
            updatedAt: now,
            intervalSeconds: validated.intervalSeconds,
            anchorTimezone: validated.anchorTimezone,
            upstreamRunID: validated.upstreamRunID,
            modelID: validated.modelID,
            environmentID: validated.environmentID,
            permissionJSON: G073SchedulePolicyCodec.encode(validated.policy))
        record.nextExpectedAt = validated.nextExpectedAt
        do {
            try await store.save(record)
        } catch {
            return .refused(.storeUnavailable, "The schedule could not be saved.")
        }
        // Align the outer revision with the ACTUAL persisted detail snapshot.
        // The in-memory `now` can carry sub-millisecond precision the row
        // encoding does not retain; returning digest(record) would not be
        // reusable as the next CAS base.
        guard let detail = await detail(id: record.id) else {
            return .refused(.storeUnavailable, "The schedule could not be read back.")
        }
        return G073ScheduleMutationResult(
            accepted: true,
            detail: detail,
            revision: detail.summary.revision)
    }

    public func update(id: UUID, draft: G073ScheduleDraft,
                       expectedRevision: String) async -> G073ScheduleMutationResult {
        guard let current = try? await store.schedule(id: id) else {
            return .refused(.notFound, "No schedule with that identifier.")
        }
        guard G073ScheduleRevision.digest(current) == expectedRevision else {
            return .refused(.revisionMismatch, "The schedule changed since it was opened.")
        }
        let now = dependencies.now()
        guard let validated = await validateDraft(draft, now: now) else {
            return .refused(.invalidPayload, "The schedule request could not be validated.")
        }
        var record = current
        record.title = validated.title
        record.prompt = validated.prompt
        record.workspaceID = validated.workspaceID
        record.cadence = validated.cadence
        record.scheduledAt = validated.scheduledAt
        record.weekday = validated.weekday
        record.intervalSeconds = validated.intervalSeconds
        record.anchorTimezone = validated.anchorTimezone
        record.upstreamRunID = validated.cadence == .afterSuccess
            ? validated.upstreamRunID : nil
        record.modelID = validated.modelID
        record.environmentID = validated.environmentID
        record.permissionJSON = G073SchedulePolicyCodec.encode(validated.policy)
        record.updatedAt = now
        record.nextExpectedAt = record.isEnabled ? validated.nextExpectedAt : nil
        // The initial read/check above is UI feedback. The FINAL write is the
        // real CAS: the store compares the CURRENT durable revision inside one
        // writer transaction and preserves a `lastStartedAt` written while
        // this validation was awaiting.
        let saved: TaskScheduleRecord?
        do {
            saved = try await store.saveIfUnchanged(
                record, expectedRevision: expectedRevision)
        } catch {
            return .refused(.storeUnavailable, "The schedule could not be saved.")
        }
        guard let saved else {
            return .refused(.revisionMismatch,
                            "The schedule changed since it was opened.")
        }
        guard let detail = await detail(id: saved.id) else {
            return .refused(.storeUnavailable, "The schedule could not be read back.")
        }
        return G073ScheduleMutationResult(
            accepted: true,
            detail: detail,
            revision: detail.summary.revision)
    }

    public func setEnabled(id: UUID, enabled: Bool,
                           expectedRevision: String) async -> G073ScheduleMutationResult {
        guard let current = try? await store.schedule(id: id) else {
            return .refused(.notFound, "No schedule with that identifier.")
        }
        guard G073ScheduleRevision.digest(current) == expectedRevision else {
            return .refused(.revisionMismatch, "The schedule changed since it was opened.")
        }
        let updated: TaskScheduleRecord?
        do {
            updated = try await store.setEnabledIfUnchanged(
                id: id, enabled: enabled, expectedRevision: expectedRevision,
                at: dependencies.now())
        } catch {
            return .refused(.storeUnavailable, "The schedule could not be updated.")
        }
        guard updated != nil else {
            return .refused(.revisionMismatch,
                            "The schedule changed since it was opened.")
        }
        guard let detail = await detail(id: id) else {
            return .refused(.storeUnavailable, "The schedule could not be read back.")
        }
        return G073ScheduleMutationResult(
            accepted: true,
            detail: detail,
            revision: detail.summary.revision)
    }

    public func delete(id: UUID, expectedRevision: String) async -> G073ScheduleMutationResult {
        guard let current = try? await store.schedule(id: id) else {
            return .refused(.notFound, "No schedule with that identifier.")
        }
        guard G073ScheduleRevision.digest(current) == expectedRevision else {
            return .refused(.revisionMismatch, "The schedule changed since it was opened.")
        }
        let deleted: Bool
        do {
            deleted = try await store.deleteIfUnchanged(
                id: id, expectedRevision: expectedRevision)
        } catch {
            return .refused(.storeUnavailable, "The schedule could not be deleted.")
        }
        guard deleted else {
            return .refused(.revisionMismatch,
                            "The schedule changed since it was opened.")
        }
        return G073ScheduleMutationResult(accepted: true)
    }

    /// Explicit user "Run now". Creates its own UNIQUE logical occurrence
    /// (never coalesced with the calendar cadence) and returns `.queued`.
    ///
    /// It deliberately performs NO Agent launch: the actual claim/launch must
    /// run inside the App-owned `TaskScheduleDispatchWorker`, which holds the
    /// existing `RunForegroundBinding` provisional/admitted lease. Launching
    /// here just because the Activity happens to be visible (or another run
    /// is active) would bypass that single foreground admission. The owned-work
    /// change notification wakes the App's existing event-driven observer so
    /// it dispatches the same pending occurrence through that worker. Exact
    /// alarm permission is NOT consulted: "run now" uses no clock wake.
    public func runNow(id: UUID, expectedRevision: String) async
        -> G073ScheduleDispatchOutcome {
        guard let record = try? await store.schedule(id: id) else {
            return G073ScheduleDispatchOutcome(state: .failed, scheduleID: id,
                                               code: .notFound,
                                               reason: "No schedule with that identifier.")
        }
        guard G073ScheduleRevision.digest(record) == expectedRevision else {
            return G073ScheduleDispatchOutcome(state: .failed, scheduleID: id,
                                               code: .revisionMismatch,
                                               reason: "The schedule changed since it was opened.")
        }
        guard record.isEnabled else {
            return G073ScheduleDispatchOutcome(state: .disabled, scheduleID: id,
                                               code: .disabled,
                                               reason: "Enable the schedule before running it.")
        }
        let now = dependencies.now()
        guard let occurrence = try? await store.runNow(id: id, at: now) else {
            return G073ScheduleDispatchOutcome(state: .failed, scheduleID: id,
                                               code: .notFound,
                                               reason: "No schedule with that identifier.")
        }
        // A durable pending row is now the ONLY truth for this request. The
        // App-owned platform path claims and launches it exactly once.
        RunForegroundChange.notifyOwnedWorkChanged()
        return G073ScheduleDispatchOutcome(
            state: .queued,
            scheduleID: id,
            occurrenceID: occurrence.id,
            nextFireAt: nextFire(record, now: now),
            reason: "The task is queued and starts when the background dispatcher admits it.")
    }

    // MARK: Dispatch

    public struct DispatchRequest: Sendable {
        public enum Trigger: String, Sendable {
            case exact
            case flexible
            case manual
            case afterSuccess
            case pending
        }
        public var scheduleID: UUID
        public var trigger: Trigger
        public var exactAlarmAllowed: Bool
        public var flexibleChosen: Bool
        public var environmentMetadata: [G073EnvironmentMetadata]
        /// Platform Stop admission (additive internal seam; same command):
        /// durably cancel the pending occurrence instead of launching it.
        public var stopPending: Bool
        public var pendingOccurrenceID: UUID?

        public init(scheduleID: UUID, trigger: Trigger, exactAlarmAllowed: Bool,
                    flexibleChosen: Bool,
                    environmentMetadata: [G073EnvironmentMetadata] = [],
                    stopPending: Bool = false,
                    pendingOccurrenceID: UUID? = nil) {
            self.scheduleID = scheduleID
            self.trigger = trigger
            self.exactAlarmAllowed = exactAlarmAllowed
            self.flexibleChosen = flexibleChosen
            self.environmentMetadata = environmentMetadata
            self.stopPending = stopPending
            self.pendingOccurrenceID = pendingOccurrenceID
        }
    }

    /// The platform wake entry. Does nothing when the wake has no due
    /// occurrence; the ledger claim makes duplicate alarms/workers collapse.
    public func dispatch(_ request: DispatchRequest) async -> G073ScheduleDispatchOutcome {
        dependencies.environmentOwnership.registerHostMetadata(
            request.environmentMetadata, at: dependencies.now())
        if request.stopPending {
            // Explicit Stop: the intended pending occurrence must never be
            // launched later by an observer/dispatcher retry. Future cadence
            // (the schedule row) is left untouched.
            return await cancelPendingOccurrence(
                scheduleID: request.scheduleID,
                occurrenceID: request.pendingOccurrenceID,
                at: dependencies.now())
        }
        guard let record = try? await store.schedule(id: request.scheduleID) else {
            return G073ScheduleDispatchOutcome(state: .disabled,
                                               scheduleID: request.scheduleID,
                                               code: .notFound,
                                               reason: "The schedule no longer exists.")
        }
        guard record.isEnabled else {
            return G073ScheduleDispatchOutcome(state: .disabled,
                                               scheduleID: request.scheduleID,
                                               code: .disabled,
                                               reason: "The schedule is paused.")
        }
        if request.trigger == .pending {
            let outcomes = await dispatchPendingOccurrences(
                scheduleID: record.id, limit: 1, now: dependencies.now())
            return outcomes.first ?? G073ScheduleDispatchOutcome(
                state: .alreadyHandled, scheduleID: record.id,
                nextFireAt: nextFire(record, now: dependencies.now()))
        }
        if request.trigger == .exact, !request.exactAlarmAllowed {
            return G073ScheduleDispatchOutcome(
                state: .waiting, scheduleID: record.id,
                nextFireAt: nextFire(record, now: dependencies.now()),
                code: .exactAlarmPermission,
                reason: "Exact alarms are not allowed for this app.")
        }
        if request.trigger == .flexible, !request.flexibleChosen {
            return G073ScheduleDispatchOutcome(
                state: .waiting, scheduleID: record.id,
                nextFireAt: nextFire(record, now: dependencies.now()),
                code: .flexibleNotChosen,
                reason: "Flexible scheduling has not been chosen by the user.")
        }
        return await dispatchDue(record: record,
                                 trigger: request.trigger,
                                 now: dependencies.now())
    }

    /// Explicit Stop admission. Claims the pending occurrence first (the SAME
    /// store claim CAS every dispatcher uses), then finishes it as cancelled.
    /// If another dispatcher already claimed/launched it, this refuses to
    /// touch real work; the post-submit Stop path owns the run cancellation.
    /// The schedule row and its future fires are untouched.
    public func cancelPendingOccurrence(scheduleID: UUID,
                                        occurrenceID: UUID? = nil,
                                        at date: Date? = nil)
        async -> G073ScheduleDispatchOutcome {
        let now = date ?? dependencies.now()
        guard let pending = try? await store.pendingOccurrences(limit: 200) else {
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: scheduleID,
                code: .storeUnavailable,
                reason: "The pending occurrence could not be read.")
        }
        let target: TaskScheduleOccurrence?
        if let occurrenceID {
            // Targeted stop reads the exact row (no bounded scan miss).
            let exact = try? await store.occurrence(id: occurrenceID)
            target = exact.flatMap {
                $0.scheduleID == scheduleID && $0.state == .pending ? $0 : nil
            }
        } else {
            target = pending.first { $0.scheduleID == scheduleID }
        }
        guard let occurrence = target else {
            return G073ScheduleDispatchOutcome(
                state: .cancelled, scheduleID: scheduleID,
                reason: "No pending occurrence needed to be stopped.")
        }
        do {
            // Claim first: exactly one dispatcher can own this row, and a
            // claimed row can never be launched by a competing worker.
            guard try await store.claimOccurrence(id: occurrence.id, at: now) else {
                return G073ScheduleDispatchOutcome(
                    state: .cancelled, scheduleID: scheduleID,
                    occurrenceID: occurrence.id,
                    code: .occurrenceInFlight,
                    reason: "The occurrence was already claimed; the running task keeps its own owner.")
            }
            try await store.finishOccurrence(
                id: occurrence.id, state: .cancelled, summary: nil,
                errorText: "Stopped before launch.", at: now)
        } catch {
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: scheduleID,
                occurrenceID: occurrence.id,
                code: .storeUnavailable,
                reason: "The pending occurrence could not be stopped.")
        }
        RunForegroundChange.notifyOwnedWorkChanged()
        return G073ScheduleDispatchOutcome(
            state: .cancelled, scheduleID: scheduleID,
            occurrenceID: occurrence.id,
            reason: "The pending occurrence was cancelled before launch.")
    }

    /// App-alive drain of pending occurrences: `.afterSuccess` rows enqueued
    /// by the real upstream completion, plus a manual row whose inline launch
    /// died before claiming. Bounded per call.
    public func dispatchPending(limit: Int = G073ScheduleLimits.maximumPendingDispatch) async
        -> [G073ScheduleDispatchOutcome] {
        await dispatchPendingOccurrences(scheduleID: nil, limit: limit,
                                         now: dependencies.now())
    }

    /// Schedule ids that currently own at least one pending occurrence. The
    /// platform uses this to enqueue the foreground-supported dispatch worker
    /// (never to launch directly from an observer/boot path).
    public func pendingScheduleIDs(limit: Int = 20) async -> [UUID] {
        let bounded = max(1, min(limit, 50))
        guard let pending = try? await store.pendingOccurrences(limit: bounded * 4)
        else { return [] }
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for occurrence in pending where !seen.contains(occurrence.scheduleID) {
            seen.insert(occurrence.scheduleID)
            result.append(occurrence.scheduleID)
            if result.count >= bounded { break }
        }
        return result
    }

    private func dispatchPendingOccurrences(
        scheduleID: UUID?,
        limit: Int,
        now: Date
    ) async -> [G073ScheduleDispatchOutcome] {
        let bounded = max(1, min(limit, 20))
        guard let pending = try? await store.pendingOccurrences(limit: bounded * 6)
        else { return [] }
        var outcomes: [G073ScheduleDispatchOutcome] = []
        var attempted = 0
        for occurrence in pending {
            if attempted >= bounded { break }
            if let scheduleID, occurrence.scheduleID != scheduleID { continue }
            guard let record = try? await store.schedule(id: occurrence.scheduleID) else {
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .cancelled,
                    summary: nil, errorText: "The schedule was deleted.",
                    at: now)
                continue
            }
            if !record.isEnabled {
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .cancelled,
                    summary: nil, errorText: "The schedule was paused.",
                    at: now)
                continue
            }
            attempted += 1
            let trigger: DispatchRequest.Trigger = record.cadence == .afterSuccess
                ? .afterSuccess : .pending
            // An explicit "run now" occurrence carries its own `manual:` key
            // and is NEVER superseded by calendar coalescing: the user asked
            // for this exact extra run, and the dispatcher must launch it
            // once. Only a natural clock occurrence can be coalesced away by
            // a newer fire time.
            if record.cadence != .afterSuccess,
               !occurrence.dedupeKey.hasPrefix("manual:") {
                // A queued clock occurrence older than the newest due fire is
                // superseded by calendar coalescing; record it as skipped
                // instead of launching stale intent.
                if let latest = TaskSchedulePlanner.dueFireTimes(record: record,
                                                                 now: now).last {
                    let latestKey = TaskSchedulePlanner.dedupeKey(
                        for: latest, record: record)
                    if occurrence.dedupeKey != latestKey {
                        try? await store.finishOccurrence(
                            id: occurrence.id, state: .skipped,
                            summary: "Superseded by a newer occurrence",
                            errorText: nil, at: now)
                        continue
                    }
                }
            }
            outcomes.append(await launchOccurrence(record: record,
                                                   occurrence: occurrence,
                                                   trigger: trigger,
                                                   now: now))
        }
        return outcomes
    }

    /// Exact next wake per enabled schedule. `.afterSuccess` is event-driven
    /// and therefore carries no clock time. Paused schedules are omitted from
    /// OS arming but reported (isEnabled=false) so the platform can cancel
    /// any stale alarm.
    public func armPlans(now date: Date? = nil) async -> [G073ScheduleArmPlan] {
        let now = date ?? dependencies.now()
        guard let records = try? await store.schedules() else { return [] }
        return records.prefix(200).map { record in
            let eventDriven = record.cadence == .afterSuccess
            return G073ScheduleArmPlan(
                scheduleID: record.id,
                nextFireAt: record.isEnabled ? nextFire(record, now: now) : nil,
                cadence: record.cadence,
                eventDriven: eventDriven,
                isEnabled: record.isEnabled)
        }
    }

    /// Real completion hook (run retirement). `recordRunCompletion` enqueues
    /// `.afterSuccess` dependents only for a clean successful upstream run;
    /// unknown/cancelled/failed runs never trigger them.
    public func recordCompletion(runID: UUID, succeeded: Bool, cancelled: Bool,
                                 summary: String?, at date: Date? = nil) async
        -> [UUID] {
        let stop = await dependencies.terminalStopReason(runID)
        var clean = succeeded
        var isCancelled = cancelled
        switch stop {
        case "cancelled":
            clean = false
            isCancelled = true
        case "maxTokens", "budgetLimited", "noProgress":
            clean = false
        default:
            break
        }
        do {
            return try await store.recordRunCompletion(
                runID: runID, succeeded: clean, cancelled: isCancelled,
                summary: summary, at: date ?? dependencies.now())
        } catch {
            return []
        }
    }

    public func runTerminal(runID: UUID, succeeded: Bool, cancelled: Bool,
                            summary: String?, at date: Date) async {
        _ = await recordCompletion(runID: runID, succeeded: succeeded,
                                   cancelled: cancelled, summary: summary, at: date)
    }

    /// Cold-start ordering: settle occurrences whose durable run really
    /// reached a terminal BEFORE interrupting leftovers, so a completed run
    /// can never be overwritten as interrupted. Unknown in-flight outcomes
    /// stop at `.interrupted` and are NOT replayed.
    @discardableResult
    public func reconcileColdStart(now date: Date? = nil) async -> Int {
        let now = date ?? dependencies.now()
        var settled = 0
        let claimed = await dependencies.claimedOccurrences()
        for occurrence in claimed.prefix(200) {
            // A deleted schedule keeps its history but can no longer own a
            // runnable occurrence; a claimed row that never bound a durable
            // run is settled honestly rather than left pending forever.
            if (try? await store.schedule(id: occurrence.scheduleID)) == nil {
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .interrupted, summary: nil,
                    errorText: "The schedule was deleted before this occurrence settled.",
                    at: now)
                settled += 1
                continue
            }
            var boundRunID = occurrence.runID
            if boundRunID == nil {
                let derived = G073ScheduleIdentity.runID(occurrenceID: occurrence.id)
                let derivedState = await dependencies.runState(derived)
                if derivedState != nil {
                    boundRunID = derived
                    _ = try? await store.markOccurrenceRunning(
                        id: occurrence.id, runID: derived,
                        conversationID: G073ScheduleIdentity.conversationID(
                            occurrenceID: occurrence.id),
                        at: now)
                }
            }
            guard let runID = boundRunID,
                  let state = await dependencies.runState(runID) else { continue }
            switch state {
            case "completed":
                _ = await recordCompletion(runID: runID, succeeded: true,
                                           cancelled: false,
                                           summary: "Completed before restart",
                                           at: now)
                settled += 1
            case "failed":
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .failed, summary: nil,
                    errorText: "The run failed before restart.", at: now)
                settled += 1
            case "cancelled":
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .cancelled, summary: nil,
                    errorText: "The run was cancelled before restart.", at: now)
                settled += 1
            default:
                break
            }
        }
        let reconciled = (try? await store.reconcileInterruptedOccurrences(at: now)) ?? 0
        return settled + reconciled
    }

    // MARK: Dispatch internals

    private func dispatchDue(record: TaskScheduleRecord,
                             trigger: DispatchRequest.Trigger,
                             now: Date) async -> G073ScheduleDispatchOutcome {
        guard record.cadence != .afterSuccess else {
            return G073ScheduleDispatchOutcome(
                state: .waiting, scheduleID: record.id,
                code: .waitingForUpstream,
                reason: "This schedule runs after a successful upstream task.")
        }
        let due = TaskSchedulePlanner.dueFireTimes(record: record, now: now)
        guard let fireTime = due.last else {
            return G073ScheduleDispatchOutcome(
                state: .waiting, scheduleID: record.id,
                nextFireAt: nextFire(record, now: now),
                reason: "No occurrence is due yet.")
        }
        let key = TaskSchedulePlanner.dedupeKey(for: fireTime, record: record)
        var occurrenceID = TaskScheduleOccurrence.stableID(
            scheduleID: record.id, dedupeKey: key)

        // Coalescing history: older missed fires are recorded as skipped,
        // never silently dropped and never executed in a burst.
        for older in due.dropLast() {
            let olderKey = TaskSchedulePlanner.dedupeKey(for: older, record: record)
            let skipped = TaskScheduleOccurrence(
                id: TaskScheduleOccurrence.stableID(scheduleID: record.id,
                                                    dedupeKey: olderKey),
                scheduleID: record.id,
                scheduledFor: older,
                state: .skipped,
                dedupeKey: olderKey,
                finishedAt: now,
                summary: "Missed occurrence coalesced",
                createdAt: now,
                updatedAt: now)
            _ = try? await store.enqueueOccurrence(skipped)
        }

        var occurrence: TaskScheduleOccurrence?
        if let existing = try? await store.occurrence(id: occurrenceID) {
            switch existing.state {
            case .pending:
                occurrence = existing
            case .claimed, .running:
                return await resolveInFlight(existing, record: record, now: now)
            case .interrupted:
                if let retried = await retryOnceIfSafe(existing, record: record,
                                                       now: now) {
                    occurrence = retried
                    occurrenceID = retried.id
                } else {
                    await advanceIfStillDue(record: record, fireTime: fireTime, now: now)
                    return G073ScheduleDispatchOutcome(
                        state: .alreadyHandled, scheduleID: record.id,
                        occurrenceID: existing.id,
                        nextFireAt: nextFire(record, now: now),
                        code: .ignored,
                        reason: "The occurrence outcome is unknown; it was not replayed.")
                }
            case .completed, .failed, .cancelled, .skipped:
                await advanceIfStillDue(record: record, fireTime: fireTime, now: now)
                return G073ScheduleDispatchOutcome(
                    state: .alreadyHandled, scheduleID: record.id,
                    occurrenceID: existing.id,
                    nextFireAt: nextFire(record, now: now))
            }
        } else {
            occurrence = TaskScheduleOccurrence(
                id: occurrenceID,
                scheduleID: record.id,
                scheduledFor: fireTime,
                state: .pending,
                dedupeKey: key,
                createdAt: now,
                updatedAt: now)
            _ = try? await store.enqueueOccurrence(occurrence!)
            occurrence = try? await store.occurrence(id: occurrenceID)
        }
        guard let occurrence else {
            return G073ScheduleDispatchOutcome(state: .failed,
                                               scheduleID: record.id,
                                               code: .storeUnavailable,
                                               reason: "The occurrence could not be recorded.")
        }
        return await launchOccurrence(record: record, occurrence: occurrence,
                                      trigger: trigger, now: now)
    }

    /// A claimed/running row belongs to another (possibly live) executor.
    /// If its deterministic durable run already reached a terminal, settle
    /// it; otherwise leave it alone. Never steal or replay.
    private func resolveInFlight(_ occurrence: TaskScheduleOccurrence,
                                 record: TaskScheduleRecord,
                                 now: Date) async -> G073ScheduleDispatchOutcome {
        let derived = G073ScheduleIdentity.runID(occurrenceID: occurrence.id)
        var candidateRunID = occurrence.runID
        if candidateRunID == nil {
            let derivedState = await dependencies.runState(derived)
            if derivedState != nil { candidateRunID = derived }
        }
        if let runID = candidateRunID,
           let state = await dependencies.runState(runID) {
            switch state {
            case "completed", "failed", "cancelled":
                if occurrence.runID == nil {
                    _ = try? await store.markOccurrenceRunning(
                        id: occurrence.id, runID: runID,
                        conversationID: G073ScheduleIdentity.conversationID(
                            occurrenceID: occurrence.id), at: now)
                }
                _ = await recordCompletion(
                    runID: runID, succeeded: state == "completed",
                    cancelled: state == "cancelled",
                    summary: state == "completed" ? nil : "The run ended before this wake.",
                    at: now)
                return G073ScheduleDispatchOutcome(
                    state: .alreadyHandled, scheduleID: record.id,
                    occurrenceID: occurrence.id, runID: runID,
                    conversationID: occurrence.conversationID,
                    nextFireAt: nextFire(record, now: now))
            default:
                break
            }
        }
        return G073ScheduleDispatchOutcome(
            state: .alreadyHandled, scheduleID: record.id,
            occurrenceID: occurrence.id, runID: occurrence.runID,
            conversationID: occurrence.conversationID,
            nextFireAt: nextFire(record, now: now),
            code: .occurrenceInFlight,
            reason: "This occurrence is already being handled.")
    }

    /// A once-only occurrence that was interrupted BEFORE any durable run
    /// existed is safe to retry exactly once per interrupted record. A
    /// durable run (terminal or not) always wins: no replay.
    private func retryOnceIfSafe(_ occurrence: TaskScheduleOccurrence,
                                 record: TaskScheduleRecord,
                                 now: Date) async -> TaskScheduleOccurrence? {
        guard record.cadence == .once else { return nil }
        let derived = G073ScheduleIdentity.runID(occurrenceID: occurrence.id)
        let derivedState = await dependencies.runState(derived)
        if derivedState != nil { return nil }
        let existing = (try? await store.occurrences(
            scheduleID: record.id, limit: G073ScheduleLimits.maximumOnceRetries + 1)) ?? []
        let interrupted = existing.filter { $0.state == .interrupted }
        guard interrupted.count < G073ScheduleLimits.maximumOnceRetries else {
            await advanceIfStillDue(record: record,
                                    fireTime: occurrence.scheduledFor, now: now)
            return nil
        }
        let key = "once:retry:\(occurrence.id.uuidString.lowercased())"
        let retry = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: record.id, dedupeKey: key),
            scheduleID: record.id,
            scheduledFor: occurrence.scheduledFor,
            state: .pending,
            dedupeKey: key,
            createdAt: now,
            updatedAt: now)
        guard (try? await store.enqueueOccurrence(retry)) == true else { return nil }
        return try? await store.occurrence(id: retry.id)
    }

    /// Advance the planner anchor when the due fire was already settled.
    /// Idempotent for anchored cadences (daily/weekly/interval recompute from
    /// the same anchor) and disables `.once` exactly like a real start.
    private func advanceIfStillDue(record: TaskScheduleRecord,
                                   fireTime: Date, now: Date) async {
        guard record.isEnabled else { return }
        if let next = record.nextExpectedAt, next > fireTime { return }
        try? await store.markStarted(id: record.id, at: fireTime)
    }

    private func launchOccurrence(record initial: TaskScheduleRecord,
                                  occurrence: TaskScheduleOccurrence,
                                  trigger: DispatchRequest.Trigger,
                                  now: Date) async
        -> G073ScheduleDispatchOutcome {
        do {
            guard try await store.claimOccurrence(id: occurrence.id, at: now) else {
                return G073ScheduleDispatchOutcome(
                    state: .alreadyHandled, scheduleID: initial.id,
                    occurrenceID: occurrence.id,
                    nextFireAt: nextFire(initial, now: now),
                    code: .occurrenceInFlight,
                    reason: "Another wake already claimed this occurrence.")
            }
        } catch {
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: initial.id,
                occurrenceID: occurrence.id, code: .storeUnavailable,
                reason: "The occurrence could not be claimed.")
        }

        guard let record = try? await store.schedule(id: initial.id),
              record.isEnabled else {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .cancelled, summary: nil,
                errorText: "The schedule was paused before launch.", at: now)
            return G073ScheduleDispatchOutcome(
                state: .disabled, scheduleID: initial.id,
                occurrenceID: occurrence.id, code: .disabled,
                reason: "The schedule is paused.")
        }

        let preflight = await preflight(record: record, now: now)
        if let failure = preflight.failure {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .failed, summary: nil,
                errorText: failure.text, at: now)
            await advance(record: record, at: now)
            let refreshed = (try? await store.schedule(id: record.id)) ?? record
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: record.id,
                occurrenceID: occurrence.id,
                nextFireAt: nextFire(refreshed, now: now),
                code: failure.code, reason: failure.text)
        }
        guard let resolved = preflight.value else {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .failed, summary: nil,
                errorText: "The schedule binding could not be resolved.", at: now)
            await advance(record: record, at: now)
            let refreshed = (try? await store.schedule(id: record.id)) ?? record
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: record.id,
                occurrenceID: occurrence.id,
                nextFireAt: nextFire(refreshed, now: now),
                code: .invalidPayload,
                reason: "The schedule binding could not be resolved.")
        }

        let conversationID = G073ScheduleIdentity.conversationID(
            occurrenceID: occurrence.id)
        let runID = G073ScheduleIdentity.runID(occurrenceID: occurrence.id)
        let request = G073ScheduledLaunchRequest(
            occurrenceID: occurrence.id,
            conversationID: conversationID,
            runID: runID,
            workspaceID: resolved.workspaceID,
            title: record.title,
            prompt: record.prompt,
            providerID: resolved.providerID,
            modelID: resolved.modelID,
            environmentID: record.environmentID,
            environmentMetadata: resolved.environmentMetadata,
            policy: resolved.policy)

        let result = await dependencies.launch.launchScheduled(request)
        guard result.accepted else {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .failed, summary: nil,
                errorText: G073ScheduleText.truncated(
                    [result.code, result.reason]
                        .filter { !$0.isEmpty }.joined(separator: ": ")),
                at: now)
            await advance(record: record, at: now)
            let refreshed = (try? await store.schedule(id: record.id)) ?? record
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: record.id,
                occurrenceID: occurrence.id,
                nextFireAt: nextFire(refreshed, now: now),
                code: .launchRefused,
                reason: result.reason.isEmpty
                    ? "The scheduled task could not be launched."
                    : G073ScheduleText.truncated(result.reason))
        }

        let bound = (try? await store.markOccurrenceRunning(
            id: occurrence.id, runID: runID,
            conversationID: conversationID, at: now)) ?? false
        guard bound else {
            return G073ScheduleDispatchOutcome(
                state: .failed, scheduleID: record.id,
                occurrenceID: occurrence.id, runID: runID,
                conversationID: conversationID, code: .occurrenceInFlight,
                reason: "The occurrence changed while launching; the run was not adopted.")
        }
        await advance(record: record, at: now)
        let refreshed = (try? await store.schedule(id: record.id)) ?? record
        return G073ScheduleDispatchOutcome(
            state: .launched, scheduleID: record.id,
            occurrenceID: occurrence.id, runID: runID,
            conversationID: conversationID,
            nextFireAt: nextFire(refreshed, now: now))
    }

    private func advance(record: TaskScheduleRecord, at date: Date) async {
        do {
            try await store.markStarted(id: record.id, at: date)
        } catch {
            // The occurrence remains terminal; the next planner pass advances
            // from that terminal row (no silent duplicate launch).
        }
    }

    // MARK: Preflight

    private struct ResolvedBinding {
        var workspaceID: UUID?
        var providerID: UUID
        var modelID: UUID
        var policy: DraftTaskPolicy
        var environmentMetadata: G073EnvironmentMetadata?
    }

    private struct PreflightFailure {
        var code: G073ScheduleErrorCode
        var text: String
    }

    private struct Preflight {
        var value: ResolvedBinding?
        var failure: PreflightFailure?
    }

    /// Re-validates every frozen binding at REAL dispatch time. A deleted or
    /// disabled model/environment is refused; nothing falls back to a default
    /// or a different environment.
    private func preflight(record: TaskScheduleRecord, now: Date) async -> Preflight {
        guard record.prompt.utf8.count > 0,
              record.prompt.utf8.count <= G073ScheduleLimits.maximumPromptBytes,
              record.title.utf8.count <= G073ScheduleLimits.maximumTitleBytes else {
            return Preflight(value: nil,
                             failure: .init(code: .promptInvalid,
                                            text: "The stored prompt or title is no longer valid."))
        }
        guard let policy = G073SchedulePolicyCodec.decode(record.permissionJSON) else {
            return Preflight(value: nil,
                             failure: .init(code: .policyInvalid,
                                            text: "The stored permission binding is invalid; it was not replaced with a default."))
        }
        var workspaceBinding: UUID?
        if let workspaceID = record.workspaceID {
            guard let workspace = await dependencies.workspace(workspaceID) else {
                return Preflight(value: nil,
                                 failure: .init(code: .workspaceUnavailable,
                                                text: "The scheduled project workspace no longer exists."))
            }
            guard workspace.kind == .project else {
                return Preflight(value: nil,
                                 failure: .init(code: .workspaceNotProject,
                                                text: "A previous task workspace cannot be reused by a new scheduled task."))
            }
            workspaceBinding = workspace.id
        }
        // nil keeps "new independent workspace per occurrence": the ordinary
        // launch transaction mints it (never a reused private task).
        var resolvedModelID = record.modelID
        if resolvedModelID == nil {
            resolvedModelID = await dependencies.defaultModelID()
        }
        guard let modelID = resolvedModelID,
              let model = await dependencies.model(modelID) else {
            return Preflight(value: nil,
                             failure: .init(code: .modelUnavailable,
                                            text: "The scheduled model is missing or disabled. Choose an available model."))
        }
        var resolvedEnvironmentMetadata: G073EnvironmentMetadata?
        if let environmentID = record.environmentID {
            guard record.workspaceID != nil else {
                return Preflight(value: nil,
                                 failure: .init(code: .environmentNotProject,
                                                text: "A project environment requires a frozen project workspace."))
            }
            let metadata = await environmentMetadata(id: environmentID, now: now)
            guard let metadata else {
                return Preflight(value: nil,
                                 failure: .init(code: .environmentSnapshotMissing,
                                                text: "The environment could not be verified. Open the app to refresh its environment metadata."))
            }
            guard let projectWorkspace = workspaceBinding,
                  await dependencies.environmentOwnership.proveScheduledEnvironment(
                    environmentID, workspaceID: projectWorkspace,
                    metadata: metadata, epoch: epoch) else {
                return Preflight(value: nil,
                                 failure: .init(code: .environmentUnavailable,
                                                text: "The scheduled environment is not an active project environment owned by the selected workspace."))
            }
            resolvedEnvironmentMetadata = metadata
        }
        return Preflight(value: ResolvedBinding(
            workspaceID: workspaceBinding,
            providerID: model.providerID,
            modelID: model.id,
            policy: policy,
            environmentMetadata: resolvedEnvironmentMetadata), failure: nil)
    }

    private struct ValidatedDraft {
        var title: String
        var prompt: String
        var cadence: TaskScheduleCadence
        var scheduledAt: Date
        var weekday: Int?
        var intervalSeconds: Int?
        var anchorTimezone: String?
        var upstreamRunID: UUID?
        var workspaceID: UUID?
        var modelID: UUID
        var environmentID: String?
        var policy: DraftTaskPolicy
        var nextExpectedAt: Date?
    }

    private func validateDraft(_ draft: G073ScheduleDraft, now: Date) async
        -> ValidatedDraft? {
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              prompt.utf8.count <= G073ScheduleLimits.maximumPromptBytes else { return nil }
        var title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = String(prompt.prefix(40)) }
        guard title.utf8.count <= G073ScheduleLimits.maximumTitleBytes else { return nil }
        let cadence = draft.cadence
        var weekday = draft.weekday
        if cadence == .weekly {
            if let weekday, !(1...7).contains(weekday) { return nil }
            if weekday == nil {
                weekday = Calendar.current.component(.weekday, from: draft.scheduledAt)
            }
        } else {
            weekday = nil
        }
        var intervalSeconds = draft.intervalSeconds
        if cadence == .interval {
            guard let seconds = intervalSeconds, seconds >= 60,
                  seconds <= 31_536_000 else { return nil }
            intervalSeconds = seconds
        } else {
            intervalSeconds = nil
        }
        var anchorTimezone = draft.anchorTimezone
        if let zone = anchorTimezone {
            guard zone.utf8.count <= G073ScheduleLimits.maximumTimezoneBytes,
                  TimeZone(identifier: zone) != nil else { return nil }
        } else {
            anchorTimezone = TimeZone.current.identifier
        }
        var workspaceID: UUID?
        if let requested = draft.workspaceID {
            guard let workspace = await dependencies.workspace(requested),
                  workspace.kind == .project else { return nil }
            workspaceID = workspace.id
        }
        var upstreamRunID: UUID?
        if cadence == .afterSuccess {
            // A follow-up occurrence can only be created by a clean SUCCESS
            // of this exact top-level ordinary run. The run must exist in the
            // durable top-level run projection (children live in a separate
            // store and never resolve here), must still be able to succeed,
            // and, when the schedule freezes a project workspace, must belong
            // to that SAME project. Anything else is refused rather than
            // silently bound to an unrelated or already-settled run.
            guard let id = draft.upstreamRunID,
                  let state = await dependencies.runState(id),
                  G073ScheduleRunSelection.canStillSucceed(state) else {
                return nil
            }
            if let workspaceID {
                guard let conversationID = await dependencies.runConversation(id),
                      let runWorkspace = await dependencies.workspaceForConversation(
                        conversationID),
                      runWorkspace == workspaceID else { return nil }
            }
            upstreamRunID = id
        }
        var resolvedModelID = draft.modelID
        if resolvedModelID == nil {
            resolvedModelID = await dependencies.defaultModelID()
        }
        guard let modelID = resolvedModelID,
              await dependencies.model(modelID) != nil else { return nil }
        var environmentID: String?
        if let requested = draft.environmentID, !requested.isEmpty {
            guard let workspaceID else { return nil }
            guard let metadata = await environmentMetadata(id: requested, now: now),
                  await dependencies.environmentOwnership.proveScheduledEnvironment(
                    requested, workspaceID: workspaceID,
                    metadata: metadata, epoch: epoch) else { return nil }
            environmentID = requested
        }
        let policy = draft.policy
        var record = TaskScheduleRecord(
            title: title, prompt: prompt, workspaceID: workspaceID,
            cadence: cadence, scheduledAt: draft.scheduledAt, weekday: weekday,
            isEnabled: true, policyJSON: "{}", createdAt: now, updatedAt: now,
            intervalSeconds: intervalSeconds, anchorTimezone: anchorTimezone,
            upstreamRunID: upstreamRunID, modelID: modelID,
            environmentID: environmentID,
            permissionJSON: G073SchedulePolicyCodec.encode(policy))
        record.nextExpectedAt = cadence == .afterSuccess
            ? nil
            : (TaskSchedulePlanner.nextFireTime(after: now, record: record)
                ?? record.scheduledAt)
        return ValidatedDraft(
            title: title, prompt: prompt, cadence: cadence,
            scheduledAt: draft.scheduledAt, weekday: weekday,
            intervalSeconds: intervalSeconds, anchorTimezone: anchorTimezone,
            upstreamRunID: upstreamRunID, workspaceID: workspaceID,
            modelID: modelID, environmentID: environmentID, policy: policy,
            nextExpectedAt: record.nextExpectedAt)
    }

    private func environmentMetadata(id: String, now: Date) async
        -> G073EnvironmentMetadata? {
        if let source = dependencies.environmentSource,
           let metadata = await source.environmentMetadata(id: id) {
            return metadata
        }
        return dependencies.environmentOwnership.metadata(id: id, now: now)
    }

    // MARK: Projections

    private func summary(_ record: TaskScheduleRecord,
                         now: Date,
                         lastOccurrence: TaskScheduleOccurrence?) async
        -> G073ScheduleSummary {
        var workspace: G073WorkspaceSummary?
        if let workspaceID = record.workspaceID {
            workspace = await dependencies.workspace(workspaceID)
        }
        var model: G073ModelSummary?
        if let modelID = record.modelID {
            model = await dependencies.model(modelID)
        } else if let fallback = await dependencies.defaultModelID() {
            model = await dependencies.model(fallback)
        }
        var environment: G073EnvironmentMetadata?
        if let environmentID = record.environmentID {
            environment = dependencies.environmentOwnership.metadata(id: environmentID, now: now)
        }
        let policy = G073SchedulePolicyCodec.decode(record.permissionJSON)
        let next = record.isEnabled ? nextFire(record, now: now) : nil
        var needsAttention = false
        if record.isEnabled {
            if record.workspaceID != nil, workspace == nil { needsAttention = true }
            if record.workspaceID != nil, workspace?.kind != .project { needsAttention = true }
            if model == nil { needsAttention = true }
            if record.environmentID != nil, environment == nil { needsAttention = true }
            if policy == nil { needsAttention = true }
        }
        if let state = lastOccurrence?.state,
           state == .failed || state == .interrupted { needsAttention = true }
        return G073ScheduleSummary(
            id: record.id,
            title: record.title,
            promptPreview: G073ScheduleText.truncated(record.prompt, limit: 160),
            cadence: record.cadence,
            isEnabled: record.isEnabled,
            scheduledAt: record.scheduledAt,
            weekday: record.weekday,
            intervalSeconds: record.intervalSeconds,
            anchorTimezone: record.anchorTimezone,
            nextFireAt: next,
            lastStartedAt: record.lastStartedAt,
            modelID: record.modelID,
            modelName: model?.displayName,
            environmentID: record.environmentID,
            environmentName: environment?.name ?? record.environmentID,
            workspaceID: record.workspaceID,
            workspaceName: workspace?.name,
            policy: policy ?? DraftTaskPolicy(),
            upstreamRunID: record.upstreamRunID,
            revision: G073ScheduleRevision.digest(record),
            lastOccurrence: lastOccurrence.map(G073ScheduleOccurrenceSummary.init),
            needsAttention: needsAttention)
    }

    private func nextFire(_ record: TaskScheduleRecord, now: Date) -> Date? {
        guard record.isEnabled, record.cadence != .afterSuccess else { return nil }
        if let next = record.nextExpectedAt { return next }
        return TaskSchedulePlanner.nextFireTime(after: now, record: record)
            ?? record.scheduledAt
    }
}
