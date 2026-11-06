import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramLayout

/// How a prepared node participates in presentation.
public enum CanvasNodeVisibility: String, Codable, Hashable, Sendable {
    /// Rendered normally.
    case visible
    /// Inside a collapsed region; rendered only through the region proxy.
    case hiddenByCollapse
}

/// A node prepared for layout queries. Geometry is world-space; rotation is
/// folded into `frame` (axis-aligned bounds) while the original rotation is
/// kept for rendering.
public struct CanvasPreparedNode: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// Axis-aligned world bounds (rotation applied).
    public var frame: DiagramRect
    /// Unrotated world bounds.
    public var unrotatedFrame: DiagramRect
    public var rotationDegrees: Double
    public var zIndex: Int
    public var isLocked: Bool
    public var kind: CanvasNodeKind
    public var groupID: UUID?
    /// Innermost region whose geometry contains this node's center.
    public var regionID: UUID?
    public var visibility: CanvasNodeVisibility
    /// The node itself when visible; otherwise the visible collapsed region
    /// proxy standing in for it (never a hidden inner region).
    public var representativeID: UUID
    /// Position in the source page's node array; breaks z-order ties.
    public var order: Int
    /// True when the node carries heavyweight content (media/PDF/web/3D) and
    /// should be replaced by a lightweight preview at low zoom.
    public var isHeavyweight: Bool

    public var isVisible: Bool { visibility == .visible }
}

/// A region prepared for layout queries. Only VISIBLE regions are exposed:
/// expanded regions and collapsed region chips that are not themselves inside
/// another collapsed region. Regions hidden by an outer collapse are omitted.
public struct CanvasPreparedRegion: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// World bounds (chip frame when collapsed, container frame when expanded).
    public var frame: DiagramRect
    public var isCollapsed: Bool

    public var isVisible: Bool { true }
}

/// What a hit test found: nodes take precedence over regions at the same
/// point; among regions the smallest (innermost) frame wins.
public enum CanvasHitTarget: Sendable, Hashable {
    case node(CanvasPreparedNode)
    case region(CanvasPreparedRegion)

    public var id: UUID {
        switch self {
        case .node(let node): node.id
        case .region(let region): region.id
        }
    }
}

/// An external connection surviving collapse: endpoints are the visible
/// representatives (a node or a visible collapsed region proxy). Connections
/// internal to one collapsed representative are omitted.
public struct CanvasProxyEdge: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var destinationID: UUID
    public var kind: CanvasRelationKind
    public var label: String?
    /// True when at least one endpoint was replaced by a region proxy.
    public var isProxy: Bool
}

/// Immutable, reusable page index for viewport / hit / lasso / nearby queries.
///
/// Build once per snapshot revision (an explicit boundary after edits), then
/// answer pan/zoom queries from spatial indexes — never O(all N) scans per
/// pan, never rebuilding per query. Query cost is proportional to the
/// candidate count. All results are deterministic: render order sorts by
/// (zIndex, source order); hit tests break ties the same way and prefer the
/// topmost target; region overlaps resolve by smallest area, then ID.
///
/// Coordinate safety: world coordinates beyond
/// `CanvasLayoutGeometry.safeWorldExtent` are refused with a diagnostic at
/// build time and never reach the diagram spatial index (whose Int cell math
/// would otherwise trap on huge finite values). Queries with out-of-range or
/// degenerate rects return empty instead of trapping.
public struct CanvasPageLayoutIndex: Sendable {
    public let pageID: UUID
    /// Visible prepared nodes in render order (zIndex ascending, then source
    /// order ascending).
    public let nodes: [CanvasPreparedNode]
    /// Visible regions (expanded containers and visible collapsed chips),
    /// outermost first (area descending, then ID).
    public let regions: [CanvasPreparedRegion]
    /// Diagnostics collected while building; malformed inputs never trap.
    public let issues: [CanvasLayoutIssue]
    /// Union of visible node frames and visible region frames; at least 1×1
    /// at the origin when nothing is visible (useful as a fit fallback).
    public let bounds: DiagramRect
    /// Frames of VISIBLE regions only (hidden inner regions are not exposed).
    public let regionFrames: [UUID: DiagramRect]
    /// IDs of visible collapsed region chips.
    public let collapsedRegionIDs: Set<UUID>
    /// External connections after collapse resolution, in source order.
    public let proxyEdges: [CanvasProxyEdge]
    /// Count of connections omitted because both endpoints collapsed into the
    /// same representative (kept for diagnostics and tests).
    public let hiddenConnectionCount: Int
    /// Flow port anchors keyed by FLOW node ID (present only when a flow
    /// graph was supplied at build time). Positions follow the display
    /// frames in `flowDisplayFrames`.
    public let flowPortAnchors: [UUID: [CanvasFlowPortAnchor]]
    /// Flow visual card bindings read from canvas card metadata (fixed
    /// `floe.flow.*` keys), present only when a flow graph was supplied.
    public let flowCardBindings: [CanvasLayoutFlowCardBinding]
    /// Display frames keyed by FLOW node ID, resolved through bindings: a
    /// bound card uses the real canvas node's frame (or its visible region
    /// chip when collapsed), an unbound node falls back to a display-only
    /// card at `FlowNode.position`. Grouping/collapse/lock of the real
    /// canvas card governs the flow display through this mapping.
    public let flowDisplayFrames: [UUID: DiagramRect]
    /// FLOW node ID → visible display endpoint ID (a visible region chip ID
    /// when the bound card is collapsed, the flow node ID otherwise). Flow
    /// edge proxies follow this mapping; real flow identity never changes.
    public let flowDisplayRepresentatives: [UUID: UUID]

    private let nodeSpatial: DiagramSpatialIndex
    private let regionSpatial: DiagramSpatialIndex
    private let nodeByID: [UUID: CanvasPreparedNode]
    private let regionByID: [UUID: CanvasPreparedRegion]
    private let nodeIDsByRegionID: [UUID: [UUID]]
    private let allPreparedNodes: [CanvasPreparedNode]
    private let allValidNodeIDs: Set<UUID>

    /// Builds the prepared index for one page. Throws `CancellationError`
    /// when the calling task is cancelled; throws nothing else.
    public init(page: CanvasPageSnapshot, flowGraph: FlowGraph? = nil) throws {
        try Task.checkCancellation()
        var issues: [CanvasLayoutIssue] = []

        // MARK: Regions (before nodes: containment needs region frames)
        var regionFrames: [UUID: DiagramRect] = [:]
        var regionNames: [UUID: String] = [:]
        for region in page.regions {
            let rect = CanvasLayoutGeometry.rect(from: region.frame)
            guard CanvasLayoutGeometry.isFinitePositiveRect(rect) else {
                issues.append(.init(
                    code: .degenerateRegionFrame, regionID: region.id,
                    detail: "region frame is non-finite or non-positive"))
                continue
            }
            guard CanvasLayoutGeometry.isSafeWorldRect(rect) else {
                issues.append(.init(
                    code: .coordinatesOutOfRange, regionID: region.id,
                    detail: "region exceeds safe world extent/span"))
                continue
            }
            regionFrames[region.id] = rect
            regionNames[region.id] = region.name
        }

        // MARK: Nodes
        var seenIDs: Set<UUID> = []
        var prepared: [CanvasPreparedNode] = []
        var nodeIDsByRegionID: [UUID: [UUID]] = [:]
        var allValidNodeIDs: Set<UUID> = []
        for (order, node) in page.nodes.enumerated() {
            try Task.checkCancellation()
            if !seenIDs.insert(node.id).inserted {
                issues.append(.init(
                    code: .duplicateNodeID, nodeID: node.id,
                    detail: "first occurrence wins; later duplicates ignored"))
                continue
            }
            let unrotated = CanvasLayoutGeometry.rect(from: node.frame)
            let rotated = CanvasLayoutGeometry.rotatedBounds(
                node.frame, rotationDegrees: node.rotationDegrees)
            guard CanvasLayoutGeometry.isFinitePositiveRect(unrotated),
                  CanvasLayoutGeometry.isFinitePositiveRect(rotated) else {
                issues.append(.init(
                    code: .degenerateNodeFrame, nodeID: node.id,
                    detail: "frame is non-finite or non-positive"))
                continue
            }
            guard CanvasLayoutGeometry.isSafeWorldRect(unrotated),
                  CanvasLayoutGeometry.isSafeWorldRect(rotated) else {
                issues.append(.init(
                    code: .coordinatesOutOfRange, nodeID: node.id,
                    detail: "node exceeds safe world extent/span"))
                continue
            }
            allValidNodeIDs.insert(node.id)
            let containingRegions = regionFrames
                .filter { $0.value.contains(unrotated.center) }
                .map { (id: $0.key, rect: $0.value) }
            let regionID = CanvasLayoutGeometry.innermostRegion(
                containing: unrotated.center, among: containingRegions)
            if let regionID {
                nodeIDsByRegionID[regionID, default: []].append(node.id)
            }
            prepared.append(CanvasPreparedNode(
                id: node.id,
                frame: rotated,
                unrotatedFrame: unrotated,
                rotationDegrees: node.rotationDegrees,
                zIndex: node.zIndex,
                isLocked: node.isLocked,
                kind: node.kind,
                groupID: node.groupID,
                regionID: regionID,
                visibility: .visible,
                representativeID: node.id,
                order: order,
                isHeavyweight: CanvasPageLayoutIndex.isHeavyweight(node)))
        }

        // MARK: Region visibility under collapse
        // A collapsed region's chip is visible only when no OTHER collapsed
        // region contains it. Nested collapsed inners are hidden: their space
        // is folded into the outermost visible chip, which alone carries
        // external connections. Overlapping non-nested collapsed regions are
        // all visible; endpoint resolution picks the smallest chip, then ID.
        let collapsedCandidates = Set(
            page.regions.filter(\.isCollapsed).map(\.id)
        ).intersection(regionFrames.keys)
        func isNestedInOtherCollapsed(_ id: UUID) -> Bool {
            guard let center = regionFrames[id]?.center else { return true }
            return collapsedCandidates.contains { other in
                other != id && (regionFrames[other]?.contains(center) ?? false)
            }
        }
        let visibleCollapsed = collapsedCandidates.filter { !isNestedInOtherCollapsed($0) }
        let hiddenRegions = Set(regionFrames.keys).filter { id in
            guard let center = regionFrames[id]?.center else { return true }
            return collapsedCandidates.contains { other in
                other != id && (regionFrames[other]?.contains(center) ?? false)
            }
        }
        let visibleRegionIDs = Set(regionFrames.keys).subtracting(hiddenRegions)

        // MARK: Collapse resolution: outermost VISIBLE collapsed ancestor
        var resolved: [CanvasPreparedNode] = []
        var representativeByNodeID: [UUID: UUID] = [:]
        for node in prepared {
            let containingRegions = regionFrames
                .filter { $0.value.contains(node.unrotatedFrame.center) }
                .map { (id: $0.key, rect: $0.value) }
            // Innermost among VISIBLE collapsed regions == the outermost
            // visible collapsed ancestor for nested collapse, and the
            // smallest-area rule for overlapping non-nested regions.
            let visibleCollapsedContaining = containingRegions
                .filter { visibleCollapsed.contains($0.id) }
            let representative = CanvasLayoutGeometry.innermostRegion(
                containing: node.unrotatedFrame.center,
                among: visibleCollapsedContaining)
            if let representative {
                var hidden = node
                hidden.visibility = .hiddenByCollapse
                hidden.representativeID = representative
                representativeByNodeID[node.id] = representative
                resolved.append(hidden)
            } else {
                representativeByNodeID[node.id] = node.id
                resolved.append(node)
            }
        }
        let visibleNodes = resolved.filter(\.isVisible).sorted {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.order < $1.order
        }

        // MARK: Visible region list (outermost first) and region spatial index
        let visibleRegions: [CanvasPreparedRegion] = visibleRegionIDs
            .compactMap { id in
                guard let frame = regionFrames[id] else { return nil }
                return CanvasPreparedRegion(
                    id: id,
                    name: regionNames[id] ?? "",
                    frame: frame,
                    isCollapsed: collapsedCandidates.contains(id))
            }
            .sorted {
                let areaA = $0.frame.width * $0.frame.height
                let areaB = $1.frame.width * $1.frame.height
                if areaA != areaB { return areaA > areaB }
                return $0.id.uuidString < $1.id.uuidString
            }
        let visibleRegionFrames = Dictionary(
            uniqueKeysWithValues: visibleRegions.map { ($0.id, $0.frame) })

        // MARK: Spatial indexes (visible content only)
        let nodeFrames = Dictionary(
            uniqueKeysWithValues: visibleNodes.map { ($0.id, $0.frame) })
        let nodeSpatial = DiagramSpatialIndex(frames: nodeFrames)
        let regionSpatial = DiagramSpatialIndex(frames: visibleRegionFrames)

        // MARK: Connection collapse routing
        var connectionIDs: Set<UUID> = []
        var proxyEdges: [CanvasProxyEdge] = []
        var hiddenConnectionCount = 0
        for connection in page.connections {
            try Task.checkCancellation()
            if !connectionIDs.insert(connection.id).inserted {
                issues.append(.init(
                    code: .duplicateConnectionID, connectionID: connection.id,
                    detail: "first occurrence is routed; later duplicates ignored"))
                continue
            }
            let sourceValid = allValidNodeIDs.contains(connection.sourceNodeID)
            let destinationValid = allValidNodeIDs.contains(connection.destinationNodeID)
            guard sourceValid, destinationValid else {
                issues.append(.init(
                    code: .danglingConnection, connectionID: connection.id,
                    detail: "endpoint missing from page"))
                continue
            }
            let source = representativeByNodeID[connection.sourceNodeID]
                ?? connection.sourceNodeID
            let destination = representativeByNodeID[connection.destinationNodeID]
                ?? connection.destinationNodeID
            // Hide only edges that became internal through collapse. A
            // self-loop between two visible nodes is a legitimate relation
            // and survives.
            let sourceCollapsed = source != connection.sourceNodeID
            let destinationCollapsed = destination != connection.destinationNodeID
            if source == destination, sourceCollapsed || destinationCollapsed {
                hiddenConnectionCount += 1
                continue
            }
            proxyEdges.append(CanvasProxyEdge(
                id: connection.id,
                sourceID: source,
                destinationID: destination,
                kind: connection.kind,
                label: connection.label,
                isProxy: sourceCollapsed || destinationCollapsed))
        }

        // MARK: Bounds over visible nodes AND visible region frames
        let contentFrames = Array(nodeFrames.values) + Array(visibleRegionFrames.values)
        let bounds = contentFrames.reduce(nil as DiagramRect?) {
            $0?.union($1) ?? $1
        } ?? DiagramRect(x: 0, y: 0, width: 1, height: 1)

        // MARK: Flow display resolution through card bindings (optional input)
        // Bound flow nodes display through their REAL canvas card: grouping,
        // collapse and lock of the canvas node govern the flow presentation.
        // Unbound flow nodes get a display-only fallback frame at
        // FlowNode.position — never persisted, never a second card set.
        let flowAnchors: [UUID: [CanvasFlowPortAnchor]]
        let flowBindings: [CanvasLayoutFlowCardBinding]
        let flowFrames: [UUID: DiagramRect]
        let flowReps: [UUID: UUID]
        if let flowGraph {
            flowBindings = CanvasFlowCardBindingReader.bindings(from: page.nodes)
            let bindingByFlowNode = CanvasFlowCardBindingReader.bindingByFlowNodeID(
                from: flowBindings)
            let preparedByID = Dictionary(
                uniqueKeysWithValues: prepared.map { ($0.id, $0) })
            var resolvedFrames: [UUID: DiagramRect] = [:]
            var resolvedReps: [UUID: UUID] = [:]
            for flowNode in flowGraph.nodes {
                let displayID: UUID
                let frame: DiagramRect
                if let binding = bindingByFlowNode[flowNode.id],
                   let card = preparedByID[binding.cardNodeID] {
                    let representative = representativeByNodeID[card.id] ?? card.id
                    displayID = representative
                    if representative == card.id {
                        frame = card.unrotatedFrame
                    } else {
                        // Collapsed card: the visible region chip is the
                        // display surface for routing endpoints.
                        frame = visibleRegionFrames[representative] ?? card.unrotatedFrame
                    }
                } else {
                    displayID = flowNode.id
                    frame = CanvasFlowEdgeLayout.defaultFrame(for: flowNode)
                }
                resolvedReps[flowNode.id] = displayID
                if CanvasLayoutGeometry.isSafeWorldRect(frame) {
                    resolvedFrames[flowNode.id] = frame
                }
            }
            flowFrames = resolvedFrames
            flowReps = resolvedReps
            flowAnchors = CanvasFlowEdgeLayout.anchors(
                for: flowGraph, nodeFrames: resolvedFrames)
        } else {
            flowAnchors = [:]
            flowBindings = []
            flowFrames = [:]
            flowReps = [:]
        }

        self.pageID = page.id
        self.nodes = visibleNodes
        self.regions = visibleRegions
        self.issues = issues
        self.bounds = bounds
        self.regionFrames = visibleRegionFrames
        self.collapsedRegionIDs = visibleCollapsed
        self.proxyEdges = proxyEdges
        self.hiddenConnectionCount = hiddenConnectionCount
        self.flowPortAnchors = flowAnchors
        self.flowCardBindings = flowBindings
        self.flowDisplayFrames = flowFrames
        self.flowDisplayRepresentatives = flowReps
        self.nodeSpatial = nodeSpatial
        self.regionSpatial = regionSpatial
        self.nodeByID = Dictionary(uniqueKeysWithValues: visibleNodes.map { ($0.id, $0) })
        self.regionByID = Dictionary(uniqueKeysWithValues: visibleRegions.map { ($0.id, $0) })
        self.nodeIDsByRegionID = nodeIDsByRegionID
        self.allPreparedNodes = prepared
        self.allValidNodeIDs = allValidNodeIDs
    }

    private static func isHeavyweight(_ node: CanvasNodeSnapshot) -> Bool {
        if node.kind == .scene3D { return true }
        switch node.content {
        case .media, .pdf, .web, .editor:
            return true
        default:
            return false
        }
    }

    // MARK: Queries

    /// Resolves spatial candidates straight from the ID set — query cost is
    /// proportional to the candidate count, never to the page size — and
    /// restores render order deterministically.
    private func preparedNodes(for ids: Set<UUID>) -> [CanvasPreparedNode] {
        ids.compactMap { nodeByID[$0] }.sorted {
            if $0.zIndex != $1.zIndex { return $0.zIndex < $1.zIndex }
            return $0.order < $1.order
        }
    }

    /// Nodes whose bounds intersect the world rect, expanded by `overscan`
    /// on every side. Results keep render order.
    public func visibleNodes(in rect: DiagramRect, overscan: Double = 64) -> [CanvasPreparedNode] {
        let padded = rect.insetBy(-max(0, overscan))
        guard CanvasLayoutGeometry.isSafeQueryRect(padded) else { return [] }
        return preparedNodes(for: nodeSpatial.query(padded))
    }

    /// Visible regions whose frames intersect the world rect plus overscan.
    public func visibleRegions(
        in rect: DiagramRect,
        overscan: Double = 64
    ) -> [CanvasPreparedRegion] {
        let padded = rect.insetBy(-max(0, overscan))
        guard CanvasLayoutGeometry.isSafeQueryRect(padded) else { return [] }
        return regionSpatial.query(padded)
            .compactMap { regionByID[$0] }
            .sorted {
                let areaA = $0.frame.width * $0.frame.height
                let areaB = $1.frame.width * $1.frame.height
                if areaA != areaB { return areaA > areaB }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    /// Deterministic topmost hit test with a constant SCREEN-space target:
    /// `screenTolerance` is measured in screen points and converted to
    /// world units with the actual viewport relation
    /// `view = (world - center) * scale + viewCenter` (one world unit is
    /// `zoom` screen points), so
    /// `worldTolerance = screenTolerance / max(0.05, zoom)` — the same
    /// conversion as `CanvasViewportTransform.worldHitTolerance` and
    /// `CanvasFlowPortAnchor.hitBounds`. A 2pt finger target is therefore
    /// 4 world units at zoom 0.5 and 0.25 world units at zoom 8, keeping
    /// the on-screen hit size invariant at any zoom.
    ///
    /// `screenTolerance == 0` performs an exact point hit (frame
    /// containment, no expansion); the candidate probe stays non-zero so
    /// the spatial index still returns the owning cell's candidates.
    /// Non-finite points, non-finite or negative zoom/tolerance refuse
    /// safely with nil. Nodes take precedence over regions; ties break on
    /// (zIndex, source order) for nodes and (area ascending, ID) for
    /// regions.
    public func hitTest(
        _ point: DiagramPoint,
        zoom: Double = 1,
        screenTolerance: Double = 2
    ) -> CanvasHitTarget? {
        guard point.isFinite else { return nil }
        guard zoom.isFinite, zoom > 0, screenTolerance.isFinite, screenTolerance >= 0 else {
            return nil
        }
        let tolerance = screenTolerance / max(0.05, zoom)
        // Candidate probe radius: the tolerance when positive, else a small
        // non-zero radius so a zero-tolerance (exact) hit still reaches the
        // spatial index; containment below stays exact.
        let probeRadius = max(tolerance, 0.5)
        let probe = DiagramRect(
            x: point.x - probeRadius, y: point.y - probeRadius,
            width: probeRadius * 2, height: probeRadius * 2)
        guard CanvasLayoutGeometry.isSafeQueryRect(probe) else { return nil }
        let expandedContains = { (frame: DiagramRect) -> Bool in
            tolerance == 0
                ? frame.contains(point)
                : frame.insetBy(-tolerance).contains(point)
        }
        if let node = preparedNodes(for: nodeSpatial.query(probe))
            .filter({ expandedContains($0.frame) })
            .last {
            return .node(node)
        }
        return regionSpatial.query(probe)
            .compactMap { regionByID[$0] }
            .filter { expandedContains($0.frame) }
            .sorted {
                let areaA = $0.frame.width * $0.frame.height
                let areaB = $1.frame.width * $1.frame.height
                if areaA != areaB { return areaA < areaB }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first
            .map { .region($0) }
    }

    /// Marquee selection: visible nodes intersecting the rect (any overlap).
    public func lasso(_ rect: DiagramRect) -> [CanvasPreparedNode] {
        guard CanvasLayoutGeometry.isSafeQueryRect(rect) else { return [] }
        return preparedNodes(for: nodeSpatial.query(rect))
    }

    /// Visible nodes whose centers lie within `radius` world units of the
    /// point, nearest first; ties break on render order.
    public func nearby(
        to point: DiagramPoint,
        radius: Double
    ) -> [CanvasPreparedNode] {
        guard point.isFinite, radius > 0 else { return [] }
        let probe = DiagramRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2)
        guard CanvasLayoutGeometry.isSafeQueryRect(probe) else { return [] }
        return preparedNodes(for: nodeSpatial.query(probe))
            .map { node in
                (node: node, distance: hypot(
                    node.frame.center.x - point.x,
                    node.frame.center.y - point.y))
            }
            .filter { $0.distance <= radius }
            .sorted {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.node.zIndex != $1.node.zIndex {
                    return $0.node.zIndex < $1.node.zIndex
                }
                return $0.node.order < $1.node.order
            }
            .map(\.node)
    }

    public func node(id: UUID) -> CanvasPreparedNode? { nodeByID[id] }

    public func region(id: UUID) -> CanvasPreparedRegion? { regionByID[id] }

    /// Nodes whose INNERMOST region is `regionID` — direct membership only.
    public func nodeIDs(innermostInRegion regionID: UUID) -> [UUID] {
        nodeIDsByRegionID[regionID] ?? []
    }

    /// Nodes geometrically contained in the region (center containment),
    /// INCLUDING members of nested inner regions — this is the set a partial
    /// arrange of an outer region should cover. Source order, deterministic.
    public func nodeIDs(containedInRegion regionID: UUID) -> [UUID] {
        guard let frame = regionFrames[regionID] else { return [] }
        return allPreparedNodes
            .filter { frame.contains($0.unrotatedFrame.center) }
            .sorted { $0.order < $1.order }
            .map(\.id)
    }

    /// Direct child regions whose center is inside this region, sorted by
    /// (area ascending, ID). Nesting is directional: a child must be
    /// strictly smaller than its parent, so concentric or mutually
    /// containing same-size regions never form cycles.
    public func nestedRegionIDs(of regionID: UUID) -> [UUID] {
        guard let frame = regionFrames[regionID] else { return [] }
        let parentArea = frame.width * frame.height
        return regions
            .filter {
                $0.id != regionID
                    && $0.frame.width * $0.frame.height < parentArea
                    && frame.contains($0.frame.center)
            }
            .sorted {
                let areaA = $0.frame.width * $0.frame.height
                let areaB = $1.frame.width * $1.frame.height
                if areaA != areaB { return areaA < areaB }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)
    }

    /// Nested region closure (direct + transitive) in deterministic BFS
    /// order, innermost-last by containment depth.
    public func descendantRegionIDs(of regionID: UUID) -> [UUID] {
        var found: [UUID] = []
        var queue = nestedRegionIDs(of: regionID)
        var index = 0
        found.append(contentsOf: queue)
        while index < queue.count {
            let current = queue[index]
            index += 1
            for child in nestedRegionIDs(of: current) where !found.contains(child) {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    public func containsNode(id: UUID) -> Bool { allValidNodeIDs.contains(id) }

    /// Flow port anchor for a port laid out at build time, if any.
    public func flowPortAnchor(nodeID: UUID, portID: UUID) -> CanvasFlowPortAnchor? {
        flowPortAnchors[nodeID]?.first(where: { $0.id == portID })
    }
}
