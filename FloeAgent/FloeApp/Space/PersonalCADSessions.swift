// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD

/// UI and task tools use the same live native document and undo ownership.
@MainActor enum PersonalCADSessions {
    private static var documents: [UUID: FloeCADDocument] = [:]
    private static var opening: Set<UUID> = []
    static func open(id: UUID, directory: URL) async throws -> FloeCADDocument {
        try PersonalLibraryFileActions.requireAvailable(id)
        let url = directory.appendingPathComponent("Document.floecad")
        if let existing = documents[id], !existing.isClosed {
            guard existing.url == url else { throw PersonalContentError.changedDocument }
            return existing
        }
        guard opening.insert(id).inserted else { throw PersonalFileActionError.busy }
        defer { opening.remove(id) }
        let value = try await FloeCADDocument.open(at: url)
        do { try PersonalLibraryFileActions.requireAvailable(id) }
        catch { value.close(); throw error }
        documents[id] = value; return value
    }
    static func prepareForLibraryMove(id: UUID, directory: URL) throws {
        guard !opening.contains(id) else { throw PersonalFileActionError.busy }
        guard let document = documents[id] else { return }
        guard document.url.standardizedFileURL.resolvingSymlinksInPath()
                == directory.appendingPathComponent("Document.floecad").standardizedFileURL.resolvingSymlinksInPath() else {
            throw PersonalContentError.changedDocument
        }
        // FloeCAD.close already cancels owned services and revokes the store
        // after draining its commit fence. Do not close another live editor.
        guard document.isClosed else { throw PersonalFileActionError.closeFirst }
        documents.removeValue(forKey: id)
    }
}
#endif
