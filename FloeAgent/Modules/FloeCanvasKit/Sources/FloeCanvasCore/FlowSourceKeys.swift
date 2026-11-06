import Foundation

/// Stable parameter keys for typed input-source flow nodes (P0.1). Source
/// cards feed flows through `.source` flow nodes whose parameters LOCATE
/// canvas content. A locator is never permission: these keys identify which
/// canvas/page/node revision a flow input reads, they grant no tool or
/// document authority. Flow runtimes resolve the locator at execution time
/// through the host's normal services.
public enum CanvasFlowSourceParameterKey {
    public static let canvasID = "floecanvas.source.canvasID"
    public static let pageID = "floecanvas.source.pageID"
    public static let nodeID = "floecanvas.source.nodeID"
    public static let usedRevision = "floecanvas.source.usedRevision"
}

/// Typed value for a canvas-bound flow source locator.
public struct CanvasFlowSourceBinding: Hashable, Sendable {
    public var canvasID: UUID
    public var pageID: UUID
    public var nodeID: UUID
    public var usedRevision: Int64

    public init(
        canvasID: UUID,
        pageID: UUID,
        nodeID: UUID,
        usedRevision: Int64
    ) {
        self.canvasID = canvasID
        self.pageID = pageID
        self.nodeID = nodeID
        self.usedRevision = usedRevision
    }

    /// Parameter dictionary for a `.source` flow node.
    public func parameters() -> [String: JSONValue] {
        [
            CanvasFlowSourceParameterKey.canvasID: .string(canvasID.uuidString),
            CanvasFlowSourceParameterKey.pageID: .string(pageID.uuidString),
            CanvasFlowSourceParameterKey.nodeID: .string(nodeID.uuidString),
            CanvasFlowSourceParameterKey.usedRevision:
                .number("\(usedRevision)"),
        ]
    }

    /// Parses a binding from flow-node parameters. Returns nil when the
    /// parameters do not carry a complete, well-formed canvas locator
    /// (nodes with no locator are ordinary literal/host sources).
    public init?(parameters: [String: JSONValue]) {
        guard let canvasLiteral = parameters[
            CanvasFlowSourceParameterKey.canvasID]?.stringValue,
            let canvasID = UUID(uuidString: canvasLiteral),
            let pageLiteral = parameters[
                CanvasFlowSourceParameterKey.pageID]?.stringValue,
            let pageID = UUID(uuidString: pageLiteral),
            let nodeLiteral = parameters[
                CanvasFlowSourceParameterKey.nodeID]?.stringValue,
            let nodeID = UUID(uuidString: nodeLiteral) else {
            return nil
        }
        let revision = parameters[
            CanvasFlowSourceParameterKey.usedRevision]?.numberLiteral
            .flatMap(Int64.init) ?? 0
        self.init(
            canvasID: canvasID, pageID: pageID, nodeID: nodeID,
            usedRevision: revision)
    }
}
