// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameArchiveImportError: Error, Equatable, Sendable {
    case originalArchiveNotPreserved
    case stagingFailed(String)
}

public struct GameArchiveImportResult: Sendable {
    /// The empty owned revision created for this import (create+import flow).
    public let created: GameStoredProject?
    /// The revision after importing the whole archive.
    public let project: GameStoredProject
    public let preview: GameArchiveImportPreview
    public let originalArchiveSHA256: String
    /// Original archive bytes durably preserved in the bounded original store.
    public let preservedOriginal: Bool
    public let importedFiles: Int
    public let importedDirectories: Int
}

/// Archive import into an ALREADY CREATED, independently owned project.
/// The entire archive is unpacked at the project root and imported whole —
/// unknown engines, multiple nested project roots and mixed content all
/// succeed. Preview diagnostics are advisory; root/engine selection and AI
/// organization are later explicit actions on the imported revision. The
/// original archive bytes are preserved in an owned, bounded store before any
/// project write; nothing is ever executed.
public struct GameArchiveProjectImporter: Sendable {
    public let exchange: GameArchiveExchange
    public let previewer: GameArchiveProjectPreviewer
    /// Required: every import preserves the exact original archive bytes.
    public let originalStore: GameArchiveOriginalStore

    public init(exchange: GameArchiveExchange = .init(),
                originalStore: GameArchiveOriginalStore) {
        self.exchange = exchange
        self.previewer = .init(exchange: exchange)
        self.originalStore = originalStore
    }

    /// User sequence: CREATE an owned empty project first, then import the
    /// archive into it. `engine` may be nil; recognition can refine later.
    public func createProjectAndImport(archive: URL,
                                       repository: FileGameProjectRepository,
                                       projectID: UUID,
                                       owner: GameProjectOwner,
                                       title: String,
                                       engine: GameEngineID? = nil,
                                       workspace: URL,
                                       filenameEncoding: String.Encoding? = nil) async throws -> GameArchiveImportResult {
        let created = try await repository.createProject(projectID: projectID, owner: owner,
                                                         title: title, engine: engine)
        do {
            return try await importIntoProject(archive: archive, repository: repository,
                                               projectID: projectID, owner: owner,
                                               expectedRevision: created.revision,
                                               replaceExisting: false, workspace: workspace,
                                               created: created, filenameEncoding: filenameEncoding)
        } catch {
            // A failed import leaves the owned empty project in place; the
            // caller decides to retry, replace or delete it explicitly.
            throw error
        }
    }

    /// Import a ZIP archive into an existing project. The target must be empty
    /// unless the caller explicitly passes replaceExisting — replacement keeps
    /// the old content in immutable revision history (normal commit parent).
    /// This is the product flow used by the iOS qualification host on a
    /// pre-created project; `roundtrip` is only a qualification helper.
    public func importIntoProject(archive: URL,
                                  repository: FileGameProjectRepository,
                                  projectID: UUID,
                                  owner: GameProjectOwner,
                                  expectedRevision: String,
                                  replaceExisting: Bool = false,
                                  workspace: URL,
                                  filenameEncoding: String.Encoding? = nil) async throws -> GameArchiveImportResult {
        try await importIntoProject(archive: archive, repository: repository, projectID: projectID,
                                    owner: owner, expectedRevision: expectedRevision,
                                    replaceExisting: replaceExisting, workspace: workspace,
                                    created: nil, filenameEncoding: filenameEncoding)
    }

    /// Import ANY supported container into an existing project. ZIP is decoded
    /// internally; tar/tar.gz/tar.bz2/tar.xz/7z/rar route through the injected
    /// existing host archive service. The host-produced tree is re-walked and
    /// validated here (no links, traversal or unbounded content) before the
    /// whole tree is imported. Exact capability/errors are surfaced.
    public func importExistingProjectArchive(archive: URL,
                                             repository: FileGameProjectRepository,
                                             projectID: UUID,
                                             owner: GameProjectOwner,
                                             expectedRevision: String,
                                             replaceExisting: Bool = false,
                                             workspace: URL,
                                             filenameEncoding: String.Encoding? = nil,
                                             password: String? = nil,
                                             hostPort: (any GameExternalArchiveHostPort)? = nil) async throws -> GameArchiveImportResult {
        let format = try GameArchiveFormatDetector.detect(at: archive)
        guard format != .zip else {
            return try await importIntoProject(archive: archive, repository: repository,
                                               projectID: projectID, owner: owner,
                                               expectedRevision: expectedRevision,
                                               replaceExisting: replaceExisting, workspace: workspace,
                                               filenameEncoding: filenameEncoding)
        }
        guard workspace.isFileURL else { throw GameArchiveError.invalidTarget }
        // 1. Pre-read the existing target identity and revision.
        let current = try await repository.open(projectID, owner: owner)
        guard current.revision == expectedRevision else {
            throw GameProjectError.conflict(expected: expectedRevision, actual: current.revision)
        }
        guard replaceExisting || (current.files.isEmpty && current.directories.isEmpty) else {
            throw GameProjectError.importDestinationNotEmpty
        }
        // 2. Preserve the bounded original FIRST; the host decodes this copy.
        let preserved = try await preserveOriginal(archive)
        guard let hostPort else {
            throw GameExternalArchiveError.formatUnavailable(format, available: [])
        }
        let available = await hostPort.capabilities()
        guard available.contains(format) else {
            throw GameExternalArchiveError.formatUnavailable(format, available: available.sorted { $0.rawValue < $1.rawValue })
        }
        try GameBuildFileSupport.makeDirectory(workspace)
        let staging = workspace.appendingPathComponent("import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        let extracted = staging.appendingPathComponent("tree")
        do {
            try await hostPort.extract(.init(archiveURL: preserved.url, format: format, destination: extracted,
                                             maximumBytes: exchange.limits.maximumProjectBytes,
                                             maximumEntries: exchange.limits.maximumEntries,
                                             password: password))
        } catch let error as GameExternalArchiveError {
            throw error
        } catch {
            throw GameExternalArchiveError.hostFailed(String(describing: error))
        }
        // Re-walk independently of the host: bounded, symlink/device-refusing.
        let walker: GameDirectoryTreeWalker
        do {
            walker = try GameDirectoryTreeWalker(rootURL: extracted)
        } catch {
            throw GameExternalArchiveError.insecureTree("host output is not a directory")
        }
        let entries: [GameDirectoryTreeWalker.Entry]
        do {
            entries = try walker.walk(maximumEntries: exchange.limits.maximumEntries,
                                      maximumDepth: exchange.limits.maximumDepth)
        } catch GameArchiveError.unsafeSourceEntry(let path) {
            throw GameExternalArchiveError.insecureTree(path)
        } catch GameArchiveError.limitExceeded(let what) {
            throw GameExternalArchiveError.limitExceeded(what)
        }
        var total = 0
        for entry in entries where !entry.directory {
            guard entry.bytes <= exchange.limits.maximumFileBytes else {
                throw GameExternalArchiveError.limitExceeded(entry.path.value)
            }
            total += entry.bytes
            guard total <= exchange.limits.maximumProjectBytes else {
                throw GameExternalArchiveError.limitExceeded("projectBytes")
            }
        }
        // 4. Advisory diagnostics on the host-extracted tree.
        let preview = try previewer.preview(tree: extracted)
        let imported = try await repository.importContents(from: extracted, into: projectID,
                                                           owner: owner, expectedRevision: expectedRevision,
                                                           replaceExisting: replaceExisting)
        return .init(created: nil, project: imported, preview: preview,
                     originalArchiveSHA256: preserved.sha256, preservedOriginal: true,
                     importedFiles: imported.files.count,
                     importedDirectories: imported.directories.count)
    }

    /// Bounded read -> immutable content-addressed copy. Size is checked from
    /// metadata before reading, and the store re-checks before hashing/write.
    private func preserveOriginal(_ archive: URL) async throws -> GameArchiveOriginal {
        guard archive.isFileURL else { throw GameArchiveError.invalidTarget }
        var info = stat()
        guard lstat(archive.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw GameArchiveError.unreadableArchive
        }
        guard info.st_size <= originalStore.maximumOriginalBytes else {
            throw GameArchiveError.limitExceeded("originalArchiveBytes")
        }
        let bytes = try Data(contentsOf: archive)
        return try await originalStore.preserve(bytes)
    }

    private func importIntoProject(archive: URL,
                                   repository: FileGameProjectRepository,
                                   projectID: UUID,
                                   owner: GameProjectOwner,
                                   expectedRevision: String,
                                   replaceExisting: Bool,
                                   workspace: URL,
                                   created: GameStoredProject?,
                                   filenameEncoding: String.Encoding?) async throws -> GameArchiveImportResult {
        guard workspace.isFileURL else { throw GameArchiveError.invalidTarget }
        // 1. Pre-read the existing target identity and revision: an empty,
        //    matching destination fails fast before any expensive work.
        let current = try await repository.open(projectID, owner: owner)
        guard current.revision == expectedRevision else {
            throw GameProjectError.conflict(expected: expectedRevision, actual: current.revision)
        }
        guard replaceExisting || (current.files.isEmpty && current.directories.isEmpty) else {
            throw GameProjectError.importDestinationNotEmpty
        }
        // 2. Preserve the bounded original archive FIRST; extraction then reads
        //    only this immutable copy (no TOCTOU against a mutable external file).
        let preserved = try await preserveOriginal(archive)
        try GameBuildFileSupport.makeDirectory(workspace)
        let staging = workspace.appendingPathComponent("import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        // 3. Full unpack at the project root from the preserved copy: every
        //    entry, whole structure, no engine/root gate.
        let extraction = try exchange.extract(archive: preserved.url, to: staging.appendingPathComponent("tree"),
                                              rootChoice: .asIs, filenameEncoding: filenameEncoding)
        guard preserved.sha256 == extraction.originalArchiveSHA256 else {
            throw GameArchiveImportError.originalArchiveNotPreserved
        }
        // 4. Advisory diagnostics (never a gate) over the preserved bytes.
        let preview = try previewer.preview(archive: preserved.url, filenameEncoding: filenameEncoding)
        // 5. CAS import of the entire tree into the pre-created project identity.
        let imported = try await repository.importContents(from: extraction.rootURL, into: projectID,
                                                           owner: owner, expectedRevision: expectedRevision,
                                                           replaceExisting: replaceExisting)
        return .init(created: created,
                     project: imported,
                     preview: preview,
                     originalArchiveSHA256: extraction.originalArchiveSHA256,
                     preservedOriginal: true,
                     importedFiles: imported.files.count,
                     importedDirectories: imported.directories.count)
    }
}
