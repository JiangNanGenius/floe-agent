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
            CADDrawingModelBridge.configure(existing)
            return existing
        }
        guard opening.insert(id).inserted else { throw PersonalFileActionError.busy }
        defer { opening.remove(id) }
        let value = try await FloeCADDocument.open(at: url)
        do { try PersonalLibraryFileActions.requireAvailable(id) }
        catch { value.close(); throw error }
        // Personal 2D/3D editors share the same drawing import/export bridge
        // as workspace CAD, including calls made before a view appears.
        CADDrawingModelBridge.configure(value)
        documents[id] = value; return value
    }
    static func restoreCopy(of record: PersonalContentRecord, preview: CADRecoveryPreview) async throws
        -> (PersonalContentRecord, CADRecoveryRestoreResult) {
        let library = try await PersonalContentService.shared.library()
        let source = try await library.resolve(record.id)
        let use = try PersonalLibraryFileActions.acquireUse(id: record.id, directory: source.url)
        defer { use.release() }
        guard source.url.appendingPathComponent("Document.floecad").standardizedFileURL
                == preview.sourceURL.standardizedFileURL else { throw PersonalContentError.changedDocument }
        let title = String(record.title.prefix(64)) + " " + IDELanguageRunText.t("恢复副本", "Recovered copy")
        let restored = try await library.create(kind: record.kind, title: title, in: source.record.folders) { directory, _ in
            _ = try await FloeCADDocument.restorePreviousCopy(preview, to: directory.appendingPathComponent("Document.floecad"))
        }
        let package = try await library.resolve(restored.id).url.appendingPathComponent("Document.floecad")
        guard let identity = await FloeCADDocument.storedIdentity(at: package) else { throw PersonalContentError.changedDocument }
        let result = CADRecoveryRestoreResult(packageURL: package, revision: identity.revision,
            contentSHA256: identity.contentSHA256, modelSHA256: identity.modelSHA256,
            sourceURL: preview.sourceURL, sourceFingerprint: preview.sourceFingerprint, report: preview.report)
        return (restored, result)
    }

    /// Read-only import snapshots must not ignore unsaved work or change a
    /// source editor's ownership. No open/close/save is performed here.
    static func requireSavedSketchSource(id: UUID, directory: URL,
                                         revision: Int? = nil, contentSHA256: String? = nil) throws {
        try PersonalLibraryFileActions.requireAvailable(id)
        guard let document = documents[id], !document.isClosed else { return }
        guard document.url == directory.appendingPathComponent("Document.floecad") else {
            throw PersonalContentError.changedDocument
        }
        guard !document.hasUnsavedChanges else { throw PersonalCADSketchImportIssue.saveSourceFirst }
        if let revision, document.revision != revision { throw CADSketchImportError.sourceChanged }
        if let contentSHA256, document.contentSHA256 != contentSHA256 { throw CADSketchImportError.sourceChanged }
    }
    static func prepareForLibraryMove(id: UUID, directory: URL) throws {
        guard !opening.contains(id) else { throw PersonalFileActionError.busy }
        if let document = documents[id] {
            guard document.url.standardizedFileURL.resolvingSymlinksInPath()
                == directory.appendingPathComponent("Document.floecad").standardizedFileURL.resolvingSymlinksInPath() else {
                throw PersonalContentError.changedDocument
            }
        // FloeCAD.close already cancels owned services and revokes the store
        // after draining its commit fence. Do not close another live editor.
            guard document.isClosed else { throw PersonalFileActionError.closeFirst }
        }
        try ManufacturingSessions.prepareForCADMove(directory: directory.appendingPathComponent("Manufacturing", isDirectory: true))
        documents.removeValue(forKey: id)
    }
}
#endif
