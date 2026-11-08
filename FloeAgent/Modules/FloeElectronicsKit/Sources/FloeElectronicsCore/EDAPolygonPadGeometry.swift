// SPDX-License-Identifier: MPL-2.0
import Foundation

/// One connected, simple, hole-free polygon on a single outside copper layer.
/// Vertices are pad-local mm before pad rotation; implicit closure does not
/// repeat the first point. `size` is checked metadata, never copper geometry.
public enum EDAPolygonPadGeometry {
    public static let maximumVertices = 256

    public static func validate(_ pad: EDAPad) throws {
        guard pad.shape == .polygon else {
            guard pad.polygon == nil else { throw EDAError.invalid("polygon vertices require polygon pad shape") }
            return
        }
        guard let vertices = pad.polygon else { throw EDAError.missing("pad.polygon") }
        try validateOutline(vertices)
        let size = try boundingSize(vertices)
        guard pad.size.isValid, abs(pad.size.x - size.x) <= EDAGeometry.tolerance,
              abs(pad.size.y - size.y) <= EDAGeometry.tolerance else { throw EDAError.invalid("polygon pad size must match its outline bounds") }
        try validateSingleSurface(pad)
    }
    public static func validateSingleSurface(_ pad: EDAPad) throws {
        guard pad.drill == nil, pad.drillPlated == nil else { throw EDAError.unsupported("polygon pad supports an undrilled SMD only") }
        let layers = Set(pad.layers)
        guard layers.count == pad.layers.count else { throw EDAError.invalid("duplicate polygon pad layer") }
        let copper = layers.intersection(["F.Cu", "B.Cu"])
        guard copper.count == 1, let surface = copper.first else { throw EDAError.unsupported("polygon pad requires one outside copper layer") }
        let prefix = surface.hasPrefix("F.") ? "F." : "B."
        guard layers.isSubset(of: [surface, prefix + "Mask", prefix + "Paste"]) else {
            throw EDAError.unsupported("polygon pad supports only same-side explicit mask and paste")
        }
    }
    public static func validateOutline(_ vertices: [EDAPoint]) throws {
        guard (3...maximumVertices).contains(vertices.count), vertices.allSatisfy(\.isValid) else {
            throw EDAError.invalid("polygon pad needs 3...256 finite local points")
        }
        for (a, b) in EDAGeometry.edges(vertices) where a.distance(to: b) <= EDAGeometry.tolerance {
            throw EDAError.invalid("polygon pad has a zero-length or repeated closing edge")
        }
        // Adjacent backtracking overlaps are not skipped as ordinary shared
        // endpoints by the generic simple-polygon test.
        for i in vertices.indices {
            let a = vertices[(i + vertices.count - 1) % vertices.count] - vertices[i]
            let b = vertices[(i + 1) % vertices.count] - vertices[i]
            if abs(EDAGeometry.cross(a, b)) <= EDAGeometry.tolerance * EDAGeometry.tolerance,
               EDAGeometry.dot(a, b) > 0 { throw EDAError.invalid("polygon pad edges overlap") }
        }
        guard EDAGeometry.simplePolygon(vertices) else { throw EDAError.invalid("polygon pad must be simple, nonzero and hole-free") }
        guard EDAGeometry.contains(.zero, polygon: vertices), distanceToBoundary(.zero, vertices) > EDAGeometry.tolerance else {
            throw EDAError.invalid("polygon pad outline must enclose its center")
        }
    }
    public static func boundingSize(_ vertices: [EDAPoint]) throws -> EDAPoint {
        guard let bounds = EDAGeometry.bounds(vertices) else { throw EDAError.missing("polygon pad vertices") }
        return bounds.max - bounds.min
    }
    public static func replacingOutline(of pad: EDAPad, with vertices: [EDAPoint]) throws -> EDAPad {
        try validateSingleSurface(pad)
        var result = pad
        result.shape = .polygon; result.polygon = vertices; result.size = try boundingSize(vertices)
        try validate(result)
        return result
    }
    /// Consumers call this after the normal project validator. No hull, size
    /// rectangle, hole reconstruction or shape repair is ever substituted.
    public static func vertices(_ pad: EDAPad, in footprint: EDAFootprint? = nil) -> [EDAPoint]? {
        guard pad.shape == .polygon, let vertices = pad.polygon, pad.position.isValid, pad.angle.isFinite,
              (3...maximumVertices).contains(vertices.count), vertices.allSatisfy(\.isValid) else { return nil }
        if let footprint, !footprint.position.isValid || !footprint.angle.isFinite { return nil }
        return vertices.map { point in
            let local = point.transformed(origin: pad.position, angle: pad.angle)
            return footprint?.point(local) ?? local
        }
    }
    public static func localDistance(_ point: EDAPoint, vertices: [EDAPoint]) -> Double {
        guard point.isValid, vertices.count >= 3 else { return .infinity }
        return EDAGeometry.contains(point, polygon: vertices) ? 0 : distanceToBoundary(point, vertices)
    }
    private static func distanceToBoundary(_ point: EDAPoint, _ vertices: [EDAPoint]) -> Double {
        EDAGeometry.edges(vertices).map { EDAGeometry.pointDistance(point, to: $0.0, $0.1) }.min() ?? .infinity
    }
}
