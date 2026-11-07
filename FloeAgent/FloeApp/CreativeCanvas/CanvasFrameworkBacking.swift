// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasUI
import FloeCanvasTemplates

extension Notification.Name {
    static let floeCanvasFrameworkExportRequested = Notification.Name("floe.canvas.framework.export")
}

/// Both existing project files and new personal canvases expose one native
/// transaction boundary. No adapter stores a second editable original.
protocol CanvasFrameworkRepository: TemplateDocumentStore {
    var root: URL { get }
    func sourceURL(canvasID: UUID) -> URL
    func loadSynchronously(canvasID: UUID) throws -> CanvasSnapshot
    func commitDocumentSynchronously(_ batch: CanvasDocumentBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt
    func undoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt
    func redoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt
    func historyAvailabilitySynchronously(canvasID: UUID) throws -> CanvasHistoryAvailability
}

extension FileCanvasRepository: CanvasFrameworkRepository {
    func sourceURL(canvasID: UUID) -> URL { root.appendingPathComponent("canvases/" + canvasID.uuidString + "/manifest.json") }
}

/// One durable authority behind the existing canvas's native gesture engine.
/// A commit returns only after the shared repository's manifest CAS succeeds.
@MainActor final class CanvasFrameworkBacking {
    let record: PersonalContentRecord
    let repository: any CanvasFrameworkRepository
    let directory: URL
    private(set) var snapshot: CanvasSnapshot
    private(set) var history: CanvasHistoryAvailability

    init(record: PersonalContentRecord, directory: URL, repository: any CanvasFrameworkRepository) throws {
        self.record = record; self.directory = directory; self.repository = repository
        snapshot = try repository.loadSynchronously(canvasID: record.id)
        guard snapshot.id == record.id else { throw PersonalContentError.changedDocument }
        history = try repository.historyAvailabilitySynchronously(canvasID: record.id)
    }

    var sourceURL: URL {
        repository.sourceURL(canvasID: record.id)
    }
    var canUndo: Bool { history.undoCount > 0 }
    var canRedo: Bool { history.redoCount > 0 }
    var isLegacySource: Bool { repository is CanvasFrameworkLegacyRepository }

    func load() throws -> FloeCore.CanvasProject {
        snapshot = try repository.loadSynchronously(canvasID: record.id)
        history = try repository.historyAvailabilitySynchronously(canvasID: record.id)
        if let legacy = repository as? CanvasFrameworkLegacyRepository { return try legacy.projectSynchronously() }
        return try CanvasFrameworkProjection.project(snapshot, record: record)
    }

    func commit(_ project: FloeCore.CanvasProject, expectedRevision: Int64) throws -> FloeCore.CanvasProject {
        guard project.id == record.id, snapshot.id == record.id,
              expectedRevision == snapshot.revision else { throw PersonalContentError.changedDocument }
        let batch = try CanvasFrameworkProjection.batch(project: project, original: snapshot, record: record)
        do {
            _ = try repository.commitDocumentSynchronously(batch, canvasID: record.id,
                expectedRevision: expectedRevision, requestID: UUID())
            return try load()
        } catch {
            // Keep the complete gesture draft, including native metadata. An
            // intervening AI commit never silently replaces the user's edit.
            let recovery = directory.appendingPathComponent("Recovery", isDirectory: true)
            try? FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
            try? JSONEncoder().encode(project).write(to: recovery.appendingPathComponent("Canvas-" + UUID().uuidString + ".json"), options: .atomic)
            throw error
        }
    }

    func undo(expectedRevision: Int64) throws -> FloeCore.CanvasProject {
        _ = try repository.undoSynchronously(canvasID: record.id, expectedRevision: expectedRevision, requestID: UUID())
        return try load()
    }
    func redo(expectedRevision: Int64) throws -> FloeCore.CanvasProject {
        _ = try repository.redoSynchronously(canvasID: record.id, expectedRevision: expectedRevision, requestID: UUID())
        return try load()
    }
}
#endif
