//
//  CADTransientMeshPreview.swift
//  FloeCADKit
//
//  Transient geometry previews for the workbench panels: a bounded mesh
//  snapshot a SwiftUI Canvas can draw, and an order-independent content hash
//  that binds a preview to the exact apply that follows. Nothing here mutates
//  the document — snapshots are built from result meshes the services already
//  computed on their own copies.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import CryptoKit
import simd

nonisolated enum CADTransientMeshPreview {
    /// Hard ceiling for a UI preview snapshot; larger results are truncated
    /// and marked, never silently "complete".
    static let defaultMaxPreviewTriangles = 8_000

    struct Snapshot: Sendable, Equatable {
        var positions: [Float]
        var indices: [UInt32]
        var triangleCount: Int
        var truncated: Bool
        var minBound = SIMD3<Float>(repeating: 0)
        var maxBound = SIMD3<Float>(repeating: 0)
    }

    /// One snapshot over one or more result meshes (indices rebased).
    static func snapshot(of meshes: [RenderMesh],
                         maxTriangles: Int = defaultMaxPreviewTriangles) -> Snapshot? {
        var positions: [Float] = []
        var indices: [UInt32] = []
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var truncated = false
        var includedTriangles = 0
        var totalTriangles = 0

        for mesh in meshes {
            totalTriangles += mesh.triangleCount
        }
        guard totalTriangles > 0 else { return nil }

        for mesh in meshes {
            let base = UInt32(positions.count / 3)
            let triangleLimit = maxTriangles - includedTriangles
            guard triangleLimit > 0 else { truncated = true; break }
            var addedTriangles = 0
            var indexCursor = 0
            while indexCursor + 2 < mesh.indices.count, addedTriangles < triangleLimit {
                let i0 = Int(mesh.indices[indexCursor])
                let i1 = Int(mesh.indices[indexCursor + 1])
                let i2 = Int(mesh.indices[indexCursor + 2])
                indexCursor += 3
                guard i0 < mesh.positions.count,
                      i1 < mesh.positions.count,
                      i2 < mesh.positions.count else { continue }
                for vertex in [i0, i1, i2] {
                    let p = mesh.positions[vertex]
                    guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                    positions.append(p.x)
                    positions.append(p.y)
                    positions.append(p.z)
                    minBound = simd_min(minBound, p)
                    maxBound = simd_max(maxBound, p)
                }
                indices.append(base + UInt32(positions.count / 3 - 3))
                indices.append(base + UInt32(positions.count / 3 - 2))
                indices.append(base + UInt32(positions.count / 3 - 1))
                addedTriangles += 1
            }
            if indexCursor + 2 < mesh.indices.count { truncated = true }
            includedTriangles += addedTriangles
        }
        guard !positions.isEmpty, !indices.isEmpty else { return nil }
        return Snapshot(positions: positions,
                        indices: indices,
                        triangleCount: totalTriangles,
                        truncated: truncated,
                        minBound: minBound,
                        maxBound: maxBound)
    }

    /// Order-independent content hash of a result mesh set: XOR of each
    /// triangle's SHA-256 (quantized to 0.1 µm) plus the total triangle count.
    /// Two runs that produce the same geometry in a different order hash the
    /// same; a materially different result does not. Preview binding, not a
    /// security boundary.
    static func hash(of meshes: [RenderMesh]) -> String? {
        var accumulator = [UInt8](repeating: 0, count: 32)
        var count: UInt64 = 0
        for mesh in meshes {
            guard mesh.triangleCount <= 2_000_000 else { continue }
            var cursor = 0
            while cursor + 2 < mesh.indices.count {
                let i0 = Int(mesh.indices[cursor])
                let i1 = Int(mesh.indices[cursor + 1])
                let i2 = Int(mesh.indices[cursor + 2])
                cursor += 3
                guard i0 < mesh.positions.count,
                      i1 < mesh.positions.count,
                      i2 < mesh.positions.count else { continue }
                var data = Data()
                data.reserveCapacity(72)
                for vertex in [i0, i1, i2] {
                    let position = mesh.positions[vertex]
                    let values = [position.x, position.y, position.z]
                    for value in values {
                        guard value.isFinite else { return nil }
                        let quantized = Int64((Double(value) * 10_000).rounded())
                        withUnsafeBytes(of: quantized.littleEndian) { data.append(contentsOf: $0) }
                    }
                }
                let digest = SHA256.hash(data: data)
                for (index, byte) in digest.enumerated() { accumulator[index] ^= byte }
                count &+= 1
            }
        }
        guard count > 0 else { return nil }
        withUnsafeBytes(of: count.littleEndian) {
            accumulator.replaceSubrange(0..<8, with: $0)
        }
        return accumulator.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(of mesh: RenderMesh) -> String? {
        hash(of: [mesh])
    }

    /// JSON-safe payload for the reply dictionary.
    static func payload(_ snapshot: Snapshot) -> [String: Any] {
        [
            "positions": snapshot.positions.map(Double.init),
            "indices": snapshot.indices.map(Int.init),
            "triangleCount": snapshot.triangleCount,
            "truncated": snapshot.truncated,
            "bounds": [
                [Double(snapshot.minBound.x), Double(snapshot.minBound.y), Double(snapshot.minBound.z)],
                [Double(snapshot.maxBound.x), Double(snapshot.maxBound.y), Double(snapshot.maxBound.z)],
            ],
        ]
    }
}
