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

    private let compatibleBaseRevisions: Set<String>
    private let roots: EnvironmentRoots
    private let fileManager = FileManager.default
    private var records: [String: ContainerRecord] = [:]
    private var quota: EnvironmentQuota = .default
    private var loaded = false
    public private(set) var baseRevision: String
    /// Backend applied to records created without an explicit choice. Phase 2
    /// (TinyEMU migration): Linux is the selected main execution path, so the
    /// default is `.linuxVM`; an explicit `.native` selection is always
    /// honored as the documented compatibility backend.
    public let defaultExecutionBackend: EnvironmentExecutionBackend

    public init(
        roots: EnvironmentRoots = .shared,
        baseRevision: String,
        compatibleBaseRevisions: Set<String> = [],
        defaultExecutionBackend: EnvironmentExecutionBackend = .linuxVM
    ) {
        self.roots = roots
        self.baseRevision = baseRevision
        self.compatibleBaseRevisions = compatibleBaseRevisions
        self.defaultExecutionBackend = defaultExecutionBackend
    }

    /// Loads the registry, creating the shared container on first use.
    public func prepare() throws {
        try roots.prepare()
        guard !loaded else { return }
        if fileManager.fileExists(atPath: roots.registryURL.path) {
            let data = try Data(floeContentsOf: roots.registryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == Self.schemaVersion,
                  Set(snapshot.containers.map(\.id)).count == snapshot.containers.count else {
                throw FloeError.validationFailed("Unsupported or duplicate environment records")
            }
            records = Dictionary(uniqueKeysWithValues: snapshot.containers.map { ($0.id, $0) })
            quota = snapshot.quota
            for (id, var record) in records where record.baseRevision != baseRevision {
                if compatibleBaseRevisions.contains(record.baseRevision), record.state != .deleting,
                   record.layerFormat == ContainerRecord.currentLayerFormat {
                    do {
                        try adoptCompatibleBase(&record, registrySnapshot: data)
                    } catch {
                        record.requiresRebuild = true
                        record.rebuildReason = "Runtime metadata migration failed; data retained: \(error.localizedDescription)"
                    }
                } else {
                    record.requiresRebuild = true
                    record.rebuildReason = "Base revision changed; rebuild dependencies before execution"
                }
                records[id] = record
            }
        }
        if records[Self.sharedContainerID] == nil {
            let shared = ContainerRecord(
                id: Self.sharedContainerID,
                kind: .shared,
                name: Self.sharedContainerName,
                baseRevision: baseRevision,
                executionBackend: defaultExecutionBackend
            )
            records[shared.id] = shared
            try materialize(shared)
        }
        try migrateLegacyExecutionBackends()
        try persist()
        loaded = true
    }

    /// Phase 2 (TinyEMU migration): records that never made an explicit
    /// backend choice (`nil`, the legacy native default) move to the Linux
    /// guest backend in place. Only the metadata field changes — environment
    /// IDs, ownership, layers, manifests and packages are untouched. The
    /// pre-migration registry is preserved next to it so the change is
    /// recoverable. Records explicitly set to `.native` keep that documented
    /// compatibility choice.
    private func migrateLegacyExecutionBackends() throws {
        let legacy = records.values.filter { $0.executionBackend == nil }
        guard !legacy.isEmpty else { return }
        let backup = roots.registryURL.appendingPathExtension("pre-linux-backend-migration")
        try validateMigrationPath(backup)
        if !fileManager.fileExists(atPath: backup.path),
           let data = try? Data(floeContentsOf: roots.registryURL) {
            try data.write(to: backup, options: .atomic)
        }
        for record in legacy {
            var migrated = record
            migrated.executionBackend = defaultExecutionBackend
            records[record.id] = migrated
        }
        FloeLogger(category: .general).info(
            "Migrated \(legacy.count) environment(s) to the Linux execution backend (metadata only; data preserved)"
        )
    }

    /// Only caller-proven ABI aliases may use this path. Preserve recovery copies
    /// and unrelated rebuild flags; no dependency or user-data file is removed.
    private func adoptCompatibleBase(_ record: inout ContainerRecord, registrySnapshot: Data) throws {
        guard !record.id.isEmpty, record.id != ".", record.id != "..",
              !record.id.contains("/"), !record.id.contains("\\"), !record.id.contains("\0") else {
            throw FloeError.validationFailed("Invalid environment identifier")
        }
        let root = roots.layerURL(id: record.id, kind: record.kind)
        let manifestURL = root.appendingPathComponent(LayerManifest.fileName)
        let snapshotBackup = roots.registryURL.appendingPathExtension("pre-runtime-version-migration")
        let manifestBackup = manifestURL.appendingPathExtension("pre-runtime-version-migration")
        for url in [manifestURL, manifestBackup, snapshotBackup] { try validateMigrationPath(url) }
        guard var manifest = try LayerManifest.loadChecked(from: root), manifest.id == record.id,
              manifest.layerFormat == record.layerFormat,
              manifest.baseRevision == record.baseRevision || manifest.baseRevision == baseRevision else {
            throw FloeError.validationFailed("Layer manifest does not match its environment")
        }
        if !fileManager.fileExists(atPath: snapshotBackup.path) { try registrySnapshot.write(to: snapshotBackup, options: .atomic) }
        if !fileManager.fileExists(atPath: manifestBackup.path) {
            try Data(contentsOf: manifestURL).write(to: manifestBackup, options: .atomic)
        }
        let previous = record.baseRevision
        manifest.baseRevision = baseRevision
        for index in manifest.packages.indices where manifest.packages[index].requiresBase == previous {
            manifest.packages[index].requiresBase = baseRevision
        }
        try manifest.write(to: root)
        record.baseRevision = baseRevision
        if record.rebuildReason == "Base revision changed; rebuild dependencies before execution" {
            record.requiresRebuild = false; record.rebuildReason = nil
        }
    }

    private func validateMigrationPath(_ url: URL) throws {
        // Resolve the caller-owned root (e.g. /var on iOS), but reject symlinks
        // below it so metadata migration never follows a dependency-owned path.
        let base = roots.rootURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path.hasPrefix(base.path + "/") else {
            throw FloeError.validationFailed("Migration path escapes environment storage")
        }
        var cursor = candidate
        while cursor != base {
            if let attributes = try? fileManager.attributesOfItem(atPath: cursor.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw FloeError.validationFailed("Migration metadata must not be a symbolic link")
            }
            cursor.deleteLastPathComponent()
        }
    }

    public func setBaseRevision(_ revision: String) {
        baseRevision = revision
    }

    public func layerURL(for id: String) -> URL? {
        guard let record = records[id] else { return nil }
        return roots.layerURL(id: record.id, kind: record.kind)
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
    /// `executionBackend` explicitly selects the backend; leaving it nil gives
    /// a **new** record the registry's `defaultExecutionBackend` (Linux since
    /// the Phase 2 migration) and never rewrites an existing record. When a
    /// template seeds the record, the template's own backend wins over the
    /// default.
    @discardableResult
    public func ensureProjectContainer(
        workspaceID: String,
        workspaceRootPath: String,
        templateID: String? = nil,
        executionBackend: EnvironmentExecutionBackend? = nil
    ) throws -> ContainerRecord {
        try prepare()
        if let existing = records.values.first(where: { $0.kind == .project && $0.ownerID == workspaceID }) {
            if let executionBackend, existing.executionBackend != executionBackend {
                var updated = existing
                updated.executionBackend = executionBackend
                try saveRecord(updated)
                return updated
            }
            touch(existing.id)
            return records[existing.id] ?? existing
        }
        let templateBackend = templateID.flatMap { records[$0]?.executionBackend }
        var record = ContainerRecord(
            kind: .project,
            ownerID: workspaceID,
            name: URL(fileURLWithPath: workspaceRootPath).lastPathComponent,
            baseRevision: baseRevision,
            templateID: templateID,
            executionBackend: executionBackend ?? templateBackend ?? defaultExecutionBackend
        )
        do {
            try materialize(record, seedFrom: templateID)
            try saveRecord(record)
        } catch {
            try? fileManager.removeItem(at: roots.layerURL(id: record.id, kind: record.kind))
            throw error
        }
        rememberWorkspaceRoot(workspaceID: workspaceID, path: workspaceRootPath, containerID: record.id)
        return record
    }

    /// Session containers fork from the project container when one exists
    /// (read-only project layers + fresh writable session layer).
    @discardableResult
    public func ensureSessionContainer(
        conversationID: String,
        workspaceID: String?,
        workspaceRootPath: String?,
        inheritFromProject: Bool = true,
        executionBackend: EnvironmentExecutionBackend? = nil
    ) throws -> ContainerRecord {
        try prepare()
        var parent: ContainerRecord?
        if inheritFromProject, let workspaceID {
            if let workspaceRootPath {
                parent = try ensureProjectContainer(workspaceID: workspaceID, workspaceRootPath: workspaceRootPath)
            } else {
                parent = records.values.first { $0.kind == .project && $0.ownerID == workspaceID }
                guard parent != nil else { throw FloeError.notFound("Session project environment") }
            }
        }
        if let parent {
            guard parent.state == .active, !parent.requiresRebuild else {
                throw FloeError.validationFailed("Project environment is stopped, deleting, or requires rebuilding")
            }
        }
        if let existing = records.values.first(where: { $0.kind == .session && $0.ownerID == conversationID && $0.parentID == parent?.id }) {
            touch(existing.id)
            return records[existing.id] ?? existing
        }
        var record = ContainerRecord(
            kind: .session,
            ownerID: conversationID,
            baseRevision: baseRevision,
            parentID: parent?.id,
            templateID: parent?.templateID,
            executionBackend: executionBackend ?? parent?.executionBackend ?? defaultExecutionBackend
        )
        do {
            try materialize(record, seedFrom: parent?.id)
            try saveRecord(record)
        } catch {
            try? fileManager.removeItem(at: roots.layerURL(id: record.id, kind: record.kind))
            throw error
        }
        return record
    }

    /// Commits the writable layer of `sourceID` into a new template.
    @discardableResult
    public func createTemplate(from sourceID: String, name: String) throws -> ContainerRecord {
        try prepare()
        guard let source = records[sourceID] else { throw FloeError.notFound("container \(sourceID)") }
        guard source.state != .deleting, !source.requiresRebuild else {
            throw FloeError.validationFailed("Source environment is deleting or requires rebuild")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, template(named: name) == nil else {
            throw FloeError.validationFailed("Template name is empty or already exists")
        }
        let sourceURL = roots.layerURL(id: source.id, kind: source.kind)
        guard var manifest = try LayerManifest.loadChecked(from: sourceURL) else {
            throw FloeError.validationFailed("Source layer manifest is missing")
        }
        var template = ContainerRecord(kind: .template, name: name, baseRevision: source.baseRevision, executionBackend: source.executionBackend)
        let destinationURL = roots.layerURL(id: template.id, kind: .template)
        do {
            try cloneOrCopyDirectory(from: sourceURL, to: destinationURL)
            manifest.kind = .shared
            manifest.id = template.id
            // Template files are independent APFS clones/copies. They do not
            // own source-layer cache references and remain valid after GC.
            manifest.casRefs = []
            for index in manifest.packages.indices { manifest.packages[index].layer = .shared }
            try manifest.write(to: destinationURL)
            template.packageCount = manifest.packages.count
            let files = fileManager.enumerator(at: destinationURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            while let file = files?.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values.isRegularFile == true { template.bytes += Int64(values.fileSize ?? 0) }
            }
            try saveRecord(template)
            return template
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    @discardableResult
    public func remove(id: String) throws -> ContainerRecord? {
        try prepare()
        guard let record = records[id] else { return nil }
        records.removeValue(forKey: id)
        do { try persist() }
        catch { records[id] = record; throw error }
        return record
    }

    private func saveRecord(_ record: ContainerRecord) throws {
        let previous = records[record.id]
        records[record.id] = record
        do { try persist() }
        catch { records[record.id] = previous; throw error }
    }

    public func transition(id: String, state: ContainerState) throws {
        guard var record = records[id] else { return }
        record.state = state
        try saveRecord(record)
    }

    /// Declares (or changes) an environment's execution backend. Records that
    /// never made a choice were migrated to `.linuxVM` by `prepare()`, so a
    /// stored `.native` here is always an intentional compatibility selection.
    /// Switching to `linuxVM` only starts a guest whose image is qualified,
    /// and the backend reports the recorded reason honestly when one cannot
    /// start.
    public func setExecutionBackend(id: String, backend: EnvironmentExecutionBackend?) throws {
        try prepare()
        guard var record = records[id] else { throw FloeError.notFound("Execution environment \(id)") }
        record.executionBackend = backend
        try saveRecord(record)
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
        try saveRecord(record)
    }

    public func markRebuild(id: String, reason: String) throws {
        guard var record = records[id] else { return }
        record.requiresRebuild = true
        record.rebuildReason = reason
        try saveRecord(record)
    }

    public func clearRebuild(id: String) throws {
        guard var record = records[id] else { return }
        record.requiresRebuild = false
        record.rebuildReason = nil
        record.baseRevision = baseRevision
        try saveRecord(record)
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
            append(roots.sharedURL, kind: .shared)
            if let bundledBaseURL { append(bundledBaseURL, kind: .base) }
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
        guard bytes >= 0, bytes <= quota.totalBytes, totalBytes() <= quota.totalBytes - bytes else { return true }
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
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FloeError.validationFailed("Template destination already exists")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FloeError.notFound("Template source directory")
        }
        #if canImport(Darwin)
        if clonefile(source.path, destination.path, 0) == 0 { return }
        #endif
        try fileManager.copyItem(at: source, to: destination)
    }

    /// Resolve this exact container's project, never an arbitrary first project.
    public func workspaceRoot(for containerID: String) throws -> URL? {
        try prepare()
        guard let record = records[containerID] else { return nil }
        let project = record.kind == .session ? record.parentID.flatMap { records[$0] } : record
        guard let project, project.kind == .project, let owner = project.ownerID else { return nil }
        let mappingURL = roots.rootURL.appendingPathComponent("workspace-containers.json")
        guard fileManager.fileExists(atPath: mappingURL.path) else { return nil }
        let mapping = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: mappingURL))
        guard let entry = mapping[owner], entry["containerID"] == project.id, let path = entry["path"] else { return nil }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard FloeDigest.sha256Hex(Data(root.path.utf8)) == owner else { return nil }
        return root
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
