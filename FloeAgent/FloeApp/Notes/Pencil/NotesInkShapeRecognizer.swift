// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Manual, local geometry proposals. This owns no editor, drawing or history.
/// Line/arrow geometry follows the existing CanvasInkRecognition primitives;
/// closed-shape residuals follow the Notes recognition qualification adapter.
/// Confidence is an ordering hint, not a handwriting accuracy measurement.
nonisolated enum NotesInkShapeRecognizer {
    struct Point: Hashable, Sendable {
        var x: Double
        var y: Double
        func distance(to p: Point) -> Double { hypot(x - p.x, y - p.y) }
    }
    struct Rect: Hashable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var diagonal: Double { hypot(width, height) }
        var maxX: Double { x + width }
        var maxY: Double { y + height }
    }
    enum Kind: String, Hashable, Sendable { case line, rectangle, ellipse, arrow }
    struct Candidate: Hashable, Sendable {
        var kind: Kind
        /// Indices in the captured PKDrawing, never in a later page snapshot.
        var sourceIndices: [Int]
        var paths: [[Point]]
        var confidence: Double
    }
    struct Stroke: Sendable {
        var index: Int
        var points: [Point]
    }
    static let maximumStrokes = 256
    static let maximumPointsPerStroke = 4096
    static let maximumTotalPoints = 65_536

    static func recognize(_ input: [Stroke]) -> [Candidate] {
        guard !input.isEmpty, input.count <= maximumStrokes,
              input.reduce(0, { $0 + $1.points.count }) <= maximumTotalPoints,
              Set(input.map(\.index)).count == input.count,
              input.allSatisfy({ $0.index >= 0 && $0.points.count <= maximumPointsPerStroke
                  && $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return [] }
        let strokes = input.map { Stroke(index: $0.index, points: unique($0.points)) }
        var used = Set<Int>()
        var candidates: [Candidate] = []
        // Group a shaft and its actual connected head strokes before proposing
        // independent straight lines. Unrelated strokes are never cleared.
        for shaft in strokes.sorted(by: { length($0.points) > length($1.points) }) where !used.contains(shaft.index) {
            guard let (start, end, _) = straight(shaft.points) else { continue }
            for (tail, tip) in [(start, end), (end, start)] {
                let heads = strokes.filter { candidate in
                    guard candidate.index != shaft.index, !used.contains(candidate.index), candidate.points.count >= 2 else { return false }
                    let amount = length(candidate.points), shaftLength = tail.distance(to: tip)
                    return amount >= shaftLength * 0.08 && amount <= shaftLength * 0.9
                        && candidate.points.contains { $0.distance(to: tip) <= max(5, shaftLength * 0.08) }
                        && candidate.points.allSatisfy { $0.distance(to: tip) <= shaftLength * 0.5 }
                }
                guard !heads.isEmpty, heads.count <= 3,
                      isArrowHead(heads.flatMap(\.points), tail: tail, tip: tip) else { continue }
                let indices = [shaft.index] + heads.map(\.index)
                used.formUnion(indices)
                candidates.append(.init(kind: .arrow, sourceIndices: indices,
                    paths: arrowPaths(tail: tail, tip: tip), confidence: 0.82))
                break
            }
        }
        for stroke in strokes where !used.contains(stroke.index) {
            guard let candidate = single(stroke) else { continue }
            candidates.append(candidate)
        }
        return candidates.sorted { ($0.sourceIndices.min() ?? 0) < ($1.sourceIndices.min() ?? 0) }
    }

    private static func single(_ stroke: Stroke) -> Candidate? {
        let points = stroke.points
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let bounds = bounds(points), pathLength = length(points)
        guard bounds.diagonal >= 24, pathLength >= 24 else { return nil }
        if first.distance(to: last) <= bounds.diagonal * 0.10, bounds.width >= 12, bounds.height >= 12 {
            let cx = bounds.x + bounds.width / 2, cy = bounds.y + bounds.height / 2
            let residual = points.map { abs(hypot(($0.x - cx) / (bounds.width / 2), ($0.y - cy) / (bounds.height / 2)) - 1) }
            let ellipseLength = Double.pi * (3 * (bounds.width + bounds.height) / 2
                - sqrt((3 * bounds.width + bounds.height) * (bounds.width + 3 * bounds.height)) / 2)
            if residual.reduce(0, +) / Double(residual.count) < 0.10,
               (residual.max() ?? 1) < 0.30, pathLength > ellipseLength * 0.72,
               pathLength < ellipseLength * 1.45 {
                let path = (0...64).map { i in
                    let angle = Double(i) / 64 * .pi * 2
                    return Point(x: cx + bounds.width / 2 * cos(angle), y: cy + bounds.height / 2 * sin(angle))
                }
                return .init(kind: .ellipse, sourceIndices: [stroke.index], paths: [path], confidence: 0.88)
            }
            let edgeResidual = points.map { min(abs($0.x - bounds.x), abs(bounds.maxX - $0.x), abs($0.y - bounds.y), abs(bounds.maxY - $0.y)) }
            let corners = [Point(x: bounds.x, y: bounds.y), Point(x: bounds.maxX, y: bounds.y),
                           Point(x: bounds.maxX, y: bounds.maxY), Point(x: bounds.x, y: bounds.maxY)]
            let perimeter = 2 * (bounds.width + bounds.height)
            if edgeResidual.reduce(0, +) / (Double(points.count) * bounds.diagonal) < 0.035,
               (edgeResidual.max() ?? .infinity) < bounds.diagonal * 0.09,
               corners.allSatisfy({ corner in points.contains { $0.distance(to: corner) < bounds.diagonal * 0.14 } }),
               pathLength > perimeter * 0.72, pathLength < perimeter * 1.45 {
                return .init(kind: .rectangle, sourceIndices: [stroke.index], paths: [corners + [corners[0]]], confidence: 0.88)
            }
            return nil
        }
        // A single-stroke arrow may revisit its tip between its two wings.
        let sampled = points.count > 512 ? (0..<512).map { points[$0 * (points.count - 1) / 511] } : points
        let simplified = simplify(sampled, tolerance: bounds.diagonal * 0.025)
        if simplified.count >= 4 {
            for index in 1..<(simplified.count - 2) {
                let tip = simplified[index]
                guard let (_, _, _) = straight(Array(simplified[0...index])),
                      first.distance(to: tip) >= 24,
                      isArrowHead(Array(simplified[(index + 1)...]), tail: first, tip: tip) else { continue }
                return .init(kind: .arrow, sourceIndices: [stroke.index],
                    paths: arrowPaths(tail: first, tip: tip), confidence: 0.8)
            }
        }
        if let (start, end, score) = straight(points) {
            return .init(kind: .line, sourceIndices: [stroke.index], paths: [[start, end]], confidence: score)
        }
        return nil
    }

    private static func isArrowHead(_ points: [Point], tail: Point, tip: Point) -> Bool {
        let span = tail.distance(to: tip)
        guard span >= 24, !points.isEmpty else { return false }
        let ux = (tip.x - tail.x) / span, uy = (tip.y - tail.y) / span
        var positive = false, negative = false
        for point in points {
            let dx = point.x - tip.x, dy = point.y - tip.y
            let along = dx * ux + dy * uy, across = dx * -uy + dy * ux
            guard along <= span * 0.08, along >= -span * 0.5,
                  point.distance(to: tip) <= span * 0.55 else { return false }
            if along < -span * 0.07, abs(across) >= span * 0.06 {
                positive = positive || across > 0
                negative = negative || across < 0
            }
        }
        return positive && negative
    }
    private static func arrowPaths(tail: Point, tip: Point) -> [[Point]] {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let head = min(28, max(10, tail.distance(to: tip) * 0.2))
        return [[tail, tip]] + [-0.5, 0.5].map { offset in
            Point(x: tip.x - head * cos(angle + offset), y: tip.y - head * sin(angle + offset))
        }.map { [$0, tip] }
    }
    private static func straight(_ points: [Point]) -> (Point, Point, Double)? {
        guard let first = points.first, let last = points.last else { return nil }
        let chord = first.distance(to: last)
        guard chord >= 24, length(points) / chord <= 1.08 else { return nil }
        let dx = last.x - first.x, dy = last.y - first.y
        var deviation = 0.0
        for point in points {
            let cross = dx * (first.y - point.y) - (first.x - point.x) * dy
            deviation = max(deviation, abs(cross) / chord)
        }
        guard deviation / chord <= 0.04 else { return nil }
        return (first, last, 1 - deviation / chord)
    }
    private static func unique(_ points: [Point]) -> [Point] {
        var result: [Point] = []
        for point in points where result.last.map({ $0.distance(to: point) > 0.001 }) ?? true { result.append(point) }
        return result
    }
    private static func length(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
    private static func bounds(_ points: [Point]) -> Rect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let x = xs.min() ?? 0, y = ys.min() ?? 0
        return Rect(x: x, y: y, width: (xs.max() ?? x) - x, height: (ys.max() ?? y) - y)
    }
    /// Bounded iterative simplification; no recursive stack for dense ink.
    private static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
        guard points.count > 2 else { return points }
        var kept: Set<Int> = [0, points.count - 1], pending = [(0, points.count - 1)]
        while let (start, end) = pending.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end], chord = a.distance(to: b)
            var largest = tolerance, split: Int?
            for index in (start + 1)..<end {
                let p = points[index]
                let distance = chord < 0.001 ? a.distance(to: p)
                    : abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / chord
                if distance > largest { largest = distance; split = index }
            }
            if let split { kept.insert(split); pending.append((start, split)); pending.append((split, end)) }
        }
        return kept.sorted().map { points[$0] }
    }
}
