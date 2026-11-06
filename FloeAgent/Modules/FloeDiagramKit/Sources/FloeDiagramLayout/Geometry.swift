// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public enum DiagramPathID: Codable, Hashable, Sendable {
    case branch(UUID)
    case connection(UUID)
    public var uuid: UUID { switch self { case .branch(let id), .connection(let id): id } }
}
public enum DiagramPathSegment: Codable, Hashable, Sendable {
    case line(DiagramPoint)
    case cubic(control1: DiagramPoint, control2: DiagramPoint, end: DiagramPoint)
}
public struct DiagramEdgeGeometry: Sendable, Hashable {
    public var id: DiagramPathID
    public var from: UUID
    public var to: UUID
    public var start: DiagramPoint
    public var segments: [DiagramPathSegment]
    public var label: String
    public var labelPosition: Double
    public var color: String
    public var width: Double
    public var dashed: Bool
    public var startArrow: Bool
    public var endArrow: Bool
    public var routingFailed: Bool
    public var end: DiagramPoint {
        guard let segment = segments.last else { return start }
        switch segment { case .line(let end), .cubic(_, _, let end): return end }
    }
    public func polyline(steps: Int = 16) -> [DiagramPoint] {
        var output = [start], current = start
        for segment in segments {
            switch segment {
            case .line(let end): output.append(end); current = end
            case .cubic(let a, let b, let end):
                for i in 1...max(2, steps) {
                    let t = Double(i) / Double(max(2, steps)), u = 1 - t
                    output.append(.init(x: u*u*u*current.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*end.x,
                                        y: u*u*u*current.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*end.y))
                }
                current = end
            }
        }
        return output
    }
    public var labelPoint: DiagramPoint { point(at: labelPosition) }
    public func point(at fraction: Double) -> DiagramPoint {
        let points = polyline(), lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let target = max(0, min(1, fraction)) * lengths.reduce(0, +)
        var cursor = 0.0
        for i in lengths.indices {
            if cursor + lengths[i] >= target {
                let t = lengths[i] == 0 ? 0 : (target - cursor) / lengths[i]
                return .init(x: points[i].x + (points[i+1].x - points[i].x)*t, y: points[i].y + (points[i+1].y - points[i].y)*t)
            }
            cursor += lengths[i]
        }
        return end
    }
    public var bounds: DiagramRect {
        let points = polyline(steps: 24)
        let minX = points.map(\.x).min() ?? start.x, minY = points.map(\.y).min() ?? start.y
        return .init(x: minX, y: minY, width: max(1, (points.map(\.x).max() ?? minX) - minX), height: max(1, (points.map(\.y).max() ?? minY) - minY))
    }
    public func distance(to point: DiagramPoint) -> Double {
        let points = polyline(steps: 24)
        return zip(points, points.dropFirst()).map { a, b in
            let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx+dy*dy
            let t = length == 0 ? 0 : max(0, min(1, ((point.x-a.x)*dx+(point.y-a.y)*dy)/length))
            return hypot(point.x-a.x-t*dx, point.y-a.y-t*dy)
        }.min() ?? .infinity
    }
}

public struct DiagramSpatialIndex: Sendable {
    private let frames: [UUID: DiagramRect]
    private let cells: [Cell: Set<UUID>]
    private let oversized: Set<UUID>
    private let cellSize: Double
    private struct Cell: Hashable, Sendable { var x: Int; var y: Int }
    public init(frames: [UUID: DiagramRect], cellSize: Double = 256) {
        self.frames = frames; self.cellSize = max(32, cellSize)
        var cells: [Cell: Set<UUID>] = [:], oversized: Set<UUID> = []
        for (id, frame) in frames {
            let x0 = Int(floor(frame.x / self.cellSize)), x1 = Int(floor(frame.maxX / self.cellSize))
            let y0 = Int(floor(frame.y / self.cellSize)), y1 = Int(floor(frame.maxY / self.cellSize))
            if (x1-x0+1) * (y1-y0+1) > 4_096 { oversized.insert(id); continue }
            for x in x0...x1 { for y in y0...y1 { cells[.init(x: x, y: y), default: []].insert(id) } }
        }
        self.cells = cells; self.oversized = oversized
    }
    public func query(_ rect: DiagramRect) -> Set<UUID> {
        guard rect.isValid else { return [] }
        let x0 = Int(floor(rect.x / cellSize)), x1 = Int(floor(rect.maxX / cellSize))
        let y0 = Int(floor(rect.y / cellSize)), y1 = Int(floor(rect.maxY / cellSize))
        if (x1-x0+1) * (y1-y0+1) > 4_096 { return Set(frames.filter { $0.value.intersects(rect) }.map(\.key)) }
        var found = oversized
        for x in x0...x1 { for y in y0...y1 { found.formUnion(cells[.init(x: x, y: y)] ?? []) } }
        return Set(found.filter { frames[$0]?.intersects(rect) == true })
    }
}

public struct DiagramLayoutResult: Sendable {
    public var frames: [UUID: DiagramRect]
    public var edges: [DiagramEdgeGeometry]
    public var visibleRepresentatives: [UUID: UUID]
    public var bounds: DiagramRect
    public var spatialIndex: DiagramSpatialIndex
    public init(frames: [UUID: DiagramRect], edges: [DiagramEdgeGeometry], visibleRepresentatives: [UUID: UUID]) {
        self.frames = frames; self.edges = edges; self.visibleRepresentatives = visibleRepresentatives
        bounds = frames.values.reduce(nil as DiagramRect?) { $0?.union($1) ?? $1 } ?? .init()
        spatialIndex = .init(frames: frames)
    }
    public func hitElement(at point: DiagramPoint, page: DiagramPage) -> UUID? {
        let ids = spatialIndex.query(.init(x: point.x-1, y: point.y-1, width: 2, height: 2))
        let hits = page.elements.enumerated().filter { ids.contains($0.element.id) && frames[$0.element.id]?.contains(point) == true }.sorted { a,b in
            let x = Int(a.element.metadata["layer"] ?? "0") ?? 0, y = Int(b.element.metadata["layer"] ?? "0") ?? 0
            return x == y ? a.offset > b.offset : x > y
        }.map(\.element)
        return hits.first { !$0.kind.isContainer && $0.kind != .boundary }?.id ?? hits.first?.id
    }
    public func hitEdge(at point: DiagramPoint, zoom: Double = 1, screenTolerance: Double = 12) -> DiagramPathID? {
        let tolerance = screenTolerance / max(0.05, zoom)
        return edges.filter { $0.bounds.insetBy(-tolerance).contains(point) }.map { ($0.id, $0.distance(to: point)) }
            .filter { $0.1 <= tolerance }.min { $0.1 < $1.1 }?.0
    }
}
