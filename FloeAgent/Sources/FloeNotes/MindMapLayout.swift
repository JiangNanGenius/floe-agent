// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Measured content size of one topic. The layout engine never touches UI;
/// the view feeds measured sizes back through this value type.
public struct MindMapSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var isValid: Bool { width.isFinite && height.isFinite && width > 0 && height > 0 }
}

/// Spacing constants for the deterministic tree layout. World coordinates are
/// points at zoom scale 1.
public struct MindMapLayoutMetrics: Hashable, Sendable {
    public var horizontalGap: Double
    public var siblingGap: Double
    public var defaultNodeWidth: Double
    public var defaultNodeHeight: Double
    public init(horizontalGap: Double = 64, siblingGap: Double = 24,
                defaultNodeWidth: Double = 160, defaultNodeHeight: Double = 44) {
        self.horizontalGap = horizontalGap
        self.siblingGap = siblingGap
        self.defaultNodeWidth = defaultNodeWidth
        self.defaultNodeHeight = defaultNodeHeight
    }
    public static let standard = MindMapLayoutMetrics()
}

/// Deterministic pure layout for the native mind map. The same model always
/// produces the same frames, so refreshing, collapsing and reopening a document
/// never rearranges topics that have no manual position. Manual positions
/// (first written by a user edit) pin only their own topic; descendants still
/// grow relative to their parent's resolved frame.
public enum MindMapLayout {
    /// Side a subtree grows toward: 0 left, 1 right.
    public typealias Side = Int

    /// World-space frame (top-left origin) for every visible topic. Collapsed
    /// subtrees contribute only their own topic frame. Pass
    /// `includeCollapsed: true` to also lay out hidden descendants (used when
    /// materializing positions so a later expand reflows nothing).
    public static func frames(
        document: NoteDocument,
        sizes: [UUID: MindMapSize],
        metrics: MindMapLayoutMetrics = .standard,
        includeCollapsed: Bool = false
    ) -> [UUID: NoteRect] {
        guard let root = document.nodes.first(where: { $0.parentID == nil }) else { return [:] }
        // One pass builds the children index and memoizes subtree heights:
        // previously every sibling re-walked its whole subtree and every
        // parent re-filtered the full node list, making each layout O(n²)
        // or worse on a per-body-evaluation hot path. Output is unchanged.
        let pass = LayoutPass(document: document, sizes: sizes, metrics: metrics, includeCollapsed: includeCollapsed)
        var output: [UUID: NoteRect] = [:]
        pass.place(root, originX: nil, centerY: 0, inheritedSide: pass.direction == 0 ? 0 : 1, output: &output)
        return output
    }

    /// All descendants of a topic (not including the topic itself), in stable
    /// display order. Used by subtree drag and reparenting.
    public static func descendants(of id: UUID, in document: NoteDocument) -> [MindMapNode] {
        var result: [MindMapNode] = []
        var queue = orderedChildren(of: id, in: document)
        while !queue.isEmpty {
            let next = queue.removeFirst()
            result.append(next)
            queue.append(contentsOf: orderedChildren(of: next.id, in: document))
        }
        return result
    }

    /// Children in display order (order, then id for stability).
    public static func orderedChildren(of parentID: UUID?, in document: NoteDocument) -> [MindMapNode] {
        document.nodes
            .filter { $0.parentID == parentID }
            .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
    }

    /// Local placement for a newly added child: one column step beside its
    /// parent, vertically after the current last sibling, so existing topics
    /// keep their positions and no global reflow happens. Spacing accounts for
    /// the new topic's own half-size so edges never overlap.
    public static func newChildPosition(
        document: NoteDocument,
        frames: [UUID: NoteRect],
        parentID: UUID,
        metrics: MindMapLayoutMetrics = .standard
    ) -> MindMapPoint? {
        guard let parent = document.nodes.first(where: { $0.id == parentID }) else { return nil }
        let fallback = NoteRect(x: 0, y: 0, width: metrics.defaultNodeWidth, height: metrics.defaultNodeHeight)
        let parentFrame = frames[parentID] ?? fallback
        let sign = childSide(parent: parent, document: document) == 0 ? -1.0 : 1.0
        let centerX = parentFrame.x + parentFrame.width / 2
            + sign * (parentFrame.width / 2 + metrics.horizontalGap + metrics.defaultNodeWidth / 2)
        let centerY: Double
        if let last = orderedChildren(of: parentID, in: document).last, let lastFrame = frames[last.id] {
            centerY = lastFrame.y + lastFrame.height + metrics.siblingGap + metrics.defaultNodeHeight / 2
        } else {
            centerY = parentFrame.y + parentFrame.height / 2
        }
        return MindMapPoint(x: centerX, y: centerY)
    }

    /// Local placement for a newly added sibling: one row step below the
    /// reference sibling, same column, leaving a full sibling gap.
    public static func newSiblingPosition(
        document: NoteDocument,
        frames: [UUID: NoteRect],
        siblingID: UUID,
        metrics: MindMapLayoutMetrics = .standard
    ) -> MindMapPoint? {
        guard document.nodes.contains(where: { $0.id == siblingID }) else { return nil }
        let fallback = NoteRect(x: 0, y: 0, width: metrics.defaultNodeWidth, height: metrics.defaultNodeHeight)
        let frame = frames[siblingID] ?? fallback
        return MindMapPoint(x: frame.x + frame.width / 2,
                            y: frame.y + frame.height + metrics.siblingGap + metrics.defaultNodeHeight / 2)
    }

    /// Direction the given parent's children grow toward in this document.
    public static func childSide(parent: MindMapNode, document: NoteDocument) -> Side {
        switch normalizedDirection(document.mindMapDirection) {
        case 0: return 0
        case 1: return 1
        default:
            if let override = parent.direction, override == 0 || override == 1 { return override }
            return 1
        }
    }

    // MARK: - Private

    /// Per-`frames` workspace: children indexed once in display order and
    /// subtree heights memoized, so one layout pass is O(n) instead of
    /// re-walking subtrees per sibling. Pure value semantics on the outside;
    /// the class box is scoped to a single pass and never shared.
    private final class LayoutPass {
        let sizes: [UUID: MindMapSize]
        let metrics: MindMapLayoutMetrics
        let includeCollapsed: Bool
        let direction: Int
        private var childrenByParent: [UUID: [MindMapNode]] = [:]
        private var measuredHeights: [UUID: Double] = [:]

        init(document: NoteDocument, sizes: [UUID: MindMapSize], metrics: MindMapLayoutMetrics, includeCollapsed: Bool) {
            self.sizes = sizes
            self.metrics = metrics
            self.includeCollapsed = includeCollapsed
            self.direction = MindMapLayout.normalizedDirection(document.mindMapDirection)
            var map: [UUID: [MindMapNode]] = [:]
            for node in document.nodes {
                guard let parentID = node.parentID else { continue }
                map[parentID, default: []].append(node)
            }
            for (parentID, children) in map {
                map[parentID] = children.sorted {
                    $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
                }
            }
            childrenByParent = map
        }

        /// Children that take part in layout: the topic itself always shows,
        /// but a collapsed topic hides its whole subtree.
        func layoutChildren(of node: MindMapNode) -> [MindMapNode] {
            guard includeCollapsed || !node.isCollapsed else { return [] }
            return childrenByParent[node.id] ?? []
        }

        func resolvedSize(_ node: MindMapNode) -> MindMapSize {
            if let size = sizes[node.id], size.isValid { return size }
            return MindMapSize(width: metrics.defaultNodeWidth, height: metrics.defaultNodeHeight)
        }

        /// Subtree column height, memoized per node within this pass.
        func measure(_ node: MindMapNode) -> Double {
            if let cached = measuredHeights[node.id] { return cached }
            let size = resolvedSize(node)
            let children = layoutChildren(of: node)
            let value: Double
            if children.isEmpty {
                value = size.height
            } else {
                let sum = children.reduce(0.0) { $0 + measure($1) }
                value = max(size.height, sum + Double(children.count - 1) * metrics.siblingGap)
            }
            measuredHeights[node.id] = value
            return value
        }

        func childSide(parent: MindMapNode) -> Side {
            if direction == 0 { return 0 }
            if direction == 1 { return 1 }
            if let override = parent.direction, override == 0 || override == 1 { return override }
            return 1
        }

        /// Balanced-mode side assignment for one parent's children.
        /// Deterministic: children visit in display order and join the
        /// lighter column unless a per-topic direction override pins them.
        func balancedAssignment(parent: MindMapNode) -> [UUID: Side] {
            let children = layoutChildren(of: parent)
            var weights: [UUID: Double] = [:]
            func weight(_ node: MindMapNode) -> Double {
                if let cached = weights[node.id] { return cached }
                let value = 1 + layoutChildren(of: node).reduce(0.0) { $0 + weight($1) }
                weights[node.id] = value
                return value
            }
            var assignment: [UUID: Side] = [:]
            var totals: [Side: Double] = [0: 0, 1: 0]
            for child in children {
                if let override = child.direction, override == 0 || override == 1 {
                    assignment[child.id] = override
                    totals[override, default: 0] += weight(child)
                } else {
                    let target = (totals[0] ?? 0) <= (totals[1] ?? 0) ? 0 : 1
                    assignment[child.id] = target
                    totals[target, default: 0] += weight(child)
                }
            }
            return assignment
        }

        func place(
            _ node: MindMapNode,
            originX: Double?,
            centerY: Double,
            inheritedSide: Side,
            output: inout [UUID: NoteRect]
        ) {
            let size = resolvedSize(node)
            let frame: NoteRect
            if let position = node.position, position.isValid {
                frame = NoteRect(x: position.x - size.width / 2, y: position.y - size.height / 2,
                                 width: size.width, height: size.height)
            } else if let originX {
                frame = NoteRect(x: originX, y: centerY - size.height / 2, width: size.width, height: size.height)
            } else {
                frame = NoteRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            }
            output[node.id] = frame

            let children = layoutChildren(of: node)
            guard !children.isEmpty else { return }
            let assignment = direction == 2 ? balancedAssignment(parent: node) : [:]
            let columnHeight = children.reduce(0.0) { $0 + measure($1) }
                + Double(children.count - 1) * metrics.siblingGap
            var cursor = (frame.y + frame.height / 2) - columnHeight / 2
            for child in children {
                let side = direction == 2 ? (assignment[child.id] ?? inheritedSide) : inheritedSide
                let sign = side == 0 ? -1.0 : 1.0
                let childSize = resolvedSize(child)
                let childOriginX = sign < 0
                    ? frame.x - metrics.horizontalGap - childSize.width
                    : frame.x + frame.width + metrics.horizontalGap
                let childCenterY = cursor + measure(child) / 2
                place(child, originX: childOriginX, centerY: childCenterY, inheritedSide: side, output: &output)
                cursor += measure(child) + metrics.siblingGap
            }
        }
    }

    private static func normalizedDirection(_ value: Int?) -> Int {
        guard let value, (0...2).contains(value) else { return 2 }
        return value
    }
}
