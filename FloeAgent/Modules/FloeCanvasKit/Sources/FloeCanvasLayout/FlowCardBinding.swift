import Foundation
import FloeCanvasCore

/// A resolved Core flow binding plus its ordinary canvas-card identity.
public struct CanvasLayoutFlowCardBinding: Sendable, Hashable {
    /// The `FlowGraph.id` the bound flow node belongs to.
    public var graphID: UUID
    /// The bound `FlowNode.id`.
    public var nodeID: UUID
    /// The canvas card node carrying the flow visual (`kind: .generationTask`).
    public var cardNodeID: UUID

    public init(graphID: UUID, nodeID: UUID, cardNodeID: UUID) {
        self.graphID = graphID
        self.nodeID = nodeID
        self.cardNodeID = cardNodeID
    }
}

public enum CanvasFlowCardBindingKeys {
    /// Fixed metadata key on the canvas card node: the flow graph ID.
    public static let graphID = CanvasFlowCardBindingKey.graphID
    /// Fixed metadata key on the canvas card node: the flow node ID.
    public static let nodeID = CanvasFlowCardBindingKey.nodeID
}

public enum CanvasFlowCardBindingReader {
    /// Reads every well-formed binding from canvas node metadata. Cards with
    /// missing or malformed values are skipped silently — layout treats them
    /// as unbound cards (display fallback) and deeper validation stays with
    /// the Core writer that owns the real binding API.
    public static func bindings(from nodes: [CanvasNodeSnapshot]) -> [CanvasLayoutFlowCardBinding] {
        var bindings: [CanvasLayoutFlowCardBinding] = []
        for node in nodes {
            guard node.kind == .generationTask,
                  let binding = FloeCanvasCore.CanvasFlowCardBinding(metadata: node.metadata) else { continue }
            bindings.append(.init(graphID: binding.graphID, nodeID: binding.nodeID, cardNodeID: node.id))
        }
        return bindings
    }

    /// First binding per flow node ID, deterministic by card source order.
    public static func bindingByFlowNodeID(
        from bindings: [CanvasLayoutFlowCardBinding]
    ) -> [UUID: CanvasLayoutFlowCardBinding] {
        var result: [UUID: CanvasLayoutFlowCardBinding] = [:]
        for binding in bindings where result[binding.nodeID] == nil {
            result[binding.nodeID] = binding
        }
        return result
    }
}
