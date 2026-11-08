// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeElectronicsCore

extension PersonalContentService {
    /// Only the explicitly selected native file is read. Native IDs and source
    /// references never grant access to files outside the imported original.
    func importElectronics(_ source: URL, folders: [String]) async throws -> PersonalContentRecord {
        let imported = try await personalPreviewOffMain {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?, result: Result<(Data, EDAProject), Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                result = Result {
                    let attributes = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw PersonalContentError.invalidProject }
                    let parent = readable.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                    let file = try PersonalPreviewFile(root: parent, url: parent.appendingPathComponent(readable.lastPathComponent), maximumBytes: 64 * 1_024 * 1_024)
                    let bytes = try file.data(), project = try EDAExchange.decodeProject(bytes)
                    return (bytes, project)
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw PersonalContentError.invalidProject }
            return try result.get()
        }
        let library = try library(), title = imported.1.title
        let record = try await library.create(kind: .electronics, title: title, in: folders) { directory, id in
            var project = imported.1
            project.id = id; project.revision = 0; project.createdAt = Date(); project.modifiedAt = project.createdAt
            for board in project.boards.indices { for zone in project.boards[board].zones.indices {
                project.boards[board].zones[zone].filledPolygons = []; project.boards[board].zones[zone].fillRevision = nil
            } }
            let root = directory.appendingPathComponent("Electronics")
            _ = try await EDAProjectStore.create(root: root, project: project)
            let originals = root.appendingPathComponent("Imported", isDirectory: true)
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
            try imported.0.write(to: originals.appendingPathComponent("Original.floeeda"), options: .withoutOverwriting)
            struct Receipt: Encodable { let sourceProjectID: UUID; let importedProjectID: UUID; let sourceRevision: UInt64; let sourceSHA256: String }
            let receipt = Receipt(sourceProjectID: imported.1.id, importedProjectID: id, sourceRevision: imported.1.revision, sourceSHA256: previewHash(imported.0))
            try JSONEncoder().encode(receipt).write(to: originals.appendingPathComponent("Import.json"), options: .withoutOverwriting)
        }
        try await verify(record)
        return record
    }
}
#endif
