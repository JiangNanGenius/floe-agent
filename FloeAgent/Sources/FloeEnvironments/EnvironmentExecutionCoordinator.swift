import Foundation
import FloeCore
import FloeTools

/// A native service's lease on the task's explicitly selected execution
/// environment. Backend identity comes from the registry, never shell labels.
public struct SelectedTaskEnvironmentLease: Sendable {
    public let context: ToolContext
    public let backend: EnvironmentExecutionBackend
    public let finish: @Sendable () async -> Void

    init(_ lease: ToolEnvironmentLease, backend: EnvironmentExecutionBackend) {
        context = lease.context; self.backend = backend; finish = lease.finish
    }
    /// The tool/worker has already returned before finish is called. Release
    /// the physical generation guard before publishing the tracked lease idle.
    public func holdingFinalizer(_ finalizer: @escaping @Sendable () async -> Void) -> Self {
        Self(ToolEnvironmentLease(context: context) { await finalizer(); await self.finish() }, backend: backend)
    }
}

/// Resolves task-owned layers and tracks executions until cooperative cleanup completes.
public actor EnvironmentExecutionCoordinator {
    private let roots: EnvironmentRoots
    private let registry: EnvironmentRegistry
    private let bundledBaseURL: URL?
    /// Narrow authority for the App-wide shared layer. It is consulted only
    /// when a caller explicitly selects the `shared` container; ordinary
    /// task/session/project execution never uses this path. The App injects a
    /// read-only check of the persisted Linux-cache-cleanup purpose.
    private let sharedCleanupAuthorization: @Sendable (UUID) async -> Bool
    private var active: [String: [UUID: CancellationToken]] = [:]
    private var stopping = Set<String>()
    private var migrationFences = Set<String>()
    private var linuxRuntimeMaintenance: UUID?

    public init(
        roots: EnvironmentRoots,
        registry: EnvironmentRegistry,
        bundledBaseURL: URL? = nil,
        sharedCleanupAuthorization: @escaping @Sendable (UUID) async -> Bool = { _ in false }
    ) {
        self.roots = roots; self.registry = registry; self.bundledBaseURL = bundledBaseURL
        self.sharedCleanupAuthorization = sharedCleanupAuthorization
    }

    public func acquire(_ original: ToolContext) async throws -> ToolEnvironmentLease {
        // Native tools retain App ownership even when the task's commands run elsewhere.
        if let name = original.executionToolName,
           CapabilityExecutionRouter.decision(for: name).backend == .nativeApple {
            return ToolEnvironmentLease(context: original)
        }
        guard original.scope == .local, let workspace = original.workspaceRootURL else {
            return ToolEnvironmentLease(context: original)
        }
        try original.cancellation.throwIfCancelled()
        try await registry.prepare()
        let workspaceID = FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record: ContainerRecord
        var sharedCleanupAuthorized = false
        if let id = original.environmentID {
            guard let selected = await registry.record(id: id) else { throw FloeError.notFound("Execution environment \(id)") }
            if selected.kind == .session {
                // Session dependencies follow the task's saved environment,
                // including after its authorized working folder changes.
                // ToolContext owns current file access; the inherited project
                // layer is not an independent grant to its old working folder.
                guard let conversationID = original.conversationID,
                      selected.ownerID == conversationID.uuidString else {
                    throw FloeError.validationFailed("Environment belongs to another conversation")
                }
            } else if selected.kind == .shared {
                // The shared layer has no workspace owner by design. It is
                // writable for exactly the persisted cleanup purpose; an
                // ordinary task, model text or an arbitrary context cannot
                // enter this branch.
                guard let conversationID = original.conversationID,
                      await sharedCleanupAuthorization(conversationID) else {
                    throw FloeError.validationFailed(
                        "The shared environment is reserved for an explicit Linux cache-cleanup task")
                }
                sharedCleanupAuthorized = true
            } else if selected.ownerID != workspaceID {
                let registered = try await registry.workspaceRoot(for: selected.id)
                guard registered?.path == workspace.resolvingSymlinksInPath().standardizedFileURL.path else {
                    throw FloeError.validationFailed("Environment belongs to another workspace")
                }
            }
            record = selected
        } else {
            let project = try await registry.ensureProjectContainer(workspaceID: workspaceID, workspaceRootPath: workspace.path)
            if let conversationID = original.conversationID {
                record = try await registry.ensureSessionContainer(conversationID: conversationID.uuidString,
                    workspaceID: workspaceID, workspaceRootPath: workspace.path)
            } else { record = project }
        }
        return try await lease(original, record: record,
                               sharedCleanupAuthorized: sharedCleanupAuthorized)
    }

    /// Native scientific services prepare work for the task's frozen target.
    /// Ordinary native tools still bypass command routing through `acquire`.
    /// This explicit path preserves the real tool name and all call authority;
    /// it never creates a default container, starts a guest or executes a tool.
    public func acquireSelectedTaskEnvironment(_ original: ToolContext) async throws -> SelectedTaskEnvironmentLease {
        try original.cancellation.throwIfCancelled(); try Task.checkCancellation()
        guard !original.temporaryReadOnly, !original.publicWebOnly,
              let taskID = original.conversationID, let workspace = original.workspaceRootURL,
              let id = original.environmentID, !id.isEmpty else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "请先为当前任务选择运行环境，再检查科学计算能力。"
                : "Choose an execution environment for this task before checking scientific capabilities.")
        }
        try await registry.prepare()
        guard let record = await registry.record(id: id),
              record.kind.isWritableLayer, record.state == .active,
              !record.requiresRebuild, record.pendingRuntimeResetID == nil,
              record.isCompatible(withLayerFormat: ContainerRecord.currentLayerFormat) else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "所选运行环境不可用。请在任务设置中检查其状态，完成恢复后重试。"
                : "The selected environment is unavailable. Check its status in task settings and finish restoring it before retrying.")
        }
        guard try await registry.ownsExecutionLocation(containerID: id, conversationID: taskID, taskRoot: workspace) else {
            throw FloeError.validationFailed(FloeL10n.isChinese
                ? "所选环境不属于当前任务或工作目录。请重新选择当前任务的运行位置。"
                : "The selected environment belongs to another task or workspace. Choose this task's execution location again.")
        }
        switch original.scope {
        case .local: break
        case .host(let hostID), .hostPath(let hostID, _):
            guard record.effectiveExecutionBackend == .remoteSSH, record.remoteHostID == hostID else {
                throw FloeError.validationFailed(FloeL10n.isChinese
                    ? "已批准的主机与所选运行环境不一致。请检查任务的运行位置后重试。"
                    : "The approved host does not match the selected environment. Check this task's execution location before retrying.")
            }
        }
        // Reuse the actual layer/root, rebuild, inherited-layer and migration
        // fences; its tracked lease is also what stopAndWait joins.
        let acquired = try await lease(original, record: record)
        do {
            let stillOwned = try await registry.ownsExecutionLocation(containerID: id, conversationID: taskID, taskRoot: workspace)
            let current = await registry.record(id: id)
            try original.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard let current, stillOwned, current.state == .active,
                  acquired.context.environmentID == id, acquired.context.environment?.id == id,
                  !current.requiresRebuild, current.pendingRuntimeResetID == nil,
                  current.effectiveExecutionBackend == record.effectiveExecutionBackend,
                  current.runtimeGeneration == record.runtimeGeneration,
                  current.remoteHostID == record.remoteHostID,
                  current.remoteRootPath == record.remoteRootPath,
                  current.parentID == record.parentID, current.layerFormat == record.layerFormat,
                  linuxRuntimeMaintenance == nil || current.effectiveExecutionBackend != .linuxVM,
                  !stopping.contains(id), !migrationFences.contains(id) else {
                throw FloeError.validationFailed(FloeL10n.isChinese
                    ? "运行环境在准备期间发生变化。请检查当前任务的运行位置后重试。"
                    : "The execution environment changed during preparation. Check this task's current location before retrying.")
            }
            return SelectedTaskEnvironmentLease(acquired, backend: current.effectiveExecutionBackend)
        } catch {
            await acquired.finish()
            throw error
        }
    }

    /// Explicit user-selected environment for the dependency manager, independent of the active chat.
    public func acquireManagement(environmentID: String, cancellation: CancellationToken) async throws -> ToolEnvironmentLease {
        try cancellation.throwIfCancelled()
        try await registry.prepare()
        guard let record = await registry.record(id: environmentID) else {
            throw FloeError.notFound("Execution environment \(environmentID)")
        }
        let context = ToolContext(runID: UUID(), workspaceRootURL: try await registry.workspaceRoot(for: environmentID), cancellation: cancellation, environmentID: environmentID)
        return try await lease(context, record: record)
    }

    private func lease(
        _ original: ToolContext,
        record: ContainerRecord,
        sharedCleanupAuthorized: Bool = false
    ) async throws -> ToolEnvironmentLease {
        if record.effectiveExecutionBackend == .macBridge || record.effectiveExecutionBackend == .remoteSSH {
            guard record.kind.isWritableLayer, record.state == .active, !record.requiresRebuild,
                  record.isCompatible(withLayerFormat: ContainerRecord.currentLayerFormat),
                  !stopping.contains(record.id), !migrationFences.contains(record.id) else {
                throw FloeError.validationFailed("The Mac environment is stopped or being removed")
            }
            if let parentID = record.parentID {
                guard let parent = await registry.record(id: parentID), parent.state == .active,
                      parent.effectiveExecutionBackend == record.effectiveExecutionBackend, !parent.requiresRebuild,
                      parent.isCompatible(withLayerFormat: ContainerRecord.currentLayerFormat),
                      !stopping.contains(parentID), !migrationFences.contains(parentID) else {
                    throw FloeError.validationFailed("The parent Mac environment is unavailable")
                }
            }
            var context = original
            context.environmentID = record.id
            let writable = roots.layerURL(id: record.id, kind: record.kind)
            context.environment = ToolEnvironment(id: record.id, writableLayerURL: writable,
                layerURLs: [writable], variables: [
                    "FLOE_ENVIRONMENT_ID": record.id,
                    "FLOE_EXECUTION_BACKEND": record.effectiveExecutionBackend.rawValue
                ])
            let leaseID = UUID()
            active[record.id, default: [:]][leaseID] = original.cancellation
            return ToolEnvironmentLease(context: context) { [weak self] in
                await self?.release(environmentID: record.id, leaseID: leaseID)
            }
        }
        let stack = await registry.layerStack(for: record.id, bundledBaseURL: bundledBaseURL)
        guard let latest = await registry.record(id: record.id), latest.state == .active,
              (linuxRuntimeMaintenance == nil || latest.effectiveExecutionBackend != .linuxVM),
              !latest.requiresRebuild, !stopping.contains(record.id), !migrationFences.contains(record.id) else {
            throw FloeError.validationFailed("Environment is stopped, being deleted, or requires a dependency rebuild")
        }
        for layer in stack.layers where layer.kind != .base {
            guard let manifest = layer.manifest,
                  let owner = await registry.record(id: manifest.id),
                  owner.state == .active, !owner.requiresRebuild else {
                throw FloeError.validationFailed("An inherited environment layer is unavailable or requires rebuilding")
            }
        }
        let writable = roots.layerURL(id: record.id, kind: record.kind)
        guard record.kind.isWritableLayer
                || (record.kind == .shared && sharedCleanupAuthorized) else {
            throw FloeError.validationFailed("Execution needs a writable environment")
        }
        let home = writable.appendingPathComponent("home/floe")
        let temporary = writable.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let binPaths = stack.searchPaths("usr/local/bin") + stack.searchPaths("usr/bin")
        // The writable layer's site-packages is the pip install target. It is
        // included even before the first install creates it: `pythonSearchPaths`
        // filters existing directories, and dropping the path at prepare time
        // made a freshly installed distribution resolve to the bundled copy
        // instead (for example importlib.metadata 0.9.0 over 0.10.0). Python
        // skips nonexistent sys.path entries, so keeping the path is safe.
        let pythonPaths = PythonEnvironmentPath.entries(
            writableLayerURL: writable,
            stackedSitePackages: stack.pythonSearchPaths()
        )
        var context = original
        context.environmentID = record.id
        context.environment = ToolEnvironment(id: record.id, writableLayerURL: writable,
            layerURLs: stack.layers.map(\.url), variables: [
                "FLOE_ENVIRONMENT_ID": record.id,
                "HOME": home.path, "TMPDIR": temporary.path,
                "PATH": (binPaths.map(\.path) + ["/usr/bin", "/bin"]).joined(separator: ":"),
                "PYTHONPATH": pythonPaths.joined(separator: ":"),
                "NODE_PATH": stack.nodeModulePaths().map(\.path).joined(separator: ":")
            ])
        // No await may separate this final admission check and registration.
        // A pending layer lookup must not enter after maintenance cancelled
        // and enumerated the previously active owners.
        guard (linuxRuntimeMaintenance == nil || record.effectiveExecutionBackend != .linuxVM),
              !stopping.contains(record.id), !migrationFences.contains(record.id) else {
            throw FloeError.validationFailed("Linux runtime maintenance is in progress")
        }
        let leaseID = UUID()
        active[record.id, default: [:]][leaseID] = original.cancellation
        return ToolEnvironmentLease(context: context) { [weak self] in
            await self?.release(environmentID: record.id, leaseID: leaseID)
        }
    }

    private func release(environmentID: String, leaseID: UUID) {
        active[environmentID]?.removeValue(forKey: leaseID)
        if active[environmentID]?.isEmpty == true { active.removeValue(forKey: environmentID) }
    }

    public func activeLeaseCount(environmentID: String) -> Int { active[environmentID]?.count ?? 0 }

    /// Atomically prevent new external leases after the last owner exits.
    public func fenceMigrationIfIdle(environmentID: String) async -> Bool {
        if linuxRuntimeMaintenance != nil {
            guard let record = await registry.record(id: environmentID), record.effectiveExecutionBackend != .linuxVM else { return false }
        }
        guard active[environmentID]?.isEmpty != false, !stopping.contains(environmentID), !migrationFences.contains(environmentID) else { return false }
        migrationFences.insert(environmentID)
        return true
    }

    public func releaseMigrationFence(environmentID: String) { migrationFences.remove(environmentID) }

    /// Reuses this coordinator's admission and cancellation ledger. The fence
    /// covers future Linux IDs too; SSH/Mac/native work is unaffected.
    public func beginLinuxRuntimeMaintenance() async throws -> UUID {
        guard linuxRuntimeMaintenance == nil else { throw FloeError.validationFailed("Linux runtime maintenance is already in progress") }
        let token = UUID(); linuxRuntimeMaintenance = token
        do {
            for id in migrationFences {
                guard let record = await registry.record(id: id) else { throw FloeError.validationFailed("An environment owner is unknown") }
                guard record.effectiveExecutionBackend != .linuxVM else { throw FloeError.validationFailed("Finish or cancel the Linux task migration first") }
            }
            for id in active.keys where active[id]?.isEmpty == false {
                guard let record = await registry.record(id: id) else { throw FloeError.validationFailed("An environment owner is unknown") }
                if record.effectiveExecutionBackend == .linuxVM { active[id]?.values.forEach { $0.cancel() } }
            }
            return token
        } catch { linuxRuntimeMaintenance = nil; throw error }
    }

    public func waitForLinuxRuntimeMaintenance(_ token: UUID, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            guard linuxRuntimeMaintenance == token else { throw FloeError.validationFailed("Linux maintenance ownership changed") }
            var live = false
            for id in active.keys where active[id]?.isEmpty == false {
                guard let record = await registry.record(id: id) else { throw FloeError.validationFailed("An environment owner is unknown") }
                if record.effectiveExecutionBackend == .linuxVM { live = true }
            }
            if !live { return }
            guard ContinuousClock.now < deadline else { throw FloeError.validationFailed("Linux still has running work; existing data was retained") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Ending an aborted admission fence never finishes or drops any worker's
    /// lease or its physical SH guard. Those remain owned by their real finish.
    public func endLinuxRuntimeMaintenance(_ token: UUID) {
        if linuxRuntimeMaintenance == token { linuxRuntimeMaintenance = nil }
    }

    /// Cancellation is not proof of termination: retain the environment if any lease remains.
    public func stopAndWait(environmentID: String, timeout: Duration = .seconds(10)) async throws {
        guard !migrationFences.contains(environmentID) else {
            throw FloeError.validationFailed("Finish or cancel the task migration before stopping this environment")
        }
        stopping.insert(environmentID)
        defer { stopping.remove(environmentID) }
        active[environmentID]?.values.forEach { $0.cancel() }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while active[environmentID]?.isEmpty == false {
            guard ContinuousClock.now < deadline else { throw FloeError.validationFailed("Environment still has running work; data was retained") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
