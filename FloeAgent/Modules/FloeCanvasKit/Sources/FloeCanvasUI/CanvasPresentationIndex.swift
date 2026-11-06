// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasLayout
import FloeDiagramCore
import FloeDiagramLayout

/// Prepared at a layout boundary, never while panning or drawing.
struct CanvasPresentationIndex: Sendable {
    private let relations: CanvasGeometrySubset<CanvasRelationEdgeGeometry>
    private let flows: CanvasGeometrySubset<CanvasFlowEdgeGeometry>
    private let ports: CanvasGeometrySubset<PortGroup>

    private struct PortGroup: Sendable {
        var id: UUID
        var frame: DiagramRect
        var anchors: [CanvasFlowPortAnchor]
    }

    init(layout: CanvasPageLayoutIndex? = nil,
         relations: [CanvasRelationEdgeGeometry] = [],
         flows: [CanvasFlowEdgeGeometry] = []) {
        self.relations = .init(elements: relations, id: { $0.id }, bounds: { $0.geometry.bounds })
        self.flows = .init(elements: flows, id: { $0.id }, bounds: { $0.geometry.bounds })
        var groups: [PortGroup] = []
        if let layout {
            for (id, anchors) in layout.flowPortAnchors {
                // Folded steps retain their real data, but do not expose
                // floating editable ports behind a collapsed region.
                guard !layout.collapsedRegionIDs.contains(layout.flowDisplayRepresentatives[id] ?? id),
                      let frame = layout.flowDisplayFrames[id] else { continue }
                groups.append(.init(id: id, frame: frame, anchors: anchors))
            }
        }
        groups.sort { $0.id.uuidString < $1.id.uuidString }
        ports = .init(elements: groups, id: { $0.id }, bounds: { $0.frame })
    }

    func relationEdges(in rect: DiagramRect) -> [CanvasRelationEdgeGeometry] {
        relations.visible(in: rect, overscan: 128)
    }

    func flowEdges(in rect: DiagramRect) -> [CanvasFlowEdgeGeometry] {
        flows.visible(in: rect, overscan: 128)
    }

    func portAnchors(in rect: DiagramRect) -> [CanvasFlowPortAnchor] {
        ports.visible(in: rect, overscan: 64).flatMap(\.anchors)
    }
}

private struct CanvasGeometrySubset<Element: Sendable>: Sendable {
    private let index: DiagramSpatialIndex
    private let values: [UUID: (order: Int, element: Element)]
    private let unindexedBounds: [UUID: DiagramRect]

    init(elements: [Element], id: (Element) -> UUID, bounds: (Element) -> DiagramRect) {
        var frames: [UUID: DiagramRect] = [:]
        var values: [UUID: (order: Int, element: Element)] = [:]
        var unindexed: [UUID: DiagramRect] = [:]
        for (order, element) in elements.enumerated() {
            let key = id(element)
            guard values[key] == nil else { continue }
            let frame = bounds(element)
            guard frame.isValid else { continue }
            values[key] = (order, element)
            if CanvasLayoutGeometry.isSafeWorldRect(frame) {
                frames[key] = frame
            } else {
                // Extremely long valid connectors use a bounded fallback;
                // never pass overflowing cell arithmetic to DiagramKit.
                unindexed[key] = frame
            }
        }
        self.values = values
        unindexedBounds = unindexed
        index = DiagramSpatialIndex(frames: frames)
    }

    func visible(in rect: DiagramRect, overscan: Double) -> [Element] {
        let query = rect.insetBy(-overscan)
        guard CanvasLayoutGeometry.isSafeQueryRect(query) else { return [] }
        var ids = index.query(query)
        for (id, frame) in unindexedBounds where frame.intersects(query) { ids.insert(id) }
        return ids.compactMap { values[$0] }.sorted { $0.order < $1.order }.map(\.element)
    }
}
