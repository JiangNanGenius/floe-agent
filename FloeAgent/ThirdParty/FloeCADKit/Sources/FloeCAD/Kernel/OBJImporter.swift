//
//  OBJImporter.swift
//  openshape3d
//
//  Wavefront OBJ parsing into RenderMesh — the read half of `OBJExporter`, and
//  the format most mesh tools hand you when STL would lose the grouping.
//
//  Like the STL path, normals are recomputed from triangle winding rather than
//  trusted from the file (`vn` records in the wild are frequently absent,
//  stale, or averaged across hard edges), and vertices are welded with the same
//  quantized position+normal key so creases survive. `o`/`g` groups are read
//  and returned separately, so an OBJ carrying several parts imports as several
//  bodies instead of one welded lump.
//

import Foundation
import simd

nonisolated enum OBJImporter {

    enum ImportError: Error, Equatable {
        case malformed(String)
        case empty
    }

    /// One `o`/`g` group in the file.
    nonisolated struct Group: Sendable {
        var name: String
        var mesh: RenderMesh
    }

    /// Mirrors `STLImporter.weldQuantum` / `EuclidBridge.weldQuantum`.
    private static let weldQuantum: Float = 1e-5

    private struct WeldKey: Hashable {
        let px, py, pz, nx, ny, nz: Int64

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

    /// Every group in the file, in declaration order. Faces appearing before
    /// any `o`/`g` land in a leading unnamed group.
    ///
    /// `unitScale` maps file units to model units (OBJ is unitless, like STL).
    static func importOBJ(_ data: Data, unitScale: Double = 1.0) throws -> [Group] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.malformed("OBJ is not text")
        }

        // `v` indices are FILE-global and 1-based (negative = relative to the
        // end), so vertices are collected across the whole file even though
        // faces are bucketed per group.
        var vertices = [SIMD3<Double>]()
        var groups = [(name: String, corners: [SIMD3<Double>])]()
        var current = (name: "", corners: [SIMD3<Double>]())

        func flush() {
            if !current.corners.isEmpty { groups.append(current) }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = fields.first else { continue }

            switch keyword {
            case "v":
                guard fields.count >= 4,
                      let x = Double(fields[1]), let y = Double(fields[2]),
                      let z = Double(fields[3]) else {
                    throw ImportError.malformed("bad vertex: \(line)")
                }
                vertices.append(SIMD3(x, y, z) * unitScale)

            case "o", "g":
                flush()
                current = (fields.dropFirst().joined(separator: " "), [])

            case "f":
                let refs = fields.dropFirst()
                guard refs.count >= 3 else {
                    throw ImportError.malformed("face with fewer than 3 corners")
                }
                // "v", "v/vt", "v//vn", "v/vt/vn" — only the position index matters.
                let corner: [SIMD3<Double>] = try refs.map { ref in
                    guard let first = ref.split(separator: "/", omittingEmptySubsequences: false).first,
                          let raw = Int(first) else {
                        throw ImportError.malformed("bad face index: \(ref)")
                    }
                    let index = raw > 0 ? raw - 1 : vertices.count + raw
                    guard vertices.indices.contains(index) else {
                        throw ImportError.malformed("face references vertex \(raw)")
                    }
                    return vertices[index]
                }
                // Fan-triangulate; OBJ polygons are planar and convex by convention.
                for i in 1..<(corner.count - 1) {
                    current.corners.append(contentsOf: [corner[0], corner[i], corner[i + 1]])
                }

            default:
                continue  // vn/vt/usemtl/mtllib/s — nothing we need
            }
        }
        flush()

        let meshes = groups.compactMap { group -> Group? in
            guard let mesh = weldedMesh(corners: group.corners) else { return nil }
            return Group(name: group.name, mesh: mesh)
        }
        guard !meshes.isEmpty else { throw ImportError.empty }
        return meshes
    }

    /// Every group welded into ONE mesh — the "import as a single body" path.
    static func importSingleMesh(_ data: Data, unitScale: Double = 1.0) throws -> RenderMesh {
        let groups = try importOBJ(data, unitScale: unitScale)
        if groups.count == 1 { return groups[0].mesh }
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()
        for group in groups {
            let base = UInt32(positions.count)
            positions.append(contentsOf: group.mesh.positions)
            normals.append(contentsOf: group.mesh.normals)
            indices.append(contentsOf: group.mesh.indices.map { $0 + base })
        }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }

    // MARK: - Helpers

    /// Nil (rather than throwing) when a group holds no non-degenerate triangle
    /// — an empty `g` line is common and must not fail the whole import.
    private static func weldedMesh(corners: [SIMD3<Double>]) -> RenderMesh? {
        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var indices = [UInt32]()
        var lookup = [WeldKey: UInt32]()

        var i = 0
        while i + 2 < corners.count {
            let a = corners[i], b = corners[i + 1], c = corners[i + 2]
            i += 3
            let cross = simd_cross(b - a, c - a)
            let lengthSquared = simd_length_squared(cross)
            guard lengthSquared > 1e-24 else { continue }
            let normal = SIMD3<Float>(cross / lengthSquared.squareRoot())
            for corner in [a, b, c] {
                let p = SIMD3<Float>(corner)
                let key = WeldKey(position: p, normal: normal, quantum: weldQuantum)
                if let existing = lookup[key] {
                    indices.append(existing)
                } else {
                    let index = UInt32(positions.count)
                    lookup[key] = index
                    positions.append(p)
                    normals.append(normal)
                    indices.append(index)
                }
            }
        }
        guard !indices.isEmpty else { return nil }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }
}
