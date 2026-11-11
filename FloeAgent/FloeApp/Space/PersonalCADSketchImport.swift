// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD

struct PersonalCADSketchSource: Sendable {
    let record: PersonalContentRecord
    let directory: URL
    let native: CADLibrarySketchSource
}

enum PersonalCADSketchImportIssue: Error, LocalizedError {
    case saveSourceFirst
    var errorDescription: String? {
        IDELanguageRunText.t("请先保存二维项目，再导入草图。", "Save the 2D project before importing its sketch.")
    }
}

/// The same active library/usage authority as Files. A selection never opens,
/// closes, saves or changes another editor's live source session.
@MainActor enum PersonalCADSketchImport {
    static func projects(service: PersonalContentService = .shared) async throws -> [PersonalContentRecord] {
        let values = try await service.library().records()
        try Task.checkCancellation()
        return values.filter { $0.kind == .cad2D && !$0.needsRecovery && $0.deletedAt == nil }
    }

    static func load(projectID: UUID, service: PersonalContentService = .shared) async throws -> PersonalCADSketchSource {
        let library = try await service.library()
        let source = try await library.resolve(projectID)
        try require2D(source.record)
        let lease = try PersonalLibraryFileActions.acquireUse(id: projectID, directory: source.url, libraryRoot: library.root)
        defer { lease.release() }
        try PersonalCADSessions.requireSavedSketchSource(id: projectID, directory: source.url)
        let native = try await FloeCADDocument.readSketchLibrarySource(at: source.url.appendingPathComponent("Document.floecad"))
        try Task.checkCancellation()
        let current = try await library.resolve(projectID)
        try require2D(current.record)
        guard current.url == source.url else { throw CADSketchImportError.sourceChanged }
        try PersonalCADSessions.requireSavedSketchSource(id: projectID, directory: current.url,
            revision: native.revision, contentSHA256: native.contentSHA256)
        return PersonalCADSketchSource(record: current.record, directory: current.url, native: native)
    }

    static func append(_ source: PersonalCADSketchSource, sketchID: UUID,
                       to document: FloeCADDocument, context: CADSketchImportContext,
                       service: PersonalContentService = .shared) async throws -> CADSketchImportReceipt {
        let library = try await service.library()
        let current = try await library.resolve(source.record.id)
        try require2D(current.record)
        guard current.url == source.directory else { throw CADSketchImportError.sourceChanged }
        let lease = try PersonalLibraryFileActions.acquireUse(id: current.record.id, directory: current.url, libraryRoot: library.root)
        defer { lease.release() }
        try PersonalCADSessions.requireSavedSketchSource(id: current.record.id, directory: current.url)
        let verified = try await FloeCADDocument.readSketchLibrarySource(at: source.native.packageURL)
        guard verified.revision == source.native.revision,
              verified.contentSHA256 == source.native.contentSHA256,
              verified.schemaVersion == source.native.schemaVersion else { throw CADSketchImportError.sourceChanged }
        let latest = try await library.resolve(source.record.id)
        try require2D(latest.record)
        guard latest.url == source.directory else { throw CADSketchImportError.sourceChanged }
        try Task.checkCancellation()
        try PersonalCADSessions.requireSavedSketchSource(id: latest.record.id, directory: latest.url,
            revision: verified.revision, contentSHA256: verified.contentSHA256)
        // No await between the final live-owner check and native target CAS.
        return try document.appendLibrarySketch(verified, sketchID: sketchID, context: context)
    }

    private static func require2D(_ record: PersonalContentRecord) throws {
        try PersonalLibraryFileActions.requireAvailable(record.id)
        guard record.schemaVersion == 1, record.kind == .cad2D,
              !record.needsRecovery, record.deletedAt == nil else { throw PersonalContentError.invalidProject }
    }
}
#endif
