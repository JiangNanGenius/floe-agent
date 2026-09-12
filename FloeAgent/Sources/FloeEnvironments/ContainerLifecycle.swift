import Foundation
import FloeCore

/// Container lifecycle: stop running work, destroy writable layers, prune
/// trash and collect orphans. The app injects hooks so this module stays free
/// of shell/job/media dependencies.
public actor ContainerLifecycle {
    public struct Hooks: Sendable {
        public var stopSessions: @Sendable (String) async throws -> Void
        public var cancelJobs: @Sendable (String) async throws -> Void
        public var terminateWorkers: @Sendable (String) async throws -> Void

        public init(
            stopSessions: @escaping @Sendable (String) async throws -> Void = { _ in throw FloeError.invalidConfiguration("Environment lifecycle hook is not configured") },
            cancelJobs: @escaping @Sendable (String) async throws -> Void = { _ in throw FloeError.invalidConfiguration("Environment lifecycle hook is not configured") },
            terminateWorkers: @escaping @Sendable (String) async throws -> Void = { _ in throw FloeError.invalidConfiguration("Environment lifecycle hook is not configured") }
        ) {
            self.stopSessions = stopSessions
            self.cancelJobs = cancelJobs
            self.terminateWorkers = terminateWorkers
        }
    }

    public struct DestroyReport: Sendable {
        public var containerID: String
        public var kind: ContainerKind
        public var reclaimedBytes: Int64
        public var casReleased: Int
        public var orphaned: Bool
    }

    private let roots: EnvironmentRoots
    private let registry: EnvironmentRegistry
    private let cas: ContainerCAS
    private let hooks: Hooks
    private let fileManager = FileManager.default
    private var deleting = Set<String>()

    public init(
        roots: EnvironmentRoots = .shared,
        registry: EnvironmentRegistry,
        cas: ContainerCAS,
        hooks: Hooks = Hooks()
    ) {
        self.roots = roots
        self.registry = registry
        self.cas = cas
        self.hooks = hooks
    }

    /// Stops work and destroys the writable layer. Templates and the shared
    /// layer are immutable here (remove them explicitly through the registry).
    @discardableResult
    public func destroy(containerID: String, orphaned: Bool = false) async throws -> DestroyReport? {
        guard let record = await registry.record(id: containerID) else { return nil }
        guard record.kind == .session || record.kind == .project else {
            return DestroyReport(
                containerID: containerID,
                kind: record.kind,
                reclaimedBytes: 0,
                casReleased: 0,
                orphaned: orphaned
            )
        }
        guard !deleting.contains(containerID) else { throw FloeError.validationFailed("Environment deletion is already in progress") }
        deleting.insert(containerID)
        defer { deleting.remove(containerID) }
        try await registry.transition(id: containerID, state: .deleting)
        do { try await stopWork(containerID: containerID) }
        catch {
            try? await registry.transition(id: containerID, state: record.state)
            throw error
        }
        let layerURL = roots.layerURL(id: record.id, kind: record.kind)
        let manifest = LayerManifest.load(from: layerURL)
        let bytes = directorySize(at: layerURL)
        let trash = roots.trashURL.appendingPathComponent(record.id + "-" + UUID().uuidString)
        do {
            try fileManager.createDirectory(at: roots.trashURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: layerURL.path) { try fileManager.moveItem(at: layerURL, to: trash) }
            _ = try await registry.remove(id: record.id)
        } catch {
            if fileManager.fileExists(atPath: trash.path), !fileManager.fileExists(atPath: layerURL.path) {
                try? fileManager.moveItem(at: trash, to: layerURL)
            }
            try? await registry.transition(id: containerID, state: .stopped)
            throw error
        }
        let refs = manifest?.casRefs ?? []
        await cas.release(refs)
        var reclaimed: Int64 = 0
        if fileManager.fileExists(atPath: trash.path) {
            do { try fileManager.removeItem(at: trash); reclaimed = bytes }
            catch { FloeLogger(category: .tools).error("containerTrashRetained id=\(record.id)") }
        }
        return DestroyReport(containerID: record.id, kind: record.kind, reclaimedBytes: reclaimed,
                             casReleased: refs.count, orphaned: orphaned)
    }

    /// Destroys every session/project container whose owner no longer exists.
    @discardableResult
    public func collectOrphans(
        liveConversationIDs: Set<String>,
        liveWorkspaceIDs: Set<String>
    ) async throws -> [DestroyReport] {
        let all = await registry.all()
        var reports: [DestroyReport] = []
        for record in all {
            switch record.kind {
            case .session:
                if let owner = record.ownerID, !liveConversationIDs.contains(owner) {
                    if let report = try await destroy(containerID: record.id, orphaned: true) {
                        reports.append(report)
                    }
                }
            case .project:
                if let owner = record.ownerID, !liveWorkspaceIDs.contains(owner) {
                    if let report = try await destroy(containerID: record.id, orphaned: true) {
                        reports.append(report)
                    }
                }
            case .shared, .template:
                continue
            }
        }
        return reports
    }

    /// Purges trash entries older than `grace` and runs CAS collection.
    @discardableResult
    public func garbageCollect(grace: TimeInterval = 7 * 24 * 3600) async -> Int64 {
        var reclaimed: Int64 = 0
        let entries = (try? fileManager.contentsOfDirectory(
            at: roots.trashURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let now = Date()
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) >= grace {
                reclaimed += directorySize(at: entry)
                try? fileManager.removeItem(at: entry)
            }
        }
        reclaimed += await cas.garbageCollect(grace: grace)
        return reclaimed
    }

    /// Recreates the container layout and clears the rebuild flag. Package
    /// replay is the caller's responsibility (it owns layer manifests).
    public func rebuild(containerID: String) async throws {
        guard let record = await registry.record(id: containerID) else {
            throw FloeError.notFound("container \(containerID)")
        }
        let url = roots.layerURL(id: record.id, kind: record.kind)
        try roots.materializeContainerLayout(at: url)
        var manifest = LayerManifest.load(from: url)
            ?? LayerManifest(id: record.id, kind: record.kind == .project ? .project : .session, baseRevision: record.baseRevision)
        manifest.baseRevision = await registry.baseRevision
        try manifest.write(to: url)
        try await registry.clearRebuild(id: containerID)
    }

    public func stop(containerID: String) async throws {
        try await stopWork(containerID: containerID)
        try? await registry.transition(id: containerID, state: .stopped)
    }

    /// Refreshes cached size/package counters for every container.
    public func refreshSizes() async {
        for record in await registry.all() where record.kind == .session || record.kind == .project || record.kind == .template {
            let url = roots.layerURL(id: record.id, kind: record.kind)
            let bytes = directorySize(at: url)
            let packageCount = LayerManifest.load(from: url)?.packages.count ?? 0
            try? await registry.updateBytes(id: record.id, bytes: bytes, packageCount: packageCount)
        }
    }

    private func stopWork(containerID: String) async throws {
        try await hooks.stopSessions(containerID)
        try await hooks.cancelJobs(containerID)
        try await hooks.terminateWorkers(containerID)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
