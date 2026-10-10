//
//  EuclidBridge.swift
//  openshape3d
//
//  Conversion layer between Euclid types (Double-precision, polygon soup)
//  and the flat Float32 buffers the Metal viewport consumes.
//

import Foundation
import simd
import Euclid

nonisolated enum EuclidBridge {
    /// Quantization for vertex welding: positions/normals equal within this
    /// tolerance share a render vertex. Preserves hard edges because the
    /// normal participates in the key.
    private static let weldQuantum: Float = 1e-5

    private struct WeldKey: Hashable {
        let px, py, pz: Int64
        let nx, ny, nz: Int64

        init(position: SIMD3<Float>, normal: SIMD3<Float>, quantum: Float) {
            let inv = 1 / quantum
            // key64: a raw Int32/Int64(_: Float) traps on NaN, and an Int32
            // key at this quantum saturates at ±21 m — which silently WELDED
            // far-apart vertices together instead. Int64 + NaN guard.
            px = MeshQuantize.key64(position.x, inverseQuantum: inv)
            py = MeshQuantize.key64(position.y, inverseQuantum: inv)
            pz = MeshQuantize.key64(position.z, inverseQuantum: inv)
            nx = MeshQuantize.key64(normal.x, inverseQuantum: inv)
            ny = MeshQuantize.key64(normal.y, inverseQuantum: inv)
            nz = MeshQuantize.key64(normal.z, inverseQuantum: inv)
        }
    }

    /// Every polygon of `mesh` as triangles — the SAME triangles
    /// `Mesh.triangulate()` produces, without building the intermediate
    /// `Mesh`. That intermediate is not free: Euclid carries the source
    /// mesh's cached "is watertight" claim onto it and, in a Debug build,
    /// `assert`s the claim against the triangles. A CSG result can be
    /// watertight as polygons yet not as triangles — a polygon whose
    /// vertices sit 5e-7 mm apart (a coincident-face union of a Float32-
    /// rebuilt body and a Double one, 2026-09-02) triangulates to one fewer
    /// triangle, and the dropped sliver leaves an edge unpaired. That
    /// assertion killed the app with no crash report. Triangulating polygon
    /// by polygon makes the conversion a pure function of the geometry.
    static func triangles(of mesh: Euclid.Mesh) -> [Euclid.Polygon] {
        mesh.polygons.flatMap { $0.triangulate() }
    }

    /// Triangulates a Euclid mesh and welds vertices into an indexed RenderMesh.
    static func renderMesh(from mesh: Euclid.Mesh) -> RenderMesh {
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()
        var lookup = [WeldKey: UInt32]()

        for polygon in triangles(of: mesh) {
            for vertex in polygon.vertices {
                let p = SIMD3<Float>(
                    Float(vertex.position.x), Float(vertex.position.y), Float(vertex.position.z)
                )
                let n = SIMD3<Float>(
                    Float(vertex.normal.x), Float(vertex.normal.y), Float(vertex.normal.z)
                )
                let key = WeldKey(position: p, normal: n, quantum: weldQuantum)
                if let existing = lookup[key] {
                    indices.append(existing)
                } else {
                    let index = UInt32(positions.count)
                    lookup[key] = index
                    positions.append(p)
                    normals.append(n)
                    indices.append(index)
                }
            }
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    /// Rebuilds a Euclid mesh from stored triangle buffers (document load path).
    /// The result is a valid polygon soup for CSG; Euclid re-derives topology.
    static func euclidMesh(from render: RenderMesh) -> Euclid.Mesh {
        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(render.triangleCount)
        var i = 0
        while i + 2 < render.indices.count {
            let ia = Int(render.indices[i])
            let ib = Int(render.indices[i + 1])
            let ic = Int(render.indices[i + 2])
            i += 3
            let vertices = [ia, ib, ic].map { idx in
                Euclid.Vertex(
                    Vector(
                        Double(render.positions[idx].x),
                        Double(render.positions[idx].y),
                        Double(render.positions[idx].z)
                    ),
                    Vector(
                        Double(render.normals[idx].x),
                        Double(render.normals[idx].y),
                        Double(render.normals[idx].z)
                    )
                )
            }
            // Degenerate (zero-area) triangles return nil and are skipped.
            if let polygon = Euclid.Polygon(vertices) {
                polygons.append(polygon)
            }
        }
        return Euclid.Mesh(polygons)
    }

    static func vector(_ v: SIMD3<Double>) -> Vector {
        Vector(v.x, v.y, v.z)
    }

    static func simd(_ v: Vector) -> SIMD3<Double> {
        SIMD3(v.x, v.y, v.z)
    }
}

/// Primitive mesh construction. Slices chosen for a CAD-smooth look
/// (Euclid's defaults of 16 are visibly faceted).
nonisolated extension Euclid.Mesh {
    static func primitive(_ spec: PrimitiveSpec) -> Euclid.Mesh {
        switch spec {
        case let .box(width, depth, height):
            // Euclid cube is centered; shift so the base sits on y=0.
            return .cube(center: Vector(0, height / 2, 0), size: Vector(width, height, depth))
        case let .cylinder(radius, height):
            return .cylinder(radius: radius, height: height, slices: 48)
                .translated(by: Vector(0, height / 2, 0))
        case let .sphere(radius):
            return .sphere(radius: radius, slices: 32, stacks: 24)
                .translated(by: Vector(0, radius, 0))
        }
    }
}
