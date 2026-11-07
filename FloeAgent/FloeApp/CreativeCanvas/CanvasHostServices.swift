// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeCanvasCore
import FloeCanvasUI
import FloeCanvasFlow
import FloeCanvasIntegration
import FloeCanvasTemplates

@MainActor enum CanvasHostServices {
    /// UI and AI resolve the same original and commit domain. This is also
    /// the host boundary for future compatible storage adapters.
    static func repository(record: PersonalContentRecord, directory: URL) throws -> FileCanvasRepository {
        guard record.kind == .canvas else { throw PersonalContentError.invalidProject }
        return try FileCanvasRepository(root: directory.appendingPathComponent("Canvas"))
    }
    static func snapshot(record: PersonalContentRecord, directory: URL) async throws -> CanvasSnapshot {
        try await repository(record: record, directory: directory).load(canvasID: record.id)
    }
    static func edit(record: PersonalContentRecord, directory: URL, batch: CanvasEditBatch,
                     expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
        // Framework body adaptation happens inside the shared edit engine;
        // forwarding the original batch preserves its idempotent request hash.
        return try await repository(record: record, directory: directory).commit(batch, canvasID: record.id,
            expectedRevision: expectedRevision, requestID: requestID)
    }
    static func make(record: PersonalContentRecord, directory: URL, environment: AppEnvironment,
                     navigation: CanvasHostNavigation, repository: (any CanvasFrameworkRepository)? = nil,
                     legacyAssets: [UUID: CanvasAssetReference] = [:]) async throws -> CanvasEditorServices {
        let session = try await CanvasHostSessions.shared.session(record: record, directory: directory, environment: environment,
            repository: repository, legacyAssets: legacyAssets)
        let gateway = CanvasHostEditorGateway(canvasID: record.id, repository: session.repository, navigation: navigation)
        return CanvasEditorServices(documentStore: session.repository, assetStore: session.assets,
            sourceService: CanvasHostSources(), sourceOpening: CanvasHostSourceOpening(navigation: navigation),
            editorGateway: gateway,
            proposalGateway: CanvasHostProvider.configured(environment).map {
                CanvasHostProposalGateway(canvasID: record.id, repository: session.repository, provider: $0)
            },
            openAssistant: { request in try await navigation.openAssistant(request) },
            previewProvider: session.assets, resourceLeasing: session.assets, stepExecutor: session.executor,
            makeFlowRuntime: { session.runtime },
            makeRunConfiguration: { snapshot, pageID, graph in
                try await session.configuration(snapshot: snapshot, pageID: pageID, graph: graph, origin: nil)
            })
    }

    static func templateLibrary() throws -> CanvasTemplateLibrary {
        let root = try PersonalContentLibrary.applicationRoot().deletingLastPathComponent()
            .appendingPathComponent("CanvasTemplates", isDirectory: true)
        return try CanvasTemplateLibrary(root: root)
    }
}

struct CanvasHostBindingResolver: FlowCanvasBindingResolver {
    let canvasID: UUID
    let repository: any CanvasDocumentStore
    func resolve(canvasBinding name: String, context: CanvasRuntimeContext) async throws -> FlowValue {
        guard name.hasPrefix(CanvasTemplateEngine.sourcePrefix),
              let id = UUID(uuidString: String(name.dropFirst(CanvasTemplateEngine.sourcePrefix.count))) else {
            throw PersonalContentError.missingDocument
        }
        let snapshot = try await repository.load(canvasID: canvasID)
        guard context.canvasID == canvasID, context.revision == snapshot.revision,
              let page = snapshot.pages.first(where: { $0.id == context.pageID }),
              let node = page.nodes.first(where: { $0.id == id }) else { throw CanvasHostError.staleRun }
        if node.metadata["floe.template.required"] == "true",
           (CanvasHostSources.text(node.content) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CanvasHostError.unsupportedStep(IDELanguageRunText.t("请先填写画布中的目标卡片。", "Fill in the canvas's goal card first."))
        }
        return .json(.object([
            "nodeID": .string(id.uuidString), "title": .string(node.title ?? ""),
            "text": .string(CanvasHostSources.text(node.content) ?? ""),
            "content": try JSONFidelity.parse(JSONEncoder().encode(node.content))
        ]))
    }
}

struct CanvasHostRunReceipt: Codable, Sendable {
    var canvasID: UUID
    var runID: UUID?
    var phase: String
    var outputs: [String: FlowValue]
    var nodeOutputs: [UUID: [String: FlowValue]]
    var pendingJobs: [CanvasFlowHandoff]
    var savedAt = Date()
}

/// The App owns sessions and work independently of view lifetime. Closing an
/// editor detaches its observer; only an explicit stop or task token cancels.
@MainActor final class CanvasHostSessions {
    static let shared = CanvasHostSessions()
    private struct Key: Hashable { var environment: ObjectIdentifier; var projectID: UUID }
    private var values: [Key: CanvasHostSession] = [:]

    func requireIdleForDeletion(canvasID: UUID, directory: URL) async throws {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        for (key, session) in values where key.projectID == canvasID {
            guard session.root == canonical else { throw PersonalFileActionError.changed }
            try await session.requireIdleForDeletion()
        }
        let last = canonical.appendingPathComponent("last-flow-run.json")
        guard FileManager.default.fileExists(atPath: last.path) else { return }
        let runID = try JSONDecoder().decode(UUID.self, from: Self.deletionReceiptBytes(last, limit: 128))
        let file = canonical.appendingPathComponent("FlowResults/" + runID.uuidString.lowercased() + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw PersonalFileActionError.busy }
        let receipt = try JSONDecoder().decode(CanvasHostRunReceipt.self, from: Self.deletionReceiptBytes(file, limit: 8 * 1_024 * 1_024))
        guard receipt.canvasID == canvasID, receipt.runID == runID, receipt.pendingJobs.isEmpty,
              ["completed", "failed", "cancelled"].contains(receipt.phase) else { throw PersonalFileActionError.busy }
    }
    private static func deletionReceiptBytes(_ file: URL, limit: Int) throws -> Data {
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= limit else { throw PersonalFileActionError.busy }
        return try Data(contentsOf: file)
    }

    func prepareIdentityMove(canvasID: UUID) async {
        for key in Array(values.keys) where key.projectID == canvasID {
            guard let session = values[key] else { continue }
            if let runID = session.lastRunID { await session.runtime.cancel(runID: runID) }
            values.removeValue(forKey: key)
        }
    }

    func session(record: PersonalContentRecord, directory: URL, environment: AppEnvironment,
                 repository: (any CanvasFrameworkRepository)? = nil,
                 legacyAssets: [UUID: CanvasAssetReference] = [:]) async throws -> CanvasHostSession {
        guard record.kind == .canvas else { throw PersonalContentError.invalidProject }
        let key = Key(environment: ObjectIdentifier(environment), projectID: record.id)
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = values[key] {
            guard existing.root == canonical else { throw PersonalContentError.changedDocument }
            return existing
        }
        let created = try CanvasHostSession(record: record, root: canonical, environment: environment,
            repository: repository, legacyAssets: legacyAssets)
        _ = try await created.repository.load(canvasID: record.id)
        values[key] = created
        return created
    }

    func run(record: PersonalContentRecord, directory: URL, environment: AppEnvironment,
             action: String, context: ToolContext?, pageID: UUID? = nil, graphID: UUID? = nil,
             expectedRevision: Int64? = nil, flowRunID: UUID? = nil, attemptID: UUID? = nil,
             jobID: UUID? = nil) async throws -> URL {
        let session = try await session(record: record, directory: directory, environment: environment)
        switch action {
        case "runFlow":
            let snapshot = try await session.repository.load(canvasID: record.id)
            if let expectedRevision, expectedRevision != snapshot.revision { throw CanvasHostError.staleRun }
            let page = snapshot.pages.first(where: { $0.id == (pageID ?? snapshot.selectedPageID) })
            guard let page, let graph = page.flowGraphs.first(where: { graphID == nil || $0.id == graphID }) else {
                throw CanvasHostError.unsupportedStep(IDELanguageRunText.t("请先添加流程步骤。", "Add workflow steps first."))
            }
            let configuration = try await session.configuration(snapshot: snapshot, pageID: page.id, graph: graph, origin: context)
            let compiled = try await session.runtime.compile(graph)
            let runID = configuration.identity.runID
            if await session.runtime.status(runID: runID) == nil {
                _ = try await session.runtime.startRun(compiled: compiled, configuration: configuration)
            }
            while await session.runtime.result(runID: runID) == nil {
                do { try Task.checkCancellation(); try context?.cancellation.throwIfCancelled() }
                catch { await session.runtime.cancel(runID: runID); throw error }
                if context != nil, await session.runtime.status(runID: runID)?.phase == .waitingReconcile { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            return try await session.saveReceipt(runID: runID)
        case "adoptJob":
            guard let context, let flowRunID, let attemptID, let jobID else { throw CanvasHostError.staleRun }
            try await session.executor.adoptJob(runID: flowRunID, attemptID: attemptID, jobID: jobID, context: context)
            await session.runtime.reconcile(runID: flowRunID, attemptID: attemptID)
            return try await session.saveReceipt(runID: flowRunID)
        case "cancelFlow":
            if let runID = session.lastRunID { await session.runtime.cancel(runID: runID) }
            return try await session.saveReceipt(runID: session.lastRunID)
        case "flowStatus": return try await session.saveReceipt(runID: session.lastRunID)
        default: throw PersonalContentError.invalidProject
        }
    }
}

@MainActor final class CanvasHostSession {
    let record: PersonalContentRecord
    let root: URL
    let repository: any CanvasFrameworkRepository
    let assets: CanvasHostAssets
    let executor: CanvasJobsStepExecutor
    let runtime: FlowRuntimeService
    private weak var environment: AppEnvironment?
    private var watchers: [UUID: Task<Void, Never>] = [:]
    private var taskRoots: [UUID: WorkspaceCenter.TaskRootLease] = [:]
    private(set) var lastRunID: UUID?

    init(record: PersonalContentRecord, root: URL, environment: AppEnvironment,
         repository: (any CanvasFrameworkRepository)? = nil,
         legacyAssets: [UUID: CanvasAssetReference] = [:]) throws {
        self.record = record; self.root = root; self.environment = environment
        self.repository = try repository ?? FileCanvasRepository(root: root.appendingPathComponent("Canvas"))
        assets = try CanvasHostAssets(root: root.appendingPathComponent("Assets"), legacyAssets: legacyAssets)
        executor = try CanvasJobsStepExecutor(environment: environment, root: root.appendingPathComponent("FlowAttempts"))
        runtime = FlowRuntimeService(executor: executor,
            journal: try FlowRunJournal(root: root.appendingPathComponent("FlowRuns")),
            bindingResolver: CanvasHostBindingResolver(canvasID: record.id, repository: self.repository))
        executor.didFinish = { [weak runtime] runID, attemptID in
            await runtime?.externalStepDidFinish(runID: runID, attemptID: attemptID)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("last-flow-run.json")),
           let id = try? JSONDecoder().decode(UUID.self, from: data) { lastRunID = id }
    }

    func requireIdleForDeletion() async throws {
        guard watchers.isEmpty else { throw PersonalFileActionError.busy }
        if let lastRunID, let status = await runtime.status(runID: lastRunID) {
            guard [.completed, .failed, .cancelled].contains(status.phase) else { throw PersonalFileActionError.busy }
        }
    }

    func configuration(snapshot: CanvasSnapshot, pageID: UUID, graph: FlowGraph,
                       origin: ToolContext?) async throws -> FlowRunConfiguration {
        guard let environment else { throw PersonalContentError.storageUnavailable }
        let latest = try await repository.load(canvasID: record.id)
        guard latest.id == snapshot.id, latest.revision == snapshot.revision,
              latest.pages.contains(where: { $0.id == pageID && $0.flowGraphs.contains(graph) }) else { throw CanvasHostError.staleRun }
        let runID: UUID
        if let origin, let callID = origin.toolCallID {
            let digest = Array(CanvasHostAssets.hash(Data("canvas.flow/\(origin.runID)/\(callID)/\(record.id)/\(graph.id)".utf8)).utf8)
            let hex = String(decoding: digest.prefix(32), as: UTF8.self)
            let p = Array(hex)
            runID = UUID(uuidString: String(p[0..<8]) + "-" + String(p[8..<12]) + "-" + String(p[12..<16]) + "-" + String(p[16..<20]) + "-" + String(p[20..<32]))!
        } else { runID = UUID() }
        let conversationID: UUID
        let hostRunID: UUID
        let executionID: String
        let workspaceRoot: URL
        let cancellation: CancellationToken
        if let origin {
            guard !origin.temporaryReadOnly, !origin.publicWebOnly, let owner = origin.conversationID,
                  let explicitEnvironment = origin.environmentID, let workspace = origin.workspaceRootURL,
                  let run = try await environment.runStore.run(id: origin.runID), run.conversationID == owner else {
                throw CanvasHostError.executionUnavailable
            }
            conversationID = owner; hostRunID = origin.runID; executionID = explicitEnvironment
            workspaceRoot = workspace; cancellation = origin.cancellation.derived()
        } else {
            try await environment.ensureDurableAutomationReady()
            conversationID = try await environment.studioCoordinator.assistant(for: record)
            let workspaces = SQLiteWorkspaceStore(database: environment.database)
            guard let workspaceID = try await workspaces.workspaceID(conversationID: conversationID),
                  let workspace = try await workspaces.workspace(id: workspaceID) else { throw PersonalContentError.storageUnavailable }
            let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: conversationID)
            workspaceRoot = lease.url; taskRoots[runID] = lease
            do {
                let environmentRecord = try await environment.environmentRegistry.ensureSessionContainer(
                    conversationID: conversationID.uuidString, workspaceID: workspaceID.uuidString,
                    workspaceRootPath: workspaceRoot.path, executionBackend: .linuxVM)
                guard environmentRecord.effectiveExecutionBackend == .linuxVM else { throw CanvasHostError.executionUnavailable }
                executionID = environmentRecord.id
                hostRunID = runID; cancellation = CancellationToken()
                try await environment.runStore.saveRun(.init(id: hostRunID, conversationID: conversationID,
                    state: "executing", goal: IDELanguageRunText.t("画布流程 · ", "Canvas workflow · ") + record.title, startedAt: Date()))
            } catch { taskRoots.removeValue(forKey: runID)?.release(); throw error }
        }
        guard let live = await environment.environmentRegistry.record(id: executionID), live.effectiveExecutionBackend == .linuxVM,
              try await environment.environmentRegistry.ownsExecutionLocation(containerID: executionID, conversationID: conversationID, taskRoot: workspaceRoot) else {
            taskRoots.removeValue(forKey: runID)?.release(); throw CanvasHostError.executionUnavailable
        }
        let identity = FlowRunIdentity(runID: runID, canvasID: record.id, canvasRevision: snapshot.revision,
            flowGraphID: graph.id, flowGraphRevision: graph.revision, environmentID: executionID, owningTaskID: conversationID)
        let provider = CanvasHostProvider.configured(environment)
        struct Configuration: Encodable { var environmentID: String; var modelID: UUID?; var providerID: UUID?; var graph: FlowGraph }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = CanvasHostAssets.hash(try encoder.encode(Configuration(environmentID: executionID,
            modelID: provider?.model.id, providerID: provider?.provider.id, graph: graph)))
        executor.bind(.init(identity: identity, hostRunID: hostRunID, conversationID: conversationID,
            workspaceRoot: workspaceRoot, allowedToolNames: origin?.allowedToolNames,
            allowedWorkspacePaths: origin?.allowedWorkspacePaths ?? [], cancellation: cancellation, provider: provider,
            externalHandoff: origin != nil))
        lastRunID = runID
        try JSONEncoder().encode(runID).write(to: root.appendingPathComponent("last-flow-run.json"), options: .atomic)
        if watchers[runID] == nil { watch(runID: runID, native: origin == nil, hostRunID: hostRunID) }
        return .init(identity: identity, pageID: pageID, sourceDigests: Dictionary(uniqueKeysWithValues:
            snapshot.pages.flatMap(\.nodes).map { ($0.id, CanvasHostAssets.hash((try? encoder.encode($0.content)) ?? Data())) }),
            configurationDigest: digest, maxConcurrency: 2, checkpointEverySteps: 1)
    }

    private func watch(runID: UUID, native: Bool, hostRunID: UUID) {
        watchers[runID] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.watchers[runID] = nil; self.executor.release(runID)
                self.taskRoots.removeValue(forKey: runID)?.release()
            }
            // The configuration is issued before compile/start. A rejected
            // graph records failure and releases its native task-root lease.
            for _ in 0..<50 {
                if await self.runtime.status(runID: runID) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard await self.runtime.status(runID: runID) != nil else {
                if native { try? await self.environment?.runStore.updateRunState(id: hostRunID, state: "failed", endedAt: Date()) }
                return
            }
            for await event in await self.runtime.events(runID: runID) {
                if case .runFinished(_, let phase) = event {
                    _ = try? await self.saveReceipt(runID: runID)
                    if native { try? await self.environment?.runStore.updateRunState(id: hostRunID, state: phase.rawValue, endedAt: Date()) }
                    return
                }
            }
        }
    }
    func saveReceipt(runID: UUID?) async throws -> URL {
        let result: FlowRunResult? = if let runID { await runtime.result(runID: runID) } else { nil }
        let status: FlowRuntimeService.RunStatusSnapshot? = if let runID { await runtime.status(runID: runID) } else { nil }
        let receipt = CanvasHostRunReceipt(canvasID: record.id, runID: runID,
            phase: status?.phase.rawValue ?? (runID == nil ? "notStarted" : "unconfirmed"),
            outputs: result?.runOutputs ?? [:], nodeOutputs: result?.nodeOutputs ?? [:],
            pendingJobs: try runID.map { try executor.pendingHandoffs(runID: $0) } ?? [])
        let directory = root.appendingPathComponent("FlowResults")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent((runID?.uuidString.lowercased() ?? "status") + ".json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }
}
#endif
