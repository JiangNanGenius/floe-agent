// FloeWorkbench — Persistent project store.
//
// Projects are Floe-owned versioned JSON documents (stable UUID project ID),
// written atomically with compare-and-swap on revision. Undo/redo history is
// persisted WITH the project (see MediaProjectMemento) so reopening a
// workbench keeps its undo stack. Transaction semantics live in
// `MediaTransactions`; this actor owns load/save, migration and revision CAS.
//
// `commit(_:expectedRevision:)` validates and applies a command sequence via
// the shared engine, then persists the result with compare-and-swap: a
// concurrent manual change on disk rejects the whole commit, which is how
// stale AI proposals lose without mutating anything.

import Foundation
import FloeCore

public actor MediaProjectStore {
    public struct Limits: Sendable {
        public var maximumDocumentBytes: Int
        public var undoDepth: Int
        public init(maximumDocumentBytes: Int = 8 * 1024 * 1024, undoDepth: Int = 100) {
            self.maximumDocumentBytes = maximumDocumentBytes
            self.undoDepth = undoDepth
        }
    }

    nonisolated let directory: URL
    private let limits: Limits
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let legacyMigrator: (@Sendable (URL) async throws -> MediaProject?)?

    public init(directory: URL, limits: Limits = Limits(),
                legacyMigrator: (@Sendable (URL) async throws -> MediaProject?)? = nil) {
        self.directory = directory
        self.limits = limits
        self.legacyMigrator = legacyMigrator
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: Paths

    public static func projectFileName(id: UUID) -> String {
        "media-project-\(id.uuidString.lowercased()).json"
    }

    public nonisolated func projectURL(id: UUID) -> URL {
        directory.appendingPathComponent(Self.projectFileName(id: id))
    }

    public struct ProjectSummary: Sendable, Hashable, Identifiable {
        public var id: UUID
        public var name: String
        public var kind: MediaProjectKind
        public var revision: Int64
        public var updatedAt: Date
        public var ownerKind: String
        public var ownerID: UUID?
        public var environmentID: String?
        public var workspacePath: String?

        public init(id: UUID, name: String, kind: MediaProjectKind, revision: Int64,
                    updatedAt: Date, ownerKind: String, ownerID: UUID?,
                    environmentID: String?, workspacePath: String?) {
            self.id = id
            self.name = name
            self.kind = kind
            self.revision = revision
            self.updatedAt = updatedAt
            self.ownerKind = ownerKind
            self.ownerID = ownerID
            self.environmentID = environmentID
            self.workspacePath = workspacePath
        }
    }

    public func loadProject(at url: URL) async throws -> MediaProject? {
        if FileManager.default.fileExists(atPath: url.path) {
            return try readProject(from: url)
        }
        if let legacyMigrator, let migrated = try await legacyMigrator(url) {
            try await persist(migrated, expectedRevision: nil)
            return migrated
        }
        return nil
    }

    public func loadProject(id: UUID) async throws -> MediaProject? {
        let url = projectURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readProject(from: url)
    }

    public func listProjects() async throws -> [ProjectSummary] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [ProjectSummary] = []
        for entry in entries where entry.lastPathComponent.hasPrefix("media-project-") {
            guard let data = try? Data(contentsOf: entry),
                  let project = try? decoder.decode(MediaProject.self, from: data) else { continue }
            result.append(ProjectSummary(id: project.id, name: project.name, kind: project.kind,
                                         revision: project.revision, updatedAt: project.updatedAt,
                                         ownerKind: project.ownerKind, ownerID: project.ownerID,
                                         environmentID: project.environmentID,
                                         workspacePath: project.taskWorkspacePath))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func readProject(from url: URL) throws -> MediaProject {
        let data = try Data(contentsOf: url)
        guard data.count <= limits.maximumDocumentBytes else {
            throw FloeError.validationFailed("Project document exceeds \(limits.maximumDocumentBytes) bytes")
        }
        var project = try decoder.decode(MediaProject.self, from: data)
        project.recoveryWarnings = MigrationSupport.recoveryWarnings(for: project)
        return project
    }

    // MARK: Persistence

    /// Atomically writes with optional compare-and-swap on revision. All
    /// transaction logic lives in the nonisolated `MediaTransactions` engine
    /// so the UI and model tool share draft-then-commit semantics without
    /// crossing actor boundaries with mutable state.
    @discardableResult
    public func save(_ project: MediaProject, expectedRevision: Int64? = nil) async throws -> URL {
        try await persist(project, expectedRevision: expectedRevision)
    }

    private func persist(_ project: MediaProject, expectedRevision: Int64?) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = projectURL(id: project.id)
        if let expectedRevision, FileManager.default.fileExists(atPath: url.path) {
            let onDisk = try readProject(from: url)
            guard onDisk.revision == expectedRevision else {
                throw FloeError.validationFailed("Project revision conflict: document changed since the transaction started")
            }
        }
        let data = try encoder.encode(project)
        guard data.count <= limits.maximumDocumentBytes else {
            throw FloeError.validationFailed("Project document exceeds \(limits.maximumDocumentBytes) bytes")
        }
        let staging = directory.appendingPathComponent(".floe-project-\(UUID().uuidString).tmp")
        try data.write(to: staging, options: .atomic)
        defer { try? FileManager.default.removeItem(at: staging) }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
        return url
    }
}
