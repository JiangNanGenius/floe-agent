// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import simd

/// Immutable scan values, copied before reconstruction. No source index is a
/// persistent face identity; reconstruction creates new grid-boundary UUIDs.
nonisolated struct CADVoxelScanSnapshot: Codable, Equatable, Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var texcoords: [SIMD2<Float>]?
    init(_ mesh: RenderMesh) {
        positions = mesh.positions; normals = mesh.normals; indices = mesh.indices; texcoords = mesh.texcoords
    }
    var render: RenderMesh { .init(positions: positions,normals: normals,indices: indices,texcoords: texcoords) }
    func validate(_ stop: () -> Bool = { false }) throws {
        guard !positions.isEmpty, positions.count <= 150_000, normals.count == positions.count,
              !indices.isEmpty, indices.count % 3 == 0, indices.count / 3 <= 50_000,
              texcoords == nil || texcoords?.count == positions.count else {
            throw CADVoxelFailure.invalid("Use a scan with at most 50,000 triangles and matching vertex buffers.")
        }
        for i in positions.indices {
            if stop() { throw CADVoxelFailure.cancelled }
            let p = positions[i], n = normals[i]
            guard [p.x,p.y,p.z,n.x,n.y,n.z].allSatisfy(\.isFinite),
                  max(abs(p.x),max(abs(p.y),abs(p.z))) <= 1e6 else {
                throw CADVoxelFailure.invalid("The scan contains invalid coordinates or normals.")
            }
            if let uv = texcoords?[i], !uv.x.isFinite || !uv.y.isFinite {
                throw CADVoxelFailure.invalid("The scan contains invalid texture coordinates.")
            }
        }
        for index in indices {
            if stop() { throw CADVoxelFailure.cancelled }
            guard Int(index) < positions.count else { throw CADVoxelFailure.invalid("The scan references a missing vertex.") }
        }
    }
}

/// Versioned, reproducible snapshot reconstruction, not an associative live
/// import. The original body remains in the document; this copy also survives
/// deletion or later editing of that body. Millimetres are world dimensions.
nonisolated struct CADVoxelRemeshDefinition: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    static let algorithmV1 = "distance-band-flood6-cubical-v1"
    var version = supportedVersion
    var algorithm = algorithmV1
    var id = UUID()
    var sourceBodyID: BodyID
    var source: CADVoxelScanSnapshot
    var voxelSizeMM: Double
    var maxDeviationMM: Double
    func validate(_ stop: () -> Bool = { false }) throws {
        guard version == Self.supportedVersion, algorithm == Self.algorithmV1 else {
            throw CADVoxelFailure.unsupported("This reconstruction algorithm or version is unavailable.")
        }
        guard voxelSizeMM.isFinite, (0.001...10_000).contains(voxelSizeMM),
              maxDeviationMM.isFinite, maxDeviationMM >= voxelSizeMM,
              maxDeviationMM <= voxelSizeMM * 20 else {
            throw CADVoxelFailure.invalid("Use a voxel size from 0.001 to 10,000 mm and a deviation limit from one to twenty voxels.")
        }
        try source.validate(stop)
    }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
    }
}

nonisolated enum CADVoxelFailure: Error, LocalizedError, Sendable {
    case invalid(String), unsupported(String), budget(String), deviation(String), cancelled, timedOut
    var errorDescription: String? {
        switch self {
        case let .invalid(s), let .unsupported(s), let .budget(s), let .deviation(s): return s
        case .cancelled: return "Reconstruction was cancelled. The scan was kept."
        case .timedOut: return "Reconstruction reached its time limit. The scan was kept."
        }
    }
    var code: String {
        switch self {
        case .invalid: return "invalid_voxel_request"
        case .unsupported: return "voxel_scope_unavailable"
        case .budget: return "voxel_budget_exceeded"
        case .deviation: return "voxel_deviation_exceeded"
        case .cancelled: return "cancelled"
        case .timedOut: return "timeout"
        }
    }
}
