// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameProjectSelectionStoreError: Error, Equatable, Sendable {
    case invalidDirectory
    case overlapWithProjectRoot
    case corruptRecord
    case tooLarge
    case io(String)
}

/// Persistence identity: owner + project + environment + live root. A new
/// revision keeps the same key; discovery revalidates the stored choice.
public struct GameProjectSelectionKey: Hashable, Codable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let rootURL: URL

    public init(context: GameProjectContext) throws {
        self.projectID = context.projectID
        self.owner = context.owner
        self.environmentID = context.environmentID
        self.rootURL = context.rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    var canonical: String {
        let ownerText: String
        switch owner {
        case .space(let recordID):
            ownerText = "space:" + recordID.uuidString.lowercased()
        case .conversation(let conversationID, let workspaceID):
            ownerText = "conversation:"
                + conversationID.uuidString.lowercased() + ":"
                + workspaceID.uuidString.lowercased()
        }
        return [
            projectID.uuidString.lowercased(),
            ownerText,
            environmentID ?? "-",
            rootURL.path
        ].joined(separator: "\n")
    }
}

/// The persisted user/automatic choice. It is bound to the revision it was
/// observed at; `refresh` must revalidate it against fresh discovery.
public struct GameProjectSelectionRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let rootURLPath: String
    public let baseRevision: String
    public let selectedRoot: GameRelativePath?
    public let selectedEngine: GameEngineID
    /// Optional so records written by the earlier schema (schemaVersion 1
    /// without this key) stay readable. Missing means `.evidenceMatched`.
    public let verification: GameProjectSelectionVerification?

    init(context: GameProjectContext, snapshot: GameProjectSelectionSnapshot) throws {
        guard snapshot.projectID == context.projectID,
              snapshot.owner == context.owner,
              snapshot.environmentID == context.environmentID,
              snapshot.rootURL == context.rootURL,
              snapshot.baseRevision == context.savedRevision else {
            throw GameProjectFlowError.invalidContext
        }
        guard let selectedEngine = snapshot.selectedEngine,
              GameProjectSelectionText.validIdentifier(snapshot.baseRevision) else {
            throw GameProjectFlowError.selectionRequired
        }
        self.schemaVersion = 1
        self.projectID = context.projectID
        self.owner = context.owner
        self.environmentID = context.environmentID
        self.rootURLPath = context.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.baseRevision = snapshot.baseRevision
        self.selectedRoot = snapshot.selectedRoot
        self.selectedEngine = selectedEngine
        self.verification = snapshot.selectionVerification ?? .evidenceMatched
    }

    /// Older records have no verification key; they were only ever written
    /// from recognized matches, so the default stays evidence-backed.
    public var effectiveVerification: GameProjectSelectionVerification {
        verification ?? .evidenceMatched
    }
}

public protocol GameProjectSelectionStore: Sendable {
    func load(for key: GameProjectSelectionKey) async throws -> GameProjectSelectionRecord?
    func save(_ record: GameProjectSelectionRecord, for key: GameProjectSelectionKey) async throws
    func remove(for key: GameProjectSelectionKey) async throws
}

/// Test/reference store. It is also useful for hosts that keep selections in
/// their own project service for the lifetime of a process.
public actor InMemoryGameProjectSelectionStore: GameProjectSelectionStore {
    private var records: [GameProjectSelectionKey: GameProjectSelectionRecord] = [:]

    public init() {}

    public func load(for key: GameProjectSelectionKey) async throws -> GameProjectSelectionRecord? {
        records[key]
    }

    public func save(_ record: GameProjectSelectionRecord,
                     for key: GameProjectSelectionKey) async throws {
        records[key] = record
    }

    public func remove(for key: GameProjectSelectionKey) async throws {
        _ = records.removeValue(forKey: key)
    }
}

/// One private JSON file per owner/project/environment/root key. The directory
/// is supplied by the host and must be outside every project live root. Writes
/// are atomic; a corrupt/mismatched record is rejected rather than trusted.
public actor FileGameProjectSelectionStore: GameProjectSelectionStore {
    public let directory: URL
    private let maximumRecordBytes = 65_536

    public init(directory: URL) throws {
        guard directory.isFileURL else {
            throw GameProjectSelectionStoreError.invalidDirectory
        }
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: canonical,
                withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: canonical.path)
        } catch {
            throw GameProjectSelectionStoreError.io(GameProjectSelectionText.bounded(error))
        }
        self.directory = canonical
    }

    public func load(for key: GameProjectSelectionKey) async throws
        -> GameProjectSelectionRecord? {
        try validateDirectory()
        try validateOverlap(key)
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
        } catch {
            throw GameProjectSelectionStoreError.io(GameProjectSelectionText.bounded(error))
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw GameProjectSelectionStoreError.corruptRecord
        }
        guard let size = values.fileSize, size >= 0,
              size <= maximumRecordBytes else {
            throw GameProjectSelectionStoreError.tooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GameProjectSelectionStoreError.io(GameProjectSelectionText.bounded(error))
        }
        guard data.count <= maximumRecordBytes else {
            throw GameProjectSelectionStoreError.tooLarge
        }
        let record: GameProjectSelectionRecord
        do {
            record = try JSONDecoder().decode(GameProjectSelectionRecord.self, from: data)
        } catch {
            throw GameProjectSelectionStoreError.corruptRecord
        }
        guard record.schemaVersion == 1,
              record.projectID == key.projectID,
              record.owner == key.owner,
              record.environmentID == key.environmentID,
              record.rootURLPath == key.rootURL.path,
              GameProjectSelectionText.validIdentifier(record.baseRevision) else {
            throw GameProjectSelectionStoreError.corruptRecord
        }
        return record
    }

    public func save(_ record: GameProjectSelectionRecord,
                     for key: GameProjectSelectionKey) async throws {
        try validateDirectory()
        try validateOverlap(key)
        guard record.schemaVersion == 1,
              record.projectID == key.projectID,
              record.owner == key.owner,
              record.environmentID == key.environmentID,
              record.rootURLPath == key.rootURL.path,
              GameProjectSelectionText.validIdentifier(record.baseRevision) else {
            throw GameProjectSelectionStoreError.corruptRecord
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(record)
        } catch {
            throw GameProjectSelectionStoreError.corruptRecord
        }
        guard data.count <= maximumRecordBytes else {
            throw GameProjectSelectionStoreError.tooLarge
        }
        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw GameProjectSelectionStoreError.io(GameProjectSelectionText.bounded(error))
        }
    }

    public func remove(for key: GameProjectSelectionKey) async throws {
        try validateDirectory()
        try validateOverlap(key)
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw GameProjectSelectionStoreError.io(GameProjectSelectionText.bounded(error))
        }
    }

    private func fileURL(for key: GameProjectSelectionKey) -> URL {
        let name = GameDigest.sha256(Data(key.canonical.utf8))
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }

    private func validateDirectory() throws {
        let values: URLResourceValues
        do {
            values = try directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey
            ])
        } catch {
            throw GameProjectSelectionStoreError.invalidDirectory
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameProjectSelectionStoreError.invalidDirectory
        }
    }

    private func validateOverlap(_ key: GameProjectSelectionKey) throws {
        let store = directory.path
        let project = key.rootURL.path
        guard store != project,
              !store.hasPrefix(project + "/"),
              !project.hasPrefix(store + "/") else {
            throw GameProjectSelectionStoreError.overlapWithProjectRoot
        }
    }
}
