// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeNotes
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistryUI
import FloeChemistrySketch

@MainActor struct NotesChemistryLease {
    let workID: UUID
    let projectID: UUID
    let service: ChemistryService
}
@MainActor struct NotesChemistryHost {
    var list: @MainActor () async throws -> [PersonalContentRecord]
    var acquire: @MainActor (UUID) async throws -> NotesChemistryLease
}
nonisolated enum NotesChemistryInsertMode: String, CaseIterable, Sendable { case image, link }
nonisolated struct NotesChemistryTarget: Sendable {
    let documentID: UUID
    let pageID: UUID?
    let parentNodeID: UUID?
}
nonisolated enum NotesChemistryError: Error, LocalizedError {
    case changed, unsupported, noNotes
    var errorDescription: String? {
        switch self {
        case .changed: IDELanguageRunText.t("内容已改变，请重新选择后插入。", "The content changed. Select it again before inserting.")
        case .unsupported: IDELanguageRunText.t("这个对象暂无可插入的图片。可以选择插入工程链接。", "This object has no supported note image. You can insert a project link.")
        case .noNotes: IDELanguageRunText.t("请先选择手记。", "Choose a note first.")
        }
    }
}

@MainActor enum NotesChemistryBridge {
    static func host(environment: AppEnvironment) -> NotesChemistryHost {
        .init(list: {
            try await PersonalContentService.shared.library().records().filter { $0.kind.rawValue == "chemistry" && !$0.needsRecovery }
        }, acquire: { [weak environment] id in
            guard let environment else { throw NotesChemistryError.changed }
            let location = try await PersonalContentService.shared.library().resolve(id)
            guard location.record.kind.rawValue == "chemistry", !location.record.needsRecovery else { throw NotesChemistryError.changed }
            // The real App session owns its one /Chemistry store and authorizer.
            let session = try await ChemistryProjectSession.open(id: id, directory: location.url, environment: environment)
            guard session.projectID == id else { throw NotesChemistryError.changed }
            return .init(workID: id, projectID: session.projectID, service: session.service)
        })
    }
    static func openWork(_ reference: NoteWorkReference) async throws -> PersonalContentRecord {
        try reference.validate()
        let location = try await PersonalContentService.shared.library().resolve(reference.workID)
        guard location.record.kind.rawValue == reference.kind, reference.kind == "chemistry" else { throw NotesChemistryError.changed }
        return location.record
    }
    static func canExportImage(_ object: ChemicalObject) -> Bool {
        object.sketchDocument != nil || [.molecule, .crystal, .biomolecule, .spectrum].contains(object.kind)
    }
    static func insert(host: NotesChemistryHost, workID: UUID, objectID: UUID?, mode: NotesChemistryInsertMode,
                       session: NotesSession, target: NotesChemistryTarget) async throws -> NoteDocument {
        guard let store = session.store, session.document?.id == target.documentID,
              session.pendingWrites == 0, !session.isSwitchingDocument else { throw NotesChemistryError.changed }
        let lease = try await host.acquire(workID)
        let project = try await lease.service.project(lease.projectID)
        guard project.id == lease.projectID, project.revision > 0 else { throw NotesChemistryError.changed }
        let object = objectID.flatMap { id in project.objects.first { $0.id == id } }
        guard objectID == nil || object != nil else { throw NotesChemistryError.changed }
        let digest: String?
        if let object { digest = try objectDigest(object) } else { digest = nil }
        let image: ChemistryNoteImage?
        if mode == .image {
            guard let object, canExportImage(object) else { throw NotesChemistryError.unsupported }
            image = try await exportImage(lease: lease, object: object)
        } else { image = nil }
        try Task.checkCancellation()
        let currentProject = try await lease.service.project(lease.projectID)
        let currentObject = objectID.flatMap { id in currentProject.objects.first { $0.id == id } }
        let currentDigest: String?
        if let currentObject { currentDigest = try objectDigest(currentObject) } else { currentDigest = nil }
        guard currentProject.revision == project.revision,
              (objectID == nil || currentObject != nil), currentDigest == digest else { throw NotesChemistryError.changed }
        let reference = NoteWorkReference(workID: lease.workID, kind: "chemistry", documentID: lease.projectID,
            revision: project.revision, objectID: object?.id, objectRevision: object?.revision, objectDigest: digest,
            imageDigest: image.map { hash($0.png) }, renderKind: image?.kind)
        try reference.validate()
        guard session.document?.id == target.documentID, session.pendingWrites == 0, !session.isSwitchingDocument else { throw NotesChemistryError.changed }
        let base = try await store.document(target.documentID)
        guard base.deletedAt == nil, [.notebook, .mindMap].contains(base.kind) else { throw NotesChemistryError.noNotes }
        var resource: UUID?
        do {
            if let image { resource = try await importImage(image.png, store: store) }
            try Task.checkCancellation()
            guard session.document?.id == target.documentID, session.pendingWrites == 0, !session.isSwitchingDocument else { throw NotesChemistryError.changed }
            let edits = try insertionEdits(base: base, target: target, project: project, object: object,
                image: image, resource: resource, reference: reference)
            // Existing Notes commit owns revision/rebase/conflict and a single
            // undo batch. The chemical original and its history stay untouched.
            let saved = try await session.commit(edits, documentID: base.id, expectedRevision: base.revision)
            if saved.kind == .notebook, session.document?.id == saved.id {
                session.requestedPageID = saved.pages.first(where: { page in !base.pages.contains(where: { $0.id == page.id }) })?.id ?? target.pageID
            }
            return saved
        } catch {
            if let resource { _ = try? await store.discardUnreferencedResource(resource) }
            throw error
        }
    }

    private static func exportImage(lease: NotesChemistryLease, object: ChemicalObject) async throws -> ChemistryNoteImage {
        guard object.source.utf8.count <= 8 * 1_024 * 1_024, (object.sketchDocument?.utf8.count ?? 0) <= 8 * 1_024 * 1_024 else { throw NotesChemistryError.unsupported }
        if object.kind == .spectrum {
            return try ChemistryNoteImageExporter.spectrumPNG(csv: object.source, title: object.title)
        }
        let ket: String
        if let drawing = object.sketchDocument { ket = drawing }
        else if object.format.lowercased() == "ket" { ket = object.source }
        else {
            let mol = try await lease.service.export(lease.projectID, objectID: object.id, format: "mol")
            guard mol.utf8.count <= 8 * 1_024 * 1_024 else { throw NotesChemistryError.unsupported }
            // The bundled offline structure processor produces real KET data;
            // its output is rendered directly, without opening an editor or saving.
            let processor = ChemistryStructureProcessor()
            ket = try await processor.evaluate(mol, layout: true).ket
        }
        try Task.checkCancellation()
        return try ChemistryNoteImageExporter.structurePNG(ket: ket)
    }
    private static func importImage(_ bytes: Data, store: NotesStore) async throws -> UUID {
        guard !bytes.isEmpty, bytes.count <= 12 * 1_024 * 1_024 else { throw NotesChemistryError.unsupported }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-note-chemistry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chemical-image.png")
        try bytes.write(to: file, options: .atomic)
        try Task.checkCancellation()
        return try await store.importResource(from: file, mediaType: "image/png")
    }
    private static func insertionEdits(base: NoteDocument, target: NotesChemistryTarget, project: ChemistryProject,
                                       object: ChemicalObject?, image: ChemistryNoteImage?, resource: UUID?, reference: NoteWorkReference) throws -> [NoteEdit] {
        let title = object.map { project.title + " · " + $0.title } ?? project.title
        if base.kind == .mindMap {
            let parent: MindMapNode?
            if let id = target.parentNodeID {
                guard let selected = base.nodes.first(where: { $0.id == id }) else { throw NotesChemistryError.changed }
                parent = selected
            } else { parent = base.nodes.first { $0.parentID == nil } }
            guard let parent else { throw NotesChemistryError.changed }
            var node = MindMapNode(parentID: parent.id, title: String(title.prefix(1_024)),
                note: reference.url.absoluteString, order: base.nodes.filter { $0.parentID == parent.id }.count,
                imageResourceID: resource)
            node.workReference = reference
            return [.upsertNode(node)]
        }
        guard let selected = target.pageID.flatMap({ id in base.pages.first { $0.id == id } }) else { throw NotesChemistryError.changed }
        var page = selected, edits: [NoteEdit] = []
        let width = min(560, page.width - 80), imageHeight = image.map { width * Double($0.height) / Double($0.width) } ?? 0
        guard width >= 80, imageHeight + 120 <= page.height else { throw NotesChemistryError.unsupported }
        var y = max(50, (page.elements.map { $0.frame.y + $0.frame.height }.max() ?? 30) + 20)
        if y + imageHeight + 88 > page.height - 30 {
            let fresh = NotePage(width: page.width, height: page.height, paper: page.paper)
            let index = base.pages.firstIndex(where: { $0.id == page.id }) ?? base.pages.count - 1
            edits.append(.insertPage(fresh, at: index + 1)); page = fresh; y = 50
        }
        if let resource {
            var element = NoteElement(kind: .image, frame: .init(x: 40, y: y, width: width, height: imageHeight), resourceID: resource)
            element.workReference = reference
            edits.append(.upsertElement(pageID: page.id, element: element)); y += imageHeight + 12
        }
        var caption = NoteElement(frame: .init(x: 40, y: y, width: width, height: 70),
            text: escapedTitle(String(title.prefix(1_024))) + "\n[" + IDELanguageRunText.t("打开化学工程", "Open chemistry project") + "](" + reference.url.absoluteString + ")", fontSize: 16)
        caption.textFormat = "markdown"; caption.workReference = reference
        edits.append(.upsertElement(pageID: page.id, element: caption))
        return edits
    }
    private static func objectDigest(_ object: ChemicalObject) throws -> String {
        guard object.source.utf8.count <= 16 * 1_024 * 1_024, (object.sketchDocument?.utf8.count ?? 0) <= 16 * 1_024 * 1_024 else { throw NotesChemistryError.unsupported }
        struct Input: Encodable { let id: UUID; let revision: UInt64; let format: String; let source: String; let drawing: String? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return hash(try encoder.encode(Input(id: object.id, revision: object.revision, format: object.format, source: object.source, drawing: object.sketchDocument)))
    }
    private nonisolated static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func escapedTitle(_ text: String) -> String {
        var result = text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\\", with: "\\\\")
        for token in ["[", "]", "(", ")", "*", "_", "`", "<", ">"] { result = result.replacingOccurrences(of: token, with: "\\" + token) }
        return result
    }
}
#endif
