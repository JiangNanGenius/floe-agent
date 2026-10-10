//
//  MeshBuffers.swift
//  openshape3d
//
//  Flat, Metal-friendly mesh buffers plus the compact binary blob used for
//  persistence ("OS3D" format).
//

import Foundation
import simd

/// Indexed triangle mesh in body-local coordinates, ready for GPU upload.
/// Vertices are welded by (position, normal) so hard edges are preserved.
nonisolated struct RenderMesh: Sendable, Equatable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    /// Per-vertex texture coordinates (Metal convention: (0,0) is the image's
    /// top-left), present only on meshes that arrived with a texture — an
    /// imported OBJ/glTF/USDZ. Modelled bodies have none; every geometry op
    /// that rebuilds a mesh drops them, which is right: a boolean or blend
    /// has no way to carry a photo across the new faces.
    var texcoords: [SIMD2<Float>]? = nil

    var triangleCount: Int { indices.count / 3 }

    /// Body-local bounding box, used for pick-ray rejection and fit-view.
    var localAABB: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard !positions.isEmpty else { return (.zero, .zero) }
        var lo = positions[0]
        var hi = positions[0]
        for p in positions {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    static func == (lhs: RenderMesh, rhs: RenderMesh) -> Bool {
        lhs.indices == rhs.indices && lhs.positions == rhs.positions && lhs.normals == rhs.normals
            && lhs.texcoords == rhs.texcoords
    }
}

/// Feature edges as a line list: pairs of world-space endpoints [a0,b0, a1,b1, ...].
nonisolated struct FeatureEdgeSet: Sendable {
    var segments: [SIMD3<Float>]
    var segmentCount: Int { segments.count / 2 }
}

/// Quantization for vertex welding, shared by `EuclidBridge` (render weld) and
/// `FeatureEdgeExtractor` (topology weld).
///
/// `Int32(Float)` TRAPS on a non-finite value or one outside Int32's range —
/// and at the 1e-5 quantum used here, that range is only ±21.47 m of model
/// space. A metre-unit import, an architectural-scale model, or a single NaN
/// out of a degenerate kernel op therefore crashed the app while merely
/// BUILDING a mesh (2026-08-25 review round 2). Clamping keeps the weld
/// well-defined: coordinates past the limit collapse together, which is a
/// cosmetic weld artifact at 21 m, not a crash.
nonisolated enum MeshQuantize {
    /// `Int64` variant for the Double-precision welds (sketch/profile/shell/
    /// projection/blend-chain). `Int64(Double.nan)` traps exactly like the
    /// Int32 case, and the round-2 fix that clamped only the Int32 sites
    /// MOVED the crash rather than removing it: an oversized or NaN-bearing
    /// import now succeeds, then trapped later in Shell or Blend on the
    /// resulting body.
    static func key64(_ value: Double, inverseQuantum: Double) -> Int64 {
        clamp64((value * inverseQuantum).rounded())
    }

    /// Same, for call sites that divide by a quantum (kept separate so the
    /// arithmetic is byte-identical to what those sites did before).
    static func key64(_ value: Double, quantum: Double) -> Int64 {
        clamp64((value / quantum).rounded())
    }

    static func clampedToInt(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -1e15), 1e15)
    }

    private static func clamp64(_ scaled: Double) -> Int64 {
        guard scaled.isFinite else { return 0 }
        // Int64's bounds are NOT exactly representable in Double (2^63), so
        // clamp to the largest/smallest Double that converts safely.
        let limit = Double(Int64.max - 1024) // 2^63 - 1024, exact in Double
        return Int64(min(max(scaled, -limit), limit))
    }

    /// Float overload for the render/topology welds. Returns Int64: at the
    /// 1e-5 mm quantum these keys use, Int32 saturates at only ±21.47 m, so
    /// clamping there did not crash but silently WELDED every far vertex to
    /// the same key — collapsing whole triangles and deleting geometry (the
    /// round-2 clamp traded a crash for silent destruction). Int64 covers
    /// ~9.2e13 mm, past any real model, so the weld keeps its exact
    /// semantics everywhere.
    static func key64(_ value: Float, inverseQuantum: Float) -> Int64 {
        clamp64((Double(value) * Double(inverseQuantum)).rounded())
    }

    static func key(_ value: Float, inverseQuantum: Float) -> Int32 {
        // Clamp in DOUBLE space: Float cannot represent Int32.max (it rounds
        // up to 2^31), so a Float-space clamp still hands Int32() a value one
        // past the top and traps — the very bug this guards against.
        // Double represents both bounds exactly.
        let scaled = (Double(value) * Double(inverseQuantum)).rounded()
        guard scaled.isFinite else { return 0 }
        return Int32(min(max(scaled, Double(Int32.min)), Double(Int32.max)))
    }
}

/// Compact binary serialization of a RenderMesh.
/// Layout (little-endian): "OS3D" magic, u32 version, u32 vertexCount,
/// u32 indexCount, positions (f32×3 × vertexCount), normals (f32×3 × vertexCount),
/// indices (u32 × indexCount).
nonisolated enum MeshBlob {
    static let magic: UInt32 = 0x4F533344 // "OS3D"
    /// v1: positions, normals, indices. v2 (2026-09-04) appends per-vertex
    /// texture coordinates after the indices; written only when the mesh
    /// carries them, so every untextured body stays a v1 blob older builds
    /// can still read.
    static let version: UInt32 = 1
    static let texturedVersion: UInt32 = 2

    enum BlobError: Error {
        case badMagic
        case unsupportedVersion(UInt32)
        case truncated
        /// Well-formed lengths, but the triangle list is not usable: an index
        /// past the vertex array, or a count that isn't whole triangles.
        case corruptIndices
    }

    static func encode(_ mesh: RenderMesh) -> Data {
        let vertexCount = UInt32(mesh.positions.count)
        let indexCount = UInt32(mesh.indices.count)
        let texcoords = mesh.texcoords.flatMap { $0.count == mesh.positions.count ? $0 : nil }
        var data = Data(capacity: 16 + mesh.positions.count * 32 + mesh.indices.count * 4)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: (texcoords == nil ? version : texturedVersion).littleEndian) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: vertexCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: indexCount.littleEndian) { data.append(contentsOf: $0) }
        // SIMD3<Float> has 16-byte stride; write tightly packed 12-byte triples.
        for p in mesh.positions {
            withUnsafeBytes(of: p.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: p.z) { data.append(contentsOf: $0) }
        }
        for n in mesh.normals {
            withUnsafeBytes(of: n.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: n.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: n.z) { data.append(contentsOf: $0) }
        }
        mesh.indices.withUnsafeBytes { data.append(contentsOf: $0) }
        if let texcoords {
            for t in texcoords {
                withUnsafeBytes(of: t.x) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: t.y) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    static func decode(_ data: Data) throws -> RenderMesh {
        var offset = 0
        func read<T>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw BlobError.truncated }
            defer { offset += size }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
        }

        let magicValue = try read(UInt32.self)
        guard magicValue == magic else { throw BlobError.badMagic }
        let versionValue = try read(UInt32.self)
        guard versionValue == version || versionValue == texturedVersion else {
            throw BlobError.unsupportedVersion(versionValue)
        }
        let textured = versionValue == texturedVersion
        let vertexCount = Int(try read(UInt32.self))
        let indexCount = Int(try read(UInt32.self))

        let payloadBytes = vertexCount * (textured ? 32 : 24) + indexCount * 4
        guard offset + payloadBytes <= data.count else { throw BlobError.truncated }
        // Lengths alone are not enough: the INDEX VALUES are unvalidated input
        // too. Every consumer subscripts `positions[index]` directly
        // (HitTester, FaceTopology, EdgeTopology) and Metal reads the buffer
        // raw, so an out-of-range index in a shared/corrupt .os3d file was a
        // hard trap on first touch (2026-08-25 review round 2).
        guard indexCount % 3 == 0 else { throw BlobError.corruptIndices }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let x = try read(Float.self)
            let y = try read(Float.self)
            let z = try read(Float.self)
            positions.append(SIMD3(x, y, z))
        }
        var normals = [SIMD3<Float>]()
        normals.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            let x = try read(Float.self)
            let y = try read(Float.self)
            let z = try read(Float.self)
            normals.append(SIMD3(x, y, z))
        }
        var indices = [UInt32]()
        indices.reserveCapacity(indexCount)
        let vertexLimit = UInt32(vertexCount)
        for _ in 0..<indexCount {
            let index = try read(UInt32.self)
            guard index < vertexLimit else { throw BlobError.corruptIndices }
            indices.append(index)
        }
        var mesh = RenderMesh(positions: positions, normals: normals, indices: indices)
        if textured {
            var texcoords = [SIMD2<Float>]()
            texcoords.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount {
                let u = try read(Float.self)
                let v = try read(Float.self)
                texcoords.append(SIMD2(u, v))
            }
            mesh.texcoords = texcoords
        }
        return mesh
    }
}

nonisolated extension Double {
    /// Safe for `Int(_:)`: non-finite becomes 0, huge magnitudes clamp.
    /// `Int(Double.nan)` and `Int(1e300)` both trap.
    var clampedToInt: Double { MeshQuantize.clampedToInt(self) }
}
