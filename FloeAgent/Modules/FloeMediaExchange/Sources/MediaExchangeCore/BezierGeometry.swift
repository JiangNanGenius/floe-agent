// SPDX-License-Identifier: MPL-2.0
//
// Editable Bezier source and tessellation contracts for the drawing geometry
// adapter. The source path is a value type and is never mutated by a boolean
// or offset operation. Flattening tolerance is always supplied by the caller;
// there is no hidden CAD-unit conversion and no dependency on FloeCADKit.

import Foundation

public struct GeometryPoint: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = GeometryPoint(x: 0, y: 0)

    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func adding(_ other: GeometryPoint) -> GeometryPoint {
        GeometryPoint(x: x + other.x, y: y + other.y)
    }

    public func subtracting(_ other: GeometryPoint) -> GeometryPoint {
        GeometryPoint(x: x - other.x, y: y - other.y)
    }

    public func scaled(by factor: Double) -> GeometryPoint {
        GeometryPoint(x: x * factor, y: y * factor)
    }

    public func distance(to other: GeometryPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }
}

public struct BezierNode: Hashable, Sendable, Codable {
    public var point: GeometryPoint
    /// Incoming control handle in canvas coordinates; nil means coincident
    /// with `point` (a straight join).
    public var controlIn: GeometryPoint?
    /// Outgoing control handle in canvas coordinates; nil means coincident
    /// with `point`.
    public var controlOut: GeometryPoint?

    public init(
        point: GeometryPoint,
        controlIn: GeometryPoint? = nil,
        controlOut: GeometryPoint? = nil
    ) {
        self.point = point
        self.controlIn = controlIn
        self.controlOut = controlOut
    }
}

public enum GeometryError: Error, Equatable, CustomStringConvertible {
    case invalidTolerance(Double)
    case invalidPath(String)
    case tooManySegments(limit: Int)
    case recursionLimit
    case nonFinitePoint
    case quantizationOverflow
    case clipperError(String)
    case emptyResult

    public var description: String {
        switch self {
        case let .invalidTolerance(value): return "invalid tessellation tolerance \(value)"
        case let .invalidPath(reason): return "invalid Bezier path: \(reason)"
        case let .tooManySegments(limit): return "tessellation exceeded \(limit) segments"
        case .recursionLimit: return "tessellation recursion limit reached"
        case .nonFinitePoint: return "geometry contains a non-finite point"
        case .quantizationOverflow: return "geometry coordinate exceeds the integer quantizer"
        case let .clipperError(message): return "Clipper2 error: \(message)"
        case .emptyResult: return "geometry operation returned no paths"
        }
    }
}

public struct BezierPath: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var nodes: [BezierNode]
    public var isClosed: Bool

    public init(id: String, nodes: [BezierNode], isClosed: Bool = true) {
        self.id = id
        self.nodes = nodes
        self.isClosed = isClosed
    }

    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let first = nodes.first?.point else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for node in nodes {
            minX = min(minX, node.point.x)
            minY = min(minY, node.point.y)
            maxX = max(maxX, node.point.x)
            maxY = max(maxY, node.point.y)
        }
        return (minX, minY, maxX, maxY)
    }

    /// Tessellates the cubic segments with a caller-supplied maximum chord
    /// error in canvas units. A 16-segment flatness recursion ceiling bounds
    /// pathological input; exceeding it throws rather than silently reducing
    /// quality. The source path is not mutated.
    public func flattened(tolerance: Double, segmentLimit: Int = 200_000) throws -> [GeometryPoint] {
        guard tolerance.isFinite, tolerance > 0 else {
            throw GeometryError.invalidTolerance(tolerance)
        }
        guard segmentLimit > 0 else { throw GeometryError.tooManySegments(limit: segmentLimit) }
        guard nodes.count >= 2 else { throw GeometryError.invalidPath("need at least two nodes") }
        for node in nodes {
            guard node.point.isFinite,
                  node.controlIn?.isFinite ?? true,
                  node.controlOut?.isFinite ?? true else {
                throw GeometryError.nonFinitePoint
            }
        }

        var output: [GeometryPoint] = []
        var segmentCount = 0
        let pairCount = isClosed ? nodes.count : nodes.count - 1
        for index in 0..<pairCount {
            let current = nodes[index]
            let next = nodes[(index + 1) % nodes.count]
            output.append(current.point)
            let control1 = current.controlOut ?? current.point
            let control2 = next.controlIn ?? next.point
            var local: [GeometryPoint] = []
            try flattenCubic(
                p0: current.point,
                p1: control1,
                p2: control2,
                p3: next.point,
                tolerance: tolerance,
                depth: 0,
                output: &local,
                segmentCount: &segmentCount,
                segmentLimit: segmentLimit
            )
            // Drop the duplicate start point emitted by flattenCubic.
            if local.first == current.point {
                local.removeFirst()
            }
            output.append(contentsOf: local)
        }
        if isClosed, let first = output.first, let last = output.last, first == last {
            output.removeLast()
        }
        guard !output.isEmpty else { throw GeometryError.invalidPath("path flattened to nothing") }
        return output
    }

    private func flattenCubic(
        p0: GeometryPoint,
        p1: GeometryPoint,
        p2: GeometryPoint,
        p3: GeometryPoint,
        tolerance: Double,
        depth: Int,
        output: inout [GeometryPoint],
        segmentCount: inout Int,
        segmentLimit: Int
    ) throws {
        if depth >= 16 {
            throw GeometryError.recursionLimit
        }
        if segmentCount >= segmentLimit {
            throw GeometryError.tooManySegments(limit: segmentLimit)
        }
        let flatness = max(distanceToLine(p1, p0, p3), distanceToLine(p2, p0, p3))
        if flatness <= tolerance {
            output.append(p0)
            output.append(p3)
            segmentCount += 1
            return
        }
        let p01 = midpoint(p0, p1)
        let p12 = midpoint(p1, p2)
        let p23 = midpoint(p2, p3)
        let p012 = midpoint(p01, p12)
        let p123 = midpoint(p12, p23)
        let p0123 = midpoint(p012, p123)
        try flattenCubic(
            p0: p0, p1: p01, p2: p012, p3: p0123,
            tolerance: tolerance, depth: depth + 1, output: &output,
            segmentCount: &segmentCount, segmentLimit: segmentLimit
        )
        try flattenCubic(
            p0: p0123, p1: p123, p2: p23, p3: p3,
            tolerance: tolerance, depth: depth + 1, output: &output,
            segmentCount: &segmentCount, segmentLimit: segmentLimit
        )
    }

    private func midpoint(_ a: GeometryPoint, _ b: GeometryPoint) -> GeometryPoint {
        GeometryPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private func distanceToLine(_ point: GeometryPoint, _ start: GeometryPoint, _ end: GeometryPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared == 0 {
            return point.distance(to: start)
        }
        let cross = abs(dy * (point.x - start.x) - dx * (point.y - start.y))
        return cross / sqrt(lengthSquared)
    }
}

public struct TessellatedPolygon: Hashable, Sendable, Codable {
    public var points: [GeometryPoint]
    public var sourcePathIDs: [String]
    public var flatteningTolerance: Double
    public var quantizationScale: Double

    public init(
        points: [GeometryPoint],
        sourcePathIDs: [String],
        flatteningTolerance: Double,
        quantizationScale: Double
    ) {
        self.points = points
        self.sourcePathIDs = sourcePathIDs
        self.flatteningTolerance = flatteningTolerance
        self.quantizationScale = quantizationScale
    }

    public var area: Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return (minX, minY, maxX, maxY)
    }

    public var signedArea: Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }
}

public enum GeometryBooleanOperation: String, Codable, Hashable, Sendable {
    case intersection
    case union
    case difference
    case xor
}

public enum GeometryFillRule: String, Codable, Hashable, Sendable {
    case evenOdd
    case nonZero
    case positive
    case negative
}

public enum GeometryJoinType: String, Codable, Hashable, Sendable {
    case square
    case bevel
    case round
    case miter
}

public enum GeometryEndType: String, Codable, Hashable, Sendable {
    case polygon
    case joined
    case butt
    case square
    case round
}
