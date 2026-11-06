import Foundation
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramLayout

public enum CanvasArrangeDirection: String, Codable, Hashable, Sendable {
    case horizontal
    case vertical
}

/// A pure placement proposal: node ID → proposed center. Nothing here moves
/// nodes; the Core edit engine validates and applies later.
public struct CanvasArrangeProposal: Sendable, Hashable {
    public var placements: [UUID: CanvasGeometry.Point]
    public var direction: CanvasArrangeDirection

    public init(
        placements: [UUID: CanvasGeometry.Point],
        direction: CanvasArrangeDirection
    ) {
        self.placements = placements
        self.direction = direction
    }
}

/// Deterministic, size-aware partial arrangement for a selection of nodes.
///
/// Topology: the selection is adapted to a `DiagramPage(structure: .flow)`
/// DTO and laid out by the PUBLIC `DiagramLayoutEngine.layout(page:sizes:)`
/// (SwiftDagre rank layout, native cycle handling via greedy feedback arc
/// breaking) with the nodes' REAL sizes — the same engine mind-map/diagram
/// arrange uses, not a rewritten algorithm. The result stays anchored to the
/// selection's original bounds (same delta rule as the engine's public
/// `arrangeEdits`), and relation cycles are handled by the engine itself.
/// A narrow deterministic layered fallback only covers the proven-
/// incompatible case: the public engine throwing `DiagramError` (e.g.
/// non-finite engine output) — everything else goes through the reuse path.
///
/// Protection rules reject the whole proposal (nothing is returned) when:
/// - the selection is empty or holds no movable node;
/// - a selected node belongs to a group with a locked member;
/// - a selected node belongs to a group with members outside the selection
///   (moving them would move unselected nodes).
/// Locked nodes are excluded from proposals; unselected and outside objects
/// are never moved. Visual relation cycles are graph-topology input here;
/// execution cycles are the Flow compiler's responsibility.
public enum CanvasPartialArrange {
    public static func proposeArrangement(
        page: CanvasPageSnapshot,
        selection: Set<UUID>,
        direction: CanvasArrangeDirection = .horizontal,
        layerSpacing: Double = 96,
        itemSpacing: Double = 48
    ) throws -> CanvasArrangeProposal {
        try Task.checkCancellation()

        // MARK: De-duplicated tables (first occurrence wins; never trap)
        var issues: [CanvasLayoutIssue] = []
        var nodeByID: [UUID: CanvasNodeSnapshot] = [:]
        for node in page.nodes {
            if nodeByID[node.id] != nil {
                issues.append(.init(
                    code: .duplicateNodeID, nodeID: node.id,
                    detail: "arrange input: first occurrence wins"))
                continue
            }
            nodeByID[node.id] = node
        }
        var groupsByID: [UUID: CanvasGroupRecord] = [:]
        for group in page.groups {
            if groupsByID[group.id] != nil {
                issues.append(.init(
                    code: .duplicateNodeID,
                    detail: "arrange input: duplicate group \(group.id), first wins"))
                continue
            }
            groupsByID[group.id] = group
        }
        if !issues.isEmpty {
            throw CanvasLayoutError.arrangeRejected(issues)
        }

        // MARK: Candidates: selected, unlocked, in-range coordinates only
        var candidates: [UUID] = []
        for id in selection {
            guard let node = nodeByID[id],
                  !node.isLocked,
                  CanvasLayoutGeometry.isSafeWorldRect(
                      CanvasLayoutGeometry.rect(from: node.frame))
            else { continue }
            candidates.append(id)
        }

        // MARK: Group protection: all-or-nothing per touched group
        var rejectedGroups: Set<UUID> = []
        for id in candidates {
            guard let groupID = nodeByID[id]?.groupID,
                  let group = groupsByID[groupID],
                  !rejectedGroups.contains(groupID) else { continue }
            let memberSet = Set(group.memberNodeIDs)
            if memberSet.contains(where: { nodeByID[$0]?.isLocked == true }) {
                issues.append(.init(
                    code: .groupLockedMember,
                    nodeID: id,
                    detail: "group \(groupID) contains a locked member"))
                rejectedGroups.insert(groupID)
            } else if !memberSet.isSubset(of: Set(candidates)) {
                issues.append(.init(
                    code: .partialGroupSelection,
                    nodeID: id,
                    detail: "group \(groupID) is only partially selected"))
                rejectedGroups.insert(groupID)
            }
        }
        if !issues.isEmpty {
            throw CanvasLayoutError.arrangeRejected(issues)
        }

        let candidateSet = Set(candidates)
        guard candidateSet.count > 1 else {
            if selection.isEmpty {
                throw CanvasLayoutError.arrangeRejected([
                    .init(code: .emptyArrangeSelection,
                          detail: "selection contains no movable nodes")])
            }
            return CanvasArrangeProposal(placements: [:], direction: direction)
        }

        let selected = candidates
            .compactMap { nodeByID[$0] }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        // MARK: Reuse path: public diagram engine with real sizes
        let adapter = flowAdapter(
            page: page, candidateSet: candidateSet, direction: direction)
        let sizes = Dictionary(uniqueKeysWithValues: selected.map {
            ($0.id, DiagramSize(width: $0.frame.size.width, height: $0.frame.size.height))
        })
        let frames: [UUID: DiagramRect]
        do {
            let layout = try DiagramLayoutEngine.layout(adapter, sizes: sizes)
            frames = layout.frames
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Narrow fallback: only when the public engine cannot produce
            // geometry (invalid input it refuses, non-finite output). Same
            // determinism contract as the reuse path.
            frames = try fallbackLayers(
                selected: selected,
                page: page,
                candidateSet: candidateSet,
                direction: direction,
                layerSpacing: layerSpacing,
                itemSpacing: itemSpacing)
        }

        // MARK: Anchor to the selection's original bounds (arrangeEdits rule)
        let oldBounds = selected.map {
            CanvasLayoutGeometry.rect(from: $0.frame)
        }.reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }
        let newBounds = selected.compactMap { frames[$0.id] }
            .reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 }
        let delta: DiagramPoint
        if let oldBounds, let newBounds {
            delta = DiagramPoint(
                x: oldBounds.center.x - newBounds.center.x,
                y: oldBounds.center.y - newBounds.center.y)
        } else {
            delta = .zero
        }

        var placements: [UUID: CanvasGeometry.Point] = [:]
        placements.reserveCapacity(selected.count)
        for node in selected {
            guard let frame = frames[node.id] else { continue }
            let shifted = frame.translated(by: delta)
            placements[node.id] = CanvasGeometry.Point(
                x: shifted.center.x, y: shifted.center.y)
        }
        return CanvasArrangeProposal(
            placements: placements, direction: direction)
    }

    /// Selection → `DiagramPage(structure: .flow)` DTO: movable nodes become
    /// unframed rectangles with real sizes supplied separately; visual
    /// relations inside the selection become connections so the engine ranks
    /// by graph depth (cycles handled natively).
    private static func flowAdapter(
        page: CanvasPageSnapshot,
        candidateSet: Set<UUID>,
        direction: CanvasArrangeDirection
    ) -> DiagramPage {
        var elements: [DiagramElement] = []
        for node in page.nodes where candidateSet.contains(node.id) {
            elements.append(DiagramElement(
                id: node.id,
                kind: .rectangle,
                title: node.title ?? "",
                frame: nil))
        }
        var connections: [DiagramConnection] = []
        for connection in page.connections
        where candidateSet.contains(connection.sourceNodeID)
            && candidateSet.contains(connection.destinationNodeID) {
            connections.append(DiagramConnection(
                id: connection.id,
                from: connection.sourceNodeID,
                to: connection.destinationNodeID,
                kind: .flow,
                route: .curve))
        }
        return DiagramPage(
            id: page.id,
            structure: .flow,
            elements: elements,
            connections: connections,
            metadata: ["direction": direction == .horizontal ? "LR" : "TB"])
    }

    /// Deterministic size-aware layered fallback (used ONLY when the public
    /// engine throws): longest-path layering over visual relations restricted
    /// to the selection; relation cycles collapse into one extra layer
    /// ordered by cross-axis position then UUID; stacking is size-aware and
    /// anchored to the selection's original bounds.
    private static func fallbackLayers(
        selected: [CanvasNodeSnapshot],
        page: CanvasPageSnapshot,
        candidateSet: Set<UUID>,
        direction: CanvasArrangeDirection,
        layerSpacing: Double,
        itemSpacing: Double
    ) throws -> [UUID: DiagramRect] {
        let nodeByID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        var outgoing: [UUID: [UUID]] = [:]
        var remainingIndegree: [UUID: Int] = [:]
        for id in candidateSet { remainingIndegree[id] = 0 }
        for connection in page.connections
        where candidateSet.contains(connection.sourceNodeID)
            && candidateSet.contains(connection.destinationNodeID) {
            outgoing[connection.sourceNodeID, default: []]
                .append(connection.destinationNodeID)
            remainingIndegree[connection.destinationNodeID, default: 0] += 1
        }
        let stableOrder: (UUID, UUID) -> Bool = { lhs, rhs in
            guard let left = nodeByID[lhs], let right = nodeByID[rhs] else {
                return lhs.uuidString < rhs.uuidString
            }
            let leftCross = direction == .horizontal
                ? left.frame.center.y : left.frame.center.x
            let rightCross = direction == .horizontal
                ? right.frame.center.y : right.frame.center.x
            if leftCross != rightCross { return leftCross < rightCross }
            return lhs.uuidString < rhs.uuidString
        }
        var layerByID: [UUID: Int] = [:]
        var queue = remainingIndegree.filter { $0.value == 0 }.map(\.key)
            .sorted(by: stableOrder)
        for id in queue { layerByID[id] = 0 }
        var cursor = 0
        while cursor < queue.count {
            try Task.checkCancellation()
            let source = queue[cursor]
            cursor += 1
            for destination in (outgoing[source] ?? []).sorted(by: stableOrder) {
                layerByID[destination] = max(
                    layerByID[destination] ?? 0,
                    (layerByID[source] ?? 0) + 1)
                remainingIndegree[destination, default: 0] -= 1
                if remainingIndegree[destination] == 0 { queue.append(destination) }
            }
        }
        let unvisited = candidateSet.subtracting(layerByID.keys)
        let cycleLayer = (layerByID.values.max() ?? -1) + 1
        for id in unvisited { layerByID[id] = cycleLayer }
        let layerCount = (layerByID.values.max() ?? 0) + 1

        func primary(_ node: CanvasNodeSnapshot) -> Double {
            direction == .horizontal ? node.frame.center.x : node.frame.center.y
        }
        func cross(_ node: CanvasNodeSnapshot) -> Double {
            direction == .horizontal ? node.frame.center.y : node.frame.center.x
        }
        func primaryExtent(_ node: CanvasNodeSnapshot) -> Double {
            direction == .horizontal ? node.frame.size.width : node.frame.size.height
        }
        func crossExtent(_ node: CanvasNodeSnapshot) -> Double {
            direction == .horizontal ? node.frame.size.height : node.frame.size.width
        }
        let minimumPrimary = selected.map { primary($0) - primaryExtent($0) / 2 }.min() ?? 0
        let minimumCross = selected.map { cross($0) - crossExtent($0) / 2 }.min() ?? 0
        let maximumCross = selected.map { cross($0) + crossExtent($0) / 2 }.max() ?? minimumCross
        let originalCrossCenter = (minimumCross + maximumCross) / 2

        let layers = Dictionary(grouping: selected) { layerByID[$0.id] ?? 0 }
        var frames: [UUID: DiagramRect] = [:]
        var primaryCursor = minimumPrimary
        for layerIndex in 0..<max(layerCount, 1) {
            try Task.checkCancellation()
            let items = (layers[layerIndex] ?? []).sorted { stableOrder($0.id, $1.id) }
            guard !items.isEmpty else { continue }
            let layerPrimaryExtent = items.map(primaryExtent).max() ?? 0
            let totalCrossExtent = items.reduce(0) { $0 + crossExtent($1) }
                + itemSpacing * Double(max(0, items.count - 1))
            var crossCursor = originalCrossCenter - totalCrossExtent / 2
            for node in items {
                let centerValue = crossCursor + crossExtent(node) / 2
                let frame = direction == .horizontal
                    ? DiagramRect(
                        x: primaryCursor,
                        y: centerValue - crossExtent(node) / 2,
                        width: primaryExtent(node),
                        height: crossExtent(node))
                    : DiagramRect(
                        x: centerValue - crossExtent(node) / 2,
                        y: primaryCursor,
                        width: crossExtent(node),
                        height: primaryExtent(node))
                frames[node.id] = frame
                crossCursor += crossExtent(node) + itemSpacing
            }
            primaryCursor += layerPrimaryExtent + layerSpacing
        }
        return frames
    }
}
