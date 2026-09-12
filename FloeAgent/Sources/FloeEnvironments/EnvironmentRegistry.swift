import Foundation
import FloeCore

/// Persistent registry of containers. JSON-backed for the first layer format;
/// the schema is versioned so a later SQLite migration can adopt it.
public actor EnvironmentRegistry {
    public struct Snapshot: Codable, Sendable {
        public var schemaVersion: Int
        public var baseRevision: String
        public var quota: EnvironmentQuota
        public var containers: [ContainerRecord]
    }

    public static let schemaVersion = 1
    public static let sharedContainerID = "shared"
    public static let sharedContainerName = "shared"

    private let roots: EnvironmentRoots
    private let fileManager = FileManager.default
    private var records: [String: ContainerRecord] = [:]
    private var quota: EnvironmentQuota = .default
    private var loaded = false
    public private(set) var baseRevision: String

    public init(roots: EnvironmentRoots = .shared, baseRevision: String) {
        self.roots = roots
        self.baseRevision = baseRevision
    }

    /// Loads the registry, creating the shared container on first use.
    public func prepare() throws {
        try roots.prepare()
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(floeContentsOf: roots.registryURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            records = Dictionary(uniqueKeysWithValues: snapshot.containers.map { ($0.id, $0) })
            quota = snapshot.quota
        }
        if records[Self.sharedContainerID] == nil {
            let shared = ContainerRecord(
                id: Self.sharedContainerID,
                kind: .shared,
                name: Self.sharedContainerName,
                baseRevision: baseRevision
            )
            records[shared.id] = shared
            try materialize(shared)
        }
        try persist()
    }

    public func setBaseRevision(_ revision: String) {
        baseRevision = revision
    }

    public func all() -> [ContainerRecord] {
        records.values.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    public func record(id: String) -> ContainerRecord? { records[id] }

    public func template(named name: String) -> ContainerRecord? {
        records.values.first { $0.kind == .template && ($0.name == name || $0.id == name) }
    }

    public func containersOwned(by ownerID: String) -> [ContainerRecord] {
        records.values.filter { $0.ownerID == ownerID }
    }

    /// Finds or creates the project container for a workspace.
    @discardableResult
    public func ensureProjectContainer(
        workspaceID: String,
        workspaceRootPath: String,
        templateID: String? = nil
    ) throws -> ContainerRecord {
        try prepare()
        if let existing = records.values.first(where: { $0.kind == .project && $0.ownerID == workspaceID }) {
            touch(existing.id)
            return records[existing.id] ?? existing
        }
        var record = ContainerRecord(
            kind: .project,
            ownerID: workspaceID,
            name: URL(fileURLWithPath: workspaceRootPath).lastPathComponent,
            baseRevision: baseRevision,
            templateID: templateID
        )
        records[record.id] = record
        try materialize(record, seedFrom: templateID)
        rememberWorkspaceRoot(workspaceID: workspaceID, path: workspaceRootPath, containerID: record.id)
        try persist()
        return record
    }

    /// Session containers fork from the project container when one exists
    /// (read-only project layers + fresh writable session layer).
    @discardableResult
    public func ensureSessionContainer(
        conversationID: String,
        workspaceID: String?,
        workspaceRootPath: String?,
        inheritFromProject: Bool = true
    ) throws -> ContainerRecord {
        try prepare()
        if let existing = records.values.first(where: { $0.kind == .session && $0.ownerID == conversationID }) {
            touch(existing.id)
            return records[existing.id] ?? existing
        }
        var parent: ContainerRecord?
        if inheritFromProject, let workspaceID {
            parent = records.values.first { $0.kind == .project && $0.ownerID == workspaceID }
        }
        var record = ContainerRecord(
            kind: .session,
            ownerID: conversationID,
            baseRevision: baseRevision,
            parentID: parent?.id,
            templateID: parent?.templateID
        )
        records[record.id] = record
        try materialize(record, seedFrom: parent?.id)
        if let workspaceID, let workspaceRootPath {
            rememberWorkspaceRoot(workspaceID: workspaceID, path: workspaceRootPath, containerID: record.id)
        }
        try persist()
        return record
    }

    /// Commits the writable layer of `sourceID` into a new template.
    @discardableResult
    public func createTemplate(from sourceID: String, name: String) throws -> ContainerRecord {
        guard let source = records[sourceID] else {
            throw FloeError.notFound("container \(sourceID)")
        }
        if let existing = template(named: name) { return existing }
        var template = ContainerRecord(
            kind: .template,
            name: name,
            baseRevision: source.baseRevision
        )
        records[template.id] = template
        let sourceURL = roots.layerURL(id: source.id, kind: source.kind)
        let destinationURL = roots.layerURL(id: template.id, kind: .template)
        try cloneOrCopyDirectory(from: sourceURL, to: destinationURL)
        if var manifest = LayerManifest.load(from: sourceURL) {
            manifest.kind = .template
            manifest.id = template.id
            try manifest.write(to: destinationURL)
        }
        template.packageCount = LayerManifest.load(from: destinationURL)?.packages.count ?? 0
        records[template.id] = template
        try persist()
        return template
    }

    @discardableResult
    public func remove(id: String) throws -> ContainerRecord? {
        try prepare()
        guard var record = records[id] else { return nil }
        record.state = .deleting
        records[id] = record
        try persist()
        records.removeValue(forKey: id)
        try persist()
        return record
    }

    public func transition(id: String, state: ContainerState) throws {
        guard var record = records[id] else { return }
        record.state = state
        records[id] = record
        try persist()
    }

    public func touch(_ id: String, at date: Date = Date()) {
        guard var record = records[id] else { return }
        record.lastUsedAt = date
        records[id] = record
    }

    public func updateBytes(id: String, bytes: Int64, packageCount: Int) throws {
        guard var record = records[id] else { return }
        record.bytes = bytes
        record.packageCount = packageCount
        records[id] = record
        try persist()
    }

    public func markRebuild(id: String, reason: String) throws {
        guard var record = records[id] else { return }
        record.requiresRebuild = true
        record.rebuildReason = reason
        records[id] = record
        try persist()
    }

    public func clearRebuild(id: String) throws {
        guard var record = records[id] else { return }
        record.requiresRebuild = false
        record.rebuildReason = nil
        records[id] = record
        try persist()
    }

    // MARK: - Layer stack resolution

    /// Builds the ordered stack for a container: session > project > parent
    /// template > shared > base.
    public func layerStack(for id: String, bundledBaseURL: URL?) -> ResolvedLayerStack {
        var layers: [ResolvedLayerStack.Layer] = []
        func append(_ url: URL, kind: LayerKind) {
            layers.append(.init(kind: kind, url: url, manifest: LayerManifest.load(from: url)))
        }
        guard let record = records[id] else {
            if let bundledBaseURL { append(bundledBaseURL, kind: .base) }
            append(roots.sharedURL, kind: .shared)
            return ResolvedLayerStack(layers: layers)
        }
        append(roots.layerURL(id: record.id, kind: record.kind), kind: record.kind == .session ? .session : .project)
        var cursor = record.parentID
        var guardCount = 0
        while let parentID = cursor, guardCount < 4 {
            guardCount += 1
            guard let parent = records[parentID] else { break }
            if parent.kind == .project {
                append(roots.layerURL(id: parent.id, kind: .project), kind: .project)
            }
            cursor = parent.parentID
        }
        if let templateID = record.templateID, let template = records[templateID] {
            append(roots.layerURL(id: template.id, kind: .template), kind: .shared)
        } else if let parentID = record.parentID,
                  let parent = records[parentID],
                  let templateID = parent.templateID,
                  let template = records[templateID] {
            append(roots.layerURL(id: template.id, kind: .template), kind: .shared)
        }
        append(roots.sharedURL, kind: .shared)
        if let bundledBaseURL { append(bundledBaseURL, kind: .base) }
        return ResolvedLayerStack(layers: layers)
    }

    public func quotaSnapshot() -> EnvironmentQuota { quota }

    public func totalBytes() -> Int64 {
        records.values.reduce(0) { $0 + $1.bytes }
    }

    public func wouldExceedQuota(kind: ContainerKind, adding bytes: Int64) -> Bool {
        switch kind {
        case .session:
            let used = records.values.filter { $0.kind == .session }.reduce(0) { $0 + $1.bytes }
            return used + bytes > quota.sessionBytes
        case .shared, .template:
            let used = records.values
                .filter { $0.kind == .shared || $0.kind == .template }
                .reduce(0) { $0 + $1.bytes }
            return used + bytes > quota.sharedBytes
        case .project:
            return totalBytes() + bytes > quota.totalBytes
        }
    }

    // MARK: - Persistence helpers

    private func persist() throws {
        let snapshot = Snapshot(
            schemaVersion: Self.schemaVersion,
            baseRevision: baseRevision,
            quota: quota,
            containers: Array(records.values)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: roots.registryURL, options: .atomic)
    }

    private func materialize(_ record: ContainerRecord, seedFrom sourceID: String? = nil) throws {
        let url = roots.layerURL(id: record.id, kind: record.kind)
        try roots.materializeContainerLayout(at: url)
        if let sourceID,
           let source = records[sourceID],
           FileManager.default.fileExists(atPath: roots.layerURL(id: source.id, kind: source.kind).path) {
            // Seed the writable layer from the parent's non-package state
            // (profiles, etc.). Package visibility comes from the layer stack.
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var manifest = LayerManifest(
            id: record.id,
            kind: record.kind == .session ? .session : (record.kind == .project ? .project : record.kind == .template ? .shared : .shared),
            baseRevision: record.baseRevision
        )
        manifest.kind = record.kind == .session
            ? .session
            : record.kind == .project ? .project : .shared
        try manifest.write(to: url)
    }

    private func cloneOrCopyDirectory(from source: URL, to destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            return
        }
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, 0) == 0 { return }
        #endif
        try fileManager.copyItem(at: source, to: destination)
    }

    private func rememberWorkspaceRoot(workspaceID: String, path: String, containerID: String) {
        let url = roots.rootURL.appendingPathComponent("workspace-containers.json")
        var mapping: [String: [String: String]] = [:]
        if let data = try? Data(floeContentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            mapping = decoded
        }
        mapping[workspaceID] = ["path": path, "containerID": containerID]
        if let data = try? JSONEncoder().encode(mapping) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
