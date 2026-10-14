// FloeExecution — jobs.* background task tools.
// Interaction model mirrors the SSH guardian tools: submit returns a durable
// jobID immediately; status/result/cancel operate on that jobID later.

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

private func jobsOutput(_ payload: some Encodable) throws -> ToolExecutionOutput {
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(payload)
    return ToolExecutionOutput(
        summary: String(decoding: data, as: UTF8.self),
        fullOutputSHA256: FloeDigest.sha256Hex(data),
        // The jobs.* envelope is an explicitly declared bounded exception
        // (ToolExecutionOutput clamps to 262_144); every field inside is
        // individually bounded and no identifier is ever truncated.
        maximumSummaryCharacters: 262_144
    )
}

private struct JobProgressView: Encodable {
    let stage: String
    let phase: String?
    let completedUnits: Int?
    let totalUnits: Int?
    let fraction: Double?
    let note: String?

    init(_ progress: NativeJobProgress) {
        stage = progress.stage.rawValue
        phase = progress.phase
        completedUnits = progress.completedUnits
        totalUnits = progress.totalUnits
        fraction = progress.fraction
        note = progress.note
    }
}

private struct JobOriginView: Encodable {
    let kind: String
    let childID: String?
    let rootTaskID: String?
    let submittedCallID: String?

    init(_ origin: NativeJobOrigin) {
        kind = origin.kind.rawValue
        childID = origin.childID?.uuidString
        rootTaskID = origin.rootTaskID?.uuidString
        submittedCallID = origin.submittedCallID
    }
}

private struct JobView: Encodable {
    let jobID: String
    let state: String
    let targetTool: String
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    let hasResult: Bool
    /// Present only when the recorded artifact path names a file that still
    /// exists; a stale path is reported honestly as absent.
    let resultPath: String?
    let lastError: String?
    /// Raw progress document (bounded) for diagnostics.
    let progressJSON: String?
    /// True while a cancellation request is outstanding and the processor has
    /// not acknowledged yet; the job is still running.
    let cancelling: Bool
    let progress: JobProgressView?
    let origin: JobOriginView?
    let preparedOperationID: String?
    let frozenRevision: String?

    init(_ job: BackgroundJob) {
        jobID = job.id.uuidString
        state = job.state.rawValue
        targetTool = job.targetTool
        createdAt = ISO8601DateFormatter().string(from: job.createdAt)
        updatedAt = ISO8601DateFormatter().string(from: job.updatedAt)
        completedAt = job.completedAt.map { ISO8601DateFormatter().string(from: $0) }
        let verifiedPath = job.resultPath.flatMap { path -> String? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return path
        }
        resultPath = verifiedPath
        hasResult = job.resultSummary != nil || verifiedPath != nil
        lastError = job.lastError
        progressJSON = job.progressJSON.map { String(decoding: $0, as: UTF8.self) }
        let document = NativeJobProgressDocument.decode(job.progressJSON)
        cancelling = !job.state.isTerminal && (document?.cancellationRequested == true)
        progress = document?.progress.map(JobProgressView.init)
        origin = document?.origin.map(JobOriginView.init)
        preparedOperationID = document?.prepared?.operationID
        frozenRevision = document?.prepared?.frozenRevision
    }
}

private func parseJobID(_ raw: String) throws -> UUID {
    guard let id = UUID(uuidString: raw) else {
        throw FloeError.validationFailed("jobID must be a UUID returned by jobs.submit")
    }
    return id
}

public struct JobsSubmitTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var tool: String
        /// JSON-encoded arguments object for the target tool.
        public var arguments: String
        public var purpose: String?
        public init(tool: String, arguments: String, purpose: String? = nil) {
            self.tool = tool; self.arguments = arguments; self.purpose = purpose
        }
    }

    public static let name = "jobs.submit"
    public static let toolDescription = """
    Submit a long-running operation as a durable background job and return immediately with a jobID instead of blocking this task. \
    Admitted targets: exec.localService (persistent Node/Python preview servers; inspect its schema first), exec.shell, \
    exec.localPython (data pulls/cleaning), network.download (large files, survives app suspension), network.http, web.fetch, \
    video.edit, video.interpolate, video.superResolution (real media pipelines), media.project (export; apply only when the app \
    registered an authorized media adapter), document.pdf.edit, document.pdf.export, document.office.updateText (Office package \
    batch) and document.office.edit (export; apply only with the app's authorized Office adapter). A delegated child may submit \
    the SAME eligible targets through the same effective parent capability ceiling; delegation itself \
    (delegate/conversation.spawn) and main-run-only capabilities can never be deferred, and a job never runs outside its \
    frozen task/environment/workspace. The declared input file, its workspace confinement and any expectedSHA256/base \
    revision are checked BEFORE the job is persisted, so resubmitting a stale revision is refused at the call site. \
    Authorized Office/media apply submissions additionally require the runtime-issued approval of this exact jobs.submit \
    call; a model-authored confirmation is never authority. arguments is a JSON-encoded object for the target tool. Track \
    progress with jobs.status, collect output with jobs.result, stop it with jobs.cancel; completion is also announced \
    automatically to this task only. Never submit a duplicate payload for the same purpose — one job is enough.
    """
    public static let parametersJSON = #"{"type":"object","properties":{"tool":{"type":"string","description":"Target tool name. Admitted: exec.localService, exec.shell, exec.localPython, network.download, network.http, web.fetch, video.edit, video.interpolate, video.superResolution, media.project, document.pdf.edit, document.pdf.export, document.office.updateText, document.office.edit (export/authorized apply)."},"arguments":{"type":"string","maxLength":65536,"description":"JSON-encoded arguments object for the target tool. For media/PDF/Office targets the input path, workspace confinement and any expectedSHA256/base revision are preflighted before the job is persisted."},"purpose":{"type":"string","maxLength":240,"description":"Short human-visible reason for this job"}},"required":["tool","arguments"],"additionalProperties":false}"#
    // The real risk profile belongs to the named target; the union keeps
    // approval policy conservative because labels are compile-time static.
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesLocalCode, .readsFiles, .writesFiles, .deletesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    /// Canonical JSON of the decoded jobs.submit arguments, in exactly the
    /// shape the runtime hashed when it minted this call's authority. Optional
    /// fields that were absent stay absent.
    public static func canonicalApprovedPayload(_ args: Arguments) throws -> Data {
        var object: [String: Any] = ["tool": args.tool, "arguments": args.arguments]
        if let purpose = args.purpose { object["purpose"] = purpose }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Mirrors `RuntimeAuthorityDigest.canonicalTarget` for this tool:
    /// `jobs.submit` is a workspace-wildcard mutating target, so the runtime
    /// resolves the canonical workspace root (or `*` when absent).
    public static func canonicalTarget(context: ToolContext) -> String {
        guard let root = context.workspaceRootURL else { return "workspace:*" }
        return "workspace:" + root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Builds the binding the runtime minted for this exact `jobs.submit`
    /// call. Throws only when the approved arguments cannot be canonicalized
    /// (itself a refusal, never a bypass).
    public static func runtimeAuthorityBinding(for args: Arguments, context: ToolContext) throws -> RuntimeAuthorityBinding {
        let payload = try canonicalApprovedPayload(args)
        return context.runtimeAuthorityBinding(
            toolName: name,
            operation: "job.submit",
            canonicalTarget: canonicalTarget(context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: payload),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payload))
    }

    public func validate(_ args: Arguments) throws {
        guard BackgroundJobService.supportedTargets.contains(args.tool) else {
            throw FloeError.validationFailed("Unsupported job target '\(args.tool)'; admitted: \(BackgroundJobService.supportedTargets.sorted().joined(separator: ", "))")
        }
        guard let data = args.arguments.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw FloeError.validationFailed("arguments must be a JSON-encoded object for the target tool")
        }
        if let purpose = args.purpose {
            guard purpose.utf8.count <= 240 else { throw FloeError.validationFailed("purpose must be at most 240 bytes") }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let payload = Data(args.arguments.utf8)
        // The runtime authority for THIS exact jobs.submit call is forwarded
        // to the service, which consumes it only for adapters that require a
        // prepared authorized operation (Office/media apply) and only for a
        // NEW job (an idempotent replay never re-consumes).
        let binding = try? Self.runtimeAuthorityBinding(for: args, context: context)
        let job = try await service.submit(
            runID: context.runID,
            toolCallID: context.toolCallID,
            targetTool: args.tool,
            payloadJSON: payload,
            scope: context.scope,
            workspaceRootURL: context.workspaceRootURL,
            allowedWorkspacePaths: context.allowedWorkspacePaths,
            environmentID: context.environmentID,
            allowedToolNames: context.allowedToolNames,
            callOrigin: context.callOrigin,
            childExecution: context.childExecution,
            toolIdempotencyKey: context.toolIdempotencyKey,
            approvalGrantID: context.approvalGrantID,
            runtimeAuthority: context.runtimeAuthority,
            runtimeAuthorityBinding: binding,
            // This is the RAW REGISTERED entry a reconstructed wrapper context
            // reaches; it must never inherit the in-process native-service
            // fallback. `.runtime` requires the runtime-issued nonnil call id
            // and the `jobs.submit` origin binding this exact call, so a
            // context with stripped provenance is refused before any record
            // or effect.
            submissionSource: .runtime
        )
        struct Response: Encodable {
            let jobID: String
            let state: String
            let targetTool: String
            /// False when this call id already owned a job with different
            /// arguments: the ORIGINAL accepted payload is what runs.
            let payloadMatches: Bool
            let note: String
        }
        let payloadMatches = job.payloadJSON == payload
        let note = payloadMatches
            ? "Job accepted. Do not resubmit the same payload; use jobs.status/jobs.result with this jobID. Completion is announced automatically to this task even if this run ends."
            : "This call id already has an accepted job with DIFFERENT arguments; the original payload runs. Poll it with this jobID, or submit the changed operation under a new call id."
        return try jobsOutput(Response(
            jobID: job.id.uuidString,
            state: job.state.rawValue,
            targetTool: job.targetTool,
            payloadMatches: payloadMatches,
            note: note
        ))
    }
}

public struct JobsStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.status"
    public static let toolDescription = "Check a background job's state (queued/running/completed/failed/cancelled/interrupted), the real processor progress (stage/phase/units when the owning service reports them), whether cancellation is still pending, who submitted it, and whether its result is ready. Poll no faster than every few seconds; completion is also announced automatically."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let job = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        return try jobsOutput(JobView(job))
    }
}

public struct JobsResultTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.result"
    public static let toolDescription = "Fetch a finished background job's output. resultSummary carries the recorded result; resultPath is present only when the owning service actually wrote a file and it still exists. For a job that is still running this returns its state — wait for the automatic completion announcement instead of tight polling. When the process died mid-job the status is interrupted: the outcome is UNKNOWN, so inspect existing outputs read-only before explicitly resubmitting."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let job = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        struct Response: Encodable {
            let job: JobView
            let resultSummary: String?
            let resultDigest: String?
            let note: String?
        }
        let note: String? = switch job.state {
        case .completed:
            job.resultPath != nil && JobView(job).resultPath == nil
                ? "The job completed, but its recorded result file is no longer present; resultSummary is what remains."
                : nil
        case .interrupted: "The process exited before this job finished, so its outcome is UNKNOWN — partial outputs may already exist. Inspect the workspace/output read-only first, then resubmit only what is still missing; do not blindly rerun."
        case .cancelled: "Job was cancelled after its processor stopped; no result is claimed complete. Check the workspace before retrying."
        case .failed: "Job failed; lastError carries the reason."
        case .queued, .running: JobView(job).cancelling
            ? "Cancellation has been requested; the processor is still stopping and cleaning up. The job is NOT terminal yet."
            : "Job is still \(job.state.rawValue); wait for the completion announcement or poll jobs.status every few seconds."
        }
        return try jobsOutput(Response(
            job: JobView(job),
            resultSummary: job.resultSummary,
            resultDigest: job.resultDigest,
            note: note
        ))
    }
}

public struct JobsCancelTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.cancel"
    public static let toolDescription = "Cancel a queued or running background job. Cancellation is cooperative and truthful: a running job stays non-terminal (jobs.status reports cancelling=true) until its processor acknowledges and its cleanup completes, then it becomes cancelled. A job that already finished keeps its actual terminal state instead. A cancelled job's partial outputs are never claimed complete."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owned = try await service.ownedJob(id: parseJobID(args.jobID), runID: context.runID)
        let job = try await service.cancel(id: owned.id)
        return try jobsOutput(JobView(job))
    }
}

/// Registers the jobs.* tool group. Call after the target tools are
/// registered so submit-time availability checks see them.
/// - Parameters:
///   - adapters: service-owned prepared-operation adapters keyed by target
///     tool (Office/media authorized jobs). An adapter with
///     `requiresRuntimeAuthorization` consumes the runtime authority for the
///     exact submitting `jobs.submit` call at submission.
/// - Returns: the service, so the app can reconcile interrupted jobs at
///   launch and observe terminal transitions for notifications.
@discardableResult
public func registerBackgroundJobTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    policy: NativeJobActionPolicy = .default,
    adapters: [String: NativeJobServiceAdapter] = [:],
    onTerminal: @escaping @Sendable (BackgroundJob) async -> Void = { _ in },
    downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)? = nil,
    downloadCancelHandler: (@Sendable (UUID) async -> Void)? = nil,
    downloadTaskLiveness: (@Sendable (UUID) async -> Bool)? = nil
) -> BackgroundJobService {
    let store = BackgroundJobStore(database: database)
    let service = BackgroundJobService(
        store: store,
        registry: registry,
        policy: policy,
        adapters: adapters,
        onTerminal: onTerminal,
        downloadHandler: downloadHandler,
        downloadCancelHandler: downloadCancelHandler,
        downloadTaskLiveness: downloadTaskLiveness
    )
    ToolCatalog.register(JobsSubmitTool.self)
    ToolCatalog.register(JobsStatusTool.self)
    ToolCatalog.register(JobsResultTool.self)
    ToolCatalog.register(JobsCancelTool.self)
    registry.register(JobsSubmitTool(service: service))
    registry.register(JobsStatusTool(service: service))
    registry.register(JobsResultTool(service: service))
    registry.register(JobsCancelTool(service: service))
    return service
}
