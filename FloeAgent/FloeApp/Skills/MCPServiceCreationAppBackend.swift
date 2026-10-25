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

    func submitBuild(_ record: MCPServiceCreationRecord) async throws -> UUID {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        try validateFixedInputs(record)
        if let existing = try await jobs.job(runID: record.runID, toolCallID: buildCallID(record)) {
            try verifyOwned(existing, record: record, tool: "exec.shell")
            return existing.id
        }
        guard let service = environment.backgroundJobService else { throw unavailable() }
        let args = LocalShellTool.Arguments(command: Self.buildCommand,
            cwd: binding.projectRelativePath + "/node-http", timeout: 600, maxOutputBytes: 262_144)
        try checkActive(record.id)
        let job = try await service.submit(runID: record.runID, toolCallID: buildCallID(record),
            targetTool: "exec.shell", payloadJSON: JSONEncoder().encode(args), scope: .local,
            workspaceRootURL: binding.root, allowedWorkspacePaths: [],
            environmentID: record.request.environmentID, submissionSource: .nativeService,
            waitForCompletion: false)
        try verifyOwned(job, record: record, tool: "exec.shell")
        try await settleLateSubmission(job, record: record)
        return job.id
    }

    func waitForBuild(_ record: MCPServiceCreationRecord) async throws {
        guard let id = record.buildJobID else { throw ownershipError() }
        while true {
            try Task.checkCancellation()
            guard let job = try await jobs.job(id: id) else { throw ownershipError() }
            try verifyOwned(job, record: record, tool: "exec.shell")
            if job.state.isTerminal {
                guard job.state == .completed else {
                    throw FloeError.validationFailed(job.lastError ?? FloeL10n.l("skills.mcp.creation.build_failed"))
                }
                try validateFixedInputs(record)
                return
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    func submitService(_ record: MCPServiceCreationRecord) async throws -> UUID {
        try beginWork(record.id)
        defer { endWork(record.id) }
        let binding = try await bindingAndLease(record)
        try validateFixedInputs(record)
        if let existing = try await jobs.job(runID: record.runID, toolCallID: serviceCallID(record)) {
            try verifyOwned(existing, record: record, tool: "exec.localService")
            observeService(existing.id, record: record)
            return existing.id
        }
        guard let service = environment.backgroundJobService else { throw unavailable() }
        let args = LocalServiceTool.Arguments(runtime: "node",
            entry: binding.projectRelativePath + "/node-http/floe-start.mjs", arguments: [],
            cwd: binding.projectRelativePath + "/node-http", port: record.request.port)
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
        for call in [buildCallID(record), serviceCallID(record)] {
            guard let job = try await jobs.job(runID: record.runID, toolCallID: call) else { continue }
            try verifyOwned(job, record: record, tool: call == buildCallID(record) ? "exec.shell" : "exec.localService")
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

    private func verifyOwned(_ job: BackgroundJob, record: MCPServiceCreationRecord, tool: String) throws {
        guard job.runID == record.runID, job.conversationID == record.conversationID,
              job.environmentID == record.request.environmentID, job.targetTool == tool,
              job.workspaceRootPath == record.binding?.root.path else { throw ownershipError() }
    }

    private func ownedEndpoint(_ record: MCPServiceCreationRecord) async throws -> URL? {
        guard let id = record.serviceJobID, let job = try await jobs.job(id: id) else { throw ownershipError() }
        try verifyOwned(job, record: record, tool: "exec.localService")
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

    private func buildCallID(_ record: MCPServiceCreationRecord) -> String { "mcp.build." + record.id.uuidString }
    private func serviceCallID(_ record: MCPServiceCreationRecord) -> String { "mcp.service." + record.id.uuidString }
    private func ownershipError() -> FloeError { .validationFailed(FloeL10n.l("skills.mcp.creation.owner_changed")) }
    private func unavailable() -> FloeError { .invalidConfiguration(FloeL10n.l("skills.mcp.creation.unavailable")) }
    private func smokeError() -> FloeError { .validationFailed(FloeL10n.l("skills.mcp.creation.check_failed")) }

    static let launcher = """
    // Floe-owned guest entry. No public listener/host configuration is changed.
    process.env.HOST = '0.0.0.0';
    process.env.FLOE_MCP_ALLOWED_HOSTS = '127.0.0.1,localhost,[::1]';
    await import('./dist/server.js');
    """

    static let buildCommand = """
    set -eu
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
    npm ci --ignore-scripts --no-audit --no-fund
    npm run build
    npm test
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
