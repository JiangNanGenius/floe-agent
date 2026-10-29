import Foundation
import FloeCore
import FloeTools

/// Resolves task-owned layers and tracks executions until cooperative cleanup completes.
public actor EnvironmentExecutionCoordinator {
    private let roots: EnvironmentRoots
    private let registry: EnvironmentRegistry
    private let bundledBaseURL: URL?
    private var active: [String: [UUID: CancellationToken]] = [:]
    private var stopping = Set<String>()

    public init(roots: EnvironmentRoots, registry: EnvironmentRegistry, bundledBaseURL: URL? = nil) {
        self.roots = roots; self.registry = registry; self.bundledBaseURL = bundledBaseURL
    }

    public func acquire(_ original: ToolContext) async throws -> ToolEnvironmentLease {
        guard original.scope == .local, let workspace = original.workspaceRootURL else {
            return ToolEnvironmentLease(context: original)
        }
        try original.cancellation.throwIfCancelled()
        try await registry.prepare()
        let workspaceID = FloeDigest.sha256Hex(Data(workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record: ContainerRecord
        if let id = original.environmentID {
            guard let selected = await registry.record(id: id) else { throw FloeError.notFound("Execution environment \(id)") }
            let projectOwner: String?
            if selected.kind == .session, let parent = selected.parentID {
                projectOwner = await registry.record(id: parent)?.ownerID
                if let conversationID = original.conversationID, selected.ownerID != conversationID.uuidString {
                    throw FloeError.validationFailed("Environment belongs to another conversation")
                }
            } else { projectOwner = selected.ownerID }
            guard projectOwner == workspaceID else {
                throw FloeError.validationFailed("Environment belongs to another workspace")
            }
            record = selected
        } else {
            let project = try await registry.ensureProjectContainer(workspaceID: workspaceID, workspaceRootPath: workspace.path)
            if let conversationID = original.conversationID {
                record = try await registry.ensureSessionContainer(conversationID: conversationID.uuidString,
                    workspaceID: workspaceID, workspaceRootPath: workspace.path)
            } else { record = project }
        }
        return try await lease(original, record: record)
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

    private func lease(_ original: ToolContext, record: ContainerRecord) async throws -> ToolEnvironmentLease {
        let stack = await registry.layerStack(for: record.id, bundledBaseURL: bundledBaseURL)
        guard let latest = await registry.record(id: record.id), latest.state == .active,
              !latest.requiresRebuild, !stopping.contains(record.id) else {
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
        guard record.kind.isWritableLayer else { throw FloeError.validationFailed("Execution needs a writable environment") }
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

    /// Cancellation is not proof of termination: retain the environment if any lease remains.
    public func stopAndWait(environmentID: String, timeout: Duration = .seconds(10)) async throws {
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
