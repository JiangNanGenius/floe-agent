// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameRoundtripError: Error, Equatable, Sendable {
    case originalArchiveNotPreserved
    case treeMismatch(String)
}

public struct GameRoundtripFileDelta: Equatable, Sendable {
    public let path: GameRelativePath
    public let reason: String
}

public struct GameRoundtripReport: Sendable {
    public let originalArchiveSHA256: String
    public let extractedRoot: URL
    public let imported: GameStoredProject
    public let edited: GameStoredProject
    public let exportedArchive: GameArchivePublication
    public let reimported: GameStoredProject
    /// Empty deltas prove a byte-identical loop (path/sha256/bytes/executable
    /// and the directory set all match between edited HEAD and re-import).
    public let deltas: [GameRoundtripFileDelta]
    public var roundtripVerified: Bool { deltas.isEmpty }
    public let originalArchivePreserved: Bool
}

/// Closed ZIP -> repository -> edit/save -> source ZIP -> re-import loop using
/// only real bytes: the exchanged archive is extracted, imported into a
/// standalone FileGameProjectRepository, edited and committed by the caller,
/// exported as a folder, re-packed as a source ZIP, extracted again, imported
/// into a scratch project, and compared file-by-file against the edited HEAD.
public struct GameProjectArchiveRoundtrip: Sendable {
    public let exchange: GameArchiveExchange
    public let originalStore: GameArchiveOriginalStore

    public init(exchange: GameArchiveExchange = .init(), originalStore: GameArchiveOriginalStore) {
        self.exchange = exchange
        self.originalStore = originalStore
    }

    public func roundtrip(archive: URL,
                          repository: FileGameProjectRepository,
                          projectID: UUID,
                          owner: GameProjectOwner,
                          title: String,
                          engine: GameEngineID?,
                          workspace: URL,
                          edits: (FileGameProjectRepository, GameStoredProject) async throws -> GameStoredProject) async throws -> GameRoundtripReport {
        guard workspace.isFileURL else { throw GameArchiveError.invalidTarget }
        try GameBuildFileSupport.makeDirectory(workspace)

        // 1. Preserve the bounded original archive first (provenance anchor).
        var info = stat()
        guard lstat(archive.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= originalStore.maximumOriginalBytes else {
            throw GameArchiveError.limitExceeded("originalArchiveBytes")
        }
        let originalArchiveBytes = try Data(contentsOf: archive)
        let preserved = try await originalStore.preserve(originalArchiveBytes)

        // 2. Extract only the immutable preserved copy (no TOCTOU), whole tree.
        let extraction = try exchange.extract(archive: preserved.url,
                                              to: workspace.appendingPathComponent("extracted"),
                                              rootChoice: .asIs)
        guard preserved.sha256 == extraction.originalArchiveSHA256 else {
            throw GameRoundtripError.originalArchiveNotPreserved
        }

        // 3. Create the owned empty project, then import the whole tree.
        let created = try await repository.createProject(projectID: projectID, owner: owner,
                                                         title: title, engine: engine)
        let imported = try await repository.importContents(from: extraction.rootURL, into: projectID,
                                                           owner: owner, expectedRevision: created.revision)
        // 4. Caller edits and commits through the real repository API.
        let edited = try await edits(repository, imported)

        // 5. Export the edited HEAD to a folder and re-pack as a source ZIP.
        let exportedFolder = workspace.appendingPathComponent("exported")
        _ = try await repository.export(projectID, owner: owner, expectedRevision: edited.revision, to: exportedFolder)
        let exported = try exchange.archive(directory: exportedFolder,
                                            to: workspace.appendingPathComponent("edited-source.zip"))

        // 6. Extract the produced ZIP again and import it into a scratch project.
        let reextraction = try exchange.extract(archive: exported.archiveURL,
                                                to: workspace.appendingPathComponent("reextracted"))
        let reimportID = UUID()
        let reimportCreated = try await repository.createProject(projectID: reimportID,
                                                                 owner: .space(recordID: reimportID),
                                                                 title: title + " (reimport)", engine: engine)
        let reimported = try await repository.importContents(from: reextraction.rootURL, into: reimportID,
                                                             owner: .space(recordID: reimportID),
                                                             expectedRevision: reimportCreated.revision)

        // 7. Compare the scratch manifest with the edited HEAD, byte-for-byte.
        let deltas = Self.deltas(expected: edited, actual: reimported)
        return .init(originalArchiveSHA256: extraction.originalArchiveSHA256,
                     extractedRoot: extraction.rootURL,
                     imported: imported,
                     edited: edited,
                     exportedArchive: exported,
                     reimported: reimported,
                     deltas: deltas,
                     originalArchivePreserved: true)
    }

    static func deltas(expected: GameStoredProject, actual: GameStoredProject) -> [GameRoundtripFileDelta] {
        var deltas: [GameRoundtripFileDelta] = []
        let expectedFiles = Dictionary(uniqueKeysWithValues: expected.files.map { ($0.path, $0) })
        let actualFiles = Dictionary(uniqueKeysWithValues: actual.files.map { ($0.path, $0) })
        for path in expectedFiles.keys where actualFiles[path] == nil {
            deltas.append(.init(path: path, reason: "missing after re-import"))
        }
        for path in actualFiles.keys where expectedFiles[path] == nil {
            deltas.append(.init(path: path, reason: "unexpected after re-import"))
        }
        for (path, record) in expectedFiles {
            guard let other = actualFiles[path] else { continue }
            if record.sha256 != other.sha256 || record.bytes != other.bytes {
                deltas.append(.init(path: path, reason: "bytes changed"))
            } else if record.executable != other.executable {
                deltas.append(.init(path: path, reason: "executable intent changed"))
            }
        }
        let missingDirs = Set(expected.directories).symmetricDifference(actual.directories)
        if let first = missingDirs.sorted(by: { $0.value < $1.value }).first {
            deltas.append(.init(path: first, reason: "directory set changed"))
        }
        return deltas.sorted { $0.path.value < $1.path.value }
    }
}
