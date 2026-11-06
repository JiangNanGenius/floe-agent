import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramLayout

/// Routed geometry of one ordinary canvas relation. Relations are visual or
/// semantic only — this type can never execute; the Flow runtime consumes
/// `FlowEdge` values exclusively.
public struct CanvasRelationEdgeGeometry: Sendable, Hashable, Identifiable {
    /// The source connection ID.
    public var id: UUID
    public var geometry: DiagramEdgeGeometry
    public var kind: CanvasRelationKind
    public var label: String?
    /// True when at least one endpoint was replaced by a collapsed region
    /// proxy while routing.
    public var isProxy: Bool
}

/// Stateless routing of canvas relations through the public diagram router.
/// A page DTO adapter feeds `DiagramRouter` — curve routes with automatic
/// orthogonal fallback around obstacles — without touching diagram editor
/// state, undo or UIKit views. Expensive passes honor task cancellation.
public enum CanvasEdgeRouter {
    /// Routes every external connection of a prepared index (ordinary
    /// relations only). Throws `CancellationError` when the calling task is
    /// cancelled; malformed connections were already diagnosed at index
    /// build time and are simply not present to route.
    public static func routeRelationEdges(
        index: CanvasPageLayoutIndex
    ) throws -> [CanvasRelationEdgeGeometry] {
        try Task.checkCancellation()
        guard !index.proxyEdges.isEmpty else { return [] }

        // Visible node obstacles + VISIBLE collapsed region chips as
        // containers (containers are excluded from obstacle avoidance but
        // still act as valid routing endpoints). Hidden inner regions are
        // never endpoints: their connections were already re-pointed at the
        // outermost visible chip by the index.
        var elements: [DiagramElement] = []
        var frames: [UUID: DiagramRect] = [:]
        for node in index.nodes {
            try Task.checkCancellation()
            elements.append(DiagramElement(
                id: node.id,
                kind: .rectangle,
                title: "",
                frame: node.frame))
            frames[node.id] = node.frame
        }
        for regionID in index.collapsedRegionIDs {
            try Task.checkCancellation()
            guard let frame = index.regionFrames[regionID] else { continue }
            elements.append(DiagramElement(
                id: regionID,
                kind: .group,
                title: "",
                frame: frame))
            frames[regionID] = frame
        }

        let connections: [DiagramConnection] = index.proxyEdges.map { edge in
            DiagramConnection(
                id: edge.id,
                from: edge.sourceID,
                to: edge.destinationID,
                kind: .association,
                route: edge.kind == .line ? .straight : .curve,
                label: edge.label ?? "",
                endArrow: edge.kind == .arrow)
        }
        let page = DiagramPage(
            id: index.pageID,
            elements: elements,
            connections: connections)

        let proxyByID = Dictionary(
            uniqueKeysWithValues: index.proxyEdges.map { ($0.id, $0) })
        return try DiagramRouter.edges(page: page, frames: frames, representatives: [:])
            .compactMap { geometry in
                guard let proxy = proxyByID[geometry.id.uuid] else { return nil }
                return CanvasRelationEdgeGeometry(
                    id: geometry.id.uuid,
                    geometry: geometry,
                    kind: proxy.kind,
                    label: proxy.label,
                    isProxy: proxy.isProxy)
            }
    }

    /// The subset of routed edges whose geometry bounds intersect the
    /// requested world rect plus overscan — how a UI asks for only the
    /// visible edge slice during pan/zoom without routing everything.
    public static func visibleEdges(
        _ edges: [CanvasRelationEdgeGeometry],
        in rect: DiagramRect,
        overscan: Double = 96
    ) -> [CanvasRelationEdgeGeometry] {
        guard rect.isValid else { return [] }
        let padded = rect.insetBy(-max(0, overscan))
        return edges.filter { $0.geometry.bounds.intersects(padded) }
    }
}
