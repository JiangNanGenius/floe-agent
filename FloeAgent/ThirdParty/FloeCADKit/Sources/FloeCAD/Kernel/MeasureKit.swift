//
//  MeasureKit.swift
//  openshape3d
//
//  Measurement math for the Measure tool and selection info bar: body volume,
//  surface/face area, world bounding box, point-to-point distance, and sketch
//  entity metrics. Pure functions over kernel types; all math in Double.
//

import Foundation
import simd

nonisolated enum MeasureKit {

    // MARK: - Body measurements

    /// Volume of a closed mesh via the signed-tetrahedron sum (divergence
    /// theorem): V = Σ dot(p0, p1 × p2) / 6 over triangles. `scale` is the
    /// body's uniform scale (volume scales with s³). Returns the magnitude —
    /// winding order flips only the sign.
    static func bodyVolume(_ mesh: RenderMesh, scale: Double = 1) -> Double {
        var sum = 0.0
        var i = 0
        while i + 2 < mesh.indices.count {
            let p0 = SIMD3<Double>(mesh.positions[Int(mesh.indices[i])])
            let p1 = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 1])])
            let p2 = SIMD3<Double>(mesh.positions[Int(mesh.indices[i + 2])])
            sum += simd_dot(p0, simd_cross(p1, p2))
            i += 3
        }
        return abs(sum) / 6 * scale * scale * scale
    }

    /// The volume to REPORT for a body: exact from its B-rep when it has one,
    /// the render mesh otherwise.
    ///
    /// The mesh is a tessellation, so on curved surfaces it reads low — an
    /// inscribed 48-gon is ~0.3% under the true circle, and every curved
    /// catalogue part rebuilt in the real-part validation landed at exactly
    /// that offset (wheel, revolved housing, drafted cone: 0.27–0.29%). The
    /// geometry was right; the ruler was faceted. `BRepGProp` integrates the
    /// analytic surfaces, so a cylinder reads π·r²·h to the mm³. Falls back
    /// to the mesh when there is no B-rep (a mesh-only op) or the kernel
    /// reports 0 (its failure value) — never silently reports nothing.
    static func volume(of body: Body) -> Double {
        let s = body.transform.scale
        if let brep = body.brep {
            let exact = OCCTKernel.volume(brep)
            if exact > 0 { return exact * s * s * s }
        }
        return bodyVolume(body.render, scale: s)
    }

    /// Total surface area of the mesh (× scale²).
    static func surfaceArea(_ mesh: RenderMesh, scale: Double = 1) -> Double {
        area(of: mesh, triangles: 0..<mesh.triangleCount, scale: scale)
    }

    /// Area of a triangle subset (e.g. a `PlanarFace.triangles` selection),
    /// × scale². Indices are triangle numbers into the mesh, not buffer offsets.
    static func faceArea(_ mesh: RenderMesh, triangles: [Int], scale: Double = 1) -> Double {
        area(of: mesh, triangles: triangles, scale: scale)
    }

    private static func area(
        of mesh: RenderMesh,
        triangles: some Sequence<Int>,
        scale: Double
    ) -> Double {
        var sum = 0.0
        for t in triangles {
            let base = t * 3
            guard base >= 0, base + 2 < mesh.indices.count else { continue }
            let p0 = SIMD3<Double>(mesh.positions[Int(mesh.indices[base])])
            let p1 = SIMD3<Double>(mesh.positions[Int(mesh.indices[base + 1])])
            let p2 = SIMD3<Double>(mesh.positions[Int(mesh.indices[base + 2])])
            sum += simd_length(simd_cross(p1 - p0, p2 - p0)) / 2
        }
        return sum * scale * scale
    }

    /// World-space AABB of the given bodies: transform the 8 local-AABB
    /// corners per body (cheap and correct for TRS). Nil when no geometry.
    static func boundingBox(bodies: [Body]) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var result: (min: SIMD3<Double>, max: SIMD3<Double>)?
        for body in bodies where !body.render.positions.isEmpty {
            let aabb = body.render.localAABB
            for i in 0..<8 {
                let corner = SIMD3<Double>(
                    Double((i & 1) == 0 ? aabb.min.x : aabb.max.x),
                    Double((i & 2) == 0 ? aabb.min.y : aabb.max.y),
                    Double((i & 4) == 0 ? aabb.min.z : aabb.max.z)
                )
                let world = body.transform.applying(to: corner)
                if let current = result {
                    result = (simd_min(current.min, world), simd_max(current.max, world))
                } else {
                    result = (world, world)
                }
            }
        }
        return result
    }

    /// Perimeter of a closed 2D loop (last point connects back to the first).
    static func perimeter(of loop: [SIMD2<Double>]) -> Double {
        guard loop.count > 1 else { return 0 }
        var sum = 0.0
        for i in 0..<loop.count {
            sum += simd_length(loop[(i + 1) % loop.count] - loop[i])
        }
        return sum
    }

    // MARK: - Point-to-point

    /// Euclidean distance plus per-axis deltas (b − a).
    static func distance(
        a: SIMD3<Double>,
        b: SIMD3<Double>
    ) -> (distance: Double, deltas: SIMD3<Double>) {
        let deltas = b - a
        return (simd_length(deltas), deltas)
    }

    // MARK: - Sketch entity metrics

    /// Length of a sketch entity: line length, rect perimeter, circle
    /// circumference.
    static func length(of entity: SketchEntity) -> Double {
        switch entity {
        case let .line(_, a, b):
            simd_length(b - a)
        case let .rect(_, lo, hi):
            2 * (abs(hi.x - lo.x) + abs(hi.y - lo.y))
        case let .circle(_, _, radius):
            2 * .pi * radius
        case let .arc(_, _, radius, startAngle, endAngle):
            arcLength(radius: radius, startAngle: startAngle, endAngle: endAngle)
        case let .ellipse(_, _, radiusX, radiusY, _):
            ellipsePerimeter(radiusX: radiusX, radiusY: radiusY)
        case let .polygon(_, _, radius, sides, _):
            Double(sides) * 2 * radius * sin(.pi / Double(sides))
        case let .spline(_, points, closed):
            // Arc length of the tessellated curve — the same polyline the user
            // sees, so the readout matches the drawing.
            polylineLength(SketchEntity.splinePoints(points, closed: closed), closed: closed)
        }
    }

    /// Summed segment length of a polyline; `closed` adds the wrap-around span.
    static func polylineLength(_ points: [SIMD2<Double>], closed: Bool) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += simd_length(points[i] - points[i - 1]) }
        if closed, let first = points.first, let last = points.last {
            total += simd_length(first - last)
        }
        return total
    }

    /// Ramanujan's approximation for an ellipse perimeter.
    static func ellipsePerimeter(radiusX: Double, radiusY: Double) -> Double {
        guard radiusX + radiusY > 0 else { return 0 }
        let h = pow((radiusX - radiusY) / (radiusX + radiusY), 2)
        return .pi * (radiusX + radiusY) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    }

    /// Radius for circular entities; nil for lines/rects.
    static func radius(of entity: SketchEntity) -> Double? {
        if case let .circle(_, _, radius) = entity { radius } else { nil }
    }

    /// Diameter for circular entities; nil for lines/rects.
    static func diameter(of entity: SketchEntity) -> Double? {
        radius(of: entity).map { $0 * 2 }
    }

    /// Arc length for a circular arc spanning `startAngle`→`endAngle`
    /// (radians, CCW). Ready for the arc sketch entity; also used for
    /// circular-edge measurements.
    static func arcLength(radius: Double, startAngle: Double, endAngle: Double) -> Double {
        var sweep = (endAngle - startAngle).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 { sweep += 2 * .pi }
        return radius * sweep
    }

    /// Enclosed area of a closed profile (positive regardless of winding).
    static func area(of profile: Profile) -> Double {
        abs(profile.area)
    }
}
