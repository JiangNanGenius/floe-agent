// FloeApp — prepared-operation adapters for native long jobs.
//
// `jobs.submit` persists the durable record FIRST and executes off the run
// path. The adapters below freeze the concrete Office/media operation before
// that record exists and run the REAL app services later:
//
//   * the Office and media-project apply adapters consume the runtime
//     authority for the EXACT submitting `jobs.submit` call
//     (`requiresRuntimeAuthorization`), so no model field or grant-looking
//     string can start an authorized edit;
//   * every operation freezes the workspace root, revision/digests and
//     command payload at submission — nothing consults a "current" project;
//   * progress and cancellation flow through `NativeJobRunHooks`; a cancelled
//     operation unwinds its own staging before it reports terminal.
//
// The interactive `grant_id` flows stay on their existing inline paths and are
// never reachable from here (a payload that carries one is refused).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloeDocuments
import FloeWorkbench
import FloeMedia

enum NativeJobAppAdapters {
    /// Adapters keyed by target tool for `registerBackgroundJobTools(adapters:)`.
    static func make(
        officeCenter: OfficeCommandCenter,
        workbenchCenter: WorkbenchCenter,
        frameProcessing: (any FrameProcessing)?
    ) -> [String: NativeJobServiceAdapter] {
        var adapters: [String: NativeJobServiceAdapter] = [:]
        adapters["document.office.edit"] = officeApplyAdapter(center: officeCenter)
        adapters["media.project"] = mediaProjectApplyAdapter(host: workbenchCenter)
        if let frameProcessing {
            adapters["video.interpolate"] = frameProcessingAdapter(
                processor: frameProcessing, targetTool: "video.interpolate")
            adapters["video.superResolution"] = frameProcessingAdapter(
                processor: frameProcessing, targetTool: "video.superResolution")
        }
        return adapters
    }

    /// The EXACT shared-contract mapping the Office job adapter applies to an
    /// executor failure. Only the two genuinely unsafe lifecycle failures
    /// (the enum's discriminant) become a `NativeJobSafetyFailure`: the job
    /// service must never downgrade them to a clean cancellation while the
    /// engine may still hold the working copy. A clean cancellation or an
    /// ordinary refusal is returned unchanged (nil here) so it keeps the
    /// normal classification — conformance to the shared protocol alone is
    /// not an unsafe state.
    static func officeSafetyFailure(from error: Error) -> NativeJobSafetyFailure? {
        guard (error as? OfficeAutomaticExecutionError)?.isUnsafeResourceState == true else { return nil }
        return NativeJobSafetyFailure(
            reason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            stagingRetained: true)
    }

    // MARK: - Payload envelope

    /// `jobs.submit` carries the target tool's JSON as a STRING inside its own
    /// arguments object; only the exact declared target is accepted.
    static func targetArguments(_ payloadJSON: Data, expectedTool: String) throws -> Data {
        struct Envelope: Decodable {
            var tool: String
            var arguments: String
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: payloadJSON)
        guard envelope.tool == expectedTool else {
            throw FloeError.validationFailed(
                "the job payload targets '\(envelope.tool)', not '\(expectedTool)'")
        }
        guard let data = envelope.arguments.data(using: .utf8) else {
            throw FloeError.validationFailed("the job payload arguments are not valid UTF-8")
        }
        return data
    }

    // MARK: - Office automatic apply

    private static func officeApplyAdapter(center: OfficeCommandCenter) -> NativeJobServiceAdapter {
        NativeJobServiceAdapter(
            targetTool: "document.office.edit",
            adaptedActions: ["apply"],
            requiresRuntimeAuthorization: true,
            prepare: { request in
                guard let binding = request.consumedBinding else {
                    throw FloeError.validationFailed(
                        "the Office apply job requires the consumed runtime authority for this exact jobs.submit call")
                }
                let argumentsData = try targetArguments(
                    request.payloadJSON, expectedTool: "document.office.edit")
                let args = try JSONDecoder().decode(OfficeEditArguments.self, from: argumentsData)
                guard args.action == .apply else {
                    throw FloeError.validationFailed(
                        "only document.office.edit apply can run as a background job")
                }
                guard (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "a user-confirmed apply must run inline through the editor session, not as a job")
                }
                guard let proposalID = args.proposalID else {
                    throw FloeError.validationFailed("apply requires proposal_id")
                }
                let access = OfficeCommandAccess(
                    environmentID: request.environmentID,
                    workspacePath: request.workspaceRootURL?
                        .resolvingSymlinksInPath().standardizedFileURL.path,
                    ownerKind: request.conversationID == nil ? "workspace" : "chat",
                    ownerID: request.conversationID,
                    conversationID: request.conversationID
                )
                guard let proposal = try await center.loadProposal(id: proposalID, access: access) else {
                    throw FloeError.notFound(
                        "Office proposal \(proposalID.uuidString) is no longer available for this task")
                }
                let authorization = OfficeAutomaticAuthorization(
                    runID: request.runID,
                    taskID: request.conversationID,
                    operationID: binding.operationID,
                    idempotencyKey: binding.idempotencyKey,
                    approvalGrantID: request.approvalGrantID,
                    binding: binding,
                    consumedAt: request.authorization.consumedAt ?? Date(),
                    origin: .approvedBackgroundJob(submitBinding: binding)
                )
                return OfficeApplyJobOperation(
                    operationID: request.operationID,
                    frozenRevision: proposal.baseSHA256,
                    center: center,
                    proposal: proposal,
                    authorization: authorization,
                    access: access,
                    relativeOutput: args.output,
                    requestID: args.requestID ?? "job-\(request.operationID)",
                    token: CancellationToken()
                )
            }
        )
    }

    // MARK: - Media frame processing

    private static func frameProcessingAdapter(
        processor: any FrameProcessing,
        targetTool: String
    ) -> NativeJobServiceAdapter {
        NativeJobServiceAdapter(
            targetTool: targetTool,
            adaptedActions: nil,
            requiresRuntimeAuthorization: false,
            prepare: { request in
                guard let root = request.workspaceRootURL?.path, !root.isEmpty else {
                    throw FloeError.validationFailed(
                        "media jobs require the task workspace frozen at submission")
                }
                let argumentsData = try targetArguments(request.payloadJSON, expectedTool: targetTool)
                guard let plan = try MediaJobEnhancementPreparation.frameProcessingPlan(
                    payloadJSON: argumentsData,
                    workspaceRootPath: root,
                    operationID: request.operationID
                ) else {
                    throw FloeError.validationFailed(
                        "the \(targetTool) payload is not a frame-processing request")
                }
                return MediaFrameJobOperation(
                    operationID: plan.operationID,
                    frozenRevision: plan.frozenRevision,
                    serviceLabel: plan.serviceLabel,
                    plan: plan,
                    processor: processor,
                    token: CancellationToken()
                )
            }
        )
    }

    // MARK: - Media project automatic apply

    private static func mediaProjectApplyAdapter(host: WorkbenchCenter) -> NativeJobServiceAdapter {
        NativeJobServiceAdapter(
            targetTool: "media.project",
            adaptedActions: ["apply"],
            requiresRuntimeAuthorization: true,
            prepare: { request in
                guard let binding = request.consumedBinding else {
                    throw FloeError.validationFailed(
                        "the media.project apply job requires the consumed runtime authority for this exact jobs.submit call")
                }
                let argumentsData = try targetArguments(request.payloadJSON, expectedTool: "media.project")
                let args = try JSONDecoder().decode(MediaProjectArguments.self, from: argumentsData)
                guard args.action == .apply else {
                    throw FloeError.validationFailed(
                        "only media.project apply can run as a background job")
                }
                guard (args.grantID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw FloeError.validationFailed(
                        "a user-confirmed apply must run inline through the workbench, not as a job")
                }
                guard let proposalID = args.proposalID else {
                    throw FloeError.validationFailed("apply requires proposal_id")
                }
                let access = MediaProjectAccess(
                    environmentID: request.environmentID,
                    workspacePath: request.workspaceRootURL?
                        .resolvingSymlinksInPath().standardizedFileURL.path,
                    ownerKind: request.conversationID == nil ? nil : "chat",
                    ownerID: request.conversationID
                )
                try await host.authorizeAccess(projectID: args.projectID, access: access)
                guard let proposal = try await host.loadProposal(id: proposalID),
                      proposal.projectID == args.projectID else {
                    throw FloeError.notFound(
                        "media proposal \(proposalID.uuidString) is no longer available for this project")
                }
                guard let project = try await host.loadProject(id: args.projectID) else {
                    throw FloeError.notFound("media project \(args.projectID.uuidString)")
                }
                guard proposal.baseRevision == project.revision else {
                    throw FloeError.validationFailed(
                        "the media project changed after this proposal was prepared (revision \(project.revision), proposal based on \(proposal.baseRevision)); the job is refused instead of applying a stale edit")
                }
                let authorization = MediaAutomaticAuthorization(
                    runID: request.runID,
                    taskID: request.conversationID,
                    operationID: binding.operationID,
                    idempotencyKey: binding.idempotencyKey,
                    approvalGrantID: request.approvalGrantID,
                    canonicalTarget: binding.canonicalTarget,
                    baseRevision: project.revision,
                    payloadDigest: binding.payloadDigest,
                    commandsDigest: MediaProposalGate.commandsDigest(proposal.commands),
                    proposalID: proposal.id
                )
                return MediaProjectApplyJobOperation(
                    operationID: request.operationID,
                    frozenRevision: String(project.revision),
                    expectedRevision: project.revision,
                    host: host,
                    proposal: proposal,
                    authorization: authorization,
                    token: CancellationToken()
                )
            }
        )
    }
}

// MARK: - Prepared operations

private struct OfficeApplyJobOperation: NativeJobPreparedOperation {
    let operationID: String
    let frozenRevision: String?
    let serviceLabel = "office.apply"
    let center: OfficeCommandCenter
    let proposal: OfficeCommandProposal
    let authorization: OfficeAutomaticAuthorization
    let access: OfficeCommandAccess
    let relativeOutput: String?
    let requestID: String
    let token: CancellationToken

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        await hooks.report(NativeJobProgress(
            stage: .running, phase: "engine-apply",
            note: "isolated verified copy; the original is never modified"))
        // A dedicated executor with the real pinned engine factory. Every
        // boundary stays inside the module-owned automatic path (CAS on the
        // approved base revision, reopen + formula verification, atomic publish
        // of a NEW copy). The process-wide gate serializes service-owned
        // automatic sessions: the engine is ONE shared runtime, and the lease
        // is released only after the session closed and acknowledged.
        let executor = OfficeAutomaticExecutor(
            factory: OfficeServiceNativeSessionFactory.makeDefault())
        // Bounded, cancellation-aware lease: a cancelled job must leave at
        // its safe pre-effect boundary instead of queueing forever.
        switch await OfficeAutomaticExecutionGate.shared.acquire(
            cancellation: token, timeout: 300
        ) {
        case .acquired:
            break
        case .cancelledBeforeStart:
            throw FloeError.cancelled
        case .timedOut:
            throw FloeError.validationFailed(
                "another automatic Office session is still running; the job will not start a second engine session")
        case .hostQuarantined(let reason):
            throw FloeError.validationFailed(
                "shared automatic engine work is suspended after an unacknowledged session close: \(reason)")
        }
        let receipt: OfficeAutomaticReceipt
        do {
            receipt = try await executor.execute(
                proposal: proposal,
                authorization: authorization,
                relativeOutput: relativeOutput,
                requestID: requestID,
                access: access,
                cancellation: token
            )
            await OfficeAutomaticExecutionGate.shared.release(closeAcknowledged: true)
        } catch {
            let safety = NativeJobAppAdapters.officeSafetyFailure(from: error)
            await OfficeAutomaticExecutionGate.shared.release(
                closeAcknowledged: safety == nil,
                failureReason: (error as? LocalizedError)?.errorDescription)
            // Map only the actual unsafe lifecycle failures into the shared job
            // safety contract so the job service can never downgrade them to a
            // clean cancellation while the engine still holds the working copy.
            if let safety { throw safety }
            throw error
        }
        await hooks.report(NativeJobProgress(stage: .verifying, phase: "verified"))
        var parts = [
            "status=\(receipt.replay ? "replayed" : "applied")",
            "output=\(receipt.outputRelativePath)",
            "sha256=\(receipt.outputSHA256)",
            "bytes=\(receipt.outputByteCount)",
            "sourceUnchanged=\(receipt.sourceUnchanged)",
            "engine=\(receipt.sessionEngine)"
        ]
        if let formula = receipt.formulaSummary { parts.append("formula=\(formula)") }
        let artifactPath = access.workspacePath.map {
            URL(fileURLWithPath: $0).appendingPathComponent(receipt.outputRelativePath).path
        }
        return NativeJobOutcome(
            summary: parts.joined(separator: " "),
            digest: receipt.outputSHA256,
            verified: receipt.verified,
            artifactPath: artifactPath,
            frozenRevision: receipt.baseSHA256
        )
    }

    func requestCancellation() async { token.cancel() }
}

private struct MediaFrameJobOperation: NativeJobPreparedOperation {
    let operationID: String
    let frozenRevision: String?
    let serviceLabel: String
    let plan: MediaJobOperationPlan
    let processor: any FrameProcessing
    let token: CancellationToken

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        // The scope lets the media tool forward the REAL processor progress
        // into this job; outside a job no progress is ever claimed.
        let bridge = JobProgressBridge(hooks: hooks)
        var request = plan.request
        request.cancellation = token
        _ = try await MediaJobProgressScope.withReporter({ update in
            bridge.submit(NativeJobProgress(
                stage: .running,
                phase: update.phase.rawValue,
                completedUnits: update.completedUnits,
                totalUnits: update.totalUnits,
                note: nil
            ))
        }) {
            try await processor.process(request)
        }
        await bridge.finish()
        let outputPath = plan.expectedOutputURL.path
        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw FloeError.validationFailed(
                "the media processor returned without a committed output at \(outputPath)")
        }
        let outputDigest = (try? FloeDigest.sha256Hex(ofFileAt: plan.expectedOutputURL)) ?? ""
        return NativeJobOutcome(
            summary: "status=ok service=\(serviceLabel) output=\(outputPath) sha256=\(outputDigest)",
            digest: outputDigest,
            verified: ["output-committed", "service-reopened-output"],
            artifactPath: outputPath,
            frozenRevision: frozenRevision
        )
    }

    func requestCancellation() async { token.cancel() }
}

private struct MediaProjectApplyJobOperation: NativeJobPreparedOperation {
    let operationID: String
    let frozenRevision: String?
    let serviceLabel = "media.project.apply"
    let expectedRevision: Int64
    let host: WorkbenchCenter
    let proposal: MediaProposal
    let authorization: MediaAutomaticAuthorization
    let token: CancellationToken

    func run(hooks: NativeJobRunHooks) async throws -> NativeJobOutcome {
        try throwIfCancelled()
        await hooks.report(NativeJobProgress(stage: .running, phase: "apply"))
        guard var live = try await host.loadProject(id: proposal.projectID) else {
            throw FloeError.notFound("media project disappeared before the job ran")
        }
        guard live.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "the media project moved to revision \(live.revision) after this job was prepared (frozen \(expectedRevision))")
        }
        let beforeAssets = MediaAutomaticVerification.assetHashes(live)
        try MediaProposalGate.applyAutomatic(proposal, authorization: authorization, to: &live)
        let appliedRevision = live.revision
        // Cooperative cancellation: the local draft is not committed yet, so a
        // request here aborts without mutating the persisted project.
        try throwIfCancelled()
        try await host.persistProject(live, expectedRevision: expectedRevision)
        try await host.removeProposal(id: proposal.id)
        // REOPEN the persisted project and prove the exact revision, digest and
        // untouched source assets — never a claimed success.
        guard let reopened = try await host.loadProject(id: proposal.projectID),
              reopened.revision == appliedRevision else {
            throw FloeError.validationFailed(
                "the applied project could not be reopened at revision \(appliedRevision); treat the revision as unverified")
        }
        guard MediaAutomaticVerification.assetHashes(reopened) == beforeAssets else {
            throw FloeError.validationFailed(
                "the apply changed referenced source assets; the revision is not a safe snapshot")
        }
        let digest = MediaAutomaticVerification.canonicalProjectDigest(reopened)
        let summary = try MediaProjectSummaries.summary(reopened)
        await hooks.report(NativeJobProgress(stage: .verifying, phase: "reopened"))
        return NativeJobOutcome(
            summary: "status=applied revision=\(appliedRevision) projectDigest=\(digest) sourceAssetsUnchanged=true\n\(summary)",
            digest: digest,
            verified: ["reopened-revision", "source-assets-unchanged"],
            artifactPath: nil,
            frozenRevision: String(appliedRevision)
        )
    }

    func requestCancellation() async { token.cancel() }

    private func throwIfCancelled() throws {
        if token.isCancelled { throw FloeError.cancelled }
    }
}

/// Coalescing bridge from the media processor's synchronous progress channel
/// into the job service's async reporter: only the latest observation is kept
/// while a write is in flight, so a long video never spawns one task per frame.
private actor JobProgressBridge {
    private let hooks: NativeJobRunHooks
    private var pending: NativeJobProgress?
    private var draining = false
    private var finished = false

    init(hooks: NativeJobRunHooks) {
        self.hooks = hooks
    }

    nonisolated func submit(_ update: NativeJobProgress) {
        Task { await self.enqueue(update) }
    }

    private func enqueue(_ update: NativeJobProgress) {
        guard !finished else { return }
        pending = update
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let next = pending {
            pending = nil
            await hooks.report(next)
        }
        draining = false
    }

    func finish() async {
        finished = true
        // Let the last coalesced observation reach the recorder.
        while draining || pending != nil {
            if let next = pending {
                pending = nil
                await hooks.report(next)
            } else {
                await Task.yield()
            }
        }
    }
}
#endif
