#if canImport(UIKit)
import UIKit
import FloeCanvasCore
import FloeCanvasLayout
import FloeDiagramCore

/// Bounded, visible-only accessibility elements for the board (UI_BRIEF).
///
/// VoiceOver and UI tests can reach the cards/regions actually on screen:
/// elements are synthesized from the SAME prepared layout index the draw
/// pass uses (O(1) node lookup via the store's cached lookup), with frames
/// transformed into screen coordinates. Nothing offscreen is materialized —
/// at most `maxNodeElements`/`maxRegionElements` elements per query, so a
/// 10k-card board never produces 10k accessibility objects per pan.
enum CanvasBoardAccessibilityBuilder {
    static let maxNodeElements = 120
    static let maxRegionElements = 40

    @MainActor
    static func elements(
        store: CanvasEditorStore,
        board: CanvasBoardView
    ) -> [UIAccessibilityElement] {
        guard store.layoutIndex.pageID == store.selectedPageID else { return [] }
        let worldRect = store.viewport.visibleWorldRect(overscan: 64)
        var elements: [UIAccessibilityElement] = []

        let regions = store.layoutIndex.visibleRegions(in: worldRect, overscan: 0)
            .prefix(maxRegionElements)
        for region in regions {
            let element = UIAccessibilityElement(accessibilityContainer: board)
            element.accessibilityFrame = screenFrame(
                of: region.frame, store: store, board: board)
            element.accessibilityLabel = region.name
            element.accessibilityValue = region.isCollapsed
                ? store.strings[.toolbarCollapseRegion]
                : nil
            element.accessibilityTraits = .none
            elements.append(element)
        }

        let preparedNodes = store.layoutIndex.visibleNodes(in: worldRect, overscan: 0)
            .prefix(maxNodeElements)
        for prepared in preparedNodes {
            guard let node = store.node(id: prepared.id) else { continue }
            let element = UIAccessibilityElement(accessibilityContainer: board)
            element.accessibilityFrame = screenFrame(
                of: CanvasLayoutGeometry.rect(from: node.frame),
                store: store,
                board: board)
            element.accessibilityLabel = label(for: node, store: store)
            var traits: UIAccessibilityTraits = .button
            if store.selection.contains(node.id) { traits.insert(.selected) }
            element.accessibilityTraits = traits
            element.accessibilityCustomActions = customActions(for: node, store: store)
            elements.append(element)
        }
        return elements
    }

    @MainActor
    private static func screenFrame(
        of worldRect: DiagramRect,
        store: CanvasEditorStore,
        board: CanvasBoardView
    ) -> CGRect {
        let viewRect = board.viewRect(forWorldRect: worldRect)
        return board.convert(viewRect, to: nil).integral
    }

    @MainActor
    private static func label(
        for node: CanvasNodeSnapshot,
        store: CanvasEditorStore
    ) -> String {
        if let title = node.title, !title.isEmpty { return title }
        let preview = CanvasSearch.contentPreview(of: node.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return String(preview.prefix(80))
        }
        return store.strings[.inspectorNodeContent]
    }

    @MainActor
    private static func customActions(
        for node: CanvasNodeSnapshot,
        store: CanvasEditorStore
    ) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        actions.append(UIAccessibilityCustomAction(
            name: store.strings[.toolSelect]) { _ in
            store.select(node.id)
            return true
        })
        actions.append(UIAccessibilityCustomAction(
            name: store.strings[.a11yOpenInspector]) { _ in
            store.select(node.id)
            store.showsInspector = true
            return true
        })
        if node.source != nil, store.services.sourceOpening != nil {
            actions.append(UIAccessibilityCustomAction(
                name: store.strings[.inspectorOpenOriginal]) { _ in
                Task { await store.openOriginalSource(nodeID: node.id) }
                return true
            })
        }
        if case .editor = node.content {
            actions.append(UIAccessibilityCustomAction(
                name: store.strings[.inspectorOpenEditor]) { _ in
                store.select(node.id)
                Task { await store.openEditorForSelectedNode() }
                return true
            })
        }
        return actions
    }
}
#endif
