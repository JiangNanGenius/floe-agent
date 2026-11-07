// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
import FloeNotes

/// Stable source identities are existing library/Notes document IDs. Opening
/// and refreshing never rebinds the active chat or replaces hand annotations.
struct CanvasHostSources: CanvasSourceService {
    func currentRevision(sourceID: UUID) async throws -> Int64 {
        try await read(sourceID: sourceID, fragment: nil).revision
    }
    func read(sourceID: UUID, fragment: String?) async throws -> CanvasSourceContent {
        let library = try await PersonalContentService.shared.library()
        if let record = try await library.records().first(where: { $0.id == sourceID }) {
            let location = try await library.resolve(record.id)
            let revision = max(1, Int64(record.modifiedAt.timeIntervalSince1970 * 1_000))
            if record.kind == .canvas {
                let snapshot = try await FileCanvasRepository(root: location.url.appendingPathComponent("Canvas")).load(canvasID: sourceID)
                let text = snapshot.pages.flatMap(\.nodes).compactMap { CanvasHostSources.text($0.content) }.joined(separator: "\n\n")
                return .init(sourceID: sourceID, revision: snapshot.revision, text: String(text.prefix(64_000)), fragment: fragment)
            }
            if record.kind == .document {
                let file = try await PersonalContentService.shared.originalFile(sourceID)
                if ["txt", "md", "json", "csv", "swift", "py", "js", "tex"].contains(file.pathExtension.lowercased()),
                   (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 256 * 1_024,
                   let text = String(data: try Data(contentsOf: file), encoding: .utf8) {
                    return .init(sourceID: sourceID, revision: revision, text: text, fragment: fragment)
                }
            }
            return .init(sourceID: sourceID, revision: revision, text: record.title, fragment: fragment)
        }
        guard let notes = try await NotesRepository.shared.existingStore() else { throw PersonalContentError.missingDocument }
        let document = try await notes.document(sourceID)
        guard document.deletedAt == nil else { throw PersonalContentError.missingDocument }
        let pages: [NotePage]
        if let fragment, fragment.hasPrefix("page:"), let id = UUID(uuidString: String(fragment.dropFirst(5))) {
            guard let page = document.pages.first(where: { $0.id == id }) else { throw PersonalContentError.missingDocument }
            pages = [page]
        } else { pages = document.pages }
        var fragments: [String] = [document.title]
        for page in pages {
            fragments.append(contentsOf: page.elements.map(\.text))
            if let extracted = page.extractedText { fragments.append(extracted) }
            if let visual = page.indexedVisualText { fragments.append(visual) }
        }
        for node in document.nodes { fragments.append(node.title); fragments.append(node.note) }
        let text = fragments.joined(separator: "\n\n")
        return .init(sourceID: sourceID, revision: Int64(document.revision), text: String(text.prefix(64_000)), fragment: fragment)
    }
    static func text(_ content: CanvasContent) -> String? {
        switch content {
        case .text(let text), .markdown(let text, _), .code(_, let text), .formula(let text, _): text
        case .richText(let document): document.runs.map(\.text).joined()
        case .table(let header, let rows): ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
        case .web(let url, let title): (title ?? "") + "\n" + url.absoluteString
        case .unknown(let kind, let payload) where kind == CanvasFrameworkProjection.frameworkNodeKind:
            if case .object(let values) = payload, case .string(let text) = values["text"] { text } else { nil }
        default: nil
        }
    }
}

struct CanvasHostNavigation: Sendable {
    var openWork: @MainActor @Sendable (UUID) async throws -> Void
    var openSource: @MainActor @Sendable (UUID, String?) async throws -> Void
    var openAssistant: @MainActor @Sendable (CanvasAssistantRequest?) async throws -> Void
    init(openWork: @escaping @MainActor @Sendable (UUID) async throws -> Void,
         openSource: @escaping @MainActor @Sendable (UUID, String?) async throws -> Void,
         openAssistant: @escaping @MainActor @Sendable (CanvasAssistantRequest?) async throws -> Void) {
        self.openWork = openWork; self.openSource = openSource; self.openAssistant = openAssistant
    }
}

struct CanvasHostSourceOpening: CanvasSourceOpening {
    let navigation: CanvasHostNavigation
    @MainActor func openSource(sourceID: UUID, fragment: String?) async throws {
        _ = try await CanvasHostSources().read(sourceID: sourceID, fragment: fragment)
        try await navigation.openSource(sourceID, fragment)
    }
}

struct CanvasHostEditorGateway: CanvasEditorGateway {
    let canvasID: UUID
    let repository: any CanvasDocumentStore
    let navigation: CanvasHostNavigation
    func openEditor(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws {
        try await validate(reference, context: context)
        try await navigation.openWork(reference.projectID)
    }
    func applyEditorResult(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws -> CanvasEditorReference {
        try await validate(reference, context: context)
        let value = try await PersonalContentService.shared.library().resolve(reference.projectID)
        try await PersonalContentService.shared.verify(value.record)
        var updated = reference
        updated.appliedRevision = max(reference.appliedRevision, Int64(value.record.modifiedAt.timeIntervalSince1970 * 1_000))
        updated.draftRevision = nil
        return updated
    }
    private func validate(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws {
        let snapshot = try await repository.load(canvasID: canvasID)
        guard context.canvasID == canvasID, context.revision == snapshot.revision,
              let page = snapshot.pages.first(where: { $0.id == context.pageID }),
              let node = page.nodes.first(where: { if case .editor(let value) = $0.content { return value.projectID == reference.projectID }; return false }) else {
            throw CanvasHostError.staleRun
        }
        guard node.metadata[CanvasFrameworkLegacyRepository.pendingEditorForkKey] != "true" else {
            throw FloeError.validationFailed(IDELanguageRunText.t("这份副本的子项目尚未复制。请先创建独立子项目，再从这里继续编辑。", "This copy's child project has not been duplicated. Create an independent child project before editing it here."))
        }
        let value = try await PersonalContentService.shared.library().resolve(reference.projectID)
        guard value.record.kind.rawValue == reference.editorKind || reference.editorKind == "mindMap" && value.record.kind == .diagram else {
            throw PersonalContentError.invalidProject
        }
    }
}
#endif
