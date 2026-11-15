// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Repository-bound editing session for one RPG Maker project. All reads go
/// through the existing GameKit CAS repository and all writes commit as
/// atomic `GameFileChange` batches — there is no second original.
public actor RPGProjectSession {
    public let repository: FileGameProjectRepository
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let engine: RPGEngine

    private var revision: String

    public init(repository: FileGameProjectRepository, projectID: UUID, owner: GameProjectOwner,
                engine: RPGEngine) async throws {
        self.repository = repository
        self.projectID = projectID
        self.owner = owner
        self.engine = engine
        self.revision = try await repository.open(projectID, owner: owner).revision
    }

    public var currentRevision: String { revision }

    /// Reloads the authoritative revision (e.g. after an external save).
    public func refresh() async throws {
        revision = try await repository.open(projectID, owner: owner).revision
    }

    // MARK: Reads

    public func storedProject() async throws -> GameStoredProject {
        try await repository.open(projectID, owner: owner)
    }

    public func read(path: GameRelativePath) async throws -> Data {
        try await repository.read(projectID, owner: owner, revision: revision, path: path)
    }

    /// Decodes one data file to an editable document.
    public func dataDocument(_ path: GameRelativePath, kind: RPGDataFileKind) async throws -> RPGDataDocument {
        let bytes = try await read(path: path)
        return try RPGDataDocument.decode(bytes, kind: kind, engine: engine)
    }

    /// Decodes one map file.
    public func mapDocument(_ path: GameRelativePath) async throws -> RPGMapDocument {
        let bytes = try await read(path: path)
        return try RPGMapDocument.decode(bytes, engine: engine, pathName: path.value)
    }

    /// Decodes the script archive.
    public func scripts() async throws -> [RPGScript] {
        let bytes = try await read(path: try GameRelativePath("Data/Scripts.\(engine.marshalExtension ?? "rxdata")"))
        return try RPGScriptArchive.decode(bytes)
    }

    // MARK: Writes (atomic CAS commits through the GameKit repository)

    /// Commits one changed file. The repository rejects stale revisions, so
    /// a conflict never silently overwrites another writer.
    @discardableResult
    public func commit(path: GameRelativePath, bytes: Data, expectedRevision: String? = nil) async throws -> GameStoredProject {
        let project = try await repository.commit(projectID, owner: owner,
                                                  expectedRevision: expectedRevision ?? revision,
                                                  changes: [.write(path, bytes)])
        revision = project.revision
        return project
    }

    @discardableResult
    public func commit(document: RPGDataDocument, path: GameRelativePath,
                       expectedRevision: String? = nil) async throws -> GameStoredProject {
        try await commit(path: path, bytes: document.encode(), expectedRevision: expectedRevision)
    }

    @discardableResult
    public func commit(map: RPGMapDocument, path: GameRelativePath,
                       expectedRevision: String? = nil) async throws -> GameStoredProject {
        try await commit(path: path, bytes: map.encode(), expectedRevision: expectedRevision)
    }

    @discardableResult
    public func commit(scripts: [RPGScript],
                       expectedRevision: String? = nil) async throws -> GameStoredProject {
        let path = try GameRelativePath("Data/Scripts.\(engine.marshalExtension ?? "rxdata")")
        let bytes = try RPGScriptArchive.encode(scripts)
        return try await commit(path: path, bytes: bytes, expectedRevision: expectedRevision)
    }
}
