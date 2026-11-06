// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public enum DiagramRouter {
    public static func edges(page: DiagramPage, frames: [UUID: DiagramRect], representatives: [UUID: UUID]) throws -> [DiagramEdgeGeometry] {
        let index = DiagramPageIndex(page)
        let obstacles = frames.filter { index.elements[$0.key].map { !$0.kind.isContainer && $0.kind != .summary && $0.kind != .boundary } ?? false }
        let spatial = DiagramSpatialIndex(frames: obstacles)
        let branchAvoidance = page.elements.contains { $0.frame != nil && !$0.kind.isContainer }
        var result: [DiagramEdgeGeometry] = []
        for node in page.elements {
            try Task.checkCancellation()
            guard let parent = node.parentID, frames[node.id] != nil, frames[parent] != nil else { continue }
            let route = DiagramRouteKind(rawValue: node.metadata["branchRoute"] ?? "") ?? .curve
            let a = frames[parent]!, b = frames[node.id]!
            let owner = index.elements[parent]
            let structure = owner?.structure ?? (owner?.parentID == nil ? page.structure : .right)
            // A tree branch follows its layout axis. Choosing each endpoint by
            // normalized distance can send it behind a taller sibling card.
            let vertical = structure == .organization
            let positive = vertical ? b.center.y >= a.center.y : b.center.x >= a.center.x
            let source: DiagramAnchorSide = vertical ? (positive ? .bottom : .top) : (positive ? .right : .left)
            let target: DiagramAnchorSide = vertical ? (positive ? .top : .bottom) : (positive ? .left : .right)
            let edge = DiagramConnection(from: parent, to: node.id, route: route,
                                         sourceAnchor: source,targetAnchor: target,
                                         color: node.metadata["branchColor"] ?? page.theme.branchColor,
                                         width: Double(node.metadata["branchWidth"] ?? "") ?? (index.elements[parent]?.parentID == nil ? 1.8 : 1.3),
                                         dashed: node.metadata["branchDashed"] == "true", endArrow: node.metadata["branchArrow"] == "true")
            result.append(try geometry(id: .branch(node.id), edge: edge, from: parent, to: node.id, frames: frames, obstacles: obstacles, spatial: spatial, branchAvoidance: branchAvoidance))
        }
        for edge in page.connections {
            try Task.checkCancellation()
            let from = representatives[edge.from] ?? edge.from, to = representatives[edge.to] ?? edge.to
            guard frames[from] != nil, frames[to] != nil else { continue }
            if from == to && edge.from != edge.to { continue }
            result.append(try geometry(id: .connection(edge.id), edge: edge, from: from, to: to, frames: frames, obstacles: obstacles, spatial: spatial, branchAvoidance: branchAvoidance))
        }
        return result
    }
    private static func automaticSide(from a: DiagramRect, toward b: DiagramRect) -> DiagramAnchorSide {
        let dx = b.center.x-a.center.x, dy = b.center.y-a.center.y
        if abs(dx)/max(1, a.width) >= abs(dy)/max(1, a.height) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }
    public static func anchor(_ rect: DiagramRect, side: DiagramAnchorSide) -> DiagramPoint {
        switch side {
        case .left: .init(x: rect.x, y: rect.center.y)
        case .right: .init(x: rect.maxX, y: rect.center.y)
        case .top: .init(x: rect.center.x, y: rect.y)
        case .bottom: .init(x: rect.center.x, y: rect.maxY)
        case .automatic: rect.center
        }
    }
    private static func outward(_ side: DiagramAnchorSide, length: Double) -> DiagramPoint {
        switch side { case .left: .init(x: -length); case .right: .init(x: length); case .top: .init(y: -length); case .bottom: .init(y: length); default: .zero }
    }
    private static func geometry(id: DiagramPathID, edge: DiagramConnection, from: UUID, to: UUID,
                                 frames: [UUID: DiagramRect], obstacles: [UUID: DiagramRect], spatial: DiagramSpatialIndex,
                                 branchAvoidance: Bool) throws -> DiagramEdgeGeometry {
        let a = frames[from]!, b = frames[to]!
        let sourceSide = edge.sourceAnchor == .automatic ? automaticSide(from: a, toward: b) : edge.sourceAnchor
        let targetSide = edge.targetAnchor == .automatic ? automaticSide(from: b, toward: a) : edge.targetAnchor
        let s = anchor(a, side: sourceSide), t = anchor(b, side: targetSide)
        let roi = a.union(b).insetBy(-180)
        let branch: Bool = { if case .branch = id { return true }; return false }()
        let nearby = branch && !branchAvoidance ? [] : spatial.query(roi).subtracting([from, to]).compactMap { obstacles[$0] }.sorted {
            hypot($0.center.x-roi.center.x, $0.center.y-roi.center.y) < hypot($1.center.x-roi.center.x, $1.center.y-roi.center.y)
        }.prefix(40).map { $0.insetBy(-10) }
        var segments: [DiagramPathSegment] = [], failed = false
        if from == to {
            let start = anchor(a, side: .right), end = anchor(a, side: .top), reach = max(40, a.width*0.5)
            let path: [DiagramPathSegment] = [.cubic(control1: .init(x: start.x+reach, y: start.y), control2: .init(x: end.x+reach, y: end.y-reach), end: end)]
            return .init(id: id, from: from, to: to, start: start, segments: path, label: edge.label, labelPosition: edge.labelPosition, color: edge.color, width: edge.width, dashed: edge.dashed, startArrow: edge.startArrow, endArrow: edge.endArrow, routingFailed: false)
        }
        if !edge.waypoints.isEmpty {
            segments = edge.waypoints.map(DiagramPathSegment.line) + [.line(t)]
        } else if edge.route == .straight {
            segments = [.line(t)]
        } else if edge.route == .curve {
            let horizontal = sourceSide == .left || sourceSide == .right
            let reach = branch ? abs(horizontal ? t.x-s.x : t.y-s.y)*0.5 : max(28, hypot(t.x-s.x, t.y-s.y)*0.45)
            var c1 = s+outward(sourceSide, length: reach), c2 = t+outward(targetSide, length: reach)
            if let raw = edge.metadata["legacyControl1"], let data = raw.data(using: .utf8), let offset = try? DiagramCodec.decode(DiagramPoint.self, from: data) { c1 = s+offset }
            if let raw = edge.metadata["legacyControl2"], let data = raw.data(using: .utf8), let offset = try? DiagramCodec.decode(DiagramPoint.self, from: data) { c2 = t+offset }
            segments = [.cubic(control1: c1, control2: c2, end: t)]
            let candidate = DiagramEdgeGeometry(id: id, from: from, to: to, start: s, segments: segments, label: "", labelPosition: 0.5, color: "", width: 1, dashed: false, startArrow: false, endArrow: false, routingFailed: false)
            let line = candidate.polyline(steps: 24)
            if !nearby.isEmpty && edge.metadata["legacyControl1"] == nil && edge.metadata["legacyControl2"] == nil && zip(line, line.dropFirst()).contains(where: { !clear($0.0, $0.1, obstacles: nearby) }) {
                let routed = try orthogonal(s+outward(sourceSide, length: 18), t+outward(targetSide, length: 18), obstacles: nearby)
                failed = !routed.success; segments = rounded([s]+routed.points+[t], radius: 12)
            }
        } else {
            let routed = try orthogonal(s+outward(sourceSide, length: 18), t+outward(targetSide, length: 18), obstacles: nearby)
            failed = !routed.success; segments = rounded([s]+routed.points+[t], radius: 8)
        }
        return .init(id: id, from: from, to: to, start: s, segments: segments, label: edge.label,
                     labelPosition: edge.labelPosition, color: edge.color, width: edge.width,
                     dashed: edge.dashed, startArrow: edge.startArrow, endArrow: edge.endArrow, routingFailed: failed)
    }
    /// A rounded polyline expressed as lines and cubic corners, shared by screen and vector exporters.
    private static func rounded(_ input: [DiagramPoint], radius: Double) -> [DiagramPathSegment] {
        var points: [DiagramPoint] = []
        for p in input where points.last != p { points.append(p) }
        guard points.count > 1 else { return [] }
        var output: [DiagramPathSegment] = []
        for i in 1..<points.count-1 {
            let a = points[i-1], p = points[i], b = points[i+1]
            let incoming = hypot(p.x-a.x, p.y-a.y), outgoing = hypot(b.x-p.x, b.y-p.y), r = min(radius, incoming/2, outgoing/2)
            guard r > 0.001 else { output.append(.line(p)); continue }
            let u = DiagramPoint(x: p.x-(p.x-a.x)/incoming*r, y: p.y-(p.y-a.y)/incoming*r)
            let v = DiagramPoint(x: p.x+(b.x-p.x)/outgoing*r, y: p.y+(b.y-p.y)/outgoing*r)
            output.append(.line(u))
            output.append(.cubic(control1: .init(x: u.x+(p.x-u.x)*2/3, y: u.y+(p.y-u.y)*2/3),
                                 control2: .init(x: v.x+(p.x-v.x)*2/3, y: v.y+(p.y-v.y)*2/3), end: v))
        }
        output.append(.line(points.last!)); return output
    }
    /// Segment/rectangle intersection excluding a tiny boundary tolerance.
    public static func clear(_ a: DiagramPoint, _ b: DiagramPoint, obstacles: [DiagramRect]) -> Bool {
        for box in obstacles {
            let r = box.insetBy(0.05), dx = b.x-a.x, dy = b.y-a.y
            var low = 0.0, high = 1.0, intersects = true
            for (p, q) in [(-dx, a.x-r.x), (dx, r.maxX-a.x), (-dy, a.y-r.y), (dy, r.maxY-a.y)] {
                if abs(p) < 1e-9 { if q < 0 { intersects = false; break } }
                else {
                    let t = q/p
                    if p < 0 { low = max(low, t) } else { high = min(high, t) }
                    if low > high { intersects = false; break }
                }
            }
            if intersects && low <= high { return false }
        }
        return true
    }
    private struct QueueItem { var index: Int; var cost: Double }
    private struct Heap {
        var storage: [QueueItem] = []
        mutating func push(_ item: QueueItem) {
            storage.append(item); var i = storage.count-1
            while i > 0 {
                let p = (i-1)/2; if storage[p].cost <= storage[i].cost { break }
                storage.swapAt(i, p); i = p
            }
        }
        mutating func pop() -> QueueItem? {
            guard !storage.isEmpty else { return nil }
            if storage.count == 1 { return storage.removeLast() }
            let first = storage[0]; storage[0] = storage.removeLast(); var i = 0
            while 2*i+1 < storage.count {
                var child = 2*i+1
                if child+1 < storage.count && storage[child+1].cost < storage[child].cost { child += 1 }
                if storage[i].cost <= storage[child].cost { break }
                storage.swapAt(i, child); i = child
            }
            return first
        }
    }
    private static func orthogonal(_ start: DiagramPoint, _ end: DiagramPoint, obstacles: [DiagramRect]) throws -> (points: [DiagramPoint], success: Bool) {
        for bend in [DiagramPoint(x: end.x, y: start.y), DiagramPoint(x: start.x, y: end.y)] {
            if clear(start, bend, obstacles: obstacles) && clear(bend, end, obstacles: obstacles) { return ([start, bend, end], true) }
        }
        let xs = Array(Set([start.x, end.x] + obstacles.flatMap { [$0.x, $0.maxX] } + [min(start.x, end.x)-60, max(start.x, end.x)+60])).sorted()
        let ys = Array(Set([start.y, end.y] + obstacles.flatMap { [$0.y, $0.maxY] } + [min(start.y, end.y)-60, max(start.y, end.y)+60])).sorted()
        let ny = ys.count, total = xs.count*ny
        guard total <= 10_000 else { return ([start, .init(x: end.x, y: start.y), end], false) }
        let first = xs.firstIndex(of: start.x)!*ny+ys.firstIndex(of: start.y)!, last = xs.firstIndex(of: end.x)!*ny+ys.firstIndex(of: end.y)!
        func point(_ n: Int) -> DiagramPoint { .init(x: xs[n/ny], y: ys[n%ny]) }
        var distance = [Double](repeating: .infinity, count: total), parent = [Int](repeating: -1, count: total), visited: Set<Int> = [], heap = Heap()
        distance[first] = 0; heap.push(.init(index: first, cost: 0)); var iterations = 0
        while let current = heap.pop() {
            let n = current.index
            if !visited.insert(n).inserted { continue }
            if n == last {
                var path = [point(n)], cursor = n
                while parent[cursor] >= 0 { cursor = parent[cursor]; path.append(point(cursor)) }
                return (Array(path.reversed()), true)
            }
            iterations += 1; if iterations.isMultiple(of: 128) { try Task.checkCancellation() }
            let x = n/ny, y = n%ny
            let neighbors = [(x-1, y), (x+1, y), (x, y-1), (x, y+1)].filter { $0.0 >= 0 && $0.0 < xs.count && $0.1 >= 0 && $0.1 < ny }
            for (nx, nyIndex) in neighbors {
                let next = nx*ny+nyIndex, a = point(n), b = point(next)
                guard !visited.contains(next), clear(a, b, obstacles: obstacles) else { continue }
                let cost = distance[n]+abs(a.x-b.x)+abs(a.y-b.y)
                if cost < distance[next] {
                    distance[next] = cost; parent[next] = n
                    heap.push(.init(index: next, cost: cost+abs(b.x-end.x)+abs(b.y-end.y)))
                }
            }
        }
        return ([start, .init(x: end.x, y: start.y), end], false)
    }
}
