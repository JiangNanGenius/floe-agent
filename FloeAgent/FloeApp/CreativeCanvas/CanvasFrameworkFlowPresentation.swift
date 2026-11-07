// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasLayout
import FloeDiagramCore
import FloeDiagramLayout

/// Typed executable relations retain their graph/port IDs. Ordinary canvas
/// relation arrows stay separate and can never become an executable edge.
struct CanvasFrameworkFlowPresentation {
    struct Edge: Identifiable {
        let graphID: UUID
        let value: CanvasFlowEdgeGeometry
        var id: String { graphID.uuidString + "/" + value.id.uuidString }
    }
    struct Port: Identifiable {
        let graphID: UUID
        let nodeID: UUID
        let canvasNodeID: UUID?
        let value: FlowPort
        let point: DiagramPoint
        let locked: Bool
        var id: String { graphID.uuidString + "/" + value.id.uuidString }
    }
    struct UnboundNode: Identifiable {
        let graphID: UUID
        let value: FlowNode
        let frame: DiagramRect
        var id: String { graphID.uuidString + "/" + value.id.uuidString }
    }
    var edges: [Edge] = []
    var ports: [Port] = []
    var unboundNodes: [UnboundNode] = []

    static func make(snapshot: CanvasSnapshot, document: FloeCore.CanvasDocument) -> Self {
        guard let page = snapshot.pages.first(where: { $0.id == document.id }) else { return .init() }
        let visible = Dictionary(document.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = Self()
        for graph in page.flowGraphs {
            var bound: [UUID: CanvasNodeSnapshot] = [:]
            for node in page.nodes {
                if let binding = CanvasFlowCardBinding(metadata: node.metadata), binding.graphID == graph.id,
                   bound[binding.nodeID] == nil { bound[binding.nodeID] = node }
            }
            let locked = bound.values.contains { visible[$0.id]?.isLocked ?? $0.isLocked }
            var frames: [UUID: DiagramRect] = [:]
            for node in graph.nodes {
                if let card = bound[node.id], let value = visible[card.id] {
                    frames[node.id] = .init(x: value.x - value.width / 2, y: value.y - value.height / 2,
                                           width: value.width, height: value.height)
                } else {
                    let frame = CanvasFlowEdgeLayout.defaultFrame(for: node)
                    frames[node.id] = frame
                    result.unboundNodes.append(.init(graphID: graph.id, value: node, frame: frame))
                }
            }
            let anchors = CanvasFlowEdgeLayout.anchors(for: graph, nodeFrames: frames)
            for node in graph.nodes {
                let positions = Dictionary((anchors[node.id] ?? []).map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
                for port in node.ports {
                    guard let point = positions[port.id] else { continue }
                    result.ports.append(.init(graphID: graph.id, nodeID: node.id, canvasNodeID: bound[node.id]?.id,
                                              value: port, point: point, locked: locked))
                }
            }
            if let routed = try? CanvasFlowEdgeLayout.routeEdges(flowGraph: graph, nodeFrames: frames) {
                result.edges += routed.edges.map { .init(graphID: graph.id, value: $0) }
            }
        }
        return result
    }
}
#endif
