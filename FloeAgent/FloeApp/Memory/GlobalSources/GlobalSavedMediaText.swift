// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(PDFKit)
import Foundation
import FloeCore
import FloeWorkbench

nonisolated struct GlobalSavedMediaBody: Sendable {
    let projectID: UUID
    let revision: String
    let updatedAt: Date
    let text: String?
}

/// Reads only the exact, already-saved project selected by its native owner.
/// It does not discover neighbouring subtitles, read referenced assets, create
/// a store/Notes copy, upgrade a document, open an editor or invoke speech AI.
actor GlobalSavedMediaTextReader {
    static let shared = GlobalSavedMediaTextReader()

    nonisolated static func revision(personalDirectory: URL, ownerID: UUID) throws -> String {
        let file = personalDirectory.appendingPathComponent("Media/Projects", isDirectory: true)
            .appendingPathComponent(MediaProjectStore.projectFileName(id: ownerID))
        return try GlobalExtractionFile.revision(file, maximumBytes: 8 * 1_024 * 1_024)
    }

    func read(personalDirectory: URL, ownerID: UUID) async throws -> GlobalSavedMediaBody? {
        let media = personalDirectory.appendingPathComponent("Media", isDirectory: true)
        let projects = media.appendingPathComponent("Projects", isDirectory: true)
        let file = projects.appendingPathComponent(MediaProjectStore.projectFileName(id: ownerID))
        let budget = GlobalFileTextBudget(seconds: 8)
        let source: GlobalExtractionFile
        do { source = try GlobalExtractionFile.read(file, maximumBytes: 8 * 1_024 * 1_024, budget: budget) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        // No migrator: loadProject(id:) is an actual read-only API. The library
        // location and expected owner came from native authority before this call.
        let store = MediaProjectStore(directory: projects, limits: .init(maximumDocumentBytes: 8 * 1_024 * 1_024))
        guard let project = try await store.loadProject(id: ownerID), project.id == ownerID,
              project.ownerKind == "files", project.ownerID == ownerID,
              project.taskWorkspacePath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) == media.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        try budget.check()
        try source.checkCurrent()
        if project.prepared != nil { try MediaPreparedIntegrity.validateEnvelope(project) }
        let values: [String]
        switch project.kind {
        case .image:
            guard project.imageLayers.count <= 1_024 else { return nil }
            values = project.imageLayers.filter { !$0.isHidden }.compactMap { $0.text?.text }
        case .video:
            // The envelope validator binds this projection to prepared v2
            // captions. Never index the undo history or discarded generations.
            let captions = project.videoTimeline?.captions ?? []
            guard captions.count <= 10_000,
                  captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }) else { return nil }
            values = captions.sorted { $0.start < $1.start }.map(\.text)
        }
        var text = ""
        for value in values {
            try budget.check()
            guard value.count <= 200_000 - text.count - (text.isEmpty ? 0 : 1) else { return nil }
            if !text.isEmpty { text += "\n" }
            text += value
        }
        try source.checkCurrent()
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(projectID: project.id,
            revision: "media:\(project.revision):" + FloeDigest.sha256Hex(source.data),
            updatedAt: project.updatedAt, text: body.isEmpty ? nil : body)
    }
}
#endif
