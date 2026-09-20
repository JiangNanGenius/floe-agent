// FloeNotesTests — MindMapLayout regression: the memoized layout pass must
// produce exactly the frames the original recursive implementation produced.

import Foundation
import Testing
@testable import FloeNotes

@Suite("Mind map layout")
struct MindMapLayoutRegressionTests {

    // MARK: - Legacy reference implementation (pre-memoization algorithm)

    private enum Legacy {
        static func frames(
            document: NoteDocument,
            sizes: [UUID: MindMapSize],
            metrics: MindMapLayoutMetrics = .standard,
            includeCollapsed: Bool = false
        ) -> [UUID: NoteRect] {
            guard let root = document.nodes.first(where: { $0.parentID == nil }) else { return [:] }
            var output: [UUID: NoteRect] = [:]
            let direction = normalizedDirection(document.mindMapDirection)
            place(root, originX: nil, centerY: 0, inheritedSide: direction == 0 ? 0 : 1,
                  direction: direction, document: document, sizes: sizes, metrics: metrics,
                  includeCollapsed: includeCollapsed, output: &output)
            return output
        }

        private static func normalizedDirection(_ value: Int?) -> Int {
            guard let value, (0...2).contains(value) else { return 2 }
            return value
        }

        private static func orderedChildren(of parentID: UUID?, in document: NoteDocument) -> [MindMapNode] {
            document.nodes
                .filter { $0.parentID == parentID }
                .sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        }

        private static func layoutChildren(of node: MindMapNode, in document: NoteDocument, includeCollapsed: Bool) -> [MindMapNode] {
            guard includeCollapsed || !node.isCollapsed else { return [] }
            return orderedChildren(of: node.id, in: document)
        }

        private static func childSide(parent: MindMapNode, direction: Int) -> MindMapLayout.Side {
            if direction == 0 { return 0 }
            if direction == 1 { return 1 }
            if let override = parent.direction, override == 0 || override == 1 { return override }
            return 1
        }

        private static func balancedAssignment(parent: MindMapNode, in document: NoteDocument, includeCollapsed: Bool) -> [UUID: MindMapLayout.Side] {
            let children = layoutChildren(of: parent, in: document, includeCollapsed: includeCollapsed)
            var weights: [UUID: Double] = [:]
            func weight(_ node: MindMapNode) -> Double {
                if let cached = weights[node.id] { return cached }
                let value = 1 + layoutChildren(of: node, in: document, includeCollapsed: includeCollapsed).reduce(0.0) { $0 + weight($1) }
                weights[node.id] = value
                return value
            }
            var assignment: [UUID: MindMapLayout.Side] = [:]
            var totals: [MindMapLayout.Side: Double] = [0: 0, 1: 0]
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

        private static func measure(_ node: MindMapNode, document: NoteDocument, sizes: [UUID: MindMapSize], metrics: MindMapLayoutMetrics, includeCollapsed: Bool) -> Double {
            let size = resolvedSize(node, sizes: sizes, metrics: metrics)
            let children = layoutChildren(of: node, in: document, includeCollapsed: includeCollapsed)
            guard !children.isEmpty else { return size.height }
            let sum = children.reduce(0.0) { $0 + measure($1, document: document, sizes: sizes, metrics: metrics, includeCollapsed: includeCollapsed) }
            return max(size.height, sum + Double(children.count - 1) * metrics.siblingGap)
        }

        private static func resolvedSize(_ node: MindMapNode, sizes: [UUID: MindMapSize], metrics: MindMapLayoutMetrics) -> MindMapSize {
            if let size = sizes[node.id], size.isValid { return size }
            return MindMapSize(width: metrics.defaultNodeWidth, height: metrics.defaultNodeHeight)
        }

        private static func place(
            _ node: MindMapNode,
            originX: Double?,
            centerY: Double,
            inheritedSide: MindMapLayout.Side,
            direction: Int,
            document: NoteDocument,
            sizes: [UUID: MindMapSize],
            metrics: MindMapLayoutMetrics,
            includeCollapsed: Bool,
            output: inout [UUID: NoteRect]
        ) {
            let size = resolvedSize(node, sizes: sizes, metrics: metrics)
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

            let children = layoutChildren(of: node, in: document, includeCollapsed: includeCollapsed)
            guard !children.isEmpty else { return }
            let assignment = direction == 2 ? balancedAssignment(parent: node, in: document, includeCollapsed: includeCollapsed) : [:]
            let columnHeight = children.reduce(0.0) { $0 + measure($1, document: document, sizes: sizes, metrics: metrics, includeCollapsed: includeCollapsed) }
                + Double(children.count - 1) * metrics.siblingGap
            var cursor = (frame.y + frame.height / 2) - columnHeight / 2
            for child in children {
                let childSide = direction == 2 ? (assignment[child.id] ?? inheritedSide) : inheritedSide
                let sign = childSide == 0 ? -1.0 : 1.0
                let childSize = resolvedSize(child, sizes: sizes, metrics: metrics)
                let childOriginX = sign < 0
                    ? frame.x - metrics.horizontalGap - childSize.width
                    : frame.x + frame.width + metrics.horizontalGap
                let childCenterY = cursor + measure(child, document: document, sizes: sizes, metrics: metrics, includeCollapsed: includeCollapsed) / 2
                place(child, originX: childOriginX, centerY: childCenterY, inheritedSide: childSide,
                      direction: direction, document: document, sizes: sizes, metrics: metrics,
                      includeCollapsed: includeCollapsed, output: &output)
                cursor += measure(child, document: document, sizes: sizes, metrics: metrics, includeCollapsed: includeCollapsed) + metrics.siblingGap
            }
        }
    }

    // MARK: - Fixtures

    /// Deterministic pseudo-random tree covering: balanced/left/right
    /// directions, collapsed subtrees, manual positions, per-topic direction
    /// overrides and measured sizes.
    private func fixture(
        seed: Int,
        breadth: Int,
        depth: Int,
        direction: Int
    ) -> (document: NoteDocument, sizes: [UUID: MindMapSize]) {
        var state = UInt64(seed) &* 2_654_435_761 &+ 14_695_981_039_346_656_037
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(1, bound)))
        }
        var document = NoteDocument(kind: .mindMap, title: "fixture")
        document.mindMapDirection = direction
        let root = document.nodes[0]
        var sizes: [UUID: MindMapSize] = [:]
        var frontier: [MindMapNode] = [root]
        for level in 0..<depth {
            var nextFrontier: [MindMapNode] = []
            for parent in frontier {
                let childCount = next(breadth) + 2
                for index in 0..<childCount {
                    var node = MindMapNode(parentID: parent.id, title: "L\(level)-\(index)", order: index)
                    if next(5) == 0 { node.isCollapsed = true }
                    if next(4) == 0 { node.position = MindMapPoint(x: Double(next(800) - 400), y: Double(next(800) - 400)) }
                    if direction == 2, next(6) == 0 { node.direction = next(2) }
                    document.nodes.append(node)
                    if next(3) == 0 {
                        sizes[node.id] = MindMapSize(width: Double(120 + next(160)), height: Double(30 + next(60)))
                    }
                    nextFrontier.append(node)
                }
            }
            frontier = nextFrontier
        }
        return (document, sizes)
    }

    private func assertSameFrames(
        _ actual: [UUID: NoteRect],
        _ expected: [UUID: NoteRect],
        _ message: String
    ) {
        #expect(actual.count == expected.count, "\(message): frame count differs")
        for (id, frame) in expected {
            guard let other = actual[id] else {
                Issue.record("\(message): missing frame for \(id)")
                continue
            }
            #expect(frame == other, "\(message): frame differs for \(id)")
        }
    }

    @Test("Memoized pass matches the legacy recursive layout exactly")
    func memoizedMatchesLegacy() {
        for direction in [0, 1, 2] {
            for seed in [1, 7, 42] {
                let (document, sizes) = fixture(seed: seed + direction * 100, breadth: 3, depth: 4, direction: direction)
                for includeCollapsed in [false, true] {
                    let actual = MindMapLayout.frames(
                        document: document, sizes: sizes, includeCollapsed: includeCollapsed
                    )
                    let expected = Legacy.frames(
                        document: document, sizes: sizes, includeCollapsed: includeCollapsed
                    )
                    assertSameFrames(
                        actual, expected,
                        "direction=\(direction) seed=\(seed) includeCollapsed=\(includeCollapsed)"
                    )
                }
            }
        }
    }

    @Test("Layout is deterministic across repeated passes")
    func deterministicAcrossPasses() {
        let (document, sizes) = fixture(seed: 11, breadth: 4, depth: 5, direction: 2)
        let first = MindMapLayout.frames(document: document, sizes: sizes)
        for _ in 0..<5 {
            #expect(MindMapLayout.frames(document: document, sizes: sizes) == first)
        }
    }

    @Test("A 600-topic tree lays out without the old per-sibling subtree walks")
    func largeTreeCompletesQuickly() {
        let (document, sizes) = fixture(seed: 99, breadth: 5, depth: 6, direction: 2)
        #expect(document.nodes.count > 300)
        let start = ContinuousClock.now
        let frames = MindMapLayout.frames(document: document, sizes: sizes, includeCollapsed: true)
        let elapsed = ContinuousClock.now - start
        #expect(frames.count == document.nodes.count)
        // Generous ceiling for shared CI hardware; the memoized pass is O(n)
        // and measures in single-digit milliseconds on device, while the old
        // per-sibling re-walks grew quadratically with tree size.
        #expect(elapsed < .seconds(5), "layout took \(elapsed)")
    }
}
