//
//  STLImporter.swift
//  openshape3d
//
//  Binary + ASCII STL parsing into RenderMesh. STL normals are unreliable in
//  the wild, so face normals are always recomputed from triangle winding.
//  Vertices are welded with the same quantized position+normal scheme as
//  EuclidBridge so hard edges survive. STL is unitless; `unitScale` maps file
//  units to model units (1.0 = the file is in mm, our model unit).
//

import Foundation
import simd

nonisolated enum STLImporter {

    enum ImportError: Error, Equatable {
        case truncated
        case malformed(String)
        case empty
    }

    /// Mirrors EuclidBridge.weldQuantum (private there).
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

    /// Parses binary or ASCII STL. Throws on malformed/truncated/empty input.
    static func importSTL(_ data: Data, unitScale: Double = 1.0) throws -> RenderMesh {
        // Binary detection first: the declared triangle count must match the
        // exact file size (binary files may legally start with "solid" too).
        if data.count >= 84 {
            let count = data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            }
            if data.count == 84 + Int(count) * 50 {
                guard count > 0 else { throw ImportError.empty }
                return try binaryMesh(data, triangleCount: Int(count), unitScale: unitScale)
            }
        }
        guard
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii),
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("solid")
        else {
            throw ImportError.malformed("Not a valid binary or ASCII STL")
        }
        return try asciiMesh(text, unitScale: unitScale)
    }

    // MARK: - Binary

    private static func binaryMesh(
        _ data: Data, triangleCount: Int, unitScale: Double
    ) throws -> RenderMesh {
        // 50-byte records: normal (3×f32, ignored), 3 vertices (9×f32), u16 attr.
        var corners = [SIMD3<Double>]()
        corners.reserveCapacity(triangleCount * 3)
        data.withUnsafeBytes { raw in
            var offset = 84
            for _ in 0..<triangleCount {
                var vertexOffset = offset + 12
                for _ in 0..<3 {
                    let x = raw.loadUnaligned(fromByteOffset: vertexOffset, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: vertexOffset + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: vertexOffset + 8, as: Float.self)
                    corners.append(SIMD3(Double(x), Double(y), Double(z)) * unitScale)
                    vertexOffset += 12
                }
                offset += 50
            }
        }
        return try weldedMesh(corners: corners)
    }

    // MARK: - ASCII

    private static func asciiMesh(_ text: String, unitScale: Double) throws -> RenderMesh {
        var corners = [SIMD3<Double>]()
        var pending = [SIMD3<Double>]()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = tokens.first else { continue }
            switch keyword.lowercased() {
            case "vertex":
                guard tokens.count >= 4,
                      let x = Double(tokens[1]),
                      let y = Double(tokens[2]),
                      let z = Double(tokens[3])
                else { throw ImportError.malformed("Bad vertex line: \(rawLine)") }
                pending.append(SIMD3(x, y, z) * unitScale)
            case "endfacet":
                guard pending.count == 3 else {
                    throw ImportError.malformed("Facet with \(pending.count) vertices")
                }
                corners.append(contentsOf: pending)
                pending.removeAll(keepingCapacity: true)
            case "solid", "endsolid", "facet", "outer", "endloop":
                continue
            default:
                throw ImportError.malformed("Unexpected token: \(keyword)")
            }
        }
        guard pending.isEmpty else { throw ImportError.malformed("Unterminated facet") }
        return try weldedMesh(corners: corners)
    }

    // MARK: - Weld

    /// `corners` is a flat triangle list (3 entries per triangle). Face normals
    /// are recomputed from winding; degenerate triangles are dropped.
    private static func weldedMesh(corners: [SIMD3<Double>]) throws -> RenderMesh {
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
        guard !indices.isEmpty else { throw ImportError.empty }
        return RenderMesh(positions: positions, normals: normals, indices: indices)
    }
}
