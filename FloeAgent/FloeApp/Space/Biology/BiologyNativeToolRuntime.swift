// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine

/// The compiled native Execute/Run event owns a real durable run. This class
/// does not invoke a model or infer approval from tool arguments. The injected
/// canonical recorder persists the exact grant before authority is issued.
@MainActor final class BiologyNativeToolRuntime: BiologyNativeRuntime {
    private weak var environment: AppEnvironment?
    private weak var host: BiologyHostServices?
    private let approval: BiologyNativeApprovalResolver
    private struct Call {
        let cancellation: CancellationToken
        let toolName: String
        var token: UUID?
        var returned = false
    }
    private struct Owner {
        let projectID: UUID
        let taskID: UUID
        let runID: UUID
        let root: WorkspaceCenter.TaskRootLease
        let layers: ToolEnvironmentLease
        let cancellation: CancellationToken
        var calls: [String: Call] = [:]
        var closing = false
        var retiring = false
        var observer: Task<Void, Never>?
    }
    private var owners: [UUID: Owner] = [:]
    private var preparing: [UUID: Task<BiologyExecutionOwner, Error>] = [:]

    init(environment: AppEnvironment, approval: @escaping BiologyNativeApprovalResolver) {
        self.environment = environment; self.approval = approval
    }
    func bind(host: BiologyHostServices) throws {
        guard self.host == nil || self.host === host else { throw BiologyHostError.changed }
        self.host = host
    }
    private func app() throws -> AppEnvironment {
        guard let environment, host != nil else { throw BiologyHostError.unavailable }
        return environment
    }
    func consoleOwner(projectID: UUID) async throws -> BiologyExecutionOwner {
        try Task.checkCancellation()
        if let owner = owners[projectID] {
            guard !owner.retiring, !owner.cancellation.isCancelled else { throw BiologyHostError.changed }
            let app = try app()
            guard let host, let run = try await app.runStore.run(id: owner.runID), run.endedAt == nil,
                  run.conversationID == owner.taskID, let saved = run.executionBinding,
                  let current = try await TaskExecutionBindingStore(database: app.database).binding(conversationID: owner.taskID),
                  current.generation == saved.generation, current.target == saved.target else { throw BiologyHostError.changed }
            _ = try await host.access.location(projectID)
            guard owners[projectID]?.runID == owner.runID, owners[projectID]?.retiring == false else { throw BiologyHostError.changed }
            // Reopening the same original can keep observing its still-owned
            // calculation. It never takes an old run to a newly selected task.
            owners[projectID]?.closing = false
            return .init(taskID: owner.taskID, hostRunID: owner.runID)
        }
        if let task = preparing[projectID] { return try await task.value }
        let task = Task { @MainActor in try await self.openOwner(projectID: projectID) }
        preparing[projectID] = task
        defer { preparing[projectID] = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func openOwner(projectID: UUID) async throws -> BiologyExecutionOwner {
        let app = try app()
        guard let host else { throw BiologyHostError.unavailable }
        let location = try await host.access.location(projectID)
        let taskID = try await app.studioCoordinator.assistant(for: location.record)
        let authority = try app.studioCoordinator.access.get()
        guard try await authority.canAccess(conversationID: taskID, projectID: projectID, editing: true),
              let conversation = try await app.conversationStore.conversation(id: taskID),
              conversation.purpose == .ordinary else { throw BiologyHostError.readOnly }
        let workspace = try await SQLiteWorkspaceStore(database: app.database)
            .ensureWorkspace(conversationID: taskID, title: location.record.title)
        let root = try await app.workspaceCenter.acquireTaskRoot(workspace, conversationID: taskID)
        let runID = UUID(), cancellation = CancellationToken()
        var layers: ToolEnvironmentLease?
        var persisted = false
        do {
            let pin = try await app.taskExecutionEnvironments.resolveBinding(conversationID: taskID,
                runID: runID, root: root.url, workspace: workspace)
            try Task.checkCancellation()
            try await app.runStore.saveRun(.init(id: runID, conversationID: taskID,
                state: "waitingNativeInput", goal: "Biology workbench", startedAt: Date(), executionBinding: pin))
            persisted = true
            // No tool is executing while acquiring the real layer lease.
            // Preserve the resolved scope and reject unavailable routing;
            // never fabricate ToolEnvironment from a selected identifier.
            let libraryRoot = try PersonalContentLibrary.applicationRoot()
            let context = ToolContext(runID: runID, scope: pin.target.remoteHostID.map(ToolScope.host) ?? .local,
                workspaceRootURL: root.url,
                serviceStorePaths: [TypedMutationContract.nativeStudioLibraryStoreKey: libraryRoot.path,
                    TypedMutationContract.nativeBiologyStoreKey: host.root.path],
                cancellation: cancellation, environmentID: pin.target.environmentID,
                executionBindingGeneration: pin.generation, conversationID: taskID,
                clientSessionID: "biology.native." + runID.uuidString.lowercased())
            let acquired = try await ToolEnvironmentRouting.shared.acquire(context)
            layers = acquired
            guard acquired.context.environment?.id == pin.target.environmentID,
                  acquired.context.environmentID == pin.target.environmentID,
                  acquired.context.conversationID == taskID else { throw BiologyHostError.missingRuntime }
            try Task.checkCancellation()
            _ = try await host.access.location(projectID)
            try await app.runStore.appendEvent(runID: runID, kind: .status,
                payloadJSON: "{\"source\":\"biology.native\",\"state\":\"waitingNativeInput\",\"projectID\":\"\(projectID.uuidString)\"}")
            try Task.checkCancellation()
            owners[projectID] = Owner(projectID: projectID, taskID: taskID, runID: runID,
                root: root, layers: acquired, cancellation: cancellation)
            return .init(taskID: taskID, hostRunID: runID)
        } catch {
            cancellation.cancel()
            if let layers { await layers.finish() }
            root.release()
            if persisted { try? await app.runStore.updateRunState(id: runID, state: "failed", endedAt: Date()) }
            throw error
        }
    }

    func authorizeTool(projectID: UUID, toolName: String, arguments: Data, requestID: String) async throws -> BiologyNativeAuthorization {
        try await authorize(projectID: projectID, toolName: toolName, arguments: arguments,
            requestID: requestID, source: .console)
    }
    func authorizeAnalysis(projectID: UUID, arguments: Data, requestID: String,
                           source: BiologyNativeUIIntent.Source) async throws -> BiologyNativeAuthorization {
        guard source == .analysis || source == .imageRegion else { throw BiologyHostError.changed }
        return try await authorize(projectID: projectID, toolName: "biology.analyze", arguments: arguments,
            requestID: requestID, source: source)
    }
    private func authorize(projectID: UUID, toolName: String, arguments: Data, requestID: String,
                           source: BiologyNativeUIIntent.Source) async throws -> BiologyNativeAuthorization {
        let app = try app()
        guard let host, BiologyHostServices.names.contains(toolName),
              !requestID.isEmpty, requestID.utf8.count <= 256,
              let runner = host.registry.runner(named: toolName) else { throw BiologyHostError.changed }
        try runner.validateArguments(arguments)
        let value = try JSONDecoder().decode(BiologyJSON.self, from: arguments)
        // The bound console cannot silently redirect its current-project
        // operation to a sibling. Source imports still need their own grant.
        if let selected = value["projectID"]?.string {
            guard UUID(uuidString: selected) == projectID else { throw BiologyHostError.readOnly }
        }
        _ = try await consoleOwner(projectID: projectID)
        guard let owner = owners[projectID], !owner.closing, owner.calls[requestID] == nil,
              owner.calls.count < 128 else { throw BiologyHostError.changed }
        let policy = try await SQLiteWorkspaceStore(database: app.database).taskPolicy(conversationID: owner.taskID)
        var allowed = Set(host.registry.allDescriptors.map(\.name)).intersection(BiologyHostServices.names.union(["exec.shell"]))
        if let ceiling = policy.allowedToolNames { allowed.formIntersection(ceiling) }
        guard allowed.contains(toolName) else { throw BiologyHostError.readOnly }
        let cancellation = owner.cancellation.derived()
        owners[projectID]?.calls[requestID] = Call(cancellation: cancellation, toolName: toolName)
        do {
            var context = owner.layers.context
            context.cancellation = cancellation
            context.allowedToolNames = allowed; context.frozenEffectiveCatalogNames = allowed
            context.toolCallID = requestID; context.executionToolName = toolName
            let call = try ToolCall(id: requestID, toolName: toolName, argumentsJSON: arguments, scope: context.scope)
            context.toolIdempotencyKey = call.idempotencyKey
            let digest = RuntimeAuthorityDigest.payloadDigest(arguments)
            let action = ProposedAction(toolCall: call, riskLabels: Set(runner.descriptor.riskLabels.map(\.rawValue)),
                userGoal: "Native biology workbench action", hostAndPathScope: call.scope)
            let grant = try await approval(action, context, runner.descriptor,
                .init(source: source, projectID: projectID, requestID: requestID, payloadDigest: digest))
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard let current = owners[projectID], current.runID == owner.runID, !current.closing,
                  host.registry.runner(named: toolName)?.descriptor.authorizationIdentity == runner.descriptor.authorizationIdentity,
                  grant.scope.toolAuthorizationIdentity == runner.descriptor.authorizationIdentity,
                  grant.scope.singleUse, grant.scope.toolName == toolName,
                  grant.expiresAt.map({ $0 > Date() }) != false else { throw BiologyHostError.changed }
            context.approvalGrantID = grant.id; context.approvalOrigin = .policy("native-ui")
            let target = RuntimeAuthorityDigest.canonicalTarget(for: call, descriptor: runner.descriptor,
                workspaceRootURL: context.workspaceRootURL, serviceStorePaths: context.serviceStorePaths)
            let base = RuntimeAuthorityDigest.baseRevision(in: arguments)
            let binding = context.runtimeAuthorityBinding(toolName: toolName, operation: "apply",
                canonicalTarget: target, baseRevision: base, payloadDigest: digest)
            let token = await RuntimeAuthorityStore.shared.issue(.init(runID: owner.runID, taskID: owner.taskID,
                environmentBinding: binding.environmentBinding, canonicalTarget: target, toolName: toolName,
                operation: "apply", operationID: requestID, idempotencyKey: call.idempotencyKey,
                baseRevision: base, payloadDigest: digest, approvalGrantID: grant.id))
            context.runtimeAuthority = token
            owners[projectID]?.calls[requestID]?.token = token.id
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            return .init(context: context, binding: binding, finish: { [weak self] in
                await self?.returned(projectID: projectID, runID: owner.runID, requestID: requestID)
            })
        } catch {
            await returned(projectID: projectID, runID: owner.runID, requestID: requestID)
            throw error
        }
    }
    // This old pair cannot describe an exact scientific action. The App uses
    // authorizeAnalysis with its compiled method/options/revision callback.
    func authorizeScientificLaunch(projectID: UUID, assetID: UUID, assetRevision: UInt64) async throws -> BiologyNativeAuthorization {
        throw BiologyHostError.missingRuntime
    }
    private func returned(projectID: UUID, runID: UUID, requestID: String) async {
        guard owners[projectID]?.runID == runID else { return }
        owners[projectID]?.calls[requestID]?.returned = true
        await retireReturned(projectID: projectID, runID: runID)
    }
    private func retireReturned(projectID: UUID, runID: UUID) async {
        guard let host, let owner = owners[projectID], owner.runID == runID,
              let project = try? await host.store.load(projectID) else { return }
        let identity = BiologyExecutionOwner(taskID: owner.taskID, hostRunID: runID)
        let finished = owner.calls.filter { $0.value.returned }
        var waiting = false
        for (requestID, call) in finished {
            if call.toolName == "biology.analyze" {
                // The original atomic receipt binds this exact request to its
                // actual biology run. A sibling call cannot retire its lease.
                if let receipt = project.mutationReceipts?.first(where: {
                    $0.identity.owner == identity && $0.identity.requestID == requestID
                }), let recorded = try? JSONDecoder().decode(BiologyRun.self, from: receipt.result) {
                    guard let saved = project.runs.first(where: { $0.id == recorded.id && $0.owner == identity }) else { continue }
                    if saved.isActive { waiting = true; continue }
                    guard let joined = try? await host.service.wait(projectID, runID: saved.id),
                          !joined.isActive, joined.workerStopUnconfirmed != true else { waiting = true; continue }
                } else if project.runs.contains(where: { $0.owner == identity && $0.isActive }) {
                    // An incomplete receipt is never evidence of a stopped
                    // worker. Preserve ownership for explicit reconciliation.
                    waiting = true; continue
                }
            }
            guard owners[projectID]?.runID == runID,
                  owners[projectID]?.calls[requestID]?.returned == true else { continue }
            owners[projectID]?.calls.removeValue(forKey: requestID)
            call.cancellation.cancel()
            if let token = call.token { await RuntimeAuthorityStore.shared.revoke(id: token) }
        }
        if waiting { observeWorker(projectID: projectID, runID: runID) }
        if owners[projectID]?.closing == true, owners[projectID]?.calls.isEmpty == true {
            await closeOwner(projectID: projectID, runID: runID)
        }
    }
    private func observeWorker(projectID: UUID, runID: UUID) {
        guard let host, owners[projectID]?.observer == nil else { return }
        owners[projectID]?.observer = Task { @MainActor [weak self, weak host] in
            guard let self, let host else { return }
            do {
                for await _ in try await host.service.changes(projectID) {
                    guard !Task.isCancelled, self.owners[projectID]?.runID == runID else { return }
                    await self.retireReturned(projectID: projectID, runID: runID)
                }
            } catch { /* Keep uncertain worker leases for explicit reconciliation. */ }
        }
    }
    func closeConsoleOwner(projectID: UUID) async {
        preparing[projectID]?.cancel()
        guard let owner = owners[projectID] else { return }
        owners[projectID]?.closing = true
        var active = true // Missing/uncertain state never proves a stopped worker.
        if let host, let project = try? await host.store.load(projectID) {
            active = project.runs.contains(where: {
                $0.owner == .init(taskID: owner.taskID, hostRunID: owner.runID) && $0.isActive
            })
        }
        if !active {
            for call in owner.calls.values where !call.returned { call.cancellation.cancel() }
        }
        await retireReturned(projectID: projectID, runID: owner.runID)
    }
    private func closeOwner(projectID: UUID, runID: UUID) async {
        guard let owner = owners[projectID], owner.runID == runID else { return }
        // Persist completion before releasing the genuine leases. If the DB
        // cannot commit, retain ownership and permit an explicit retry.
        guard let app = environment else { return }
        owners[projectID]?.retiring = true
        do {
            try await app.runStore.appendEvent(runID: runID, kind: .status,
                payloadJSON: "{\"source\":\"biology.native\",\"state\":\"completed\"}")
            try await app.runStore.updateRunState(id: runID, state: "completed", endedAt: Date())
        } catch {
            if owners[projectID]?.runID == runID { owners[projectID]?.retiring = false }
            return
        }
        guard owners[projectID]?.runID == runID else { return }
        owners.removeValue(forKey: projectID)
        owner.observer?.cancel(); owner.cancellation.cancel()
        _ = await RuntimeAuthorityStore.shared.revoke(runID: runID)
        await owner.layers.finish(); owner.root.release()
    }
}
#endif
