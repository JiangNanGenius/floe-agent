import Foundation
import FloeCanvasCore

/// Non-fatal diagnostics collected while a layout structure is built.
/// Layout never traps on malformed snapshots: every recoverable problem is
/// reported as an issue and the affected input is skipped deterministically.
public struct CanvasLayoutIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        /// Two nodes on the page share an ID; the first occurrence wins.
        case duplicateNodeID
        /// A node frame is non-finite or non-positive; the node is excluded
        /// from spatial queries.
        case degenerateNodeFrame
        /// Two connections share an ID; the first occurrence is routed.
        case duplicateConnectionID
        /// A connection references a missing endpoint; it is not routed.
        case danglingConnection
        /// A region frame is non-finite or non-positive; the region does not
        /// participate in containment or collapse.
        case degenerateRegionFrame
        /// Arrange was asked to place zero movable nodes.
        case emptyArrangeSelection
        /// Arrange selection covers only part of a group; the whole proposal
        /// is rejected because moving some members would move unselected ones.
        case partialGroupSelection
        /// Arrange selection touches a group that contains a locked member;
        /// the whole proposal is rejected.
        case groupLockedMember
        /// A flow node has no resolvable canvas frame; its ports are not laid out.
        case missingFlowNodeFrame
        /// A flow edge references a missing node or port; it is not routed.
        case malformedFlowLink
        /// World coordinates exceed `CanvasLayoutGeometry.safeWorldExtent`;
        /// the value is excluded from spatial structures so the diagram
        /// index's Int cell math can never trap.
        case coordinatesOutOfRange
        /// Two flow nodes share an ID; the first occurrence wins.
        case duplicateFlowNodeID
        /// Two flow edges share an ID; the first occurrence wins.
        case duplicateFlowEdgeID
        /// A flow node declares two ports with the same ID; the first wins.
        case duplicateFlowPortID
        /// A flow edge leaves an input port or enters an output port; the
        /// edge is not routed. Semantic validation stays with
        /// `FlowGraphValidator` — this is a layout-time refusal.
        case flowPortDirectionMismatch
        /// A flow edge connects incompatible port types (variadic accepts
        /// many edges, not any type); the edge is not routed here and the
        /// Flow compiler stays the execution authority.
        case flowPortTypeMismatch
    }

    public var code: Code
    public var nodeID: UUID?
    public var connectionID: UUID?
    public var regionID: UUID?
    public var flowEdgeID: UUID?
    public var detail: String?

    public init(
        code: Code,
        nodeID: UUID? = nil,
        connectionID: UUID? = nil,
        regionID: UUID? = nil,
        flowEdgeID: UUID? = nil,
        detail: String? = nil
    ) {
        self.code = code
        self.nodeID = nodeID
        self.connectionID = connectionID
        self.regionID = regionID
        self.flowEdgeID = flowEdgeID
        self.detail = detail
    }
}

/// Fatal layout failures. Inputs that would make geometry meaningless throw
/// before any structure is produced; arrange rejections carry every violated
/// rule so the host can explain the refusal in one pass.
public enum CanvasLayoutError: Error, Hashable, Sendable {
    /// A viewport transform or fit request used non-finite or out-of-range
    /// values.
    case invalidInput(String)
    /// A partial-arrange proposal was rejected; the array carries one issue
    /// per violated rule and no placement was produced.
    case arrangeRejected([CanvasLayoutIssue])
}
