#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeExecution
import FloePersistence
import FloeSkills
import FloeWorkspace
import FloeEnvironments

struct MCPServiceCreationOption: Identifiable, Sendable {
    let id: String
    let title: String
}

/// Uses AppEnvironment's existing launch, workspace, jobs and connection
/// owners. No provider, interpreter, credential or service registry is added.
@MainActor
final class MCPServiceCreationAppBackend: MCPServiceCreationBackend {
    let environment: AppEnvironment
    let connections: MCPSettingsCenter
    private var rootLeases: [UUID: WorkspaceCenter.TaskRootLease] = [:]
    private var frozenModels: [UUID: (ProviderProfile, ModelProfile)] = [:]
    private var generationTasks: [UUID: StartedConversationRun] = [:]
    private var clients: [UUID: MCPRemoteClient] = [:]
    private let jobs: BackgroundJobStore
    private var stopping: Set<UUID> = []
    private var inFlight: [UUID: Int] = [:]
    private var serviceObservers: [UUID: Task<Void, Never>] = [:]
    var onServiceEvent: ((MCPServiceCreationServiceEvent) -> Void)?

    init(environment: AppEnvironment, connections: MCPSettingsCenter) {
        self.environment = environment; self.connections = connections
        jobs = BackgroundJobStore(database: environment.database)
    }

    func validateTaskLink(_ record: MCPServiceCreationRecord) async throws {
        guard let run = try await environment.runStore.run(id: record.runID),
              run.conversationID == record.conversationID,
              try await environment.conversationStore.conversation(id: record.conversationID) != nil else {
            throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.task_preparing"))
        }
    }

    func projectOptions() async throws -> [MCPServiceCreationOption] {
        try await SQLiteWorkspaceStore(database: environment.database).workspaces()
            .filter { $0.kind == .project }
            .map { MCPServiceCreationOption(id: $0.id.uuidString, title: $0.name) }
    }

    func environmentOptions(workspaceID: UUID) async throws -> [MCPServiceCreationOption] {
        let lease = try await acquireRoot(workspaceID: workspaceID, conversationID: UUID())
        defer { lease.release() }
        let root = lease.url.resolvingSymlinksInPath().standardizedFileURL
        let owner = FloeDigest.sha256Hex(Data(root.path.utf8))
        try await environment.environmentRegistry.prepare()
        // Explicit project selection can materialize its metadata; it does
        // not boot a guest or choose a different project's environment.
        _ = try await environment.environmentRegistry.ensureProjectContainer(
            workspaceID: owner, workspaceRootPath: root.path)
        return await environment.environmentRegistry.all().filter {
            $0.kind == .project && $0.ownerID == owner && $0.state == .active
                && !$0.requiresRebuild && $0.executionBackend == .linuxVM
        }.map { MCPServiceCreationOption(id: $0.id, title: $0.name ?? FloeL10n.l("skills.mcp.creation.project_environment")) }
    }

    func resolve(_ record: MCPServiceCreationRecord) async throws -> MCPServiceCreationBinding {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let lease = try await acquireRoot(workspaceID: record.request.workspaceID, conversationID: record.conversationID)
        let root = lease.url.resolvingSymlinksInPath().standardizedFileURL
        do {
            try await validateEnvironment(record.request.environmentID, root: root)
            // Read only the existing persisted route. A full conversation
            // reload may initialize unrelated local models and must not be
            // a prerequisite for opening this creator.
            let preferences = try await environment.configurationStore.preferences()
            guard let modelID = preferences.generalAuxiliaryLLMModelID ?? preferences.defaultAgentModelID,
                  let model = try await environment.configurationStore.model(id: modelID),
                  let provider = try await environment.configurationStore.provider(id: model.providerID),
                  provider.isEnabled, model.isEnabled, model.supportsGeneralAuxiliaryLLM,
                  model.capabilities.contains(.tools) else {
                throw FloeError.invalidConfiguration(FloeL10n.l("skills.mcp.creation.model_required"))
            }
            let pair = (provider, model)
            try checkActive(record.id)
            rootLeases[record.id]?.release(); rootLeases[record.id] = lease
            frozenModels[record.id] = pair
            return MCPServiceCreationBinding(root: root,
                projectRelativePath: "MCPServices/" + record.id.uuidString.lowercased(),
                providerID: pair.0.id, modelID: pair.1.id, modelName: pair.1.displayName)
        } catch { lease.release(); throw error }
    }

    func prepare(_ record: MCPServiceCreationRecord, template: MCPServiceTemplate.VerifiedPackage) async throws {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        let guardPaths = WorkspacePathGuard(rootURL: binding.root)
        let destination = try guardPaths.resolve(binding.projectRelativePath)
        try checkActive(record.id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            // A fresh operation directory; the archive helper refuses an
            // existing destination and validates every member before writing.
            _ = try SignedContentArchive.extract(template.archive, at: destination,
                limits: .init(maximumEntries: 32, maximumFileBytes: 262_144, maximumTotalBytes: 1_048_576),
                allowedTopLevel: ["README.md", "contract.json", "node-http"])
            let launcher = destination.appendingPathComponent("node-http/floe-start.mjs")
            try Data(Self.launcher.utf8).write(to: launcher, options: .atomic)
        }
        try validateFixedInputs(record)
    }

    func generate(_ record: MCPServiceCreationRecord) async throws {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        if let existing = try await environment.runStore.run(id: record.runID) {
            guard existing.conversationID == record.conversationID,
                  existing.providerID == binding.providerID, existing.modelID == binding.modelID else {
                throw ownershipError()
            }
            if let started = generationTasks[record.id] { try await started.result.value.get() }
            else {
                // Re-entry observes the same run, never resubmits its provider
                // request. Process recovery reports interrupted through the
                // existing ConversationCenter launch-reconciliation path.
                while environment.conversationCenter.hasLiveOwner(runID: record.runID) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(400))
                }
            }
        } else {
            let pair = try await frozenPair(record)
            try checkActive(record.id)
            let started = try await environment.conversationCenter.startTask(
                goal: Self.generationGoal(record), title: record.request.name,
                provider: pair.0, model: pair.1, workspaceID: record.request.workspaceID,
                executionMode: .agent, newConversationID: record.conversationID,
                newRunID: record.runID, executionEnvironmentID: record.request.environmentID,
                startOrigin: .explicitUserAction)
            guard started.conversationID == record.conversationID, started.run.runID == record.runID else { throw ownershipError() }
            generationTasks[record.id] = started.run
            if stopping.contains(record.id) || Task.isCancelled {
                await environment.conversationCenter.cancel(runID: record.runID)
                _ = await started.run.result.value
                throw CancellationError()
            }
            try await started.run.result.value.get()
        }
        try Task.checkCancellation()
        guard let completed = try await environment.runStore.run(id: record.runID),
              completed.conversationID == record.conversationID, completed.state == "completed" else {
            throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.generation_incomplete"))
        }
        try validateFixedInputs(record)
    }

    /// Submits the first outstanding bounded build phase and returns its job
    /// ID as the persisted `buildJobID` anchor. The anchor is the row adopted
    /// at submit time — a pre-patch monolithic row, the first live or honestly
    /// terminal phase row, or the first missing phase just submitted here. The
    /// coordinator stores it once and `waitForBuild` advances through the later
    /// phases with a local id, so this persisted field is the recovery anchor,
    /// not a "current phase" claim: re-entry re-traverses the already-completed
    /// bound phases (skipped, never replayed) and re-anchors on the first
    /// outstanding row.
    ///
    /// Resume rules, applied only to rows this backend can actually prove:
    /// every present legacy or phase row is verified for owner identity AND for
    /// this backend's exact fixed native command payload before any of its
    /// state is used to decide anything, so a completed row from a foreign
    /// conversation, environment or root, or a same-owner row carrying some
    /// other payload, can never authorize a new phase. A verified completed
    /// phase is skipped (never replayed); a verified live or honestly terminal
    /// phase row is attached and judged by `waitForBuild` (failure stays
    /// failure, no automatic replay); only a missing phase whose verified
    /// predecessors are all completed is submitted. A present-but-unbound row
    /// is a hard refusal: it is not counted and not cancelled, because it is
    /// not our work. Every submission uses the same explicit run, environment,
    /// root lease and permission ceiling as before, and a late receipt during
    /// Stop is cancelled and settled by `settleLateSubmission` before the
    /// caller's `inFlight` count drops, so Stop cannot release the lease while
    /// a phase submit is still in flight.
    func submitBuild(_ record: MCPServiceCreationRecord) async throws -> UUID {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        try validateFixedInputs(record)
        if let legacy = try await jobs.job(runID: record.runID, toolCallID: Self.legacyBuildCallID(record.id)) {
            try verifyOwned(legacy, record: record, tool: "exec.shell")
            guard Self.matchesNativeBuildPayload(legacy.payloadJSON, callID: Self.legacyBuildCallID(record.id),
                                                 recordID: record.id,
                                                 projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
            return legacy.id
        }
        var rows: [MCPServiceBuildRow?] = []
        var jobsByPhase: [BackgroundJob?] = []
        for callID in Self.buildPhaseCallIDs(record.id) {
            guard let job = try await jobs.job(runID: record.runID, toolCallID: callID) else {
                rows.append(nil); jobsByPhase.append(nil); continue
            }
            try verifyOwned(job, record: record, tool: "exec.shell")
            rows.append(MCPServiceBuildRow(state: job.state, bound: Self.matchesNativeBuildPayload(
                job.payloadJSON, callID: callID, recordID: record.id, projectRelativePath: binding.projectRelativePath)))
            jobsByPhase.append(job)
        }
        switch Self.nextBuildPhaseAction(rows: rows) {
        case .reject:
            throw ownershipError()
        case .attachPhase(let index):
            guard index < jobsByPhase.count, let job = jobsByPhase[index] else { throw ownershipError() }
            return job.id
        case .submitPhase(let index):
            return try await submitBuildPhase(record: record, binding: binding, index: index)
        case .allCompleted:
            guard let final = jobsByPhase.last, let job = final else { throw ownershipError() }
            try verifyOwned(job, record: record, tool: "exec.shell")
            return job.id
        }
    }

    /// Waits for the anchored phase job and advances serially. The anchored row
    /// must be owned by this record and carry this backend's exact fixed native
    /// payload before its state is judged; each verified completed phase
    /// re-validates the fixed inputs and only then submits the next phase. The
    /// final (test) phase completing is what returns success; a terminal
    /// non-completed phase throws its real error and no service can start.
    /// Advancement is owned work: it runs inside `beginWork`/`endWork` so Stop
    /// drains it before releasing the root lease. The advanced id stays local:
    /// the persisted `buildJobID` anchor is never rewritten here (re-entry
    /// re-traverses the completed bound phases instead of replaying them).
    func waitForBuild(_ record: MCPServiceCreationRecord) async throws {
        // The trusted advisory-group lease spans the whole phased build:
        // group liveness stays true across phase-handoff gaps (a fired
        // duration advisory is never swallowed between two bound phases),
        // and the lease is released exactly once at this driver's terminal
        // exit — success, failure, cancellation or ownership refusal.
        defer { scheduleAdvisoryLeaseRelease(record.id) }
        guard let id = record.buildJobID, let binding = record.binding else { throw ownershipError() }
        var currentID = id
        while true {
            try Task.checkCancellation()
            guard let job = try await jobs.job(id: currentID) else { throw ownershipError() }
            try verifyOwned(job, record: record, tool: "exec.shell")
            guard let callID = job.toolCallID,
                  Self.matchesNativeBuildPayload(job.payloadJSON, callID: callID, recordID: record.id,
                                                projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
            if job.state.isTerminal {
                guard job.state == .completed else {
                    throw FloeError.validationFailed(job.lastError ?? FloeL10n.l("skills.mcp.creation.build_failed"))
                }
                try validateFixedInputs(record)
                if callID == Self.legacyBuildCallID(record.id) { return }
                guard let index = Self.phaseIndex(forCallID: callID, recordID: record.id) else { throw ownershipError() }
                guard index + 1 < Self.buildPhaseSpecs.count else { return }
                currentID = try await advanceBuildPhase(record, after: index)
            } else {
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func submitService(_ record: MCPServiceCreationRecord) async throws -> UUID {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        try validateFixedInputs(record)
        // Defense in depth for the phased build: never launch the service
        // unless every owned phase row (or the pre-patch monolithic row) is
        // actually present, owner- and payload-verified and completed. A
        // missing, failed, cancelled, still-queued or unbound build row is a
        // hard refusal, not a substitute flag.
        try await verifyBuildPhasesCompleted(record, binding: binding)
        if let existing = try await jobs.job(runID: record.runID, toolCallID: serviceCallID(record)) {
            try verifyOwned(existing, record: record, tool: "exec.localService")
            guard Self.matchesNativeServicePayload(existing.payloadJSON, projectRelativePath: binding.projectRelativePath,
                                                   port: record.request.port) else { throw ownershipError() }
            observeService(existing.id, record: record)
            return existing.id
        }
        guard let service = environment.backgroundJobService else { throw unavailable() }
        let args = Self.expectedServicePayload(projectRelativePath: binding.projectRelativePath,
                                               port: record.request.port)
        try checkActive(record.id)
        let job = try await service.submit(runID: record.runID, toolCallID: serviceCallID(record),
            targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(args), scope: .local,
            workspaceRootURL: binding.root, allowedWorkspacePaths: [],
            environmentID: record.request.environmentID, submissionSource: .nativeService,
            waitForCompletion: false)
        try verifyOwned(job, record: record, tool: "exec.localService")
        try await settleLateSubmission(job, record: record)
        observeService(job.id, record: record)
        return job.id
    }

    func waitForEndpoint(_ record: MCPServiceCreationRecord) async throws -> URL {
        while true {
            try Task.checkCancellation()
            if let endpoint = try await ownedEndpoint(record) { return endpoint }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    func verify(_ record: MCPServiceCreationRecord, endpoint: URL) async throws -> MCPServiceCreationReceipt {
        guard try await ownedEndpoint(record) == endpoint, let jobID = record.serviceJobID else { throw ownershipError() }
        try checkActive(record.id)
        let configuration = MCPServerConfiguration(id: record.connectionID,
            displayName: record.request.name, endpoint: endpoint, enabled: true,
            allowInCanvas: false, allowInsecureHTTP: true, authentication: .none)
        let client = try MCPRemoteClient(configuration: configuration, credential: nil)
        clients[record.id] = client
        do {
            // Fixed SDK 1.x template explicitly negotiates its supported
            // session protocol; this is not inferred from a successful list.
            try await client.prepareLegacySession()
            let tools = try await client.discoverTools()
            guard let status = tools.first(where: { $0.remoteName == "service_status" }),
                  status.readOnlyHint, !status.destructiveHint else { throw smokeError() }
            let output = try await client.callTool(name: "service_status",
                argumentsJSON: Data(#"{"label":"floe-native-verification"}"#.utf8))
            guard output.exitStatus == 0,
                  let value = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: String],
                  value["status"] == "ready", value["service"] == "floe-mcp-service",
                  value["label"] == "floe-native-verification" else { throw smokeError() }
            try Task.checkCancellation()
            guard try await ownedEndpoint(record) == endpoint else { throw ownershipError() }
            await client.disconnect(); clients[record.id] = nil
            return MCPServiceCreationReceipt(conversationID: record.conversationID,
                runID: record.runID, serviceJobID: jobID, environmentID: record.request.environmentID,
                endpoint: endpoint, smokeDigest: output.fullOutputSHA256, verifiedAt: Date())
        } catch {
            await client.disconnect(); clients[record.id] = nil
            throw error
        }
    }

    func saveConnection(_ record: MCPServiceCreationRecord) async throws -> UUID {
        guard record.canSave, let receipt = record.receipt,
              try await ownedEndpoint(record) == receipt.endpoint else { throw ownershipError() }
        try Task.checkCancellation()
        // A previous commit may have survived a lost feature receipt. Never
        // replay upsert over a user's subsequent edits to that same entry.
        if connections.servers.contains(where: { $0.id == record.connectionID }) { return record.connectionID }
        let configuration = MCPServerConfiguration(id: record.connectionID,
            displayName: record.request.name, endpoint: receipt.endpoint, enabled: true,
            allowInCanvas: false, allowInsecureHTTP: true, authentication: .none)
        try await connections.upsert(configuration, credential: nil)
        // upsert persists configuration before refresh. Report the actual
        // committed identity even when connectivity changes during refresh.
        guard connections.servers.contains(where: { $0 == configuration }) else { throw ownershipError() }
        return configuration.id
    }

    func savedConnectionID(_ record: MCPServiceCreationRecord) -> UUID? {
        guard connections.servers.contains(where: { $0.id == record.connectionID }) else { return nil }
        return record.connectionID
    }

    func stop(_ record: MCPServiceCreationRecord) async throws {
        // Stop is a terminal exit for the trusted operation even when the
        // build driver is not (or no longer) running: release the advisory
        // group lease so a queued duration advisory cannot read a stopped
        // creation as live.
        defer { scheduleAdvisoryLeaseRelease(record.id) }
        stopping.insert(record.id)
        if let client = clients.removeValue(forKey: record.id) { await client.disconnect() }
        await environment.conversationCenter.cancel(runID: record.runID)
        if let started = generationTasks[record.id] { _ = await started.result.value }
        // A submit/launch may already be inside a different actor when Stop
        // arrives. Its late receipt is cancelled and settled by that caller;
        // wait for it before declaring cleanup done or releasing the root.
        while inFlight[record.id, default: 0] > 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        // Stop drains only our own rows: the pre-patch monolithic build row,
        // each bounded phase row and the service row, each re-proved as owned
        // and payload-bound before anything is cancelled. A present row whose
        // payload is not this backend's fixed native payload is left untouched
        // (force-cancelling another context's work is not ours to do) and is
        // never reported as our cleanup; the build/service stay honestly
        // unfulfilled. A phase submitted late during this stop was already
        // cancelled and settled by its caller inside the inFlight drain above.
        for call in [Self.legacyBuildCallID(record.id)] + Self.buildPhaseCallIDs(record.id) + [serviceCallID(record)] {
            guard let job = try await jobs.job(runID: record.runID, toolCallID: call) else { continue }
            let isService = call == serviceCallID(record)
            try verifyOwned(job, record: record, tool: isService ? "exec.localService" : "exec.shell")
            guard let binding = record.binding else { throw ownershipError() }
            let bound = isService
                ? Self.matchesNativeServicePayload(job.payloadJSON, projectRelativePath: binding.projectRelativePath,
                                                  port: record.request.port)
                : Self.matchesNativeBuildPayload(job.payloadJSON, callID: call, recordID: record.id,
                                                 projectRelativePath: binding.projectRelativePath)
            guard bound else { continue }
            if !job.state.isTerminal {
                guard let service = environment.backgroundJobService else { throw unavailable() }
                _ = try await service.cancel(id: job.id)
                while true {
                    guard let current = try await jobs.job(id: job.id) else { throw ownershipError() }
                    try verifyOwned(current, record: record, tool: job.targetTool)
                    if current.state.isTerminal { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    func release(_ record: MCPServiceCreationRecord) {
        rootLeases.removeValue(forKey: record.id)?.release()
        frozenModels[record.id] = nil; generationTasks[record.id] = nil
    }

    private func observeService(_ id: UUID, record: MCPServiceCreationRecord) {
        guard serviceObservers[record.id] == nil else { return }
        serviceObservers[record.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.serviceObservers[record.id] = nil }
            while !Task.isCancelled {
                do {
                    let job = try await self.jobs.job(id: id)
                    guard let job else {
                        self.onServiceEvent?(.init(operationID: record.id, jobID: id, kind: .unavailable))
                        return
                    }
                    try self.verifyOwned(job, record: record, tool: "exec.localService")
                    // The observed row must also carry this record's exact
                    // fixed native service payload; an unbound same-owner row
                    // is not our service, so report unavailability instead of
                    // judging or ending it.
                    guard let path = record.binding?.projectRelativePath,
                          Self.matchesNativeServicePayload(job.payloadJSON, projectRelativePath: path,
                                                           port: record.request.port) else {
                        self.onServiceEvent?(.init(operationID: record.id, jobID: id, kind: .unavailable))
                        return
                    }
                    if job.state.isTerminal {
                        self.release(record)
                        self.onServiceEvent?(.init(operationID: record.id, jobID: id, kind: .ended))
                        let expected = URL(string: "http://127.0.0.1:\(record.request.port)/mcp")
                        if self.connections.servers.contains(where: {
                            $0.id == record.connectionID && $0.endpoint == expected
                        }) {
                            await self.connections.refresh(serverID: record.connectionID)
                        }
                        return
                    }
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch {
                    // A DB failure is unknown, not a confirmed dead process.
                    // Preserve the root lease and actual owned service.
                    self.onServiceEvent?(.init(operationID: record.id, jobID: id, kind: .unavailable))
                    return
                }
            }
        }
    }

    private func acquireRoot(workspaceID: UUID, conversationID: UUID) async throws -> WorkspaceCenter.TaskRootLease {
        guard let project = try await SQLiteWorkspaceStore(database: environment.database).workspace(id: workspaceID),
              project.kind == .project else { throw ownershipError() }
        return try await environment.workspaceCenter.acquireTaskRoot(project, conversationID: conversationID)
    }

    private func bindingAndLease(_ record: MCPServiceCreationRecord) async throws -> MCPServiceCreationBinding {
        guard let binding = record.binding else { throw ownershipError() }
        if rootLeases[record.id] == nil {
            let lease = try await acquireRoot(workspaceID: record.request.workspaceID, conversationID: record.conversationID)
            guard lease.url.resolvingSymlinksInPath().standardizedFileURL == binding.root else {
                lease.release(); throw ownershipError()
            }
            do { try checkActive(record.id) }
            catch { lease.release(); throw error }
            rootLeases[record.id] = lease
        }
        try await validateEnvironment(record.request.environmentID, root: binding.root)
        return binding
    }

    private func validateEnvironment(_ id: String, root: URL) async throws {
        try await environment.environmentRegistry.prepare()
        let owner = FloeDigest.sha256Hex(Data(root.path.utf8))
        guard let selected = await environment.environmentRegistry.record(id: id),
              selected.kind == .project, selected.ownerID == owner,
              selected.state == .active, !selected.requiresRebuild,
              selected.executionBackend == .linuxVM else { throw ownershipError() }
    }

    private func frozenPair(_ record: MCPServiceCreationRecord) async throws -> (ProviderProfile, ModelProfile) {
        if let pair = frozenModels[record.id] { return pair }
        guard let binding = record.binding,
              let provider = try await environment.configurationStore.provider(id: binding.providerID), provider.isEnabled,
              let model = try await environment.configurationStore.model(id: binding.modelID),
              model.providerID == provider.id, model.isEnabled, model.supportsGeneralAuxiliaryLLM,
              model.capabilities.contains(.tools) else {
            throw FloeError.invalidConfiguration(FloeL10n.l("skills.mcp.creation.model_required"))
        }
        frozenModels[record.id] = (provider, model)
        return (provider, model)
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard !stopping.contains(id) else { throw CancellationError() }
    }

    private func beginWork(_ id: UUID) throws {
        try checkActive(id)
        inFlight[id, default: 0] += 1
    }

    private func endWork(_ id: UUID) {
        let count = max(0, inFlight[id, default: 0] - 1)
        inFlight[id] = count == 0 ? nil : count
    }

    private func settleLateSubmission(_ job: BackgroundJob, record: MCPServiceCreationRecord) async throws {
        guard stopping.contains(record.id) || Task.isCancelled else { return }
        guard let service = environment.backgroundJobService else { throw unavailable() }
        _ = try await service.cancel(id: job.id)
        // The original task is cancelled, so this drain deliberately has its
        // own uncancelled task rather than escaping on Task.sleep's cancel.
        let jobs = self.jobs
        try await Task.detached {
            while true {
                guard let current = try await jobs.job(id: job.id),
                      current.runID == job.runID, current.conversationID == job.conversationID,
                      current.environmentID == job.environmentID, current.targetTool == job.targetTool,
                      current.workspaceRootPath == job.workspaceRootPath else {
                    throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.owner_changed"))
                }
                if current.state.isTerminal { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }.value
        throw CancellationError()
    }

    /// Trusted-operation lease release (protocol entry, called by the
    /// coordinator when the record reaches an owner-terminal phase): drops
    /// the lease AND withdraws any still-queued duration advisory of this
    /// operation, so a late "still running" reminder never outlives the
    /// actual end. Never touches job state, payload binding or terminals.
    func releaseAdvisoryLease(recordID: UUID) async {
        guard let jobs = environment.backgroundJobService else { return }
        await jobs.releaseAdvisoryGroupLease(groupID: recordID)
        await environment.backgroundRunCoordinator.discardPendingDurationAdvisory(
            ownershipKey: "job.\(recordID.uuidString)")
    }

    /// Fire-and-forget variant for `defer` sites (the build driver's terminal
    /// exits cannot await): a delayed release merely widens the tiny window
    /// in which a queued advisory may still read the group as live, and the
    /// coordinator's terminal-phase release is the authoritative close.
    private func scheduleAdvisoryLeaseRelease(_ recordID: UUID) {
        Task { [weak self] in
            await self?.releaseAdvisoryLease(recordID: recordID)
        }
    }

    /// Submits one bounded owned build phase. Same explicit run, toolCall
    /// keying by the deterministic per-record phase ID, environment, root
    /// lease, workspace ceiling, native submission source, payload bytes and
    /// output bound as the previous single build row. The payload's literal
    /// `timeout: 600` is preserved BYTE-IDENTICAL (row validation binds those
    /// exact bytes); under the new time policy (2026-10-26) a bare number is
    /// an advisory hint, so the phase's effective execution is unlimited
    /// instead of the old app-default 600 s kill — no payload edit, no phase
    /// replay, and terminal historical rows stay terminal. The record id is
    /// bound as the trusted native advisory group so the phases of ONE
    /// creation share one 600 s reminder identity (no per-phase reset or
    /// duplicate advisory).
    /// The payload is taken from the single `expectedBuildPayload` source, so
    /// the bytes submitted here are exactly the bytes later rows are validated
    /// against and the two can never drift apart.
    private func submitBuildPhase(record: MCPServiceCreationRecord, binding: MCPServiceCreationBinding, index: Int) async throws -> UUID {
        guard let service = environment.backgroundJobService else { throw unavailable() }
        let spec = Self.buildPhaseSpecs[index]
        let callID = spec.callID(record.id)
        guard let args = Self.expectedBuildPayload(callID: callID, recordID: record.id,
                                                   projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
        try checkActive(record.id)
        let job = try await service.submit(runID: record.runID, toolCallID: callID,
            targetTool: "exec.shell", payloadJSON: JSONEncoder().encode(args), scope: .local,
            workspaceRootURL: binding.root, allowedWorkspacePaths: [],
            environmentID: record.request.environmentID, submissionSource: .nativeService,
            waitForCompletion: false,
            // Trusted native parent-operation advisory identity (never a
            // model-supplied alias): one creation record = one advisory.
            advisoryGroupID: record.id)
        try verifyOwned(job, record: record, tool: "exec.shell")
        try await settleLateSubmission(job, record: record)
        return job.id
    }

    /// Advances exactly one phase after the anchored row completed. The
    /// submit is owned work (`inFlight`) so Stop drains late submissions
    /// before the lease can be released, and it re-validates the fixed
    /// immutable inputs before any new guest execution starts. An already
    /// present next row is identity- and payload-verified before it is
    /// attached; an unbound row is a hard refusal, never a skipped step.
    private func advanceBuildPhase(_ record: MCPServiceCreationRecord, after index: Int) async throws -> UUID {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        try validateFixedInputs(record)
        let next = index + 1
        guard next < Self.buildPhaseSpecs.count else { throw ownershipError() }
        let callID = Self.buildPhaseSpecs[next].callID(record.id)
        if let existing = try await jobs.job(runID: record.runID, toolCallID: callID) {
            try verifyOwned(existing, record: record, tool: "exec.shell")
            guard Self.matchesNativeBuildPayload(existing.payloadJSON, callID: callID, recordID: record.id,
                                                 projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
            return existing.id
        }
        return try await submitBuildPhase(record: record, binding: binding, index: next)
    }

    /// No service launch before every owned build row actually completed:
    /// either the pre-patch monolithic row or all three phase rows. Every
    /// present row is verified for identity and exact native payload before
    /// its state is read, so a completed foreign or forged row cannot pass
    /// this gate. Any missing, non-completed or unbound row is a hard refusal.
    private func verifyBuildPhasesCompleted(_ record: MCPServiceCreationRecord,
                                            binding: MCPServiceCreationBinding) async throws {
        let legacyCallID = Self.legacyBuildCallID(record.id)
        if let legacy = try await jobs.job(runID: record.runID, toolCallID: legacyCallID) {
            try verifyOwned(legacy, record: record, tool: "exec.shell")
            guard Self.matchesNativeBuildPayload(legacy.payloadJSON, callID: legacyCallID, recordID: record.id,
                                                 projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
            guard legacy.state == .completed else { throw buildIncomplete() }
            return
        }
        for callID in Self.buildPhaseCallIDs(record.id) {
            guard let job = try await jobs.job(runID: record.runID, toolCallID: callID) else { throw buildIncomplete() }
            try verifyOwned(job, record: record, tool: "exec.shell")
            guard Self.matchesNativeBuildPayload(job.payloadJSON, callID: callID, recordID: record.id,
                                                 projectRelativePath: binding.projectRelativePath) else { throw ownershipError() }
            guard job.state == .completed else { throw buildIncomplete() }
        }
    }

    private func verifyOwned(_ job: BackgroundJob, record: MCPServiceCreationRecord, tool: String) throws {
        guard job.runID == record.runID, job.conversationID == record.conversationID,
              job.environmentID == record.request.environmentID, job.targetTool == tool,
              job.workspaceRootPath == record.binding?.root.path else { throw ownershipError() }
    }

    private func ownedEndpoint(_ record: MCPServiceCreationRecord) async throws -> URL? {
        guard let id = record.serviceJobID, let job = try await jobs.job(id: id) else { throw ownershipError() }
        try verifyOwned(job, record: record, tool: "exec.localService")
        guard let binding = record.binding,
              Self.matchesNativeServicePayload(job.payloadJSON, projectRelativePath: binding.projectRelativePath,
                                               port: record.request.port) else { throw ownershipError() }
        guard !job.state.isTerminal else {
            throw FloeError.validationFailed(job.lastError ?? FloeL10n.l("skills.mcp.creation.service_stopped"))
        }
        guard let bytes = job.progressJSON,
              let progress = try? JSONDecoder().decode(LocalServiceProgress.self, from: bytes),
              progress.state == "running", let text = progress.previewURL,
              let forward = URL(string: text), forward.scheme == "http",
              forward.host == "127.0.0.1", forward.port == record.request.port,
              forward.user == nil, forward.password == nil, forward.query == nil, forward.fragment == nil else { return nil }
        return forward.appendingPathComponent("mcp")
    }

    private func validateFixedInputs(_ record: MCPServiceCreationRecord) throws {
        guard let binding = record.binding else { throw ownershipError() }
        let guardPaths = WorkspacePathGuard(rootURL: binding.root)
        for (path, expected) in MCPServiceTemplate.immutableProjectDigests {
            let file = try guardPaths.resolve(binding.projectRelativePath + "/" + path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262_144,
                  FloeDigest.sha256Hex(try Data(contentsOf: file)) == expected else {
                throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.template_changed"))
            }
        }
        let launcher = try guardPaths.resolve(binding.projectRelativePath + "/node-http/floe-start.mjs")
        guard try Data(contentsOf: launcher) == Data(Self.launcher.utf8) else {
            throw FloeError.validationFailed(FloeL10n.l("skills.mcp.creation.template_changed"))
        }
    }

    private func serviceCallID(_ record: MCPServiceCreationRecord) -> String { "mcp.service." + record.id.uuidString }
    private func ownershipError() -> FloeError { .validationFailed(FloeL10n.l("skills.mcp.creation.owner_changed")) }
    private func unavailable() -> FloeError { .invalidConfiguration(FloeL10n.l("skills.mcp.creation.unavailable")) }
    private func buildIncomplete() -> FloeError { .validationFailed(FloeL10n.l("skills.mcp.creation.build_failed")) }
    private func smokeError() -> FloeError { .validationFailed(FloeL10n.l("skills.mcp.creation.check_failed")) }

    static let launcher = """
    // Floe-owned guest entry. No public listener/host configuration is changed.
    process.env.HOST = '0.0.0.0';
    process.env.FLOE_MCP_ALLOWED_HOSTS = '127.0.0.1,localhost,[::1]';
    await import('./dist/server.js');
    """

    /// The frozen monolithic contract bytes. Production no longer submits a
    /// single job with this command (it could not finish `npm ci` plus the
    /// double `tsc` run of `npm test` inside the unchanged 600s bound on the
    /// real 9p guest); it is retained only as the immutable reference for the
    /// phase decomposition below and for recognising pre-patch rows.
    static let buildCommand = """
    set -eu
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
    npm ci --ignore-scripts --no-audit --no-fund
    npm run build
    npm test
    """

    /// Bounded owned build phases. Each phase is its own real `exec.shell`
    /// job under the unchanged 600s timeout and 262_144 output bound, run in
    /// the same explicit run, environment and workspace-root lease. Together
    /// they execute the template's frozen contract exactly once:
    /// `commands["install"]` (npm ci), the required `npm run build` (tsc), and
    /// the reviewed fixed HTTP test invocation. The test phase runs the
    /// `node --test tests/http.test.mjs` step of the pinned `npm test` script
    /// directly; omitting only its internal duplicated full TypeScript rebuild
    /// is legitimate because the required build already completed as its own
    /// phase and every phase boundary re-validates the unchanged fixed
    /// package.json/package-lock.json/tests/server.ts/tsconfig hashes through
    /// `validateFixedInputs` before the next phase or the service starts.
    /// No command is dropped, no timeout is raised, no fake completion exists.
    struct MCPServiceBuildPhaseSpec: Equatable, Sendable {
        let name: String
        let callPrefix: String
        let command: String
        func callID(_ recordID: UUID) -> String { callPrefix + recordID.uuidString }
    }

    static let buildPhaseSpecs: [MCPServiceBuildPhaseSpec] = [
        .init(name: "install", callPrefix: "mcp.build.install.", command: installCommand),
        .init(name: "compile", callPrefix: "mcp.build.compile.", command: compileCommand),
        .init(name: "test", callPrefix: "mcp.build.test.", command: testCommand),
    ]

    static func buildPhaseCallIDs(_ recordID: UUID) -> [String] {
        buildPhaseSpecs.map { $0.callID(recordID) }
    }

    /// Exact identity match only: a phase row belongs to this record or to
    /// no one. A call ID from another record can never resolve an index.
    static func phaseIndex(forCallID callID: String, recordID: UUID) -> Int? {
        buildPhaseSpecs.firstIndex { $0.callID(recordID) == callID }
    }

    enum MCPServiceBuildPhaseAction: Equatable, Sendable {
        case attachPhase(Int)
        case submitPhase(Int)
        case allCompleted
    }

    /// Deterministic resume decision over the persisted per-phase job states,
    /// in phase order: a completed phase is skipped and never replayed; an
    /// existing live or honestly terminal row is attached and judged by
    /// `waitForBuild` (failure stays failure); only the first missing phase —
    /// whose predecessors are all completed by loop invariant — is submitted.
    /// Advancement never stops at the first completed phase.
    static func nextBuildPhaseAction(states: [BackgroundJobState?]) -> MCPServiceBuildPhaseAction {
        for (index, state) in states.enumerated() {
            switch state {
            case .completed: continue
            case .some: return .attachPhase(index)
            case nil: return .submitPhase(index)
            }
        }
        return .allCompleted
    }

    /// Pre-patch single monolithic build row. Recognised on resume so an
    /// existing terminal row keeps its exact honest handling; it is never
    /// submitted again.
    static func legacyBuildCallID(_ recordID: UUID) -> String { "mcp.build." + recordID.uuidString }

    /// One present build row reduced to what the resume scan may legally use:
    /// its persisted state plus whether production proved it is this backend's
    /// owned, payload-bound native row. `nil` means the row is absent.
    struct MCPServiceBuildRow: Equatable, Sendable {
        let state: BackgroundJobState
        let bound: Bool
    }

    enum MCPServiceBuildResumeAction: Equatable, Sendable {
        case reject
        case attachPhase(Int)
        case submitPhase(Int)
        case allCompleted
    }

    /// The resume scan's ordering rule, expressed purely so it can be
    /// regressed: every present row must be proven bound before any state is
    /// consulted. A present-but-unbound row rejects the whole scan — its state,
    /// even `.completed`, may not skip its predecessor, may not be attached and
    /// may not be cancelled as ours. Bound rows keep the predecessor semantics
    /// byte-for-byte: completed → skip, live or honestly terminal → attach,
    /// missing → submit, all completed → no replay.
    static func nextBuildPhaseAction(rows: [MCPServiceBuildRow?]) -> MCPServiceBuildResumeAction {
        guard !rows.contains(where: { $0?.bound == false }) else { return .reject }
        switch nextBuildPhaseAction(states: rows.map { $0?.state }) {
        case .attachPhase(let index): return .attachPhase(index)
        case .submitPhase(let index): return .submitPhase(index)
        case .allCompleted: return .allCompleted
        }
    }

    /// A run/conversation/environment/root/target match proves identity, not
    /// that the row ran this backend's fixed build command. The jobs service
    /// reuses any existing row for a (run, tool call ID) pair, provider tool
    /// call IDs are untrusted while this record's UUID is already published to
    /// the model in the project path, and `submissionSource` is not persisted
    /// on `BackgroundJob`, so who submitted a row cannot be read back. The
    /// durable receipt is the persisted payload itself: a row may be attached,
    /// may advance the build, may pass the service gate or may be cancelled by
    /// Stop only when its `payloadJSON` decodes to exactly the fixed native
    /// payload for its call ID. Genuine completed execution of that exact
    /// payload may therefore be reused; an `echo done`, a drifted bound, an
    /// injected environment or an undecodable body can never count as complete.
    static func matchesNativeBuildPayload(_ payloadJSON: Data, callID: String, recordID: UUID,
                                          projectRelativePath: String) -> Bool {
        guard let expected = expectedBuildPayload(callID: callID, recordID: recordID,
                                                  projectRelativePath: projectRelativePath) else { return false }
        return matchesExpectedShellPayload(payloadJSON, expected: expected)
    }

    /// The exact fixed native payload this backend submits for one build call
    /// ID: the legacy monolithic command or one phase command, the record's own
    /// project directory, and the unchanged 600 s / 262 144 bounds. Derived only
    /// from record identity plus frozen command bytes — nothing configurable,
    /// model-supplied or persisted alongside it.
    static func expectedBuildPayload(callID: String, recordID: UUID,
                                     projectRelativePath: String) -> LocalShellTool.Arguments? {
        let command: String
        if callID == legacyBuildCallID(recordID) {
            command = buildCommand
        } else if let index = phaseIndex(forCallID: callID, recordID: recordID) {
            command = buildPhaseSpecs[index].command
        } else {
            return nil
        }
        return LocalShellTool.Arguments(command: command, cwd: projectRelativePath + "/node-http",
                                        timeout: 600, maxOutputBytes: 262_144)
    }

    /// Canonical semantic comparison over the existing typed shell arguments
    /// (no new schema): the command that actually runs must be the exact fixed
    /// bytes, so the tool's own `script` alias is accepted only when it carries
    /// those same bytes and no second, different command may hide in either
    /// field; `timeout`/`timeoutSeconds` must resolve through the tool's own
    /// resolver to the fixed 600 (a real disagreement resolves to nothing and
    /// is refused); cwd and the output bound must match exactly. Every input
    /// this backend's payload omits must stay absent: an injected environment,
    /// stdin or package channel — even an empty one — proves the row was not
    /// written by this submission path, whatever its persisted identity says.
    static func matchesExpectedShellPayload(_ payloadJSON: Data,
                                            expected: LocalShellTool.Arguments) -> Bool {
        guard let actual = try? JSONDecoder().decode(LocalShellTool.Arguments.self, from: payloadJSON) else { return false }
        guard actual.resolvedCommand == expected.command else { return false }
        guard actual.command == nil || actual.command == expected.command else { return false }
        guard actual.script == nil || actual.script == expected.command else { return false }
        guard actual.cwd == expected.cwd else { return false }
        guard (try? actual.resolvedTimeout) == expected.timeout else { return false }
        guard actual.maxOutputBytes == expected.maxOutputBytes else { return false }
        guard actual.env == nil, actual.stdin == nil, actual.packages == nil,
              actual.packagePurpose == nil, actual.packageCapabilities == nil else { return false }
        return true
    }

    /// The fixed native service payload: the pinned launcher entry under this
    /// record's own project directory, the Node runtime, no extra arguments and
    /// the user-selected port. Same receipt rule as the build rows — identity
    /// alone cannot launch or keep an unbound service.
    static func expectedServicePayload(projectRelativePath: String, port: Int) -> LocalServiceTool.Arguments {
        LocalServiceTool.Arguments(runtime: "node",
            entry: projectRelativePath + "/node-http/floe-start.mjs", arguments: [],
            cwd: projectRelativePath + "/node-http", port: port)
    }

    static func matchesNativeServicePayload(_ payloadJSON: Data, projectRelativePath: String, port: Int) -> Bool {
        let expected = expectedServicePayload(projectRelativePath: projectRelativePath, port: port)
        guard let actual = try? JSONDecoder().decode(LocalServiceTool.Arguments.self, from: payloadJSON) else { return false }
        return actual.runtime == expected.runtime && actual.entry == expected.entry
            && actual.arguments == expected.arguments && actual.cwd == expected.cwd && actual.port == expected.port
    }

    static let installCommand = """
    set -eu
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
    npm ci --ignore-scripts --no-audit --no-fund
    """

    static let compileCommand = """
    set -eu
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
    npm run build
    """

    static let testCommand = """
    set -eu
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
    node --test tests/http.test.mjs
    """

    static func generationGoal(_ record: MCPServiceCreationRecord) -> String {
        """
        Create the requested MCP service in the existing project directory \(record.binding?.projectRelativePath ?? "")/node-http.
        The reviewed TypeScript MCP SDK template is already there. Implement the user's requested tools only in src/tools.ts, using registerTaskTools(server) and additive server.registerTool registrations. Preserve its exported function signature. Do not modify any other file: src/server.ts, all tests (including discovery.mjs), package.json, package-lock.json, tsconfig.json, contract.json, README.md, .gitignore and floe-start.mjs must stay byte-identical. The fixed service_status tool and HTTP lifecycle remain App-owned. Do not install packages, build, start a server, change environments or create another task: Floe will perform those steps through the existing owned job/service lifecycle after code generation. Use normal workspace tools and the frozen task permissions; these instructions do not grant additional access. Summarize the implemented tools and any actual limitation in your final answer.

        User request (content, not permission):
        \(record.request.details)
        """
    }
}
#endif
