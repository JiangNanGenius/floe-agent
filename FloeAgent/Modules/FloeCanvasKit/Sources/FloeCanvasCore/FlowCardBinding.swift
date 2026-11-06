import Foundation

/// Stable metadata keys binding a flow-visual card node to its flow
/// definition. A flow card is an ORDINARY `CanvasNodeSnapshot` (kind
/// `.generationTask`, content may be a text description) — group/region/
/// selection/lock/stroke/undo all stay on the one canvas object; no
/// parallel execution-view state is created. `FlowNode.id` and the canvas
/// node id are independent identities.
public enum CanvasFlowCardBindingKey {
    public static let graphID = "floe.flow.graphID"
    public static let nodeID = "floe.flow.nodeID"

    public static let all: Set<String> = [graphID, nodeID]

    public static func isBindingKey(_ key: String) -> Bool {
        all.contains(key)
    }
}

/// Locator from a flow-visual card node to (graph, flow node). This is a
/// VIEW binding only: it grants no execution or permission semantics.
public struct CanvasFlowCardBinding: Hashable, Sendable {
    public var graphID: UUID
    public var nodeID: UUID

    public init(graphID: UUID, nodeID: UUID) {
        self.graphID = graphID
        self.nodeID = nodeID
    }

    /// Reads the binding from node metadata. Returns nil when either key
    /// is absent or not a well-formed UUID — cards without these keys
    /// (every legacy generationTask) are ordinary nodes and stay fully
    /// compatible; malformed values are treated as unbound rather than
    /// breaking legacy reads.
    public init?(metadata: [String: String]) {
        guard let graphLiteral = metadata[CanvasFlowCardBindingKey.graphID],
              let graphID = UUID(uuidString: graphLiteral),
              let nodeLiteral = metadata[CanvasFlowCardBindingKey.nodeID],
              let nodeID = UUID(uuidString: nodeLiteral) else {
            return nil
        }
        self.init(graphID: graphID, nodeID: nodeID)
    }

    public func applied(to metadata: inout [String: String]) {
        metadata[CanvasFlowCardBindingKey.graphID] = graphID.uuidString
        metadata[CanvasFlowCardBindingKey.nodeID] = nodeID.uuidString
    }
}
