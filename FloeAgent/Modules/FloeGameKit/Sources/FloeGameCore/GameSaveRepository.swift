// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct GameSaveCheckpoint: Sendable {
    public let revision: UInt64
    public let state: Data
}

/// Game progress is separate from source revisions. It is not stored in the Web
/// origin or exported with project files. Explicit host identity scopes every save.
public actor FileGameSaveRepository {
    public let directory: URL
    private let projectID: UUID
    private let owner: GameProjectOwner
    private let name: String
    public let maximumStateBytes: Int
    private struct Record: Codable {
        let version: Int; let projectID: UUID; let owner: GameProjectOwner
        let revision: UInt64; let state: Data
    }
    public init(directory: URL, projectID: UUID, owner: GameProjectOwner,
                maximumStateBytes: Int = 65_536) throws {
        guard directory.isFileURL, (1...4_194_304).contains(maximumStateBytes) else { throw GameProjectError.invalidContext }
        if case .space(let recordID) = owner, recordID != projectID { throw GameProjectError.ownershipMismatch }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.projectID = projectID; self.owner = owner
        self.maximumStateBytes = maximumStateBytes
        name = projectID.uuidString.lowercased() + "-" + GameDigest.sha256(try GameFileStorage.encode(owner))
        try GameFileStorage.directory(self.directory)
    }
    public func load() throws -> GameSaveCheckpoint? {
        try GameFileStorage.locked(root: directory, name: name + ".lock") {
            guard let record = try read() else { return nil }
            return .init(revision: record.revision, state: record.state)
        }
    }
    public func save(_ state: Data, expectedRevision: UInt64) throws -> GameSaveCheckpoint {
        try validate(state)
        return try GameFileStorage.locked(root: directory, name: name + ".lock") {
            let revision = try read()?.revision ?? 0
            guard revision == expectedRevision, revision < UInt64.max else {
                throw GameProjectError.conflict(expected: String(expectedRevision), actual: String(revision))
            }
            let record = Record(version: 1, projectID: projectID, owner: owner, revision: revision + 1, state: state)
            try GameFileStorage.atomicWrite(GameFileStorage.encode(record), to: file)
            guard let stored = try read(), stored.revision == record.revision, stored.state == state else { throw GameProjectError.corruptStorage }
            return .init(revision: stored.revision, state: stored.state)
        }
    }
    private var file: URL { directory.appendingPathComponent(name + ".json") }
    private func validate(_ data: Data) throws {
        guard data.count <= maximumStateBytes else { throw GameProjectError.limitExceeded("gameSave") }
        _ = try JSONSerialization.jsonObject(with: data)
    }
    private func read() throws -> Record? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: GameFileStorage.read(file, maximum: maximumStateBytes * 2 + 8_192))
        guard record.version == 1, record.projectID == projectID, record.owner == owner else { throw GameProjectError.ownershipMismatch }
        try validate(record.state)
        return record
    }
}
