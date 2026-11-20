// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import PencilKit
import UIKit
import FloeCore
import FloeNotes

struct NoteInkShapeRequest: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Sendable { case selection, page }
    let id = UUID()
    let documentID: UUID
    let pageID: UUID
    let scope: Scope
}

struct NoteInkShapeCapture: Sendable {
    let request: NoteInkShapeRequest
    let drawing: Data
    let sourceIndices: [Int]
    let generation: UInt64
    let mutation: UInt64
}

enum NoteInkShapeError: LocalizedError, Sendable {
    case drawingInUse, selectionUnavailable, emptySource, tooLarge, sourceChanged, noCandidate
    var errorDescription: String? {
        switch self {
        case .drawingInUse: FloeL10n.l("app.notes_ink_shape_draft.finish_the_stroke_and_wait")
        case .selectionUnavailable: FloeL10n.l("app.notes_ink_shape_draft.use_convert_on_this_page")
        case .emptySource: FloeL10n.l("app.notes_ink_shape_draft.select_ink_or_draw_on")
        case .tooLarge: FloeL10n.l("app.notes_ink_shape_draft.use_the_lasso_to_select")
        case .sourceChanged: FloeL10n.l("app.notes_ink_shape_draft.the_page_ink_changed_preview")
        case .noCandidate: FloeL10n.l("app.notes_ink_shape_draft.there_are_no_shapes_to")
        }
    }
}

@MainActor struct NotesInkShapeDraft: Identifiable {
    struct Proposal: Identifiable {
        let id = UUID()
        let geometry: NotesInkShapeRecognizer.Candidate
        let strokes: [PKStroke]
        var title: String {
            switch geometry.kind {
            case .line: FloeL10n.l("cad.pattern.line")
            case .rectangle: FloeL10n.l("cad.datum.entity.rect")
            case .ellipse: FloeL10n.l("cad.datum.entity.ellipse")
            case .arrow: FloeL10n.l("notes.notes_document_editor.arrow")
            }
        }
    }
    let id: UUID
    let base: NoteDocument
    let pageID: UUID
    let sourceResourceID: UUID?
    let sourceDrawing: Data
    let original: PKDrawing
    let sourceIndices: [Int]
    let scope: NoteInkShapeRequest.Scope
    let proposals: [Proposal]

    var sourcePreview: PKDrawing { PKDrawing(strokes: sourceIndices.map { original.strokes[$0] }) }
    func candidatePreview(selected: Set<UUID>) -> PKDrawing {
        PKDrawing(strokes: proposals.filter { selected.contains($0.id) }.flatMap(\.strokes))
    }
    func converted(selected: Set<UUID>, keepOriginal: Bool) throws -> PKDrawing {
        let chosen = proposals.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { throw NoteInkShapeError.noCandidate }
        let replaced = Set(chosen.flatMap { $0.geometry.sourceIndices })
        let retained = original.strokes.enumerated().compactMap { index, stroke in
            keepOriginal || !replaced.contains(index) ? stroke : nil
        }
        return PKDrawing(strokes: retained + chosen.flatMap(\.strokes))
    }
    func editBatch(resourceID: UUID) -> NoteEditBatch {
        .init(documentID: base.id, expectedRevision: base.revision,
              title: FloeL10n.l("app.notes_ink_shape_draft.convert_ink_to_shapes"),
              edits: [.drawing(pageID: pageID, resourceID: resourceID)])
    }

    static func prepare(_ capture: NoteInkShapeCapture, session: NotesSession) async throws -> Self {
        guard session.document?.id == capture.request.documentID, !session.isSwitchingDocument,
              session.pendingWrites == 0,
              !session.hasPendingInk(documentID: capture.request.documentID, pageID: capture.request.pageID),
              let store = session.store else { throw NoteInkShapeError.drawingInUse }
        guard capture.drawing.count <= 32 * 1024 * 1024 else { throw NoteInkShapeError.tooLarge }
        let source = try PKDrawing(data: capture.drawing)
        let indices = Array(Set(capture.sourceIndices)).sorted()
        guard !indices.isEmpty else { throw NoteInkShapeError.emptySource }
        guard indices.count <= NotesInkShapeRecognizer.maximumStrokes,
              indices.allSatisfy({ source.strokes.indices.contains($0) }) else { throw NoteInkShapeError.tooLarge }
        if capture.request.scope == .page, indices != Array(source.strokes.indices) { throw NoteInkShapeError.sourceChanged }
        let base = try await store.document(capture.request.documentID)
        guard base.kind == .notebook, base.deletedAt == nil,
              let page = base.pages.first(where: { $0.id == capture.request.pageID }) else { throw NoteInkShapeError.sourceChanged }
        let stored: Data
        if let resource = page.drawingResourceID {
            let url = try await store.resourceURL(resource)
            stored = try await Task.detached { try Data(contentsOf: url) }.value
        } else { stored = PKDrawing().dataRepresentation() }
        try Task.checkCancellation()
        // Compare actual native drawing serialization; a local unsaved canvas
        // can never acquire a current revision merely by opening this panel.
        guard try PKDrawing(data: stored).dataRepresentation() == source.dataRepresentation(),
              try await store.document(base.id).revision == base.revision else { throw NoteInkShapeError.sourceChanged }
        var total = 0
        var strokes: [NotesInkShapeRecognizer.Stroke] = []
        for index in indices {
            let stroke = source.strokes[index]
            // A masked stroke may contain erased spans. Its control points do
            // not describe the visible source, so retain it without a proposal.
            guard stroke.mask == nil else { continue }
            let count = stroke.path.count
            total += count
            guard count <= NotesInkShapeRecognizer.maximumPointsPerStroke,
                  total <= NotesInkShapeRecognizer.maximumTotalPoints else { throw NoteInkShapeError.tooLarge }
            let points = stroke.path.map { point -> NotesInkShapeRecognizer.Point in
                let location = point.location.applying(stroke.transform)
                return .init(x: Double(location.x), y: Double(location.y))
            }
            strokes.append(.init(index: index, points: points))
        }
        let input = strokes
        let recognized = await Task.detached(priority: .userInitiated) {
            NotesInkShapeRecognizer.recognize(input)
        }.value
        try Task.checkCancellation()
        let proposals = recognized.map { geometry in
            let template = source.strokes[geometry.sourceIndices[0]]
            return Proposal(geometry: geometry, strokes: cleanStrokes(geometry.paths, template: template))
        }
        return Self(id: capture.request.id, base: base, pageID: page.id,
                    sourceResourceID: page.drawingResourceID, sourceDrawing: capture.drawing,
                    original: source, sourceIndices: indices, scope: capture.request.scope, proposals: proposals)
    }

    private static func cleanStrokes(_ paths: [[NotesInkShapeRecognizer.Point]], template: PKStroke) -> [PKStroke] {
        let samples = template.path.map(\.size)
        let scale = (hypot(template.transform.a, template.transform.b) + hypot(template.transform.c, template.transform.d)) / 2
        let widths = samples.map { max($0.width, $0.height) * scale }.sorted()
        let width = min(40, max(0.5, widths.isEmpty ? 2 : widths[widths.count / 2]))
        return paths.map { path in
            var dense: [NotesInkShapeRecognizer.Point] = []
            for (start, end) in zip(path, path.dropFirst()) {
                let count = max(1, min(256, Int(ceil(start.distance(to: end) / 6))))
                dense += (0..<count).map { step in
                    let t = Double(step) / Double(count)
                    return .init(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                }
            }
            if let end = path.last { dense.append(end) }
            let points = dense.enumerated().map { index, point in
                PKStrokePoint(location: CGPoint(x: point.x, y: point.y), timeOffset: Double(index) / 120,
                              size: CGSize(width: width, height: width), opacity: 1, force: 0.7,
                              azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: template.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()),
                            transform: .identity, mask: nil, randomSeed: template.randomSeed)
        }
    }
}

@MainActor extension NotesSession {
    /// Existing NoteEditBatch/CAS/conflict handling and undo remain authoritative.
    func applyInkShapes(_ draft: NotesInkShapeDraft, selected: Set<UUID>, keepOriginal: Bool) async throws -> NoteDocument {
        guard document?.id == draft.base.id, !isSwitchingDocument, pendingWrites == 0,
              !hasPendingInk(documentID: draft.base.id, pageID: draft.pageID),
              let store else { throw NoteInkShapeError.drawingInUse }
        let current = try await store.document(draft.base.id)
        guard current.revision == draft.base.revision, current.deletedAt == nil,
              current.pages.first(where: { $0.id == draft.pageID })?.drawingResourceID == draft.sourceResourceID else { throw NoteInkShapeError.sourceChanged }
        let drawing = try draft.converted(selected: selected, keepOriginal: keepOriginal)
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/InkShapeStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".drawing")
        defer { try? FileManager.default.removeItem(at: file) }
        try drawing.dataRepresentation().write(to: file, options: .atomic)
        let resource = try await store.importResource(from: file, mediaType: "application/vnd.apple.pencilkit")
        do {
            try Task.checkCancellation()
            guard document?.id == draft.base.id, !isSwitchingDocument,
                  !hasPendingInk(documentID: draft.base.id, pageID: draft.pageID) else { throw NoteInkShapeError.sourceChanged }
            let batch = draft.editBatch(resourceID: resource)
            return try await commit(batch.edits, documentID: batch.documentID, expectedRevision: batch.expectedRevision)
        } catch {
            // A conflict-preserved copy or history reference protects the blob.
            _ = try? await store.discardUnreferencedResource(resource)
            throw error
        }
    }
}

enum NotesInkShapeText {
    static func text(_ zh: String, _ en: String) -> String { FloeL10n.bilingual(chinese: zh, english: en) }
}
#endif
