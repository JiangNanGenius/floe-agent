// SPDX-License-Identifier: MIT
// SwiftDagre - A Swift port of @dagrejs/dagre

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Label attached to nodes for layout purposes
/// Contains both input dimensions and output coordinates
public final class DagreNodeLabel {
    // MARK: - Input properties (set before layout)

    /// Width of the node (required for layout)
    public var width: Double

    /// Height of the node (required for layout)
    public var height: Double

    // MARK: - Output properties (set by layout)

    /// X coordinate of node center (set by layout)
    public var x: Double = 0

    /// Y coordinate of node center (set by layout)
    public var y: Double = 0

    /// Rank (layer) assigned to this node
    public var rank: Int = 0

    /// Order within the rank
    public var order: Int = 0

    // MARK: - Internal layout properties

    /// True if this is a dummy node inserted for long edges
    var dummy: DummyType?

    /// For edge dummies: the original edge source
    var edgeSource: String?

    /// For edge dummies: the original edge target
    var edgeTarget: String?

    /// For edge dummies: the original edge name (multigraph)
    var edgeName: String?

    /// For edge-label dummies: label position (l, c, r)
    var labelpos: LabelPosition?

    /// For compound nodes: the parent node ID
    var parent: String?

    /// For border dummies: the border type
    var borderType: BorderType?

    /// For compound nodes: minimum rank of children
    var minRank: Int?

    /// For compound nodes: maximum rank of children
    var maxRank: Int?

    /// For compound nodes: left border nodes by rank (from addBorderSegments)
    var borderLeft: [Int: String] = [:]

    /// For compound nodes: right border nodes by rank (from addBorderSegments)
    var borderRight: [Int: String] = [:]

    /// For compound nodes: top border node ID (from nesting-graph)
    var borderTop: String?

    /// For compound nodes: bottom border node ID (from nesting-graph)
    var borderBottom: String?

    /// Padding around the node
    var paddingLeft: Double = 0
    var paddingRight: Double = 0
    var paddingTop: Double = 0
    var paddingBottom: Double = 0

    /// Low value for network simplex (postorder number)
    var low: Int = 0

    /// Lim value for network simplex (postorder number)
    var lim: Int = 0

    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }

    #if canImport(CoreGraphics)
    public init(size: CGSize) {
        self.width = size.width
        self.height = size.height
    }
    #endif

    /// For edge-proxy dummies: reference to the original edge (v, w, name)
    var edgeRef: (v: String, w: String, name: String?)?

    /// For edge dummies: reference to the original edge label
    /// Used during denormalization to preserve label properties
    var edgeLabel: DagreEdgeLabel?

    /// For edge dummies: reference to the original edge object (v, w, name)
    /// Used during denormalization to restore the edge
    var edgeObj: (v: String, w: String, name: String?)?

    /// Type of dummy node
    enum DummyType: String {
        case edge = "edge"
        case edgeLabel = "edge-label"
        case edgeProxy = "edge-proxy"
        case border = "border"
        case root = "root"
        case selfedge = "selfedge"
    }

    /// Edge label position
    public enum LabelPosition: String {
        case left = "l"
        case center = "c"
        case right = "r"
    }

    /// Border node type
    enum BorderType: String {
        case top = "borderTop"
        case bottom = "borderBottom"
        case left = "borderLeft"
        case right = "borderRight"
    }
}

/// Label attached to edges for layout purposes
public final class DagreEdgeLabel {
    // MARK: - Input properties

    /// Minimum edge length in ranks (default: 1)
    public var minlen: Int = 1

    /// Edge weight for crossing minimization (default: 1)
    public var weight: Int = 1

    /// Width of edge label (if any)
    public var width: Double = 0

    /// Height of edge label (if any)
    public var height: Double = 0

    /// Label position: l (left), c (center), r (right)
    public var labelpos: DagreNodeLabel.LabelPosition = .center

    /// Offset of label from edge
    public var labeloffset: Double = 10

    // MARK: - Output properties

    /// Points along the edge path (set by layout)
    public var points: [Point] = []

    /// X coordinate of edge label (set by layout)
    public var x: Double = 0

    /// Y coordinate of edge label (set by layout)
    public var y: Double = 0

    /// True if x/y coordinates have been explicitly set (matches TypeScript Object.hasOwn check)
    var hasLabelPosition: Bool = false

    // MARK: - Internal properties

    /// True if edge was reversed for acyclic layout
    var reversed: Bool = false

    /// Original edge name before reversal
    var forwardName: String?

    /// For dummy edge chain: reference to next dummy
    var next: String?

    /// Rank for edge label positioning (set by removeEdgeLabelProxies)
    var labelRank: Int?

    /// True if this is a nesting edge created by NestingGraph (for cleanup)
    var nestingEdge: Bool = false

    public init(minlen: Int = 1, weight: Int = 1) {
        self.minlen = minlen
        self.weight = weight
    }

    /// A 2D point
    public struct Point: Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }

        #if canImport(CoreGraphics)
        public init(_ point: CGPoint) {
            self.x = point.x
            self.y = point.y
        }

        public var cgPoint: CGPoint {
            CGPoint(x: x, y: y)
        }
        #endif
    }
}

/// Graph-level layout options
public final class LayoutOptions {
    /// Direction of graph layout
    public var rankdir: RankDirection = .topBottom

    /// Alignment of nodes within ranks
    public var align: Alignment?

    /// Horizontal separation between nodes
    public var nodesep: Double = 50

    /// Separation between adjacent edge segments
    public var edgesep: Double = 20

    /// Vertical separation between ranks
    public var ranksep: Double = 50

    /// Horizontal margin around the graph
    public var marginx: Double = 0

    /// Vertical margin around the graph
    public var marginy: Double = 0

    /// Ranking algorithm to use
    public var ranker: RankingAlgorithm = .networkSimplex

    /// Custom ranking function (if provided, overrides ranker algorithm)
    /// Matches TypeScript: if (ranker instanceof Function) { return ranker(g); }
    public var customRanker: ((DagreGraph) -> Void)?

    /// Acyclic algorithm to use (greedy matches TypeScript dagre default)
    public var acyclicer: AcyclicAlgorithm = .greedy

    /// Custom order function (if provided, overrides order heuristic)
    /// Matches TypeScript: if (opts && typeof opts.customOrder === 'function') { opts.customOrder(g, order); return; }
    public var customOrder: ((DagreGraph, [[String]]) -> Void)?

    /// Width of graph (output, set by layout)
    public var width: Double = 0

    /// Height of graph (output, set by layout)
    public var height: Double = 0

    /// Node rank factor for preserving intermediate ranks
    /// Set by NestingGraph.run() - determines which empty ranks to preserve
    /// With nodeRankFactor=1 (default), NO empty ranks are removed
    /// Matches TypeScript g.graph().nodeRankFactor
    var nodeRankFactor: Int = 1

    public init() {}

    public enum RankDirection: String {
        case topBottom = "TB"
        case bottomTop = "BT"
        case leftRight = "LR"
        case rightLeft = "RL"
    }

    public enum Alignment: String {
        case upLeft = "UL"
        case upRight = "UR"
        case downLeft = "DL"
        case downRight = "DR"
    }

    public enum RankingAlgorithm: String {
        case networkSimplex = "network-simplex"
        case tightTree = "tight-tree"
        case longestPath = "longest-path"
        /// Skip ranking entirely - assumes ranks are already assigned
        case none = "none"
    }

    public enum AcyclicAlgorithm: String {
        case dfs = "dfs"
        case greedy = "greedy"
    }
}

/// Type alias for the dagre graph type
public typealias DagreGraph = Graph<DagreNodeLabel, DagreEdgeLabel>
