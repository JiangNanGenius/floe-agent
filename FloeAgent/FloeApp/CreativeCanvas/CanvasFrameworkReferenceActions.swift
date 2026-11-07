// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasUI

/// Discoverable card actions share the host's actual gateway/source services.
/// A child save is adopted only by the original node and parent revision.
@MainActor enum CanvasFrameworkReferenceActions {
    enum Action: Equatable { case openEditor, applyEditor, openSource, refreshSource }

    static func hasEditor(_ nodeID: UUID, store: CanvasEditorStore?) -> Bool {
        guard let node = store?.page.nodes.first(where: { $0.id == nodeID }) else { return false }
        if case .editor = node.content { return true }; return false
    }
    static func hasSource(_ nodeID: UUID, store: CanvasEditorStore?) -> Bool {
        store?.page.nodes.first(where: { $0.id == nodeID })?.source != nil
    }
    static func flowGraph(_ nodeID: UUID, store: CanvasEditorStore?) -> UUID? {
        guard let node = store?.page.nodes.first(where: { $0.id == nodeID }) else { return nil }
        return CanvasFlowCardBinding(metadata: node.metadata)?.graphID
    }

    @discardableResult
    static func perform(_ action: Action, store: CanvasEditorStore,
                        canvasID: UUID, pageID: UUID, nodeID: UUID, revision: Int64,
                        isCurrent: @MainActor () -> Bool) async throws -> CanvasCommitReceipt? {
        await store.refreshFromHost()
        let node = try checked(store, canvasID: canvasID, pageID: pageID, nodeID: nodeID,
                               revision: revision, isCurrent: isCurrent)
        let context = CanvasRuntimeContext(canvasID: canvasID, pageID: pageID, revision: revision)
        switch action {
        case .openEditor, .applyEditor:
            guard !node.isLocked else { throw FloeError.validationFailed(IDELanguageRunText.t("请先解锁这张卡片。", "Unlock this card first.")) }
            guard node.metadata[CanvasFrameworkLegacyRepository.pendingEditorForkKey] != "true" else {
                throw FloeError.validationFailed(IDELanguageRunText.t("这份副本的子项目尚未复制，请先创建独立子项目。", "This copy needs an independent child project before editing."))
            }
            guard case .editor(let reference) = node.content, let gateway = store.services.editorGateway else {
                throw PersonalContentError.missingDocument
            }
            store.select(nodeID)
            if action == .openEditor {
                try await gateway.openEditor(reference, context: context)
                return nil
            }
            let updated = try await gateway.applyEditorResult(reference, context: context)
            _ = try checked(store, canvasID: canvasID, pageID: pageID, nodeID: nodeID,
                            revision: revision, isCurrent: isCurrent)
            guard updated.projectID == reference.projectID, updated.editorKind == reference.editorKind else {
                throw PersonalContentError.changedDocument
            }
            guard updated != reference else { return nil }
            let receipt = try await store.services.documentStore.commit(.init(pageID: pageID,
                operations: [.updateContent(nodeID: nodeID, content: .editor(updated))]),
                canvasID: canvasID, expectedRevision: revision, requestID: UUID())
            await store.refreshFromHost()
            return receipt
        case .openSource:
            guard let source = node.source, let opening = store.services.sourceOpening else {
                throw PersonalContentError.missingDocument
            }
            try await opening.openSource(sourceID: source.sourceID, fragment: source.fragment)
            return nil
        case .refreshSource:
            guard !node.isLocked else { throw FloeError.validationFailed(IDELanguageRunText.t("请先解锁这张卡片。", "Unlock this card first.")) }
            guard node.source != nil else { throw PersonalContentError.missingDocument }
            await store.refreshSource(nodeID: nodeID, instruction: .default)
            return nil
        }
    }

    private static func checked(_ store: CanvasEditorStore, canvasID: UUID, pageID: UUID,
                                nodeID: UUID, revision: Int64, isCurrent: @MainActor () -> Bool) throws -> CanvasNodeSnapshot {
        try Task.checkCancellation()
        guard isCurrent(), store.canvasID == canvasID, store.selectedPageID == pageID else { throw CancellationError() }
        guard store.revision == revision else { throw CanvasKitError.revisionConflict(expected: revision, current: store.revision) }
        guard !store.isMutating, let node = store.page.nodes.first(where: { $0.id == nodeID }) else {
            throw PersonalContentError.changedDocument
        }
        return node
    }
}
#endif
