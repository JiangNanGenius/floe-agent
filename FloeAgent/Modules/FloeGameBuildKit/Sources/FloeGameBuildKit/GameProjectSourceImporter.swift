// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct GameProjectSourceImportResult: Sendable {
    public let project: GameStoredProject
    public let preview: GameArchiveImportPreview
    public let originalArchiveSHA256: String?
    public let importedFiles: Int
    public let importedDirectories: Int
}

/// System Files selections use the same complete-project importer as host
/// archives. The caller owns this operation in its project/jobs service. A
/// security-scoped selection remains open until all awaited reads finish;
/// cancelling or dismissing a picker never releases it while IO is in flight.
public struct GameProjectSourceImporter: Sendable {
    public let archives: GameArchiveProjectImporter

    public init(originalStore: GameArchiveOriginalStore,
                exchange: GameArchiveExchange = .init()) {
        archives = .init(exchange: exchange, originalStore: originalStore)
    }

    public func importSource(_ source: URL, into project: GameStoredProject,
                             repository: FileGameProjectRepository, workspace: URL,
                             hostPort: (any GameExternalArchiveHostPort)? = nil) async throws -> GameProjectSourceImportResult {
        try Task.checkCancellation()
        guard source.isFileURL else { throw GameArchiveError.invalidTarget }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw GameArchiveError.unsafeSourceEntry(source.lastPathComponent)
        }
        let current = try await repository.open(project.projectID, owner: project.owner)
        guard current.revision == project.revision else {
            throw GameProjectError.conflict(expected: project.revision, actual: current.revision)
        }
        guard current.files.isEmpty, current.directories.isEmpty else {
            throw GameProjectError.importDestinationNotEmpty
        }
        if values.isDirectory == true {
            let preview = try archives.previewer.preview(tree: source)
            try Task.checkCancellation()
            let imported = try await repository.importContents(from: source, into: project.projectID,
                owner: project.owner, expectedRevision: project.revision)
            return .init(project: imported, preview: preview, originalArchiveSHA256: nil,
                         importedFiles: imported.files.count, importedDirectories: imported.directories.count)
        }
        guard values.isRegularFile == true else {
            throw GameArchiveError.unsafeSourceEntry(source.lastPathComponent)
        }
        let result = try await archives.importExistingProjectArchive(archive: source,
            repository: repository, projectID: project.projectID, owner: project.owner,
            expectedRevision: project.revision, workspace: workspace, hostPort: hostPort)
        return .init(project: result.project, preview: result.preview,
                     originalArchiveSHA256: result.originalArchiveSHA256,
                     importedFiles: result.importedFiles, importedDirectories: result.importedDirectories)
    }
}
