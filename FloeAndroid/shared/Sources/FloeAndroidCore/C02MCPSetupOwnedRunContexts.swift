// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeAndroidJobTools
import FloeAndroidShellTools

/// Native maintenance runs use the original conversation/run/job stores and
/// the original conversation-owned operation lease. No model is selected or
/// invoked. The token stays live until jobs and mailbox IO really drain.
public actor C02MCPSetupOwnedRunContexts: C02MCPSetupExecutionContextProviding {
    private struct Owner: Sendable {
        let context: C02MCPSetupExecutionContext
        let binding: C02MCPSetupBinding
        let revision: String
        let operation: G04WorkspaceOwnedOperation
        let domain: FacadeRunDomain
        var jobIDs: Set<UUID> = []
        var submissions = 0
    }
    private let epoch: UInt64
    private let conversations: FacadeConversationDomain
    private let library: C01ProjectLibrary
    private let runs: any RunStore
    private let jobs: BackgroundJobService
    private let targets: C02ExecutionTargetDomain
    private var owners: [UUID: Owner] = [:]
    private struct Pending: Sendable { let id: UUID; let task: Task<Owner, Error> }
    private var pending: [UUID: Pending] = [:]
    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var settling: Set<UUID> = []

    public init(epoch: UInt64, conversations: FacadeConversationDomain,
                library: C01ProjectLibrary, runs: any RunStore,
                jobs: BackgroundJobService, targets: C02ExecutionTargetDomain) {
        self.epoch = epoch; self.conversations = conversations
        self.library = library; self.runs = runs; self.jobs = jobs; self.targets = targets
    }

    public func prepare(binding: C02MCPSetupBinding, expectedProjectRevision: String) async throws -> String? {
        if let owner = owners[binding.recordID] {
            try await validate(owner, binding: binding)
            return nil // This call did not change the project revision.
        }
        let admitted: Pending
        if let existing = pending[binding.recordID] { admitted = existing }
        else {
            guard owners.count + pending.count < C02MCPSetupLimits.maximumRecords else {
                throw failure("Too many MCP setup tasks are retained.")
            }
            admitted = Pending(id: UUID(), task: Task {
                try await self.makeOwner(binding: binding, revision: expectedProjectRevision)
            })
            pending[binding.recordID] = admitted
        }
        let task = admitted.task
        do {
            let owner = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            if owners[binding.recordID] == nil {
                owners[binding.recordID] = owner
                startMonitor(binding.recordID)
            }
            if pending[binding.recordID]?.id == admitted.id { pending[binding.recordID] = nil }
            if task.isCancelled { owner.context.cancellation.cancel() }
            try await validate(owner, binding: binding)
            return owner.revision
        } catch {
            if pending[binding.recordID]?.id == admitted.id { pending[binding.recordID] = nil }
            throw error
        }
    }

    public func context(for binding: C02MCPSetupBinding) async throws -> C02MCPSetupExecutionContext {
        guard let owner = owners[binding.recordID] else {
            throw failure("Prepare this MCP service before starting its jobs.")
        }
        try await validate(owner, binding: binding)
        return owner.context
    }

    public func submissionStarted(recordID: UUID) async throws {
        guard var owner = owners[recordID] else { throw failure("The setup task is no longer available.") }
        try await validate(owner, binding: owner.binding)
        // validate suspends. Re-read so another submission's reservation is
        // never lost through actor reentrancy.
        guard let latest = owners[recordID], !latest.context.cancellation.isCancelled else {
            throw failure("The setup task was cancelled.")
        }
        owner = latest; owner.submissions += 1; owners[recordID] = owner
    }

    public func submissionFinished(recordID: UUID, jobID: UUID?) async {
        guard let owner = owners[recordID] else { return }
        let ownedJob: UUID?
        if let jobID, let job = try? await jobs.job(id: jobID),
           job.runID == owner.context.runID, job.conversationID == owner.context.conversationID {
            ownedJob = jobID
        } else { ownedJob = nil }
        guard var latest = owners[recordID], latest.context.runID == owner.context.runID else { return }
        if let ownedJob { latest.jobIDs.insert(ownedJob) }
        latest.submissions = max(0, latest.submissions - 1)
        owners[recordID] = latest
    }

    public func finish(recordID: UUID) async throws {
        if let admitted = pending[recordID] { admitted.task.cancel() }
        owners[recordID]?.context.cancellation.cancel()
        await settle(recordID)
        if owners[recordID] != nil || pending[recordID] != nil {
            throw failure("The MCP setup task is still stopping. Wait for its jobs to release.")
        }
    }

    private func makeOwner(binding: C02MCPSetupBinding, revision: String) async throws -> Owner {
        guard G02NativeRootEpoch.readback() == epoch else { throw failure("The storage location changed.") }
        try Task.checkCancellation()
        let project = try await library.get(projectID: binding.projectID).project
        guard project.revision == revision else { throw failure("The project changed before setup started.") }
        let created = try await conversations.create(payload: .object([
            "title": .string("MCP · " + String(binding.projectName.prefix(100)))
        ]))
        try Task.checkCancellation()
        let assignment = try await library.assign(projectID: binding.projectID,
            conversationID: created.conversationID, expectedRevision: revision)
        let runID = UUID()
        guard assignment.fenceSettled,
              let domain = RunDomainFacade.current(epoch: epoch)?.0,
              let operation = await domain.beginG04WorkspaceOperation(
                conversationID: created.conversationID, expectedEpoch: epoch,
                nativeRunID: runID) else {
            throw failure("The project is busy or stopping.")
        }
        var stored = false
        do {
            try Task.checkCancellation()
            try operation.cancellation.throwIfCancelled()
            guard let workspace = await LinuxWorkspaceAuthority.resolveWorkspace(
                conversationID: created.conversationID),
                workspace.workspaceID == binding.projectID,
                workspace.rootURL.standardizedFileURL.resolvingSymlinksInPath().path ==
                    binding.rootURL.standardizedFileURL.resolvingSymlinksInPath().path else {
                throw failure("The task no longer belongs to this project.")
            }
            try await runs.saveRun(RunRecord(id: runID, conversationID: created.conversationID,
                state: "running", goal: "MCP · " + String(binding.projectName.prefix(100)), startedAt: Date(), conversationMode: "agent"))
            stored = true
            let resolved = try await targets.resolveUsingExistingEnvironment(
                taskID: created.conversationID, runID: runID,
                preferredEnvironmentID: binding.environmentID)
            guard resolved?.target.kind == .localLinux,
                  resolved?.target.environmentID == binding.environmentID else {
                throw failure("The selected Linux environment could not be bound.")
            }
            try Task.checkCancellation()
            try operation.cancellation.throwIfCancelled()
            return Owner(context: C02MCPSetupExecutionContext(runID: runID,
                conversationID: created.conversationID, workspaceRootURL: binding.rootURL,
                environmentID: binding.environmentID, cancellation: operation.cancellation),
                binding: binding, revision: assignment.revision, operation: operation, domain: domain)
        } catch {
            // No job/process has been admitted yet. Preserve the real task in
            // history, settle its header, then release this exact lease.
            if stored { try? await runs.updateRunState(id: runID, state: "failed", endedAt: Date()) }
            await domain.endG04WorkspaceOperation(operation)
            throw error
        }
    }

    private func validate(_ owner: Owner, binding: C02MCPSetupBinding) async throws {
        guard G02NativeRootEpoch.readback() == epoch,
              owner.binding.projectID == binding.projectID,
              owner.context.environmentID == binding.environmentID,
              owner.binding.rootIdentity == binding.rootIdentity,
              owner.binding.workspaceRelativePath == binding.workspaceRelativePath,
              await owner.domain.validateG04WorkspaceOperation(owner.operation),
              let run = try await runs.run(id: owner.context.runID),
              run.conversationID == owner.context.conversationID,
              run.state == "running" else { throw failure("The setup task is no longer active in this project.") }
    }

    private func startMonitor(_ id: UUID) {
        guard monitors[id] == nil else { return }
        monitors[id] = Task { [weak self] in
            while let self, await self.contains(id) {
                await self.settle(id)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await self?.monitorFinished(id)
        }
    }
    private func contains(_ id: UUID) -> Bool { owners[id] != nil }
    private func monitorFinished(_ id: UUID) { monitors[id] = nil }

    private func settle(_ id: UUID) async {
        guard let owner = owners[id], !settling.contains(id) else { return }
        guard owner.context.cancellation.isCancelled || G02NativeRootEpoch.readback() != epoch else { return }
        owner.context.cancellation.cancel()
        settling.insert(id)
        defer { settling.remove(id) }
        guard owner.submissions == 0 else { return }
        for jobID in owner.jobIDs {
            guard let job = try? await jobs.job(id: jobID),
                  job.runID == owner.context.runID,
                  job.conversationID == owner.context.conversationID else { return }
            if !job.state.isTerminal { _ = try? await jobs.cancel(id: jobID); return }
            if C01ManagedServiceDomain.shared.hasLiveService(jobID: jobID) { return }
        }
        guard !LinuxShellMailbox.shared.hasLiveTickets(runID: owner.context.runID),
              owners[id]?.submissions == 0 else { return }
        do { try await runs.updateRunState(id: owner.context.runID, state: "interrupted", endedAt: Date()) }
        catch { return } // Storage failure is not a successful settlement.
        await owner.domain.endG04WorkspaceOperation(owner.operation)
        owners[id] = nil
    }

    private func failure(_ message: String) -> C02MCPSetupFailure {
        C02MCPSetupFailure(.buildStepFailed, message: message, retryable: true)
    }
}
