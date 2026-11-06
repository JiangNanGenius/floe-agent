import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramLayout

/// World-space anchor of one typed flow port. Input ports sit on the leading
/// edge, output ports on the trailing edge, distributed along the edge in
/// DECLARATION ORDER (the order ports appear on `FlowNode.ports`), so the
/// visual row order matches the editor's semantic order and never reorders
/// by random UUID.
public struct CanvasFlowPortAnchor: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var nodeID: UUID
    public var position: DiagramPoint
    /// Outward direction of the port for edge routing.
    public var outward: CanvasConnectionPort

    /// Axis-aligned square hit bounds in world units for a constant screen
    /// target: `screenSize / zoom` on each side, centered on the port.
    public func hitBounds(zoom: Double, screenSize: Double = 16) -> DiagramRect {
        let side = max(4, screenSize) / max(0.05, zoom)
        return DiagramRect(
            x: position.x - side / 2, y: position.y - side / 2,
            width: side, height: side)
    }
}

/// Routed geometry of one executable `FlowEdge`. Display endpoints may be
/// re-pointed at collapsed region proxies, but `sourceNodeID`,
/// `destinationNodeID` and the port IDs always carry the REAL flow identity —
/// proxies never rewrite what a run actually connected.
public struct CanvasFlowEdgeGeometry: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var geometry: DiagramEdgeGeometry
    public var sourceNodeID: UUID
    public var destinationNodeID: UUID
    public var sourcePortID: UUID
    public var destinationPortID: UUID
    /// True when a display endpoint was replaced by a collapsed region chip.
    public var isProxy: Bool
}

public enum CanvasFlowEdgeLayout {
    /// Display-only fallback card for a flow node with NO binding: a
    /// 200×100 card centered at `FlowNode.position`. This is never persisted
    /// and never manufactures a second set of cards — it exists only so an
    /// unbound flow node can still be laid out on screen. When a binding
    /// exists the bound canvas card's frame wins and this is not used.
    public static func defaultFrame(
        for node: FlowNode,
        cardSize: DiagramSize = .init(width: 200, height: 100)
    ) -> DiagramRect {
        DiagramRect(
            x: node.position.x - cardSize.width / 2,
            y: node.position.y - cardSize.height / 2,
            width: cardSize.width,
            height: cardSize.height)
    }

    /// Deterministic port anchors for every flow node that has an in-range
    /// display frame. Ports are processed in declaration order; duplicate
    /// port IDs keep the first occurrence.
    public static func anchors(
        for flowGraph: FlowGraph,
        nodeFrames: [UUID: DiagramRect]
    ) -> [UUID: [CanvasFlowPortAnchor]] {
        var result: [UUID: [CanvasFlowPortAnchor]] = [:]
        for node in flowGraph.nodes {
            // First occurrence wins, matching routeEdges' node de-dup: a
            // duplicate-id twin must never clobber the kept node's anchors
            // with an empty (or different) port list.
            guard result[node.id] == nil else { continue }
            guard let frame = nodeFrames[node.id],
                  CanvasLayoutGeometry.isSafeWorldRect(frame) else { continue }
            var seenPortIDs: Set<UUID> = []
            var inputs: [FlowPort] = []
            var outputs: [FlowPort] = []
            for port in node.ports where seenPortIDs.insert(port.id).inserted {
                if port.direction == .input { inputs.append(port) }
                else { outputs.append(port) }
            }
            var anchors: [CanvasFlowPortAnchor] = []
            anchors.reserveCapacity(inputs.count + outputs.count)
            for (index, port) in inputs.enumerated() {
                let t = inputs.count == 1
                    ? 0.5
                    : Double(index) / Double(inputs.count - 1)
                anchors.append(CanvasFlowPortAnchor(
                    id: port.id,
                    nodeID: node.id,
                    position: DiagramPoint(
                        x: frame.x,
                        y: frame.y + frame.height * (0.15 + 0.7 * t)),
                    outward: .leading))
            }
            for (index, port) in outputs.enumerated() {
                let t = outputs.count == 1
                    ? 0.5
                    : Double(index) / Double(outputs.count - 1)
                anchors.append(CanvasFlowPortAnchor(
                    id: port.id,
                    nodeID: node.id,
                    position: DiagramPoint(
                        x: frame.maxX,
                        y: frame.y + frame.height * (0.15 + 0.7 * t)),
                    outward: .trailing))
            }
            result[node.id] = anchors
        }
        return result
    }

    /// Routes the structurally sound edges of a flow graph through the public
    /// diagram router (curve with orthogonal obstacle fallback), then attaches
    /// the exact declared port coordinates: visible endpoints land precisely
    /// on their port anchors; endpoints whose bound canvas card is collapsed
    /// attach at the visible region chip boundary facing the other endpoint.
    /// Real flow identity is never rewritten.
    ///
    /// Malformed wiring is diagnosed, never trapped: duplicate node/edge/port
    /// IDs (first occurrence wins), missing frames, direction violations
    /// (edge leaving an input or entering an output) and incompatible
    /// non-variadic port types are reported as issues and skipped.
    /// Throws `CancellationError` when the calling task is cancelled.
    ///
    /// - Parameters:
    ///   - nodeFrames: DISPLAY frames keyed by FLOW node ID. Supply bound
    ///     canvas card frames (so grouping/collapse/lock of the real canvas
    ///     node governs the display), region chip frames for collapsed cards,
    ///     or `defaultFrame(for:)` for unbound nodes.
    ///   - representatives: FLOW node ID → visible display endpoint ID (its
    ///     visible region chip when its bound card is collapsed). Omit for
    ///     graphs without canvas bindings.
    ///   - endpointFrames: display endpoint ID (e.g. region chip) → frame,
    ///     for endpoints that are not flow nodes themselves.
    public static func routeEdges(
        flowGraph: FlowGraph,
        nodeFrames: [UUID: DiagramRect],
        representatives: [UUID: UUID] = [:],
        endpointFrames: [UUID: DiagramRect] = [:]
    ) throws -> (edges: [CanvasFlowEdgeGeometry], issues: [CanvasLayoutIssue], hiddenCount: Int) {
        try Task.checkCancellation()
        var issues: [CanvasLayoutIssue] = []

        // MARK: De-duplicated node/port tables (first occurrence wins)
        var nodeByID: [UUID: FlowNode] = [:]
        var portsByNodeID: [UUID: [FlowPort]] = [:]
        for node in flowGraph.nodes {
            try Task.checkCancellation()
            if nodeByID[node.id] != nil {
                issues.append(.init(
                    code: .duplicateFlowNodeID, nodeID: node.id,
                    detail: "first occurrence wins"))
                continue
            }
            nodeByID[node.id] = node
            var seenPortIDs: Set<UUID> = []
            var ports: [FlowPort] = []
            for port in node.ports where seenPortIDs.insert(port.id).inserted {
                ports.append(port)
            }
            if ports.count != node.ports.count {
                issues.append(.init(
                    code: .duplicateFlowPortID, nodeID: node.id,
                    detail: "duplicate port IDs keep the first occurrence"))
            }
            portsByNodeID[node.id] = ports
        }

        // MARK: Display frames
        var frames: [UUID: DiagramRect] = [:]
        for id in nodeByID.keys {
            guard let frame = nodeFrames[id],
                  frame.isValid,
                  CanvasLayoutGeometry.isSafeWorldRect(frame) else {
                issues.append(.init(
                    code: .missingFlowNodeFrame, nodeID: id,
                    detail: "flow node has no resolvable, in-range display frame"))
                continue
            }
            frames[id] = frame
        }
        for (id, frame) in endpointFrames where !frames.keys.contains(id) {
            guard frame.isValid, CanvasLayoutGeometry.isSafeWorldRect(frame) else { continue }
            frames[id] = frame
        }

        // MARK: De-duplicated, validated edges
        var seenEdgeIDs: Set<UUID> = []
        var connections: [FlowEdge] = []
        var hiddenCount = 0
        for edge in flowGraph.edges {
            try Task.checkCancellation()
            if !seenEdgeIDs.insert(edge.id).inserted {
                issues.append(.init(
                    code: .duplicateFlowEdgeID, flowEdgeID: edge.id,
                    detail: "first occurrence wins"))
                continue
            }
            guard nodeByID[edge.sourceNodeID] != nil,
                  nodeByID[edge.destinationNodeID] != nil,
                  frames[edge.sourceNodeID] != nil,
                  frames[edge.destinationNodeID] != nil,
                  let sourcePort = portsByNodeID[edge.sourceNodeID]?
                      .first(where: { $0.id == edge.sourcePortID }),
                  let destinationPort = portsByNodeID[edge.destinationNodeID]?
                      .first(where: { $0.id == edge.destinationPortID }) else {
                issues.append(.init(
                    code: .malformedFlowLink, flowEdgeID: edge.id,
                    detail: "endpoint node or port missing"))
                continue
            }
            if sourcePort.direction != .output || destinationPort.direction != .input {
                issues.append(.init(
                    code: .flowPortDirectionMismatch, flowEdgeID: edge.id,
                    detail: "edge must leave an output port and enter an input port"))
                continue
            }
            // Variadic does NOT mean "any type": mixed types are diagnosed
            // here as a layout-time approximation; the Flow compiler remains
            // the final authority on executability.
            if sourcePort.dataType != destinationPort.dataType {
                issues.append(.init(
                    code: .flowPortTypeMismatch, flowEdgeID: edge.id,
                    detail: "\(sourcePort.dataType.rawValue) → \(destinationPort.dataType.rawValue)"))
                continue
            }
            // Hide only edges that became internal through collapse; a real
            // self-loop on a visible node stays.
            let sourceDisplay = representatives[edge.sourceNodeID] ?? edge.sourceNodeID
            let destinationDisplay = representatives[edge.destinationNodeID]
                ?? edge.destinationNodeID
            if sourceDisplay == destinationDisplay,
               sourceDisplay != edge.sourceNodeID || destinationDisplay != edge.destinationNodeID {
                hiddenCount += 1
                continue
            }
            connections.append(edge)
        }

        // MARK: Route through the public diagram router
        var routerRepresentatives: [UUID: UUID] = [:]
        for edge in connections {
            let source = representatives[edge.sourceNodeID] ?? edge.sourceNodeID
            let destination = representatives[edge.destinationNodeID] ?? edge.destinationNodeID
            if source != edge.sourceNodeID {
                routerRepresentatives[edge.sourceNodeID] = source
            }
            if destination != edge.destinationNodeID {
                routerRepresentatives[edge.destinationNodeID] = destination
            }
        }
        var elements: [DiagramElement] = []
        for (id, frame) in frames {
            elements.append(DiagramElement(id: id, kind: .rectangle, title: "", frame: frame))
        }
        let routerConnections: [DiagramConnection] = connections.map { edge in
            DiagramConnection(
                id: edge.id,
                from: edge.sourceNodeID,
                to: edge.destinationNodeID,
                kind: .flow,
                route: .curve,
                endArrow: true)
        }
        let page = DiagramPage(
            id: flowGraph.id,
            elements: elements,
            connections: routerConnections)
        let routed = try DiagramRouter.edges(
            page: page, frames: frames, representatives: routerRepresentatives)

        // MARK: Attach exact declared port coordinates
        let anchorTable = anchors(for: flowGraph, nodeFrames: frames)
        func anchor(_ nodeID: UUID, _ portID: UUID) -> CanvasFlowPortAnchor? {
            anchorTable[nodeID]?.first(where: { $0.id == portID })
        }
        func chipAttachment(_ chip: DiagramRect, toward target: DiagramPoint) -> DiagramPoint {
            let dx = target.x - chip.center.x, dy = target.y - chip.center.y
            if abs(dx) / max(1, chip.width) >= abs(dy) / max(1, chip.height) {
                return DiagramPoint(x: dx >= 0 ? chip.maxX : chip.x, y: chip.center.y)
            }
            return DiagramPoint(x: chip.center.x, y: dy >= 0 ? chip.maxY : chip.y)
        }

        var result: [CanvasFlowEdgeGeometry] = []
        let edgeByID = Dictionary(
            uniqueKeysWithValues: connections.map { ($0.id, $0) })
        for geometry in routed {
            try Task.checkCancellation()
            guard let edge = edgeByID[geometry.id.uuid],
                  let sourceAnchor = anchor(edge.sourceNodeID, edge.sourcePortID),
                  let destinationAnchor = anchor(
                      edge.destinationNodeID, edge.destinationPortID) else {
                continue
            }
            let sourceDisplay = representatives[edge.sourceNodeID] ?? edge.sourceNodeID
            let destinationDisplay = representatives[edge.destinationNodeID]
                ?? edge.destinationNodeID
            // Hide only edges that became internal through collapse; a real
            // self-loop on a visible node stays.
            if sourceDisplay == destinationDisplay,
               sourceDisplay != edge.sourceNodeID || destinationDisplay != edge.destinationNodeID {
                hiddenCount += 1
                continue
            }
            let start: DiagramPoint
            if sourceDisplay == edge.sourceNodeID {
                start = sourceAnchor.position
            } else if let chip = frames[sourceDisplay] {
                start = chipAttachment(chip, toward: destinationAnchor.position)
            } else {
                start = sourceAnchor.position
            }
            let end: DiagramPoint
            if destinationDisplay == edge.destinationNodeID {
                end = destinationAnchor.position
            } else if let chip = frames[destinationDisplay] {
                end = chipAttachment(chip, toward: start)
            } else {
                end = destinationAnchor.position
            }
            let adjusted = adjustEndpoints(geometry, newStart: start, newEnd: end)
            result.append(CanvasFlowEdgeGeometry(
                id: edge.id,
                geometry: adjusted,
                sourceNodeID: edge.sourceNodeID,
                destinationNodeID: edge.destinationNodeID,
                sourcePortID: edge.sourcePortID,
                destinationPortID: edge.destinationPortID,
                isProxy: sourceDisplay != edge.sourceNodeID
                    || destinationDisplay != edge.destinationNodeID))
        }
        return (result, issues, hiddenCount)
    }

    /// Safely re-anchors a routed path: the first segment is translated by
    /// the start delta, the last segment by the end delta, middle bends are
    /// untouched. For the common single-cubic curve this exactly reproduces
    /// the router's outward-control construction anchored at the ports.
    static func adjustEndpoints(
        _ geometry: DiagramEdgeGeometry,
        newStart: DiagramPoint,
        newEnd: DiagramPoint
    ) -> DiagramEdgeGeometry {
        let startDelta = newStart - geometry.start
        let endDelta = newEnd - geometry.end
        var segments = geometry.segments
        guard !segments.isEmpty else {
            var adjusted = geometry
            adjusted.start = newStart
            adjusted.segments = [.line(newEnd)]
            return adjusted
        }
        func translatedStart(_ segment: DiagramPathSegment, by delta: DiagramPoint)
            -> DiagramPathSegment {
            switch segment {
            case .line(let end): return .line(end)
            case .cubic(let control1, let control2, let end):
                return .cubic(control1: control1 + delta, control2: control2, end: end)
            }
        }
        func translatedEnd(_ segment: DiagramPathSegment, by delta: DiagramPoint)
            -> DiagramPathSegment {
            switch segment {
            case .line(let end): return .line(end + delta)
            case .cubic(let control1, let control2, let end):
                return .cubic(control1: control1, control2: control2 + delta, end: end + delta)
            }
        }
        if segments.count == 1 {
            var only = translatedStart(segments[0], by: startDelta)
            only = translatedEnd(only, by: endDelta)
            segments[0] = only
        } else {
            segments[0] = translatedStart(segments[0], by: startDelta)
            let last = segments.count - 1
            segments[last] = translatedEnd(segments[last], by: endDelta)
        }
        var adjusted = geometry
        adjusted.start = newStart
        adjusted.segments = segments
        return adjusted
    }

    /// Topmost port anchor whose constant-screen-size hit square contains the
    /// world point at the given zoom.
    public static func hitTestPort(
        _ anchors: [CanvasFlowPortAnchor],
        point: DiagramPoint,
        zoom: Double,
        screenSize: Double = 16
    ) -> CanvasFlowPortAnchor? {
        guard point.isFinite else { return nil }
        return anchors.last(where: {
            $0.hitBounds(zoom: zoom, screenSize: screenSize).contains(point)
        })
    }
}
