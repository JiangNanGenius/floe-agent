// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeCore
import FloeTools
import FloePersistence
import FloeExecution
import FloeEnvironments
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyHostAdapter

/// One App-owned composition, retained across editors/assistants. Root creates
/// it after the genuine background-job service and exec.shell registration.
@MainActor final class BiologyHostServices {
    static let names: Set<String> = ["biology.read", "biology.methods", "biology.import", "biology.edit",
        "biology.analyze", "biology.job", "biology.derive", "biology.export", "biology.create",
        "biology.importProject", "biology.describe", "biology.projects", "biology.update", "biology.select",
        "biology.status", "biology.stop", "biology.history", "biology.restore", "biology.deleteProject",
        "biology.deleted", "biology.restoreDeleted", "biology.file.read"]
    let root: URL
    let store: BiologyProjectStore
    let service: BiologyService
    let files: BiologyHostFiles
    let contexts: BiologyExecutionContexts
    let scientificJobs: BiologyScientificJobs
    let access: BiologyHostAccess
    let registry: ToolRunnerRegistry
    let jobs: BackgroundJobService
    let hooks: BiologyLibraryHooks
    var nativeRuntime: (any BiologyNativeRuntime)?
    private let bridge: BiologyToolBridge
    private var installation: Task<Void, Error>?
    private var installed = false
    private var recovered = false
    private struct MetadataObservation {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var metadataObservers: [UUID: MetadataObservation] = [:]
    private struct NativeOwner {
        let projectID: UUID
        let authorization: BiologyNativeAuthorization
        let previousRuns: Set<UUID>
        var monitor: Task<Void, Never>?
    }
    private var nativeOwners: [BiologyExecutionOwner: NativeOwner] = [:]

    init(environment: AppEnvironment, root: URL, jobs: BackgroundJobService,
         registry: ToolRunnerRegistry = .shared, hooks: BiologyLibraryHooks,
         nativeRuntime: (any BiologyNativeRuntime)? = nil) throws {
        self.root = root.standardizedFileURL; self.jobs = jobs; self.registry = registry
        self.hooks = hooks; self.nativeRuntime = nativeRuntime
        let access = try BiologyHostAccess(environment: environment)
        let store = try BiologyProjectStore(root: root.appendingPathComponent("Projects", isDirectory: true),
            ownedFilesRoot: root.appendingPathComponent("OriginalFiles", isDirectory: true))
        let files = BiologyHostFiles(root: root.appendingPathComponent("OriginalFiles", isDirectory: true), access: access)
        let contexts = BiologyExecutionContexts()
        let service = try BiologyService(store: store, fileAccess: files, authorize: { operation in try await access.permit(operation) })
        let scientific = BiologyScientificJobs(jobs: jobs, registry: registry,
            environments: environment.environmentRegistry, contexts: contexts, files: files,
            resolveEnvironment: { [weak environment] context in
                guard let environment else { throw BiologyHostError.unavailable }
                return try await environment.executionSelectedTaskLease(context)
            })
        self.access = access; self.store = store; self.files = files; self.contexts = contexts
        self.service = service; scientificJobs = scientific
        bridge = BiologyToolBridge(service: service, contexts: contexts, scientificJobs: scientific,
            grant: { context in try await access.grant(context) },
            registerCreatedProject: { id, context in
                try context.cancellation.throwIfCancelled()
                try await hooks.attachCreated(id, context)
                guard let taskID = context.conversationID,
                      try await access.authority.canAccess(conversationID: taskID, projectID: id, editing: true) else { throw BiologyHostError.changed }
            })
    }

    /// Install one family once, then decorate those same runners with the
    /// App's usage/lifecycle boundary. Descriptor, validator, routing and wire
    /// names are copied intact; no second registry or executor is introduced.
    func registerTools() async throws {
        if installed { return }
        if let installation { return try await installation.value }
        let task = Task { @MainActor in
            try await self.bridge.register(in: self.registry)
            let originals = try Self.names.map { name -> AnyAgentTool in
                guard let runner = self.registry.runner(named: name) else { throw BiologyHostError.unavailable }
                return runner
            }
            let boundary = BiologyToolCallBoundary(access: self.access, hooks: self.hooks,
                didMutate: { [weak self] ids, name in
                    guard let self else { throw BiologyHostError.unavailable }
                    if name == "biology.deleteProject" {
                        for id in ids { self.stopMetadataObservation(id) }
                    } else { try await self.synchronizeMetadata(ids) }
                })
            for original in originals {
                self.registry.register(boundary.wrap(original))
            }
            self.installed = true
        }
        installation = task
        defer { installation = nil }
        try await task.value
    }
    func descriptors(for context: ToolContext) async throws -> [ToolCatalog.Descriptor] {
        guard installed else { return [] }
        return try await bridge.descriptors(for: context)
    }
    func synchronizeMetadata(_ ids: Set<UUID>) async throws {
        try await access.synchronizeMetadata(ids, store: store)
        for id in ids {
            observeMetadata(id)
            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
        }
    }
    /// This App-owned observer survives the editor. It reflects completed
    /// calculations into Files even when no Biology view is mounted. The
    /// observation inherits no provider call's TaskLocal grant or selection.
    private func observeMetadata(_ id: UUID) {
        guard metadataObservers[id] == nil else { return }
        let generation = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await BiologyHostOperation.$scope.withValue(nil) {
                defer {
                    if self.metadataObservers[id]?.id == generation { self.metadataObservers[id] = nil }
                }
                do {
                    for await _ in try await self.service.changes(id) {
                        guard !Task.isCancelled, self.metadataObservers[id]?.id == generation else { return }
                        do {
                            try await self.access.synchronizeMetadata([id], store: self.store)
                            NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
                        } catch {
                            if (try? await self.store.deletedProjects().contains(where: { $0.projectID == id })) == true { return }
                            // A Library mutation may briefly own the barrier.
                            // Retain the observer for the next actual commit;
                            // do not invent success or touch a deleted original.
                            FloeLogger(category: .persistence).warning("biologyMetadataRefreshDeferred")
                        }
                    }
                } catch {
                    if !Task.isCancelled { FloeLogger(category: .persistence).warning("biologyMetadataObservationUnavailable") }
                }
            }
        }
        metadataObservers[id] = MetadataObservation(id: generation, task: task)
    }
    private func stopMetadataObservation(_ id: UUID) {
        metadataObservers.removeValue(forKey: id)?.task.cancel()
    }

    /// Called only by the Library's trusted creation transaction after it
    /// reserves this same Personal ID. Collisions never replace an original.
    func createReserved(id: UUID, title: String) async throws {
        _ = try await store.createBound(id: id, title: title)
    }
    /// Failed wrapper creation retains a recoverable native original. It must
    /// still be the untouched first revision and have no Personal record.
    @discardableResult func compensateFailedCreation(id: UUID, identity: BiologyMutationIdentity? = nil) async throws -> Bool {
        let records = try await PersonalContentService.shared.library().records(includingDeleted: true)
        guard !records.contains(where: { $0.id == id }) else { return false }
        let project = try await store.load(id)
        guard project.revision == 1, project.assets.isEmpty, project.runs.isEmpty,
              project.createdByOperation == identity else { return false }
        try await store.trash(id, expectedRevision: project.revision)
        return true
    }

    func validatedNative(_ authorization: BiologyNativeAuthorization, projectID: UUID) async throws {
        let context = authorization.context
        try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
        let app = try access.app()
        // Same-task parity for canonical children: every identity, authority,
        // environment and runtimeAuthority binding checked below is issued by
        // the parent runtime for the exact call, not inferred from a child.
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              let taskID = context.conversationID,
              let run = try await app.runStore.run(id: context.runID), run.conversationID == taskID, run.endedAt == nil,
              let task = try await app.conversationStore.conversation(id: taskID), task.purpose == .ordinary,
              try await access.authority.canAccess(conversationID: taskID, projectID: projectID, editing: true),
              context.environmentID == context.environment?.id, context.environment != nil,
              context.runtimeAuthority != nil,
              (await context.validatedRuntimeAuthority(binding: authorization.binding)) == .valid else { throw BiologyHostError.missingRuntime }
        _ = try await access.location(projectID)
    }
    func closeConsoleOwner(projectID: UUID) async {
        await nativeRuntime?.closeConsoleOwner(projectID: projectID)
    }
    func makeTools(projectID: UUID, isCancelled: @escaping @Sendable () -> Bool) async throws -> BiologyToolSession {
        _ = try await access.location(projectID)
        guard let nativeRuntime else { throw BiologyHostError.missingRuntime }
        let owner = try await nativeRuntime.consoleOwner(projectID: projectID)
        let app = try access.app()
        guard let run = try await app.runStore.run(id: owner.hostRunID), run.conversationID == owner.taskID,
              run.endedAt == nil, try await access.authority.canAccess(conversationID: owner.taskID, projectID: projectID, editing: true) else { throw BiologyHostError.changed }
        return BiologyToolSession(service: service, authorizedProjectIDs: [projectID], owner: owner,
            isCancelled: isCancelled, hostInvocation: { [weak self] name, arguments, requestID in
                guard let self, let requestID, !isCancelled() else { throw CancellationError() }
                return try await self.invokeNativeTool(projectID: projectID, owner: owner, name: name,
                    arguments: arguments, requestID: requestID, isCancelled: isCancelled)
            })
    }
    private func invokeNativeTool(projectID: UUID, owner: BiologyExecutionOwner, name: String,
                                  arguments: BiologyJSON, requestID: String, source: BiologyNativeUIIntent.Source = .console,
                                  isCancelled: @Sendable () -> Bool) async throws -> BiologyJSON {
        guard let nativeRuntime, let runner = registry.runner(named: name), Self.names.contains(name), !isCancelled() else { throw BiologyHostError.missingRuntime }
        let bytes = try BiologyCoding.encode(arguments)
        let authorization: BiologyNativeAuthorization
        if source == .console {
            authorization = try await nativeRuntime.authorizeTool(projectID: projectID, toolName: name, arguments: bytes, requestID: requestID)
        } else {
            guard name == "biology.analyze" else { throw BiologyHostError.changed }
            authorization = try await nativeRuntime.authorizeAnalysis(projectID: projectID, arguments: bytes, requestID: requestID, source: source)
        }
        do {
            try await validatedNative(authorization, projectID: projectID)
            guard authorization.context.conversationID == owner.taskID, authorization.context.runID == owner.hostRunID,
                  authorization.context.toolCallID == requestID, !isCancelled() else { throw BiologyHostError.changed }
            let output = try await withTaskCancellationHandler(operation: {
                try await runner.execute(argumentsJSON: bytes, context: authorization.context)
            }, onCancel: {
                // An accepted calculation is service-owned. Cancellation of a
                // view task must not revoke its live worker context. Pending
                // analysis still sees task cancellation at its real boundary.
                if name != "biology.analyze" { authorization.context.cancellation.cancel() }
            })
            try authorization.context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard !isCancelled(), output.exitStatus == 0,
                  let text = output.capturedOutput ?? (output.summary.isEmpty ? nil : output.summary),
                  !output.capturedOutputTruncated else { throw BiologyHostError.changed }
            let result = try JSONDecoder().decode(BiologyJSON.self, from: Data(text.utf8))
            await authorization.finish()
            return result
        } catch { await authorization.finish(); throw error }
    }
    func runNativeAnalysis(projectID: UUID, assetID: UUID, assetRevision: UInt64, method: String,
                           options: BiologyJSON, environmentID: String, source: BiologyNativeUIIntent.Source,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> BiologyRun {
        guard let nativeRuntime, !isCancelled(), source != .console else { throw BiologyHostError.changed }
        let original = try await store.load(projectID)
        guard let asset = original.assets.first(where: { $0.id == assetID && $0.revision == assetRevision }),
              assetRevision <= UInt64(Int.max), !method.isEmpty else { throw BiologyHostError.changed }
        try BiologyMethodCatalog.validate(options, method: method)
        if environmentID != "native.local", let reference = asset.fileReference,
           reference.environmentID != environmentID {
            throw FloeError.validationFailed(IDELanguageRunText.t("请先从更多菜单选择“用于任务计算环境”，再对新数据运行分析。原件会保留。", "Choose Use in task environment in More, then analyze the new dataset. The original is kept."))
        }
        let owner = try await nativeRuntime.consoleOwner(projectID: projectID)
        let arguments: BiologyJSON = .object(["projectID": .string(projectID.uuidString),
            "assetID": .string(assetID.uuidString), "expectedRevision": .number(Double(assetRevision)),
            "method": .string(method), "options": options, "environmentID": .string(environmentID)])
        let value = try await invokeNativeTool(projectID: projectID, owner: owner, name: "biology.analyze",
            arguments: arguments, requestID: UUID().uuidString.lowercased(), source: source, isCancelled: isCancelled)
        let returned = try JSONDecoder().decode(BiologyRun.self, from: BiologyCoding.encode(value))
        guard let saved = try await store.load(projectID).runs.first(where: { $0.id == returned.id }),
              saved.owner == owner, saved.assetID == assetID, saved.assetRevision == assetRevision,
              saved.method == method, saved.options == options, saved.environmentID == environmentID else { throw BiologyHostError.changed }
        return saved
    }
    /// The file picker is native user intent. Register one real opaque handle
    /// in the SAME task environment before executing the existing import tool.
    /// No URL/path is passed to a model or decoded as filesystem authority.
    func importNativeFile(projectID: UUID, url: URL, isCancelled: @escaping @Sendable () -> Bool) async throws -> (projectID: UUID, assetID: UUID?) {
        guard let nativeRuntime, !isCancelled() else { throw CancellationError() }
        _ = try await access.location(projectID)
        if url.lastPathComponent.lowercased().hasSuffix(".biology.json") {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let count = values.fileSize, count > 0, count <= BiologyProjectStore.maximumProjectBytes else { throw BiologyHostError.changed }
        }
        let owner = try await nativeRuntime.consoleOwner(projectID: projectID)
        let reference = try await files.register(trustedSourceURL: url, fileName: url.lastPathComponent,
            context: .init(projectID: projectID, owner: owner))
        try Task.checkCancellation(); guard !isCancelled() else { throw CancellationError() }
        if url.lastPathComponent.lowercased().hasSuffix(".biology.json") {
            guard reference.byteCount <= UInt64(BiologyProjectStore.maximumProjectBytes) else { throw BiologyHostError.changed }
            let value = try await invokeNativeTool(projectID: projectID, owner: owner, name: "biology.importProject",
                arguments: .object(["fileID": .string(reference.id.uuidString), "sourceProjectID": .string(projectID.uuidString)]),
                requestID: UUID().uuidString.lowercased(), isCancelled: isCancelled)
            guard let id = value["id"]?.string.flatMap(UUID.init(uuidString:)), id != projectID else { throw BiologyHostError.changed }
            _ = try await access.location(id)
            return (id, nil)
        }
        let asset = try await importRegisteredFile(projectID: projectID, reference: reference,
            title: url.deletingPathExtension().lastPathComponent, format: url.pathExtension,
            owner: owner, isCancelled: isCancelled)
        return (projectID, asset.id)
    }
    private func importRegisteredFile(projectID: UUID, reference: BiologyFileReference, title: String, format: String,
                                      owner: BiologyExecutionOwner, isCancelled: @Sendable () -> Bool) async throws -> BiologyAsset {
        let value = try await invokeNativeTool(projectID: projectID, owner: owner, name: "biology.import",
            arguments: .object(["projectID": .string(projectID.uuidString), "fileID": .string(reference.id.uuidString),
                "title": .string(title), "format": .string(format)]), requestID: UUID().uuidString.lowercased(), isCancelled: isCancelled)
        guard let id = value["id"]?.string.flatMap(UUID.init(uuidString:)),
              let asset = try await store.load(projectID).assets.first(where: { $0.id == id }) else { throw BiologyHostError.changed }
        return asset
    }
    /// Explicit user action creates a task-bound dataset copy; it never
    /// rewrites an old asset/reference or lowers the adapter's environment check.
    func authorizeNativeFile(projectID: UUID, assetID: UUID, assetRevision: UInt64,
                             isCancelled: @escaping @Sendable () -> Bool) async throws -> BiologyAsset {
        guard let nativeRuntime, !isCancelled() else { throw CancellationError() }
        let original = try await store.load(projectID)
        guard let asset = original.assets.first(where: { $0.id == assetID && $0.revision == assetRevision }),
              let file = asset.fileReference else { throw BiologyHostError.changed }
        let owner = try await nativeRuntime.consoleOwner(projectID: projectID)
        let reference = try await files.reauthorize(file, to: .init(projectID: projectID, owner: owner))
        try Task.checkCancellation(); guard !isCancelled() else { throw CancellationError() }
        guard try await store.load(projectID).assets.contains(where: { $0.id == assetID && $0.revision == assetRevision && $0.fileReference == file }) else { throw BiologyHostError.changed }
        let created = try await importRegisteredFile(projectID: projectID, reference: reference,
            title: asset.title + IDELanguageRunText.t(" · 任务副本", " · task copy"), format: asset.originalFormat, owner: owner, isCancelled: isCancelled)
        struct Source: Encodable { let source: String; let originalAssetID: UUID; let originalRevision: UInt64; let newAssetID: UUID; let sha256: String }
        let bytes = try JSONEncoder().encode(Source(source: "biology.native.fileAuthorization", originalAssetID: assetID,
            originalRevision: assetRevision, newAssetID: created.id, sha256: file.sha256))
        let app = try access.app()
        try await app.runStore.appendEvent(runID: owner.hostRunID, kind: .status, payloadJSON: String(decoding: bytes, as: UTF8.self))
        return created
    }
    func prepareScientificOwner(projectID: UUID, assetID: UUID, assetRevision: UInt64) async throws -> BiologyExecutionOwner {
        guard let nativeRuntime else { throw BiologyHostError.missingRuntime }
        let authorization = try await nativeRuntime.authorizeScientificLaunch(projectID: projectID, assetID: assetID, assetRevision: assetRevision)
        do {
            try await validatedNative(authorization, projectID: projectID)
            let original = try await service.project(projectID)
            guard original.assets.contains(where: { $0.id == assetID && $0.revision == assetRevision }) else { throw BiologyHostError.changed }
            let qualification = try await scientificJobs.probe(context: authorization.context)
            let backend = try await scientificJobs.backend(qualified: qualification)
            try await service.configureBackend(backend)
            let current = try await service.project(projectID)
            guard current.assets.contains(where: { $0.id == assetID && $0.revision == assetRevision }) else { throw BiologyHostError.changed }
            guard let taskID = authorization.context.conversationID else { throw BiologyHostError.changed }
            let owner = BiologyExecutionOwner(taskID: taskID, hostRunID: authorization.context.runID)
            guard nativeOwners[owner] == nil, nativeOwners.count < 64 else { throw BiologyHostError.missingRuntime }
            _ = try await contexts.authorizeNative(authorization.context, binding: authorization.binding)
            nativeOwners[owner] = NativeOwner(projectID: projectID, authorization: authorization,
                previousRuns: Set(current.runs.map(\.id)))
            monitorNativeOwner(owner)
            return owner
        } catch { await authorization.finish(); throw error }
    }
    private func monitorNativeOwner(_ owner: BiologyExecutionOwner) {
        guard let pending = nativeOwners[owner] else { return }
        nativeOwners[owner]?.monitor = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let changes = try await service.changes(pending.projectID)
                for await _ in changes {
                    guard !Task.isCancelled, nativeOwners[owner] != nil else { return }
                    let saved = try await store.load(pending.projectID)
                    guard let run = saved.runs.last(where: { $0.owner == owner && !pending.previousRuns.contains($0.id) }) else { continue }
                    if !run.isActive, run.workerStopUnconfirmed != true {
                        let joined = try await service.wait(pending.projectID, runID: run.id)
                        if !joined.isActive, joined.workerStopUnconfirmed != true { await finishNativeOwner(owner); return }
                    }
                }
            } catch { /* Keep an uncertain worker's ownership until reconciliation. */ }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.abandonUnusedNativeOwners(projectID: pending.projectID)
        }
    }
    private func finishNativeOwner(_ owner: BiologyExecutionOwner) async {
        guard let pending = nativeOwners.removeValue(forKey: owner) else { return }
        pending.monitor?.cancel()
        await pending.authorization.finish()
    }
    func abandonUnusedNativeOwners(projectID: UUID) async {
        guard let saved = try? await store.load(projectID) else { return }
        for (owner, pending) in nativeOwners where pending.projectID == projectID {
            guard !saved.runs.contains(where: { $0.owner == owner && !pending.previousRuns.contains($0.id) }),
                  await contexts.discardNative(owner) else { continue }
            await finishNativeOwner(owner)
        }
    }

    /// Root calls once for this newly constructed process-owned service,
    /// before mounting editors. Old remote workers remain blocked until their
    /// real job records independently confirm that the exact processor exited.
    func recoverAfterProcessRestart() async throws {
        guard !recovered else { return }
        let scope = BiologyHostCallScope(context: nil, projects: [], canCreate: false, lifecycle: true, recoveringNativeWorkers: true)
        try await BiologyHostOperation.$scope.withValue(scope) {
            try await service.recoverInterruptedNativeRuns()
            for project in try await store.list() {
                let orphaned = Set(project.runs.filter { $0.environmentID != "native.local" && $0.isActive }.map(\.id))
                if !orphaned.isEmpty {
                    _ = try await store.update(project.id, expectedRevision: project.revision) { value in
                        for i in value.runs.indices where orphaned.contains(value.runs[i].id) {
                            value.runs[i].workerStopUnconfirmed = true
                            value.runs[i].status = .interrupted
                            value.runs[i].error = "The previous scientific worker requires its owning job service to confirm exit."
                        }
                    }
                }
            }
        }
        recovered = true
    }
    private func actualJobs(_ run: BiologyRun) async throws -> [BackgroundJob] {
        guard let owner = run.owner else { throw BiologyHostError.workerNotStopped }
        let database = try access.app().database
        let prefix = "biology." + run.id.uuidString.lowercased() + ".%"
        let ids: [String] = try await database.reader { db in
            try String.fetchAll(db, sql: "SELECT id FROM background_jobs WHERE run_id=? AND conversation_id=? AND environment_id=? AND target_tool='exec.shell' AND tool_call_id LIKE ? ORDER BY created_at LIMIT 16385",
                arguments: [owner.hostRunID.uuidString, owner.taskID.uuidString, run.environmentID, prefix])
        }
        guard !ids.isEmpty, ids.count <= 16384 else { throw BiologyHostError.workerNotStopped }
        var result: [BackgroundJob] = []
        for raw in ids {
            guard let id = UUID(uuidString: raw), let job = try await jobs.job(id: id),
                  job.runID == owner.hostRunID, job.conversationID == owner.taskID,
                  job.environmentID == run.environmentID,
                  job.toolCallID?.hasPrefix("biology." + run.id.uuidString.lowercased() + ".") == true else { throw BiologyHostError.workerNotStopped }
            result.append(job)
        }
        return result
    }
    private static func confirmsExit(_ job: BackgroundJob) -> Bool {
        if job.state == .completed || job.state == .cancelled { return true }
        guard job.state == .failed, let line = job.resultSummary?.split(separator: "\n").first,
              line.hasPrefix("exit="), let code = line.split(separator: " ").first.flatMap({ Int($0.dropFirst(5)) }) else { return false }
        return code != 0
    }
    /// Must be called within the Personal Library owner's active barrier.
    /// Cancels actual jobs, joins their durable exit, then reconciles the same
    /// project/run/owner/environment; no missing-job/status-label shortcut.
    func prepareForLibraryDeletion(id: UUID) async throws -> UInt64 {
        let scope = BiologyHostCallScope(context: nil, projects: [id], canCreate: false, lifecycle: true, recoveringNativeWorkers: false)
        return try await BiologyHostOperation.$scope.withValue(scope) {
            let project = try await store.load(id)
            for run in project.runs where run.isActive {
                if run.workerStopUnconfirmed == true {
                    let owned = try await actualJobs(run)
                    for job in owned where !job.state.isTerminal { _ = try await jobs.cancel(id: job.id) }
                    for job in owned {
                        while let current = try await jobs.job(id: job.id), !current.state.isTerminal {
                            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(120))
                        }
                        guard let current = try await jobs.job(id: job.id), Self.confirmsExit(current) else { throw BiologyHostError.workerNotStopped }
                    }
                    guard let owner = run.owner else { throw BiologyHostError.workerNotStopped }
                    try await service.reconcileStoppedWorker(id, runID: run.id, owner: owner, environmentID: run.environmentID)
                } else {
                    try await service.cancel(id, runID: run.id)
                    _ = try await service.wait(id, runID: run.id)
                }
            }
            let saved = try await store.load(id)
            guard !saved.runs.contains(where: \.isActive) else { throw BiologyHostError.workerNotStopped }
            for (owner, pending) in nativeOwners where pending.projectID == id {
                _ = await contexts.discardNative(owner)
                await finishNativeOwner(owner)
            }
            await nativeRuntime?.closeConsoleOwner(projectID: id)
            return saved.revision
        }
    }
    func requireNoPermanentDeletionOwners(_ ids: Set<UUID>) throws {
        guard !nativeOwners.values.contains(where: { ids.contains($0.projectID) }) else { throw BiologyHostError.workerNotStopped }
    }
    func trashPrepared(id: UUID, expectedRevision: UInt64) async throws {
        try await store.trash(id, expectedRevision: expectedRevision)
        stopMetadataObservation(id)
    }
    func restoreNative(id: UUID, trashID: String) async throws {
        _ = try await store.restoreDeleted(trashID, projectID: id)
    }
}
#endif
