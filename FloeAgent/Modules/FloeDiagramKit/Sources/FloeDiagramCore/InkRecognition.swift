// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct DiagramInkStroke: Sendable, Hashable {
    public var points: [DiagramPoint]
    public init(points: [DiagramPoint]) { self.points = points }
}
public enum DiagramRecognizedInk: Sendable, Hashable {
    case rectangle(DiagramRect, strokeIndices: Set<Int>)
    case ellipse(DiagramRect, strokeIndices: Set<Int>)
    case arrow(from: DiagramPoint, to: DiagramPoint, strokeIndices: Set<Int>)
}
public enum DiagramInkRecognizer {
    /// Conservative geometry recognition; ambiguous drawings stay ink. No network or model is needed.
    public static func recognize(_ strokes: [DiagramInkStroke]) -> [DiagramRecognizedInk] {
        var output: [DiagramRecognizedInk] = [], consumed: Set<Int> = []
        for (i, stroke) in strokes.enumerated() {
            guard stroke.points.count >= 4, stroke.points.allSatisfy(\.isFinite), let first = stroke.points.first, let last = stroke.points.last else { continue }
            let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
            let box = DiagramRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!)
            guard box.width >= 16, box.height >= 16 else { continue }
            let diagonal = hypot(box.width, box.height), closed = hypot(first.x-last.x, first.y-last.y) < diagonal*0.16
            if closed {
                let tolerance = max(1.5, min(box.width, box.height)*0.06)
                let edgeRatio = Double(stroke.points.filter { min(abs($0.x-box.x), abs($0.x-box.maxX), abs($0.y-box.y), abs($0.y-box.maxY)) <= tolerance }.count)/Double(stroke.points.count)
                let ellipseRatio = Double(stroke.points.filter {
                    let x = ($0.x-box.center.x)/(box.width/2), y = ($0.y-box.center.y)/(box.height/2)
                    return abs(x*x+y*y-1) < 0.28
                }.count)/Double(stroke.points.count)
                if edgeRatio > 0.88 { output.append(.rectangle(box, strokeIndices: [i])); consumed.insert(i) }
                else if ellipseRatio > 0.85 { output.append(.ellipse(box, strokeIndices: [i])); consumed.insert(i) }
            }
        }
        // Shaft plus two wings, or a continuous arrow whose two wings follow its farthest point.
        for (i, stroke) in strokes.enumerated() where !consumed.contains(i) {
            guard let tail = stroke.points.first, let tip = stroke.points.max(by: { distance($0, tail) < distance($1, tail) }) else { continue }
            let length = distance(tail, tip); guard length > 30 else { continue }
            let vx = (tip.x-tail.x)/length, vy = (tip.y-tail.y)/length
            var wings: [(DiagramPoint, Int)] = []
            for (j, candidate) in strokes.enumerated() where !consumed.contains(j) {
                guard let first = candidate.points.first, let last = candidate.points.last else { continue }
                if j == i {
                    guard let index = candidate.points.firstIndex(of: tip) else { continue }
                    wings += candidate.points.dropFirst(index+1).map { ($0, j) }
                } else {
                    if distance(first, tip) < max(14, length*0.12) { wings.append((last, j)) }
                    if distance(last, tip) < max(14, length*0.12) { wings.append((first, j)) }
                }
            }
            let candidates = wings.filter {
                let dx = $0.0.x-tip.x, dy = $0.0.y-tip.y, distance = hypot(dx, dy)
                let along = -(dx*vx+dy*vy), across = abs(dx*vy-dy*vx)
                return distance > 7 && distance < length*0.6 && along > 3 && across / max(1, along) > 0.25 && across / max(1, along) < 2.2
            }
            if let upper = candidates.first(where: { ($0.0.x-tip.x)*vy-($0.0.y-tip.y)*vx > 0 }),
               let lower = candidates.first(where: { ($0.0.x-tip.x)*vy-($0.0.y-tip.y)*vx < 0 }) {
                let ids: Set<Int> = [i, upper.1, lower.1]
                output.append(.arrow(from: tail, to: tip, strokeIndices: ids)); consumed.formUnion(ids)
            }
        }
        return output
    }
    private static func distance(_ a: DiagramPoint, _ b: DiagramPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
}
