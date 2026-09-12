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
        maximumSummaryCharacters: 262_144
    )
}

private struct JobView: Encodable {
    let jobID: String
    let state: String
    let targetTool: String
    let createdAt: String
    let updatedAt: String
    let completedAt: String?
    let hasResult: Bool
    let resultPath: String?
    let lastError: String?

    init(_ job: BackgroundJob) {
        jobID = job.id.uuidString
        state = job.state.rawValue
        targetTool = job.targetTool
        createdAt = ISO8601DateFormatter().string(from: job.createdAt)
        updatedAt = ISO8601DateFormatter().string(from: job.updatedAt)
        completedAt = job.completedAt.map { ISO8601DateFormatter().string(from: $0) }
        hasResult = job.resultSummary != nil || job.resultPath != nil
        resultPath = job.resultPath
        lastError = job.lastError
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
    public static let toolDescription = "Submit a long-running operation as a durable background job and return immediately with a jobID instead of blocking this task. Supported targets: exec.localPython (data pulls/cleaning), network.download (large files, survives app suspension), network.http, web.fetch. arguments is a JSON-encoded object for the target tool. Track progress with jobs.status, collect output with jobs.result, stop it with jobs.cancel; completion is also announced automatically. Never submit a duplicate payload for the same purpose — one job is enough."
    public static let parametersJSON = #"{"type":"object","properties":{"tool":{"type":"string","description":"Target tool name: exec.localPython, network.download, network.http, or web.fetch"},"arguments":{"type":"string","maxLength":65536,"description":"JSON-encoded arguments object for the target tool"},"purpose":{"type":"string","maxLength":240,"description":"Short human-visible reason for this job"}},"required":["tool","arguments"],"additionalProperties":false}"#
    // The real risk profile belongs to the named target; the union keeps
    // approval policy conservative because labels are compile-time static.
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesLocalCode, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        guard BackgroundJobService.supportedTargets.contains(args.tool) else {
            throw FloeError.validationFailed("Unsupported job target '\(args.tool)'; supported: \(BackgroundJobService.supportedTargets.sorted().joined(separator: ", "))")
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
        let job = try await service.submit(
            runID: context.runID,
            toolCallID: context.toolCallID,
            targetTool: args.tool,
            payloadJSON: payload,
            scope: context.scope,
            workspaceRootURL: context.workspaceRootURL,
            allowedWorkspacePaths: context.allowedWorkspacePaths,
            environmentID: context.environmentID
        )
        struct Response: Encodable {
            let jobID: String
            let state: String
            let targetTool: String
            let note: String
        }
        return try jobsOutput(Response(
            jobID: job.id.uuidString,
            state: job.state.rawValue,
            targetTool: job.targetTool,
            note: "Job accepted. Do not resubmit the same payload; use jobs.status/jobs.result with this jobID. Completion is announced automatically even if this run ends."
        ))
    }
}

public struct JobsStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.status"
    public static let toolDescription = "Check a background job's state (queued/running/completed/failed/cancelled/interrupted), progress, and whether its result is ready. Poll no faster than every few seconds; completion is also announced automatically."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let job = try await service.job(id: parseJobID(args.jobID)) else {
            throw FloeError.validationFailed("No such background job: \(args.jobID)")
        }
        return try jobsOutput(JobView(job))
    }
}

public struct JobsResultTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var jobID: String
        public init(jobID: String) { self.jobID = jobID }
    }

    public static let name = "jobs.result"
    public static let toolDescription = "Fetch a finished background job's output. Large results are spilled to a workspace file whose path is reported as resultPath. For a job that is still running this returns its state — wait for the automatic completion announcement instead of tight polling."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let job = try await service.job(id: parseJobID(args.jobID)) else {
            throw FloeError.validationFailed("No such background job: \(args.jobID)")
        }
        struct Response: Encodable {
            let job: JobView
            let resultSummary: String?
            let resultDigest: String?
            let note: String?
        }
        let note: String? = switch job.state {
        case .completed: nil
        case .interrupted: "The process exited before this job finished; nothing completed. Resubmit via jobs.submit when still needed."
        case .cancelled: "Job was cancelled; no result exists."
        case .failed: "Job failed; lastError carries the reason."
        case .queued, .running: "Job is still \(job.state.rawValue); wait for the completion announcement or poll jobs.status every few seconds."
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
    public static let toolDescription = "Cancel a queued or running background job. Cancellation is cooperative: runners stop at their next checkpoint, and a job that already finished reports its terminal state instead."
    public static let parametersJSON = #"{"type":"object","properties":{"jobID":{"type":"string","description":"UUID returned by jobs.submit"}},"required":["jobID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let service: BackgroundJobService
    public init(service: BackgroundJobService) { self.service = service }

    public func validate(_ args: Arguments) throws { _ = try parseJobID(args.jobID) }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let job = try await service.cancel(id: parseJobID(args.jobID))
        return try jobsOutput(JobView(job))
    }
}

/// Registers the jobs.* tool group. Call after the target tools are
/// registered so submit-time availability checks see them.
/// - Returns: the service, so the app can reconcile interrupted jobs at
///   launch and observe terminal transitions for notifications.
@discardableResult
public func registerBackgroundJobTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    onTerminal: @escaping @Sendable (BackgroundJob) async -> Void = { _ in },
    downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)? = nil,
    downloadCancelHandler: (@Sendable (UUID) async -> Void)? = nil,
    downloadTaskLiveness: (@Sendable (UUID) async -> Bool)? = nil
) -> BackgroundJobService {
    let store = BackgroundJobStore(database: database)
    let service = BackgroundJobService(
        store: store,
        registry: registry,
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
