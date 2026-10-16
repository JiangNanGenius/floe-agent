// FloeExecution — action-aware native background job policy, provenance,
// progress and service-owned prepared operations.
//
// `jobs.submit` used to accept a fixed six-tool list with no notion of the
// action, target revision, origin or resource scope. Native long jobs (video
// edit/interpolate/super-resolution, media project work, PDF edit/export,
// Office package batches) are long-running in exactly the same way, so they
// are admitted here — through one policy that:
//
//   * allow-lists the exact target AND the payload's action before a durable
//     record is created;
//   * verifies the CALL PROVENANCE of the submission (`NativeJobProvenance`):
//     a delegated child is admitted through the same effective parent ceiling
//     instead of being refused wholesale, while a forged/contradictory origin
//     (a child-origin without the runtime child handoff, a main-run origin
//     carrying child identity, cross-run/cross-task claims) fails closed;
//   * preflights the real workspace target (existing regular input file,
//     output confined to the task workspace, and the declared
//     `expectedSHA256`/`baseSHA256` revision matching the bytes on disk)
//     BEFORE the job is persisted, so a job never starts against a stale
//     revision or a path outside the task;
//   * routes targets with a registered `NativeJobServiceAdapter` through a
//     SERVICE-OWNED prepared operation: the adapter freezes the concrete
//     operation (target/revision/commands) at submission, consumes the
//     runtime authority for the exact approved `jobs.submit` call when it
//     declares `requiresRuntimeAuthorization`, reports real processor
//     progress into the durable record, owns cooperative cancellation and
//     reconciles interrupted work against real side effects;
//   * optionally reconciles an interrupted job against a real side effect
//     instead of blindly marking it interrupted; the default stays honest
//     "interrupted".
//
// Every stored job already freezes its run/task/environment/workspace root;
// this policy adds no second scope and never guesses a current project or a
// global root.

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

// MARK: - Provenance

/// Runtime-verified provenance of one submitted job. Built only by
/// `NativeJobProvenance.verify` from the runtime-issued `ToolCallOrigin` and
/// `ChildExecutionHandoff` (both non-Codable, never model-minted). The value
/// is persisted with the job's progress document so status/result output can
/// state who submitted the work honestly, including after a relaunch.
public struct NativeJobOrigin: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, Equatable {
        /// A main-run (user-visible) tool call.
        case mainRun
        /// A runtime-issued delegated child of the owning task.
        case delegatedChild
    }

    public var kind: Kind
    /// Root business task (conversation) the submission belongs to.
    public var rootTaskID: UUID?
    /// The delegated child, when `kind == .delegatedChild`.
    public var childID: UUID?
    /// Provider call id of the `delegate` call that started the child.
    public var delegateCallID: String?
    /// Provider call id of the `jobs.submit` call itself.
    public var submittedCallID: String?

    public init(kind: Kind, rootTaskID: UUID? = nil, childID: UUID? = nil,
                delegateCallID: String? = nil, submittedCallID: String? = nil) {
        self.kind = kind
        self.rootTaskID = rootTaskID
        self.childID = childID
        self.delegateCallID = delegateCallID
        self.submittedCallID = submittedCallID
    }

    public var displayLabel: String {
        switch kind {
        case .mainRun: return "main-run"
        case .delegatedChild:
            return "delegated-child:\(childID?.uuidString.prefix(8) ?? "unknown")"
        }
    }
}

/// Where a submission came from. The two sources are an explicit API
/// distinction, never a fallback: `.runtime` is the ONLY source a
/// runtime-dispatched `jobs.submit` call (including any reconstructed wrapper
/// context that reaches the raw registered entry) can use, and `.nativeService`
/// is the explicit in-process API for trusted app actions (restarting a
/// stopped local service, the shell `floe-service` command, the IDE run-service
/// action) that are not model/tool calls to `jobs.submit`.
public enum NativeJobSubmissionSource: Sendable, Equatable {
    /// A runtime-dispatched `jobs.submit` call. The context MUST carry BOTH
    /// the provider call id and the runtime call origin bound to `jobs.submit`
    /// for that exact call; a missing call id, a missing/legacy origin without
    /// a tool name, a wrapper origin bound to another tool and a child handoff
    /// without a matching origin are all refused. There is no all-nil
    /// in-process fallback here.
    case runtime
    /// Explicit in-process native API call (shared code, no `jobs.submit`
    /// dispatch). Provenance is still cross-checked: a child handoff keeps its
    /// real child identity, and a present origin must agree with the
    /// run/handoff. The `jobs.submit` tool-name binding is not required
    /// because no such call exists.
    case nativeService
}

/// Verification of the runtime-issued provenance for one `jobs.submit` call.
/// Fail-closed: an origin that contradicts the child handoff, a missing
/// origin, a legacy origin without the approved tool name and any origin bound
/// to another tool are all refused before anything is persisted.
public enum NativeJobProvenance {
    /// The only tool a job submission may originate from. The runtime-issued
    /// origin binds the APPROVED tool name (`ToolCallOrigin.toolName`); it
    /// must be exactly this for main-run and delegated-child submissions
    /// alike, so a wrapper that forwards its own otherwise identical context
    /// into the raw registry entry can never submit jobs.
    public static let submittingToolName = "jobs.submit"

    public static func verify(runID: UUID,
                              toolCallID: String?,
                              origin: ToolCallOrigin?,
                              childExecution: ChildExecutionHandoff?,
                              source: NativeJobSubmissionSource = .nativeService) throws -> NativeJobOrigin {
        switch source {
        case .nativeService:
            return try verifyInProcessOrigin(runID: runID, toolCallID: toolCallID,
                                             origin: origin, childExecution: childExecution)
        case .runtime:
            // A runtime-dispatched tool call ALWAYS carries BOTH the provider
            // call id and the runtime-issued call origin (minted together by
            // the canonical dispatcher). There is deliberately NO all-nil
            // in-process fallback here: a reconstructed wrapper context with
            // stripped provenance reaches the raw registered `jobs.submit`
            // entry in exactly that shape, and it must fail closed. The
            // in-process API declares `NativeJobSubmissionSource.nativeService`
            // explicitly instead of being inferred from missing provenance.
            guard let toolCallID else {
                throw FloeError.validationFailed(
                    "This call has no runtime provider call id; background work is refused without the runtime-issued provenance of the approved '\(submittingToolName)' call")
            }
            guard let origin else {
                throw FloeError.validationFailed(
                    "This submission has no runtime call origin; background work is refused without the runtime-issued provenance of the approved '\(submittingToolName)' call")
            }
            guard origin.toolName == submittingToolName else {
                throw FloeError.validationFailed(
                    "The call origin is bound to tool '\(origin.toolName ?? "unknown")', not '\(submittingToolName)'; the submission is refused")
            }
            return try verifyRuntimeOrigin(runID: runID, toolCallID: toolCallID,
                                           origin: origin, childExecution: childExecution)
        }
    }

    /// In-process (native-app) submission: the tool-name binding is not
    /// required because no `jobs.submit` call exists, but any provenance that
    /// IS present is still cross-checked, and a child handoff keeps its real
    /// child identity for ownership.
    private static func verifyInProcessOrigin(runID: UUID,
                                              toolCallID: String?,
                                              origin: ToolCallOrigin?,
                                              childExecution: ChildExecutionHandoff?) throws -> NativeJobOrigin {
        if let handoff = childExecution {
            let identity = handoff.identity
            guard identity.parentRunID == runID, identity.depth == 1 else {
                throw FloeError.validationFailed(
                    "The child handoff belongs to a different run or a nested delegation; the submission is refused")
            }
            if let origin {
                guard origin.runID == runID else {
                    throw FloeError.validationFailed(
                        "The call origin belongs to a different run; the submission is refused")
                }
                if origin.kind == .delegatedChild {
                    guard origin.childID == identity.childID, origin.rootTaskID == identity.rootTaskID else {
                        throw FloeError.validationFailed(
                            "The delegated-child origin does not match the runtime child identity; the submission is refused")
                    }
                } else {
                    guard origin.callID == identity.delegateCallID else {
                        throw FloeError.validationFailed(
                            "A main-run origin on a child handoff must be the delegate call itself; the submission is refused")
                    }
                }
            }
            return NativeJobOrigin(kind: .delegatedChild, rootTaskID: identity.rootTaskID,
                                   childID: identity.childID, delegateCallID: identity.delegateCallID,
                                   submittedCallID: toolCallID)
        }
        if let origin {
            guard origin.kind == .mainRunDelegate, origin.runID == runID else {
                throw FloeError.validationFailed(
                    "The call origin is not the main run's own call; the submission is refused")
            }
            guard origin.childID == nil, origin.rootTaskID == nil else {
                throw FloeError.validationFailed(
                    "A main-run origin must not carry a child identity; the submission is refused")
            }
        }
        return NativeJobOrigin(kind: .mainRun, rootTaskID: nil, submittedCallID: toolCallID)
    }

    private static func verifyRuntimeOrigin(runID: UUID,
                                            toolCallID: String,
                                            origin: ToolCallOrigin,
                                            childExecution: ChildExecutionHandoff?) throws -> NativeJobOrigin {
        if let handoff = childExecution {
            let identity = handoff.identity
            guard origin.kind == .delegatedChild else {
                throw FloeError.validationFailed(
                    "This call carries a delegated-child handoff with a main-run origin; the submission is refused")
            }
            guard origin.runID == runID, identity.parentRunID == runID else {
                throw FloeError.validationFailed(
                    "The delegated-child handoff belongs to a different run; the submission is refused")
            }
            guard identity.depth == 1 else {
                throw FloeError.validationFailed(
                    "Nested delegation is not permitted; the submission is refused")
            }
            guard origin.childID == identity.childID, origin.rootTaskID == identity.rootTaskID else {
                throw FloeError.validationFailed(
                    "The delegated-child origin does not match the runtime child identity; the submission is refused")
            }
            guard origin.callID == toolCallID else {
                throw FloeError.validationFailed(
                    "The delegated-child origin belongs to a different provider call; the submission is refused")
            }
            return NativeJobOrigin(kind: .delegatedChild, rootTaskID: identity.rootTaskID,
                                   childID: identity.childID,
                                   delegateCallID: identity.delegateCallID,
                                   submittedCallID: toolCallID)
        }
        guard origin.kind == .mainRunDelegate else {
            throw FloeError.validationFailed(
                "A delegated-child origin without the runtime child handoff cannot be trusted; the submission is refused")
        }
        guard origin.runID == runID else {
            throw FloeError.validationFailed(
                "The call origin belongs to a different run; the submission is refused")
        }
        guard origin.childID == nil, origin.rootTaskID == nil else {
            throw FloeError.validationFailed(
                "A main-run origin must not carry a child identity; the submission is refused")
        }
        guard origin.callID == toolCallID else {
            throw FloeError.validationFailed(
                "The call origin belongs to a different provider call; the submission is refused")
        }
        return NativeJobOrigin(kind: .mainRun, rootTaskID: nil,
                               submittedCallID: toolCallID)
    }
}

// MARK: - Progress

/// Real, bounded progress for one native job. Units come from the actual
/// processor (media frames, document batches, …); a phase change is never
/// invented as a percentage.
public struct NativeJobProgress: Sendable, Equatable, Codable {
    public enum Stage: String, Sendable, Codable, Equatable {
        case preparing
        case running
        case finalizing
        case verifying
        case cancelling
    }

    public var stage: Stage
    /// Tool/service-specific phase (e.g. "processing", "encoding").
    public var phase: String?
    public var completedUnits: Int?
    public var totalUnits: Int?
    /// Bounded, human-readable note; never user content.
    public var note: String?

    public init(stage: Stage, phase: String? = nil, completedUnits: Int? = nil,
                totalUnits: Int? = nil, note: String? = nil) {
        self.stage = stage
        self.phase = phase.map { String($0.prefix(64)) }
        self.completedUnits = completedUnits.map { max(0, $0) }
        self.totalUnits = totalUnits.map { max(0, $0) }
        self.note = note.map { String($0.prefix(512)) }
    }

    public var fraction: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else { return nil }
        return min(1, Double(completedUnits) / Double(totalUnits))
    }
}

/// Bridges the runtime/app progress contract (`FloeTools.TaskProgressReporting`,
/// injected into a job's tool context) to the durable job recorder. A tool
/// reporting real units through `context.taskProgress` therefore lands in
/// `progress_json` and in `jobs.status` without knowing anything about jobs.
public struct NativeJobTaskProgressReporter: TaskProgressReporting {
    private let record: @Sendable (NativeJobProgress) async -> Void

    public init(record: @escaping @Sendable (NativeJobProgress) async -> Void) {
        self.record = record
    }

    public func report(_ update: TaskProgressUpdate) async {
        let stage = NativeJobProgress.Stage(rawValue: update.stage) ?? .running
        await record(NativeJobProgress(stage: stage, phase: update.phase,
                                       completedUnits: update.completedUnits,
                                       totalUnits: update.totalUnits,
                                       note: update.note))
    }
}

/// Identity of a prepared service operation, persisted with the job so status
/// output and retries share ONE operation identity.
public struct NativeJobPreparationSummary: Sendable, Equatable, Codable {
    public var operationID: String
    public var serviceLabel: String
    public var frozenRevision: String?

    public init(operationID: String, serviceLabel: String, frozenRevision: String? = nil) {
        self.operationID = operationID
        self.serviceLabel = String(serviceLabel.prefix(128))
        self.frozenRevision = frozenRevision.map { String($0.prefix(128)) }
    }
}

/// The durable job metadata document stored in `progress_json`: provenance,
/// the prepared-operation identity and the latest bounded progress. Written
/// only through `NativeJobProgressRecorder` (coalesced).
public struct NativeJobProgressDocument: Sendable, Equatable, Codable {
    public static let currentSchema = 1

    public var schema: Int
    public var origin: NativeJobOrigin?
    public var prepared: NativeJobPreparationSummary?
    public var progress: NativeJobProgress?
    public var cancellationRequested: Bool?
    public var updatedAt: Date?

    public init(schema: Int = NativeJobProgressDocument.currentSchema,
                origin: NativeJobOrigin? = nil,
                prepared: NativeJobPreparationSummary? = nil,
                progress: NativeJobProgress? = nil,
                cancellationRequested: Bool? = nil,
                updatedAt: Date? = nil) {
        self.schema = schema
        self.origin = origin
        self.prepared = prepared
        self.progress = progress
        self.cancellationRequested = cancellationRequested
        self.updatedAt = updatedAt
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data?) -> NativeJobProgressDocument? {
        guard let data, !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(NativeJobProgressDocument.self, from: data)
    }
}

/// Coalesces real processor progress into `progress_json` without writing on
/// every frame: a write happens at most every `minimumInterval`, always on a
/// stage change, and exactly once more when the processor acknowledges.
public actor NativeJobProgressRecorder {
    static let minimumInterval: TimeInterval = 0.5

    private let store: BackgroundJobStore
    private let jobID: UUID
    private var document: NativeJobProgressDocument
    private var lastWriteAt: Date = .distantPast
    private var lastWrittenStage: NativeJobProgress.Stage?
    private var flushTask: Task<Void, Never>?
    private var finished = false
    /// Number of durable progress writes performed (coalescing evidence).
    public private(set) var writeCount = 0

    public init(store: BackgroundJobStore, jobID: UUID, document: NativeJobProgressDocument) {
        self.store = store
        self.jobID = jobID
        self.document = document
    }

    /// The document as last recorded in memory (test/introspection helper).
    public var snapshot: NativeJobProgressDocument { document }

    public func record(_ progress: NativeJobProgress) async {
        guard !finished else { return }
        // A stage-only observation (finalizing/verifying/cancelling) keeps the
        // last REAL units/phase instead of erasing them.
        var merged = progress
        if merged.phase == nil { merged.phase = document.progress?.phase }
        if merged.completedUnits == nil { merged.completedUnits = document.progress?.completedUnits }
        if merged.totalUnits == nil { merged.totalUnits = document.progress?.totalUnits }
        document.progress = merged
        document.updatedAt = Date()
        let stageChanged = merged.stage != lastWrittenStage
        if stageChanged || Date().timeIntervalSince(lastWriteAt) >= Self.minimumInterval {
            await write()
        } else {
            scheduleFlush()
        }
    }

    public func markCancellationRequested(note: String? = nil) async {
        guard !finished else { return }
        document.cancellationRequested = true
        document.progress = NativeJobProgress(stage: .cancelling,
                                              phase: document.progress?.phase,
                                              completedUnits: document.progress?.completedUnits,
                                              totalUnits: document.progress?.totalUnits,
                                              note: note ?? "Cancellation requested; waiting for the processor to stop and clean up")
        document.updatedAt = Date()
        await write()
    }

    /// Final flush before the terminal transition (the store ignores writes
    /// once the job is no longer running, so this must run first).
    public func finish() async {
        finished = true
        flushTask?.cancel()
        flushTask = nil
        document.updatedAt = Date()
        await write()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NativeJobProgressRecorder.minimumInterval * 1_000_000_000))
            guard let self else { return }
            await self.flushIfPending()
        }
    }

    private func flushIfPending() async {
        flushTask = nil
        guard !finished else { return }
        guard Date().timeIntervalSince(lastWriteAt) >= Self.minimumInterval else {
            scheduleFlush()
            return
        }
        await write()
    }

    private func write() async {
        lastWriteAt = Date()
        lastWrittenStage = document.progress?.stage
        guard let data = document.encoded() else { return }
        writeCount += 1
        try? await store.updateProgress(id: jobID, data: data)
    }
}

// MARK: - Prepared service operations

/// Hooks the job service provides to one prepared operation. `report` is
/// coalesced by the service; `isCancellationRequested` is the cooperative
/// signal the operation must honor at its own safe checkpoints.
public struct NativeJobRunHooks: Sendable {
    public var report: @Sendable (NativeJobProgress) async -> Void
    public var isCancellationRequested: @Sendable () -> Bool

    public init(report: @escaping @Sendable (NativeJobProgress) async -> Void,
                isCancellationRequested: @escaping @Sendable () -> Bool) {
        self.report = report
        self.isCancellationRequested = isCancellationRequested
    }
}

/// Terminal result of one prepared operation. `artifactPath` is a REAL file
/// the service already verified (never a promise); the job service re-checks
/// existence before recording it as `resultPath`.
public struct NativeJobOutcome: Sendable {
    public var summary: String
    public var digest: String?
    public var verified: [String]
    public var artifactPath: String?
    public var frozenRevision: String?

    public init(summary: String, digest: String? = nil, verified: [String] = [],
                artifactPath: String? = nil, frozenRevision: String? = nil) {
        self.summary = summary
        self.digest = digest
        self.verified = verified
        self.artifactPath = artifactPath
        self.frozenRevision = frozenRevision
    }
}

/// Proof that the exact submitting `jobs.submit` call was runtime-approved.
/// `.consumed` is built by `BackgroundJobService.submit` only after
/// `RuntimeAuthorityStore.consume` returned `.valid` for the binding the
/// runtime minted; a model field can never produce it.
public enum NativeJobAuthorization: Sendable {
    case notRequired
    case consumed(binding: RuntimeAuthorityBinding, at: Date)

    public var binding: RuntimeAuthorityBinding? {
        switch self {
        case .notRequired: return nil
        case .consumed(let binding, _): return binding
        }
    }

    public var consumedAt: Date? {
        switch self {
        case .notRequired: return nil
        case .consumed(_, let at): return at
        }
    }
}

/// Everything a service adapter needs to freeze the concrete operation
/// BEFORE the durable record exists.
public struct NativeJobPreparationRequest: Sendable {
    /// Stable operation identity derived from the submitting call
    /// (`NativeJobOperationIdentity.derive`); reused across retries.
    public var operationID: String
    public var runID: UUID
    public var conversationID: UUID
    public var environmentID: String?
    public var workspaceRootURL: URL?
    public var allowedWorkspacePaths: [String]
    public var scope: ToolScope
    public var payloadJSON: Data
    public var origin: NativeJobOrigin
    public var authorization: NativeJobAuthorization
    public var approvalGrantID: UUID?
    public var submittedCallID: String?
    public var idempotencyKey: String

    public init(operationID: String, runID: UUID, conversationID: UUID,
                environmentID: String?, workspaceRootURL: URL?,
                allowedWorkspacePaths: [String], scope: ToolScope,
                payloadJSON: Data, origin: NativeJobOrigin,
                authorization: NativeJobAuthorization, approvalGrantID: UUID?,
                submittedCallID: String?, idempotencyKey: String) {
        self.operationID = operationID
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.workspaceRootURL = workspaceRootURL
        self.allowedWorkspacePaths = allowedWorkspacePaths
        self.scope = scope
        self.payloadJSON = payloadJSON
        self.origin = origin
        self.authorization = authorization
        self.approvalGrantID = approvalGrantID
        self.submittedCallID = submittedCallID
        self.idempotencyKey = idempotencyKey
    }

    /// Consumed-authority binding for the exact `jobs.submit` call, when the
    /// adapter declared `requiresRuntimeAuthorization`.
    public var consumedBinding: RuntimeAuthorityBinding? { authorization.binding }
}

/// A service-owned operation prepared before the durable record was created.
/// `run` must reach a real, verified terminal result or throw; when
/// cancellation is requested it must unwind its own staging and throw
/// `FloeError.cancelled` only AFTER cleanup is complete. It must never claim
/// a success it cannot verify.
public protocol NativeJobPreparedOperation: Sendable {
    /// Stable identity reused for this operation across retries/replays.
    var operationID: String { get }
    /// Revision frozen at submission (base SHA, project revision, …).
    var frozenRevision: String? { get }
    /// Human-readable service label used in receipts.
    var serviceLabel: String { get }
    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome
    /// Cooperative request; does NOT force. `run` remains responsible for
    /// unwinding and for the final acknowledgement.
    func requestCancellation() async
}

public extension NativeJobPreparedOperation {
    func requestCancellation() async {}
}

/// One service-owned adapter keyed by target tool. `prepare` runs inside
/// `BackgroundJobService.submit` before persistence; throwing refuses the
/// submission with nothing durable left behind.
public struct NativeJobServiceAdapter: Sendable {
    public var targetTool: String
    /// Payload actions this adapter owns; nil = every action the policy admits.
    public var adaptedActions: Set<String>?
    /// Consume the runtime authority for the EXACT submitting `jobs.submit`
    /// call before `prepare` runs. Required for authorized Office/media apply.
    public var requiresRuntimeAuthorization: Bool
    public var prepare: @Sendable (NativeJobPreparationRequest) async throws -> any NativeJobPreparedOperation
    /// Launch reconciliation for an interrupted attempt of this target: check
    /// a REAL side effect and return a terminal state only when it is proven.
    /// nil keeps the honest `interrupted` outcome.
    public var reconcile: (@Sendable (BackgroundJob) async -> BackgroundJobState?)?

    public init(targetTool: String,
                adaptedActions: Set<String>? = nil,
                requiresRuntimeAuthorization: Bool = false,
                prepare: @escaping @Sendable (NativeJobPreparationRequest) async throws -> any NativeJobPreparedOperation,
                reconcile: (@Sendable (BackgroundJob) async -> BackgroundJobState?)? = nil) {
        self.targetTool = targetTool
        self.adaptedActions = adaptedActions
        self.requiresRuntimeAuthorization = requiresRuntimeAuthorization
        self.prepare = prepare
        self.reconcile = reconcile
    }

    /// Whether this adapter owns the given payload action. An adapter without
    /// `adaptedActions` owns every action the policy admits.
    public func handles(action: String?) -> Bool {
        guard let adaptedActions else { return true }
        guard let action else { return false }
        return adaptedActions.contains(action)
    }
}

/// Stable operation identity for one submitted call: the same run + call id +
/// approved payload always derives the same id, so a retried submission
/// reuses one operation identity instead of creating a parallel operation.
/// A prepared operation failed while resources may still be live. Distinct
/// from a cancellation: the processor did not stop cleanly and its staging is
/// retained, so no consumer may report a clean cancelled state.
public struct NativeJobSafetyFailure: Error, LocalizedError, UnsafeResourceStateError, Sendable, Equatable {
    public var reason: String
    public var stagingRetained: Bool

    public init(reason: String, stagingRetained: Bool = true) {
        self.reason = reason
        self.stagingRetained = stagingRetained
    }

    public var unsafeResourceReason: String { reason }

    public var errorDescription: String? {
        "The job stopped in an unsafe resource state: \(reason). "
            + (stagingRetained
               ? "Its staging was retained for recovery and native workers may still be finishing; do not retry until the app restarts."
               : "Verify the target before retrying.")
    }
}

public enum NativeJobOperationIdentity {
    public static func derive(runID: UUID, toolCallID: String?, payloadDigest: String) -> String {
        let material = "job|\(runID.uuidString)|\(toolCallID ?? "-")|\(payloadDigest)"
        return String(FloeDigest.sha256Hex(Data(material.utf8)).prefix(32))
    }
}

// MARK: - Action policy

/// One admitted target. `allowedActions` contains `"*"` when any payload is
/// acceptable (single-purpose tools whose arguments carry no `action`).
public struct NativeJobHandler: Sendable {
    public var allowedActions: Set<String>
    /// Runs after argument decode/validation and before the durable record is
    /// created. Throwing refuses the submission with no job left behind.
    public var preflight: (@Sendable (Data, URL?) async throws -> Void)?
    /// Launch reconciliation hook for an interrupted job. Returning a terminal
    /// state reclassifies it; nil keeps the honest `interrupted` outcome.
    public var reconcile: (@Sendable (BackgroundJob) async -> BackgroundJobState?)?

    public init(allowedActions: Set<String>,
                preflight: (@Sendable (Data, URL?) async throws -> Void)? = nil,
                reconcile: (@Sendable (BackgroundJob) async -> BackgroundJobState?)? = nil) {
        self.allowedActions = allowedActions
        self.preflight = preflight
        self.reconcile = reconcile
    }

    /// Path-aware handler: admits the actions and preflights real workspace
    /// files/revisions with `NativeJobPreflight.standard`.
    public static func pathAware(allowedActions: Set<String>) -> NativeJobHandler {
        NativeJobHandler(allowedActions: allowedActions,
                         preflight: { payload, root in
                             try await NativeJobPreflight.standard(payload: payload,
                                                                   workspaceRoot: root)
                         })
    }
}

public struct NativeJobActionPolicy: Sendable {
    public static let anyAction = "*"

    /// Targets that must NEVER run as deferred work, by name, in addition to
    /// the structural `mainRunOnly`/`childOnly` boundary checks: delegation
    /// itself and user-visible task spawning can never be smuggled through a
    /// job wrapper.
    public static let delegationDeniedTargets: Set<String> = [
        "delegate", "conversation.spawn"
    ]

    public var handlers: [String: NativeJobHandler]

    public init(handlers: [String: NativeJobHandler]) {
        self.handlers = handlers
    }

    public var supportedTargetNames: Set<String> {
        Set(handlers.keys)
    }

    /// The action a payload declares, when it has one.
    public func action(in payload: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let action = object["action"] as? String else { return nil }
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func allows(target: String, action: String?) -> Bool {
        guard let handler = handlers[target] else { return false }
        if handler.allowedActions.contains(Self.anyAction) { return true }
        guard let action else { return false }
        return handler.allowedActions.contains(action)
    }

    public func refusal(target: String, action: String?) -> String {
        guard let handler = handlers[target] else {
            return "jobs.submit does not admit '\(target)'; admitted targets: \(supportedTargetNames.sorted().joined(separator: ", ")). Run other tools directly."
        }
        if handler.allowedActions.contains(Self.anyAction) {
            return "jobs.submit does not admit '\(target)' from this build"
        }
        let admitted = handler.allowedActions.sorted().joined(separator: ", ")
        return "jobs.submit admits '\(target)' only for action(s) \(admitted), not '\(action ?? "none")'. Run that action directly instead of as a background job."
    }

    /// Default policy: the legacy six targets plus the native long-job
    /// targets. `media.project` apply and `document.office.edit` apply are
    /// admitted only through a registered service adapter (which consumes the
    /// runtime authority for the submitting call at submission); without one,
    /// only their export actions are admitted so a single-use authority is
    /// never deferred past its approving call.
    public static let `default`: NativeJobActionPolicy = {
        let any: Set<String> = [anyAction]
        return NativeJobActionPolicy(handlers: [
            // Legacy targets keep their exact previous admission.
            "exec.localService": NativeJobHandler(allowedActions: any),
            "exec.shell": NativeJobHandler(allowedActions: any),
            "network.download": NativeJobHandler(allowedActions: any),
            "network.http": NativeJobHandler(allowedActions: any),
            "web.fetch": NativeJobHandler(allowedActions: any),
            // Native media pipelines.
            "video.edit": .pathAware(allowedActions: any),
            "video.interpolate": .pathAware(allowedActions: any),
            "video.superResolution": .pathAware(allowedActions: any),
            "media.project": .pathAware(allowedActions: ["export"]),
            // PDF and Office package work.
            "document.pdf.export": .pathAware(allowedActions: any),
            "document.pdf.edit": .pathAware(allowedActions: any),
            "document.office.updateText": .pathAware(allowedActions: any),
            "document.office.edit": .pathAware(allowedActions: ["export"]),
        ])
    }()

    /// The policy an app with prepared Office/media adapters uses: identical
    /// to `.default` plus the adapt-supplied apply actions.
    public static func withAdaptedApplyActions(_ extra: [String: Set<String>]) -> NativeJobActionPolicy {
        var handlers = `default`.handlers
        for (target, actions) in extra {
            guard let existing = handlers[target] else { continue }
            handlers[target] = NativeJobHandler(
                allowedActions: existing.allowedActions.union(actions),
                preflight: existing.preflight,
                reconcile: existing.reconcile)
        }
        return NativeJobActionPolicy(handlers: handlers)
    }
}

// MARK: - Submit-time workspace preflight

/// Submit-time workspace preflight shared by the path-aware handlers.
public enum NativeJobPreflight {
    static let inputKeys = ["input", "inputPath", "path", "source"]
    static let outputKeys = ["output", "outputPath"]
    static let revisionKeys = ["expectedSHA256", "expected_sha256", "baseSHA256", "base_sha256"]
    static let maximumDigestBytes: Int64 = 256 * 1_024 * 1_024

    /// Rejects a job whose declared input does not exist under the resolved
    /// task workspace, whose output escapes that workspace, or whose declared
    /// base revision no longer matches the bytes on disk. Nothing is persisted
    /// when this throws.
    public static func standard(payload: Data, workspaceRoot: URL?,
                                fileManager: FileManager = .default) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }
        var declaredPaths: [String] = []
        for key in inputKeys + outputKeys {
            if let value = object[key] as? String, !value.isEmpty { declaredPaths.append(value) }
        }
        guard !declaredPaths.isEmpty else { return }
        guard let root = workspaceRoot else {
            throw FloeError.validationFailed(
                "This job targets workspace files but the call has no task workspace; run it from a task with a workspace")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        func resolve(_ raw: String) throws -> URL {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else {
                throw FloeError.validationFailed("invalid job path")
            }
            let url: URL
            if trimmed.hasPrefix("/") {
                url = URL(fileURLWithPath: trimmed)
            } else {
                url = canonicalRoot.appendingPathComponent(trimmed)
            }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path == canonicalRoot.path
                || canonical.path.hasPrefix(canonicalRoot.path + "/") else {
                throw FloeError.validationFailed("job path is outside the task workspace")
            }
            return canonical
        }

        var inputs: [URL] = []
        for key in inputKeys {
            guard let raw = object[key] as? String, !raw.isEmpty else { continue }
            let url = try resolve(raw)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw FloeError.validationFailed("job input does not exist or is not a regular file: \(raw)")
            }
            inputs.append(url)
        }
        for key in outputKeys {
            guard let raw = object[key] as? String, !raw.isEmpty else { continue }
            let url = try resolve(raw)
            let parent = url.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: parent.path) else {
                throw FloeError.validationFailed("job output directory does not exist: \(parent.path)")
            }
        }
        for url in inputs {
            guard let expected = declaredRevision(object) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size <= maximumDigestBytes else {
                throw FloeError.validationFailed("job input is too large to revision-check before submission")
            }
            let actual = try FloeDigest.sha256Hex(ofFileAt: url)
            guard actual.lowercased() == expected.lowercased() else {
                throw FloeError.validationFailed(
                    "job input changed since it was read (expected \(expected.prefix(12))…, found \(actual.prefix(12))…); re-read and resubmit")
            }
        }
    }

    /// The declared base revision applies to the tool's primary input. Only a
    /// well-formed 64-hex value participates; other shapes are left to the
    /// tool's own validation.
    private static func declaredRevision(_ object: [String: Any]) -> String? {
        for key in revisionKeys {
            guard let value = object[key] as? String, value.count == 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                continue
            }
            return value
        }
        return nil
    }
}

// MARK: - Cross-task/environment declarations

/// Rejects a submitted payload that DECLARES a run/task/environment different
/// from the trusted submission context. A job always executes on the frozen
/// task/environment/workspace of the submitting call; a payload claiming
/// another owner is refused instead of being silently rerouted.
public enum NativeJobRequestScope {
    static let taskKeys = ["taskID", "task_id", "conversationID", "conversation_id", "runID", "run_id"]
    static let environmentKeys = ["environmentID", "environment_id"]

    public static func check(payload: Data,
                             runID: UUID,
                             conversationID: UUID,
                             environmentID: String?) throws {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return
        }
        for key in taskKeys {
            guard let raw = object[key] as? String else { continue }
            guard let declared = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw FloeError.validationFailed("job argument '\(key)' is not a valid identifier")
            }
            guard declared == runID || declared == conversationID else {
                throw FloeError.validationFailed(
                    "job argument '\(key)' names a different task/run; background work runs only on the submitting task")
            }
        }
        for key in environmentKeys {
            guard let raw = object[key] as? String, !raw.isEmpty else { continue }
            guard let environmentID else {
                throw FloeError.validationFailed(
                    "job argument '\(key)' names an environment but the submitting call has none")
            }
            guard raw == environmentID else {
                throw FloeError.validationFailed(
                    "job argument '\(key)' names a different environment; background work runs only in the submitting environment")
            }
        }
    }
}

// MARK: - Text bounds

public enum NativeJobTextLimits {
    /// Durable failure text bound: identifiers and the cause survive, a giant
    /// stack dump does not silently enter the store or a tool result.
    public static let maximumFailureCharacters = 4_096

    public static func bounded(_ text: String, limit: Int = maximumFailureCharacters) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        return String(head) + " […truncated at \(limit) characters]"
    }
}
