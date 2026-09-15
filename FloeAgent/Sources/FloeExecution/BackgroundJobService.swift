// FloeExecution — Durable background job execution for long-running tools.
// The model-facing contract mirrors the SSH guardian pattern: submit returns
// a jobID immediately; status/result/cancel operate on that jobID.

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

/// Everything a background-download owner needs that is not already in the
/// durable job record.
public struct BackgroundJobDownloadContext: Sendable {
    public var workspaceRootURL: URL?
    public var allowedWorkspacePaths: [String]

    public init(workspaceRootURL: URL?, allowedWorkspacePaths: [String]) {
        self.workspaceRootURL = workspaceRootURL
        self.allowedWorkspacePaths = allowedWorkspacePaths
    }
}

/// Runs eligible tools off the agent run's critical path. A submitted job is
/// persisted first, then executed on a detached task with its own cooperative
/// cancellation token, so the calling run settles immediately.
public actor BackgroundJobService {
    /// Tools whose execution may be moved off the run's critical path.
    /// Only non-host-scoped, workspace-safe targets are eligible; expanding
    /// this list requires a fresh approval-surface review.
    public static let supportedTargets: Set<String> = [
        "exec.localService",
        "exec.localPython", "exec.shell", "network.download", "network.http", "web.fetch"
    ]

    private let store: BackgroundJobStore
    private let registry: ToolRunnerRegistry
    /// App-injected completion hook: steer a live run, queue a follow-up
    /// input, and post a local notification. Kept outside this module so the
    /// SPM target stays platform-independent.
    private let onTerminal: @Sendable (BackgroundJob) async -> Void
    /// App-injected owner for download jobs backed by a background URLSession.
    /// Returning true transfers persistence/completion ownership to the handler.
    private let downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)?
    /// Cancels the URLSession task of a background-owned download job.
    private let downloadCancelHandler: (@Sendable (UUID) async -> Void)?
    /// Reports whether a background URLSession task still exists for a job.
    /// Launch reconciliation only interrupts download jobs whose task is gone.
    private let downloadTaskLiveness: (@Sendable (UUID) async -> Bool)?

    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: CancellationToken] = [:]
    private var restartingIDs: Set<UUID> = []

    public init(
        store: BackgroundJobStore,
        registry: ToolRunnerRegistry = .shared,
        onTerminal: @escaping @Sendable (BackgroundJob) async -> Void = { _ in },
        downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)? = nil,
        downloadCancelHandler: (@Sendable (UUID) async -> Void)? = nil,
        downloadTaskLiveness: (@Sendable (UUID) async -> Bool)? = nil
    ) {
        self.store = store
        self.registry = registry
        self.onTerminal = onTerminal
        self.downloadHandler = downloadHandler
        self.downloadCancelHandler = downloadCancelHandler
        self.downloadTaskLiveness = downloadTaskLiveness
    }

    /// Validates and persists the job, then starts it. Retried tool calls
    /// (same runID + toolCallID) return the original job unchanged.
    @discardableResult
    public func submit(
        runID: UUID,
        toolCallID: String?,
        targetTool: String,
        payloadJSON: Data,
        scope: ToolScope,
        workspaceRootURL: URL?,
        allowedWorkspacePaths: [String],
        environmentID: String? = nil,
        allowedToolNames: Set<String>? = nil
    ) async throws -> BackgroundJob {
        guard Self.supportedTargets.contains(targetTool) else {
            throw FloeError.validationFailed(
                "jobs.submit supports \(Self.supportedTargets.sorted().joined(separator: ", ")) for now; call other tools directly"
            )
        }
        guard allowedToolNames?.contains(targetTool) != false else {
            throw FloeError.validationFailed("The current task does not permit this background target")
        }
        guard let runner = registry.runner(named: targetTool) else {
            throw FloeError.validationFailed("Tool '\(targetTool)' is not available in this build")
        }
        // Fail fast at the call site: a job whose arguments never decode would
        // otherwise fail asynchronously with no caller left to correct them.
        try runner.validateArguments(payloadJSON)
        guard let conversationID = try await store.conversationID(runID: runID) else {
            throw FloeError.validationFailed("Run has no owning task")
        }
        let isDownload = targetTool == "network.download"
        let job = BackgroundJob(
            conversationID: conversationID, runID: runID, toolCallID: toolCallID,
            kind: isDownload ? .download : .tool,
            targetTool: targetTool, payloadJSON: payloadJSON,
            workspaceRootPath: workspaceRootURL?.path,
            environmentID: environmentID
        )
        let persisted: BackgroundJob
        do {
            persisted = try await store.submit(job)
        } catch {
            // Unique-index race between two concurrent submits of one call:
            // the first writer wins and both callers share its job.
            if let toolCallID, let existing = try await store.job(runID: runID, toolCallID: toolCallID) {
                return existing
            }
            throw error
        }
        guard persisted.id == job.id, persisted.state == .queued else {
            // Idempotent replay of an earlier submit.
            return persisted
        }
        if persisted.kind == .download, let downloadHandler {
            do {
                let context = BackgroundJobDownloadContext(
                    workspaceRootURL: workspaceRootURL,
                    allowedWorkspacePaths: allowedWorkspacePaths
                )
                if try await downloadHandler(persisted, context) {
                    return try await store.job(id: persisted.id) ?? persisted
                }
            } catch {
                // Fall back to the in-process path below.
            }
        }
        start(job: persisted, scope: scope, workspaceRootURL: workspaceRootURL,
              allowedWorkspacePaths: allowedWorkspacePaths, allowedToolNames: allowedToolNames)
        return persisted
    }

    private func start(
        job: BackgroundJob,
        scope: ToolScope,
        workspaceRootURL: URL?,
        allowedWorkspacePaths: [String],
        allowedToolNames: Set<String>?
    ) {
        let token = CancellationToken()
        cancellations[job.id] = token
        let registry = self.registry
        let store = self.store
        runningTasks[job.id] = Task.detached(priority: .utility) { [weak self] in
            var finalState: BackgroundJobState
            var summary: String?
            var digest: String?
            var errorText: String?
            do {
                _ = try await store.transition(id: job.id, to: .running)
                guard let runner = registry.runner(named: job.targetTool) else {
                    throw FloeError.validationFailed("Tool '\(job.targetTool)' is no longer registered")
                }
                let context = ToolContext(
                    runID: job.runID,
                    toolCallID: "jobs.\(job.id.uuidString)",
                    scope: scope,
                    allowedToolNames: allowedToolNames,
                    workspaceRootURL: workspaceRootURL,
                    allowedWorkspacePaths: allowedWorkspacePaths,
                    cancellation: token,
                    environmentID: job.environmentID,
                    conversationID: job.conversationID
                )
                let output = try await runner.execute(argumentsJSON: job.payloadJSON, context: context)
                summary = output.summary
                digest = output.fullOutputSHA256
                if token.isCancelled {
                    finalState = .cancelled
                } else if output.requiresUserAction {
                    finalState = .failed
                    errorText = "User action is required before this job can complete: \(output.summary)"
                } else if let exit = output.exitStatus, exit != 0 {
                    finalState = .failed
                    errorText = "Tool exited with status \(exit): \(output.summary)"
                } else {
                    finalState = .completed
                }
            } catch {
                finalState = token.isCancelled ? .cancelled : .failed
                errorText = String(describing: error)
            }
            do {
                let finalSummary = summary
                let finalDigest = digest
                let finalError = errorText
                let terminal = try await store.transition(id: job.id, to: finalState) { job in
                    job.resultSummary = finalSummary
                    job.resultDigest = finalDigest
                    job.lastError = finalError
                }
                await self?.jobDidFinish(terminal)
            } catch {
                // The job was cancelled while the runner was still unwinding;
                // the cancelled terminal state already won.
                await self?.jobDidFinish(id: job.id)
            }
        }
    }

    public func job(id: UUID) async throws -> BackgroundJob? {
        try await store.job(id: id)
    }

    /// Resolve ownership from the durable run, not a caller-supplied task ID.
    public func ownedJob(id: UUID, runID: UUID) async throws -> BackgroundJob {
        guard let owner = try await store.conversationID(runID: runID),
              let job = try await store.job(id: id), job.conversationID == owner else {
            throw FloeError.validationFailed("No background job is available to this task with that ID")
        }
        return job
    }

    /// Native UI action; explicit restart creates a fresh durable attempt.
    /// Tools resubmit with their current approved context instead.
    public func restartLocalService(id: UUID) async throws -> BackgroundJob {
        guard restartingIDs.insert(id).inserted else { throw FloeError.validationFailed("Restart is already in progress") }
        defer { restartingIDs.remove(id) }
        guard let job = try await store.job(id: id), job.targetTool == "exec.localService",
              job.state.isTerminal, let path = job.workspaceRootPath, job.environmentID != nil else {
            throw FloeError.validationFailed("Stop the local service before restarting it")
        }
        if let existing = try await store.jobs(conversationID: job.conversationID, limit: 100).first(where: {
            !$0.state.isTerminal && $0.targetTool == job.targetTool && $0.environmentID == job.environmentID && $0.payloadJSON == job.payloadJSON
        }) { return existing }
        return try await submit(runID: job.runID, toolCallID: nil, targetTool: job.targetTool,
            payloadJSON: job.payloadJSON, scope: .local, workspaceRootURL: URL(fileURLWithPath: path),
            allowedWorkspacePaths: [], environmentID: job.environmentID)
    }

    public func cancel(id: UUID) async throws -> BackgroundJob {
        guard let job = try await store.job(id: id) else { throw BackgroundJobStoreError.missingJob(id) }
        guard !job.state.isTerminal else { return job }
        cancellations[id]?.cancel()
        if job.targetTool == "exec.localService", job.state == .running {
            // The service runner retains its environment lease until native exit.
            // Cancellation acknowledgement is not a terminal execution result.
            try await store.requestCancellation(id: id)
            return try await store.job(id: id) ?? job
        }
        if job.kind == .download { await downloadCancelHandler?(id) }
        do {
            return try await store.transition(id: id, to: .cancelled) { $0.lastError = "Cancelled by user or agent request" }
        } catch BackgroundJobStoreError.invalidStateTransition {
            // The runner reached a terminal state first; report that state.
            if let current = try await store.job(id: id) { return current }
            throw BackgroundJobStoreError.missingJob(id)
        }
    }

    /// Marks every non-terminal in-process job interrupted. Called once at
    /// process launch, because in-process execution cannot survive the
    /// previous process exiting. Download jobs owned by a background
    /// URLSession stay untouched while their system task is still alive;
    /// orphaned tasks (no live URLSession task) are interrupted too, so a
    /// relaunch cannot leave them stuck at "running" forever.
    @discardableResult
    public func reconcileInterruptedOnLaunch() async throws -> Int {
        let active = try await store.activeJobs()
        var count = 0
        for job in active where job.kind == .tool {
            if (try? await store.transition(id: job.id, to: .interrupted) {
                $0.lastError = "Process exited before the job finished"
            }) != nil { count += 1 }
        }
        for job in active where job.kind == .download {
            let alive = await downloadTaskLiveness?(job.id) ?? false
            guard !alive else { continue }
            if (try? await store.transition(id: job.id, to: .interrupted) {
                $0.lastError = "Download was interrupted by relaunch and its system task is gone; resubmit with jobs.submit"
            }) != nil { count += 1 }
        }
        return count
    }

    private func jobDidFinish(_ job: BackgroundJob) {
        runningTasks[job.id] = nil
        cancellations[job.id] = nil
        Task { await onTerminal(job) }
    }

    private func jobDidFinish(id: UUID) {
        runningTasks[id] = nil
        cancellations[id] = nil
    }
}
