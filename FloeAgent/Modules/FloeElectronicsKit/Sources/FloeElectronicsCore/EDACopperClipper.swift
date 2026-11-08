// SPDX-License-Identifier: MPL-2.0
import Foundation
import Clipper2C

/// Direct binding to the existing pinned C ABI. No document/media engine.
/// Vector coordinates use a 1 nm integer grid; this is not a raster fill.
final class EDACopperClipper {
    typealias Paths = [[EDAPoint]]
    static let scale = 1_000_000.0
    static let grid = 1 / scale
    static let chordError = 0.0001 // mm; explicit round-offset chord error.
    static let safety = chordError + 20 * grid
    let cancelled: @Sendable () -> Bool
    private var remaining = 20_000_000
    private var nativeCalls = 0
    init(cancelled: @escaping @Sendable () -> Bool) { self.cancelled = cancelled }
    func step(_ cost: Int = 1) throws {
        if cancelled() { throw EDAError.cancelled }
        remaining -= max(1, cost)
        guard remaining >= 0 else { throw EDAError.invalid("copper fill geometry budget") }
    }
    var version: String { String(cString: floe_clipper_version()) }

    func boolean(_ operation: Int32, _ subject: Paths, _ clip: Paths = []) throws -> Paths {
        try step(); nativeCalls += 1
        guard nativeCalls <= 10_000 else { throw EDAError.invalid("copper fill native-call budget") }
        let a = try encode(subject), b = try encode(clip)
        let raw = a.coords.withUnsafeBufferPointer { ac in a.offsets.withUnsafeBufferPointer { ao in
            b.coords.withUnsafeBufferPointer { bc in b.offsets.withUnsafeBufferPointer { bo in
                floe_clipper_boolean(operation, 1, ac.baseAddress, ac.count, ao.baseAddress, subject.count,
                                     bc.baseAddress, bc.count, bo.baseAddress, clip.count)
            }}
        }}
        let result = try decode(raw)
        try step()
        return result
    }
    func union(_ paths: Paths) throws -> Paths { try boolean(1, paths) }
    func intersection(_ a: Paths, _ b: Paths) throws -> Paths { try boolean(0, a, b) }
    func difference(_ a: Paths, _ b: Paths) throws -> Paths { try boolean(2, a, b) }
    func offset(_ paths: Paths, _ delta: Double, open: Bool = false) throws -> Paths {
        try step(); nativeCalls += 1
        guard nativeCalls <= 10_000, delta.isFinite else { throw EDAError.invalid("copper fill offset budget") }
        let a = try encode(paths)
        let raw = a.coords.withUnsafeBufferPointer { ac in a.offsets.withUnsafeBufferPointer { ao in
            floe_clipper_offset(ac.baseAddress, ac.count, ao.baseAddress, paths.count,
                                delta * Self.scale, 2, open ? 4 : 0, 2, Self.chordError * Self.scale)
        }}
        let result = try decode(raw)
        try step()
        return result
    }
    func contour(_ polygon: [EDAPoint]) -> [EDAPoint] {
        EDAGeometry.signedArea(polygon) < 0 ? Array(polygon.reversed()) : polygon
    }
    func outer(_ shape: EDADRCOuterShape, inflation: Double = 0) throws -> Paths {
        switch shape {
        case .polygon(let polygon):
            return inflation == 0 ? [contour(polygon)] : try offset([contour(polygon)], inflation)
        case let .capsule(a, b, radius):
            return try offset([a == b ? [a] : [a, b]], radius + inflation + Self.safety, open: true)
        }
    }
    func solid(_ shape: EDADRCShape) throws -> Paths {
        // Connection witnesses must be a subset of the real pad copper.
        // Outer obstacle envelopes use the opposite, conservative direction.
        var result: Paths
        switch shape.outer {
        case .polygon(let path): result = [contour(path)]
        case let .capsule(a, b, r):
            guard r > 2 * Self.safety else { throw EDAError.unsupported("copper fill pad below curve precision") }
            result = try outer(.capsule(a, b, r), inflation: -2 * Self.safety)
        }
        if let hole = shape.hole {
            result = try difference(result, outer(.capsule(hole.center, hole.center, hole.radius)))
        }
        return result
    }
    static func area(_ paths: Paths) -> Double { paths.reduce(0) { $0 + EDAGeometry.signedArea($1) } }
    static func perimeter(_ paths: Paths) -> Double {
        paths.reduce(0) { sum, path in sum + EDAGeometry.edges(path).reduce(0) { $0 + $1.0.distance(to: $1.1) } }
    }

    /// Open each inner contour with vertical clipping planes through its
    /// interior. These are vector boolean partitions, not scanline samples.
    /// Every returned polygon is a solid. A hole is never emitted as a solid.
    func simpleSolids(_ paths: Paths) throws -> Paths {
        try step()
        if paths.isEmpty { return [] }
        let holes = paths.filter { EDAGeometry.signedArea($0) < 0 }
        var pieces: Paths = []
        if holes.isEmpty { pieces = paths }
        else {
            let points = paths.flatMap { $0 }
            guard let bounds = EDAGeometry.bounds(points) else { return [] }
            var cuts = Set<Double>()
            for hole in holes {
                try step(hole.count)
                guard let b = EDAGeometry.bounds(hole), b.max.x - b.min.x > 2 * Self.grid else {
                    throw EDAError.unsupported("copper fill hole below coordinate precision")
                }
                cuts.insert(((b.min.x + b.max.x) * 0.5 * Self.scale).rounded() / Self.scale)
            }
            guard cuts.count <= 2000 else { throw EDAError.invalid("copper fill hole decomposition budget") }
            let xs = [bounds.min.x] + cuts.sorted() + [bounds.max.x]
            for (a, b) in zip(xs, xs.dropFirst()) where b > a {
                try step()
                let slab = [EDAPoint(a, bounds.min.y - 1), .init(b, bounds.min.y - 1),
                            .init(b, bounds.max.y + 1), .init(a, bounds.max.y + 1)]
                let part = try intersection(paths, [slab])
                guard part.allSatisfy({ EDAGeometry.signedArea($0) > 0 }) else {
                    throw EDAError.unsupported("copper fill unresolved inner contour")
                }
                pieces.append(contentsOf: part)
            }
        }
        guard pieces.count <= 5000, pieces.reduce(0, { $0 + $1.count }) <= 50_000 else {
            throw EDAError.invalid("copper fill output budget")
        }
        for polygon in pieces {
            try step(polygon.count * polygon.count)
            guard EDAGeometry.simplePolygon(polygon) else {
                throw EDAError.unsupported("copper fill polygon below model precision or non-simple")
            }
        }
        // Prove the partition against the native boolean result. Rounding of
        // newly intersected edges is bounded by the same explicit 1 nm grid.
        let united = try union(pieces), delta = try boolean(3, paths, united)
        let areaBound = (Self.perimeter(paths) + Self.perimeter(pieces)) * Self.grid * 4
        guard abs(Self.area(delta)) <= max(Self.grid * Self.grid * 16, areaBound) else {
            throw EDAError.invalid("copper fill decomposition changed copper")
        }
        return pieces.map(canonical).sorted(by: lexicographic)
    }
    private func canonical(_ path: [EDAPoint]) -> [EDAPoint] {
        let p = contour(path)
        let start = p.indices.min { p[$0].x == p[$1].x ? p[$0].y < p[$1].y : p[$0].x < p[$1].x }!
        return Array(p[start...]) + Array(p[..<start])
    }
    private func lexicographic(_ a: [EDAPoint], _ b: [EDAPoint]) -> Bool {
        for (p, q) in zip(a, b) {
            if p.x != q.x { return p.x < q.x }
            if p.y != q.y { return p.y < q.y }
        }
        return a.count < b.count
    }
    private func encode(_ paths: Paths) throws -> (coords: [Int64], offsets: [Int]) {
        let count = paths.reduce(0) { $0 + $1.count }
        guard paths.count <= 10_000, count <= 20_000 else { throw EDAError.invalid("copper fill native input budget") }
        try step(count)
        var coords: [Int64] = [], offsets = [0]
        coords.reserveCapacity(count * 2)
        for path in paths {
            for point in path {
                guard point.isValid else { throw EDAError.invalid("copper fill coordinate") }
                coords.append(Int64((point.x * Self.scale).rounded()))
                coords.append(Int64((point.y * Self.scale).rounded()))
            }
            offsets.append(coords.count / 2)
        }
        return (coords, offsets)
    }
    private func decode(_ raw: FloeClipperResult) throws -> Paths {
        var raw = raw
        defer { floe_clipper_result_free(&raw) }
        guard raw.error_code == 0 else {
            throw EDAError.invalid(raw.error_message.map { String(cString: $0) } ?? "copper fill native error")
        }
        guard raw.path_count <= 10_000, raw.coord_count <= 100_000 else { throw EDAError.invalid("copper fill native result budget") }
        guard raw.path_count > 0 else { return [] }
        guard let coords = raw.coords, let offsets = raw.offsets else { throw EDAError.invalid("copper fill result storage") }
        var paths: Paths = []
        for index in 0..<raw.path_count {
            try step()
            let a = offsets[index], b = offsets[index + 1]
            guard a <= b, b * 2 <= raw.coord_count else { throw EDAError.invalid("copper fill result offsets") }
            paths.append((a..<b).map { EDAPoint(Double(coords[$0 * 2]) / Self.scale, Double(coords[$0 * 2 + 1]) / Self.scale) })
        }
        return paths
    }
}
