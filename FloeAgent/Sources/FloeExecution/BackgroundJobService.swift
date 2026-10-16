// FloeExecution — Durable background job execution for long-running tools.
// The model-facing contract mirrors the SSH guardian pattern: submit returns
// a jobID immediately; status/result/cancel operate on that jobID.
//
// Native long-job rules enforced here:
//   * submission verifies runtime-issued CALL PROVENANCE and freezes
//     run/task/environment/workspace before the durable record exists;
//   * a delegated child is admitted through the same effective ceiling and
//     the same admission checks as a main-run call (and can never smuggle
//     delegation or a main-run-only capability into deferred work);
//   * targets with a registered service adapter prepare a SERVICE-OWNED
//     operation at submission — including consuming the runtime authority for
//     the exact approved `jobs.submit` call when the adapter requires it —
//     and run it with real progress, cooperative cancellation and terminal
//     verification instead of a raw registry execute;
//   * cancellation REQUESTS a stop and keeps the job non-terminal until the
//     running processor acknowledges and its cleanup completes; a job that
//     finished first keeps its ACTUAL result.

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
    /// Tools whose execution may be moved off the run's critical path. This is
    /// the default action-aware policy's target set; a service may be built
    /// with a narrower/tighter policy. `media.project` apply and
    /// `document.office.edit` apply are admitted when a service adapter owns
    /// them (the adapter freezes the operation and consumes the runtime
    /// authority for the submitting call); without an adapter only their
    /// export actions are admitted.
    public static let retiredExecutionTargets = RetiredExecutionTools.names

    public static let supportedTargets: Set<String> = NativeJobActionPolicy.default.supportedTargetNames

    /// Writes the full (bounded) job output to a spooled artifact BEFORE any
    /// summary truncation and returns its absolute path + exact byte count.
    /// Implementations bound the artifact size and never throw content away
    /// silently.
    public typealias OutputSpooler = @Sendable (UUID, String) async throws -> (path: String, bytes: Int)
    /// Records a durable parent-run dependency edge for a required job.
    /// `(jobID, runID, conversationID, kind)` where kind is `job` or
    /// `service`.
    public typealias DependencyRegistrar = @Sendable (UUID, UUID, UUID, String) async -> Void
    /// Resolves a dependency edge exactly once with its honest terminal
    /// outcome.
    public typealias DependencyResolver = @Sendable (UUID, RunDependencyState, String?) async -> Void

    private let store: BackgroundJobStore
    private let registry: ToolRunnerRegistry
    private let policy: NativeJobActionPolicy
    /// Service-owned prepared operation adapters, keyed by target tool.
    private let adapters: [String: NativeJobServiceAdapter]
    /// App-injected completion hook: steer a live run, queue a follow-up
    /// input, and post a local notification. Kept outside this module so the
    /// SPM target stays platform-independent.
    private let onTerminal: @Sendable (BackgroundJob) async -> Void
    /// Full-output spool (nil keeps summary-only behavior for callers/tests
    /// that do not provide one).
    private let outputSpooler: OutputSpooler?
    /// Durable dependency edges that keep a parent run nonterminal while a
    /// required finite job is outstanding.
    private let registerDependency: DependencyRegistrar?
    private let resolveDependency: DependencyResolver?
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
    private var preparedOperations: [UUID: any NativeJobPreparedOperation] = [:]
    private var progressRecorders: [UUID: NativeJobProgressRecorder] = [:]
    private var restartingIDs: Set<UUID> = []

    public init(
        store: BackgroundJobStore,
        registry: ToolRunnerRegistry = .shared,
        policy: NativeJobActionPolicy = .default,
        adapters: [String: NativeJobServiceAdapter] = [:],
        onTerminal: @escaping @Sendable (BackgroundJob) async -> Void = { _ in },
        downloadHandler: (@Sendable (BackgroundJob, BackgroundJobDownloadContext) async throws -> Bool)? = nil,
        downloadCancelHandler: (@Sendable (UUID) async -> Void)? = nil,
        downloadTaskLiveness: (@Sendable (UUID) async -> Bool)? = nil,
        outputSpooler: OutputSpooler? = nil,
        registerDependency: DependencyRegistrar? = nil,
        resolveDependency: DependencyResolver? = nil
    ) {
        self.store = store
        self.registry = registry
        self.policy = policy
        self.adapters = adapters
        self.onTerminal = onTerminal
        self.downloadHandler = downloadHandler
        self.downloadCancelHandler = downloadCancelHandler
        self.downloadTaskLiveness = downloadTaskLiveness
        self.outputSpooler = outputSpooler
        self.registerDependency = registerDependency
        self.resolveDependency = resolveDependency
    }

    /// Validates and persists the job, then starts it. Retried tool calls
    /// (same runID + toolCallID) return the original job unchanged, without
    /// re-consuming an authorization or re-preparing an operation.
    ///
    /// `submissionSource` is an explicit API split, never a provenance
    /// fallback: the default `.nativeService` is the in-process API for
    /// trusted app actions (shell `floe-service`, IDE run-service,
    /// local-service restart) that are not model/tool calls to `jobs.submit`;
    /// the raw registered `JobsSubmitTool` always passes `.runtime`
    /// explicitly, and `.runtime` refuses any context without the
    /// runtime-issued nonnil call id + `jobs.submit` origin for the exact call
    /// (so a reconstructed wrapper context with stripped provenance can never
    /// submit ordinary write/export jobs through the raw entry).
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
        allowedToolNames: Set<String>? = nil,
        callOrigin: ToolCallOrigin? = nil,
        childExecution: ChildExecutionHandoff? = nil,
        toolIdempotencyKey: String = "",
        approvalGrantID: UUID? = nil,
        runtimeAuthority: RuntimeTaskAuthority? = nil,
        runtimeAuthorityBinding: RuntimeAuthorityBinding? = nil,
        submissionSource: NativeJobSubmissionSource = .nativeService,
        /// Required (default) work keeps the submitting run nonterminal until
        /// the job reaches a terminal state (finite jobs) or a long-lived
        /// service is verifiably ready. `false` is an explicit fire-and-forget
        /// submission: the run may finish and the job continues independently.
        waitForCompletion: Bool = true
    ) async throws -> BackgroundJob {
        guard !RetiredExecutionTools.contains(targetTool) else {
            throw FloeError.validationFailed("This execution tool was removed. Inspect existing outputs first, then use exec.shell in the task Linux environment; long commands use jobs.submit.")
        }
        let action = policy.action(in: payloadJSON)
        let adapter = adapters[targetTool].flatMap { $0.handles(action: action) ? $0 : nil }
        guard policy.allows(target: targetTool, action: action) || adapter != nil else {
            throw FloeError.validationFailed(policy.refusal(target: targetTool, action: action))
        }
        // Runtime-verified provenance. A delegated child is ELIGIBLE for the
        // same native long jobs its parent's effective ceiling admits; the
        // child kind is never a permission difference. For `.runtime` a
        // missing call id/origin, a legacy origin without the approved tool
        // name, a wrapper origin bound to another tool, a mismatched call id
        // or a contradictory child handoff all fail closed before anything is
        // persisted; only an explicitly declared `.nativeService` submission
        // may omit the `jobs.submit` binding.
        let origin = try NativeJobProvenance.verify(
            runID: runID, toolCallID: toolCallID,
            origin: callOrigin, childExecution: childExecution,
            source: submissionSource)
        // Idempotent replay first: a retried call id must return its original
        // job and must never re-consume a single-use authorization.
        if let toolCallID, let existing = try await store.job(runID: runID, toolCallID: toolCallID) {
            return existing
        }
        // When the runtime issued an approval token for this exact call, its
        // binding is verified BEFORE anything is persisted: the token names the
        // approved tool+operation+target+payload, so a context that carries a
        // mismatched/stale token is refused instead of being treated as an
        // ordinary main-run submission. Adapters that need the single-use
        // token still consume it below; this check is read-only.
        if let runtimeAuthority {
            guard let runtimeAuthorityBinding else {
                throw FloeError.validationFailed(
                    "the submission carries a runtime approval that could not be bound to this call; the job is refused")
            }
            let verdict = await RuntimeAuthorityStore.shared.validate(
                runtimeAuthority, binding: runtimeAuthorityBinding)
            guard verdict.isValid else {
                throw FloeError.validationFailed(
                    "the runtime approval carried by this call does not bind the job submission"
                        + (verdict.failureReason.map { " (\($0))" } ?? "")
                        + "; the job is refused")
            }
        }
        guard allowedToolNames?.contains(targetTool) != false else {
            throw FloeError.validationFailed("The current task does not permit this background target")
        }
        guard !NativeJobActionPolicy.delegationDeniedTargets.contains(targetTool) else {
            throw FloeError.validationFailed(
                "'\(targetTool)' can never run as deferred work: delegation itself is main-run-only and cannot be smuggled through a job")
        }
        guard let runner = registry.runner(named: targetTool) else {
            throw FloeError.validationFailed("Tool '\(targetTool)' is not available in this build")
        }
        // Main-only capabilities can never become deferred work: the exact
        // call-scoped origin check would refuse the dispatch later, and a job
        // wrapper must not try anyway. Child-only capabilities need a live
        // child and can never be detached either.
        switch runner.descriptor.executionBoundary {
        case .mainRunOnly:
            throw FloeError.validationFailed(
                "'\(targetTool)' is a main-run-only capability and cannot run as a background job")
        case .childOnly:
            throw FloeError.validationFailed(
                "'\(targetTool)' requires a live delegated child and cannot run as a background job")
        case .any:
            break
        }
        // Fail fast at the call site: a job whose arguments never decode would
        // otherwise fail asynchronously with no caller left to correct them.
        try runner.validateArguments(payloadJSON)
        // Workspace preflight (optional, per tool): reject a job whose entry
        // file or working directory does not exist under the resolved
        // workspace before the durable record is created. The error is
        // synchronous and actionable; nothing is persisted to clean up.
        if let preflight = runner.preflightSubmission {
            try await preflight(payloadJSON, workspaceRootURL)
        }
        // Action-aware native preflight: real target existence, workspace
        // confinement and the declared base revision, before persistence.
        if let handler = policy.handlers[targetTool], let preflight = handler.preflight {
            try await preflight(payloadJSON, workspaceRootURL)
        }
        guard let conversationID = try await store.conversationID(runID: runID) else {
            throw FloeError.validationFailed("Run has no owning task")
        }
        // A payload that DECLARES another task/environment is refused instead
        // of being silently rerouted onto this call's frozen scope.
        try NativeJobRequestScope.check(payload: payloadJSON, runID: runID,
                                        conversationID: conversationID,
                                        environmentID: environmentID)
        let operationID = NativeJobOperationIdentity.derive(
            runID: runID, toolCallID: toolCallID,
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(payloadJSON))
        // Service-owned prepared operation (Office/media edit jobs). Prepared
        // BEFORE persistence; throwing leaves no durable record behind.
        var prepared: (any NativeJobPreparedOperation)?
        var preparationSummary: NativeJobPreparationSummary?
        if let adapter {
            let authorization: NativeJobAuthorization
            if adapter.requiresRuntimeAuthorization {
                // The ONLY authority for a deferred authorized edit is the
                // runtime-issued token for this exact approved `jobs.submit`
                // call. A model field, a rehearsed grant id or a re-serialized
                // payload creates nothing; a missing/mismatched token fails
                // closed before any operation is prepared.
                guard let runtimeAuthority, let runtimeAuthorityBinding else {
                    throw FloeError.validationFailed(
                        "'\(targetTool)' requires the runtime-issued approval for this exact jobs.submit call; "
                            + "the submission cannot be prepared without it")
                }
                let verdict = await RuntimeAuthorityStore.shared.consume(
                    runtimeAuthority, binding: runtimeAuthorityBinding)
                guard verdict.isValid else {
                    throw FloeError.validationFailed(
                        "the jobs.submit runtime authorization for this exact call is not valid"
                            + (verdict.failureReason.map { " (\($0))" } ?? "")
                            + "; no operation was prepared")
                }
                authorization = .consumed(binding: runtimeAuthorityBinding, at: Date())
            } else {
                authorization = .notRequired
            }
            let request = NativeJobPreparationRequest(
                operationID: operationID,
                runID: runID,
                conversationID: conversationID,
                environmentID: environmentID,
                workspaceRootURL: workspaceRootURL,
                allowedWorkspacePaths: allowedWorkspacePaths,
                scope: scope,
                payloadJSON: payloadJSON,
                origin: origin,
                authorization: authorization,
                approvalGrantID: approvalGrantID ?? runtimeAuthority?.approvalGrantID,
                submittedCallID: toolCallID,
                idempotencyKey: toolIdempotencyKey)
            let operation = try await adapter.prepare(request)
            prepared = operation
            preparationSummary = NativeJobPreparationSummary(
                operationID: operation.operationID,
                serviceLabel: operation.serviceLabel,
                frozenRevision: operation.frozenRevision)
        }
        let isDownload = targetTool == "network.download"
        let progressDocument = NativeJobProgressDocument(
            origin: origin,
            prepared: preparationSummary,
            progress: NativeJobProgress(stage: .preparing, note: "queued"),
            updatedAt: Date())
        let job = BackgroundJob(
            conversationID: conversationID, runID: runID, toolCallID: toolCallID,
            kind: isDownload ? .download : .tool,
            targetTool: targetTool, payloadJSON: payloadJSON,
            progressJSON: progressDocument.encoded(),
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
        // Durable dependency edge FIRST: it exists before any executor can
        // observe the job as pending, so a crash between submit and launch
        // leaves a reconcilable edge instead of a lost wait.
        if waitForCompletion, let registerDependency {
            await registerDependency(
                persisted.id,
                persisted.runID,
                persisted.conversationID,
                persisted.targetTool == "exec.localService" ? "service" : "job"
            )
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
              allowedWorkspacePaths: allowedWorkspacePaths, allowedToolNames: allowedToolNames,
              origin: origin, prepared: prepared, progressDocument: progressDocument)
        return persisted
    }

    private func start(
        job: BackgroundJob,
        scope: ToolScope,
        workspaceRootURL: URL?,
        allowedWorkspacePaths: [String],
        allowedToolNames: Set<String>?,
        origin: NativeJobOrigin,
        prepared: (any NativeJobPreparedOperation)?,
        progressDocument: NativeJobProgressDocument
    ) {
        let token = CancellationToken()
        cancellations[job.id] = token
        if let prepared { preparedOperations[job.id] = prepared }
        let recorder = NativeJobProgressRecorder(store: store, jobID: job.id, document: progressDocument)
        progressRecorders[job.id] = recorder
        let registry = self.registry
        let store = self.store
        let outputSpooler = self.outputSpooler
        runningTasks[job.id] = Task.detached(priority: .utility) { [weak self] in
            var finalState: BackgroundJobState
            var summary: String?
            var digest: String?
            var errorText: String?
            var resultPath: String?
            /// Full, un-truncated processor output captured BEFORE the
            /// summary bound: spooled to a durable artifact so the complete
            /// result survives even when the summary is clipped.
            var fullOutput: String?
            do {
                _ = try await store.transition(id: job.id, to: .running)
                await recorder.record(NativeJobProgress(stage: .running, note: "processor started"))
                if let prepared {
                    let hooks = NativeJobRunHooks(
                        report: { update in await recorder.record(update) },
                        isCancellationRequested: { token.isCancelled })
                    let outcome = try await prepared.run(hooks: hooks)
                    if let artifact = outcome.artifactPath {
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: artifact, isDirectory: &isDirectory),
                              !isDirectory.boolValue else {
                            throw FloeError.validationFailed(
                                "the prepared operation reported an artifact that does not exist: \(artifact)")
                        }
                        resultPath = artifact
                    }
                    fullOutput = outcome.summary
                    summary = NativeJobTextLimits.bounded(outcome.summary)
                    digest = outcome.digest ?? FloeDigest.sha256Hex(Data(outcome.summary.utf8))
                    if token.isCancelled {
                        // A prepared operation that RETURNED a terminal outcome
                        // reached its own commit boundary and verified the
                        // result; report the ACTUAL result with an honest note
                        // instead of falsely claiming a cancelled success. An
                        // operation that did not commit throws cancelled
                        // itself (after its cleanup).
                        finalState = .completed
                        summary = (summary ?? "") + "\nnote: cancellation was requested while this operation was "
                            + "already completing; its verified terminal result is reported."
                    } else {
                        finalState = .completed
                    }
                } else if let runner = registry.runner(named: job.targetTool) {
                    let context = ToolContext(
                        runID: job.runID,
                        toolCallID: "jobs.\(job.id.uuidString)",
                        toolIdempotencyKey: "job:\(job.id.uuidString)",
                        scope: scope,
                        allowedToolNames: allowedToolNames,
                        workspaceRootURL: workspaceRootURL,
                        allowedWorkspacePaths: allowedWorkspacePaths,
                        cancellation: token,
                        environmentID: job.environmentID,
                        conversationID: job.conversationID,
                        taskProgress: NativeJobTaskProgressReporter { update in
                            await recorder.record(update)
                        }
                    )
                    let output = try await runner.execute(argumentsJSON: job.payloadJSON, context: context)
                    fullOutput = output.summary
                    summary = NativeJobTextLimits.bounded(output.summary)
                    digest = output.fullOutputSHA256
                    if token.isCancelled {
                        finalState = .cancelled
                        errorText = "Cancellation acknowledged after the processor stopped. Check the workspace for partial outputs before retrying."
                    } else if output.requiresUserAction {
                        finalState = .failed
                        errorText = NativeJobTextLimits.bounded(
                            "User action is required before this job can complete: \(output.summary)")
                    } else if let exit = output.exitStatus, exit != 0 {
                        finalState = .failed
                        errorText = NativeJobTextLimits.bounded(
                            "Tool exited with status \(exit): \(output.summary)")
                    } else {
                        finalState = .completed
                    }
                } else {
                    throw FloeError.validationFailed("Tool '\(job.targetTool)' is no longer registered")
                }
            } catch {
                // Safety first: a failure that leaves live native resources or
                // retained staging must NEVER be reported as a clean
                // cancellation, even when the job token was cancelled. The
                // shared contract's discriminant decides: mere conformance is
                // not enough, because an error family may also carry ordinary
                // safe failures (e.g. a clean Office cancellation).
                if let unsafe = error as? any UnsafeResourceStateError, unsafe.isUnsafeResourceState {
                    finalState = .failed
                    errorText = NativeJobTextLimits.bounded(
                        "Unsafe resource state (not a clean cancellation): \(unsafe.unsafeResourceReason). "
                            + "Staging was retained and native workers may still be finishing; "
                            + "do not retry until the app restarts.")
                } else if Self.isCancellationSignal(error, token: token) {
                    finalState = .cancelled
                    errorText = "Cancellation acknowledged after the processor stopped and its staging was cleaned. "
                        + "Check the workspace for partial outputs before retrying."
                } else {
                    finalState = .failed
                    errorText = NativeJobTextLimits.bounded(String(describing: error))
                }
            }
            // Spool the FULL output before settling: a consumer paging
            // `jobs.result` reads this artifact, never a re-derived summary.
            var outputPath: String?
            var outputBytes: Int?
            if let fullOutput, let outputSpooler, let spooled = try? await outputSpooler(job.id, fullOutput) {
                outputPath = spooled.path
                outputBytes = spooled.bytes
            }
            await recorder.record(NativeJobProgress(stage: .finalizing, note: "settling terminal state"))
            await recorder.finish()
            do {
                let finalSummary = summary
                let finalDigest = digest
                let finalError = errorText
                let finalPath = resultPath
                let finalOutputPath = outputPath
                let finalOutputBytes = outputBytes
                let terminal = try await store.transition(id: job.id, to: finalState) { job in
                    job.resultSummary = finalSummary
                    job.resultDigest = finalDigest
                    job.resultPath = finalPath
                    job.outputPath = finalOutputPath
                    job.outputBytes = finalOutputBytes
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

    /// Cancellation is a REQUEST, not a terminal result. A running job stays
    /// non-terminal (with `cancellationRequested` in its progress document)
    /// until its processor acknowledges and its cleanup completes; a queued
    /// job (nothing started) is cancelled directly; a job that finished first
    /// keeps its ACTUAL terminal state.
    public func cancel(id: UUID) async throws -> BackgroundJob {
        guard let job = try await store.job(id: id) else { throw BackgroundJobStoreError.missingJob(id) }
        guard !job.state.isTerminal else { return job }
        cancellations[id]?.cancel()
        if job.kind == .download { await downloadCancelHandler?(id) }
        if let operation = preparedOperations[id] { await operation.requestCancellation() }
        if let recorder = progressRecorders[id] { await recorder.markCancellationRequested() }
        try await store.requestCancellation(
            id: id,
            reason: job.targetTool == "exec.localService"
                ? "Stop requested; waiting for the native service to exit"
                : "Cancellation requested; waiting for the processor to stop and clean up")
        if job.state == .queued {
            // Nothing has started executing yet; queued work may cancel
            // safely before effects. If the runner won the race, report it.
            do {
                let cancelled = try await store.transition(id: id, to: .cancelled) {
                    $0.lastError = "Cancelled before execution started; no effects were produced."
                }
                jobDidFinish(cancelled)
                return cancelled
            } catch {
                return try await store.job(id: id) ?? job
            }
        }
        return try await store.job(id: id) ?? job
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
            allowedWorkspacePaths: [], environmentID: job.environmentID,
            submissionSource: .nativeService)
    }

    /// Marks every non-terminal in-process job interrupted. Called once at
    /// process launch, because in-process execution cannot survive the
    /// previous process exiting. Download jobs owned by a background
    /// URLSession stay untouched while their system task is still alive;
    /// orphaned tasks (no live URLSession task) are interrupted too, so a
    /// relaunch cannot leave them stuck at "running" forever.
    ///
    /// An action-aware handler (or adapter) may check a REAL side effect
    /// before the honest `interrupted` outcome; an unknown outcome is never
    /// reported as success and never silently replayed.
    @discardableResult
    public func reconcileInterruptedOnLaunch() async throws -> Int {
        let active = try await store.activeJobs()
        var count = 0
        for job in active where job.kind == .tool {
            if RetiredExecutionTools.contains(job.targetTool) {
                if let interrupted = try? await store.transition(id: job.id, to: .interrupted, mutate: { job in
                    job.lastError = "The previous execution tool is no longer available. Its outcome is UNKNOWN. Inspect saved outputs before explicitly resubmitting with exec.shell in the task Linux environment."
                }) {
                    count += 1
                    await resolveDependency?(interrupted.id, .interrupted, interrupted.lastError)
                }
                continue
            }
            let reconcile = policy.handlers[job.targetTool]?.reconcile
                ?? adapters[job.targetTool]?.reconcile
            if let reconcile,
               let resolved = await reconcile(job), resolved.isTerminal,
               job.state.canTransition(to: resolved) {
                if let reconciled = try? await store.transition(
                    id: job.id, to: resolved,
                    mutate: { job in job.lastError = "Reconciled after relaunch: \(resolved.rawValue)" }
                ) {
                    count += 1
                    if let resolveDependency {
                        await resolveDependency(
                            reconciled.id,
                            Self.dependencyState(for: reconciled.state),
                            "Reconciled after relaunch: \(resolved.rawValue)"
                        )
                    }
                    continue
                }
            }
            if let interrupted = try? await store.transition(
                id: job.id, to: .interrupted,
                mutate: { job in
                    job.lastError = "Process exited before the job finished. The outcome is UNKNOWN: inspect the workspace/output first (read-only) before resubmitting; do not blindly rerun."
                }
            ) {
                count += 1
                if let resolveDependency {
                    await resolveDependency(
                        interrupted.id,
                        .interrupted,
                        "The process exited before this job finished; its outcome is UNKNOWN. Inspect existing outputs read-only before resubmitting."
                    )
                }
            }
        }
        for job in active where job.kind == .download {
            let alive = await downloadTaskLiveness?(job.id) ?? false
            guard !alive else { continue }
            if let interrupted = try? await store.transition(
                id: job.id, to: .interrupted,
                mutate: { job in
                    job.lastError = "Download was interrupted by relaunch and its system task is gone; resubmit with jobs.submit"
                }
            ) {
                count += 1
                if let resolveDependency {
                    await resolveDependency(
                        interrupted.id,
                        .interrupted,
                        "The download was interrupted by relaunch; resubmit with an explicit new jobs.submit."
                    )
                }
            }
        }
        return count
    }

    /// True when an error means "the processor stopped on a cancellation
    /// request" rather than a genuine failure.
    static func isCancellationSignal(_ error: any Error, token: CancellationToken) -> Bool {
        // An unsafe resource state is not a cancellation, whatever the token.
        // Only the contract's discriminant counts: a conforming error whose
        // discriminant is false (a clean Office cancellation, an ordinary
        // output conflict) keeps the normal error path below.
        if let unsafe = error as? any UnsafeResourceStateError, unsafe.isUnsafeResourceState { return false }
        if token.isCancelled { return true }
        if error is CancellationError { return true }
        if let floe = error as? FloeError, floe == .cancelled { return true }
        let text = String(describing: error).lowercased()
        return text.contains("cancelled") || text.contains("canceled")
    }

    private func jobDidFinish(_ job: BackgroundJob) {
        runningTasks[job.id] = nil
        cancellations[job.id] = nil
        preparedOperations[job.id] = nil
        progressRecorders[job.id] = nil
        if let resolveDependency {
            let state = Self.dependencyState(for: job.state)
            let note = job.lastError ?? "job \(job.state.rawValue)"
            Task { await resolveDependency(job.id, state, note) }
        }
        Task { await onTerminal(job) }
    }

    private func jobDidFinish(id: UUID) {
        runningTasks[id] = nil
        cancellations[id] = nil
        preparedOperations[id] = nil
        progressRecorders[id] = nil
        if let resolveDependency {
            Task { [store] in
                guard let job = try? await store.job(id: id) else { return }
                let state = Self.dependencyState(for: job.state)
                await resolveDependency(id, state, job.lastError ?? "job \(job.state.rawValue)")
            }
        }
    }

    /// Resolves a long-lived service dependency once the service is
    /// verifiably READY (its own readiness probe answered), leaving the job
    /// running. Matching is idempotent: the first resolution wins and a later
    /// terminal state does not overwrite it.
    public func resolveServiceReady(id: UUID, note: String) async {
        guard let resolveDependency else { return }
        guard let job = try? await store.job(id: id), job.targetTool == "exec.localService" else { return }
        await resolveDependency(id, .resolved, note)
    }

    /// Maps a job's terminal/nonterminal state to the durable dependency
    /// state (shared by the service and the app-side terminal projection).
    public static func dependencyState(for state: BackgroundJobState) -> RunDependencyState {
        switch state {
        case .completed: .resolved
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        case .queued, .running: .pending
        }
    }
}
