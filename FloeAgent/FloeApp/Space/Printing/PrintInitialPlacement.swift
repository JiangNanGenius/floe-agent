// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloePrintCore

/// A rigid initial layout, separate from the retained source asset. Neither
/// frame conversion nor placement scales, clips, repairs or drops triangles.
nonisolated struct PrintInitialPlacement: Codable, Sendable, Equatable {
    enum SourceFrame: String, Codable, Sendable {
        /// Native CAD export preserves its world placement: XZ ground, +Y up.
        case cadWorldYUp
        /// Unit-converted exchange-file coordinates are kept as supplied.
        /// STL/OBJ have no trustworthy up-axis metadata to infer from bounds.
        case fileCoordinatesZUp
    }
    let version: Int
    let sourceFrame: SourceFrame
    /// Row-major 3x3 proper rotation. Print coordinates are X/Y bed, +Z up.
    let rotationRows: [Double]
    let translationMM: [Double]
    let sourceGeometrySHA256: String
    let geometrySHA256: String
    let geometryAsset: String

    private static func rotation(for frame: SourceFrame) -> [Double] {
        switch frame {
        case .cadWorldYUp: [1, 0, 0, 0, 0, -1, 0, 1, 0] // (x,y,z) -> (x,-z,y)
        case .fileCoordinatesZUp: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }
    }
    func validate() throws {
        guard version == 1, rotationRows == Self.rotation(for: sourceFrame),
              translationMM.count == 3, translationMM.allSatisfy(\.isFinite),
              sourceGeometrySHA256.count == 64, sourceGeometrySHA256.allSatisfy(\.isHexDigit),
              geometrySHA256.count == 64, geometrySHA256.allSatisfy(\.isHexDigit),
              geometryAsset == geometrySHA256 + ".mesh" else { throw PrintError.invalidMesh }
    }
    /// Reproduces the initial placed mesh from the immutable original, without
    /// consulting live CAD state or silently changing its stored orientation.
    func applying(to mesh: PrintMesh) throws -> PrintMesh {
        try validate()
        guard mesh.sha256 == sourceGeometrySHA256 else { throw PrintError.invalidMesh }
        return try Self.transformed(mesh, frame: sourceFrame, translation: translationMM)
    }
    private static func transformed(_ mesh: PrintMesh, frame: SourceFrame, translation: [Double]) throws -> PrintMesh {
        var positions = [Float](); positions.reserveCapacity(mesh.positions.count)
        for i in stride(from: 0, to: mesh.positions.count, by: 3) {
            if i % 12_288 == 0 { try Task.checkCancellation() }
            let value = oriented(mesh.positions, at: i, frame: frame)
            for axis in 0..<3 { positions.append(Float(value[axis] + translation[axis])) }
        }
        try Task.checkCancellation()
        return try PrintMesh(positions: positions)
    }
    private static func oriented(_ positions: [Float], at i: Int, frame: SourceFrame) -> SIMD3<Double> {
        switch frame {
        case .cadWorldYUp: SIMD3(Double(positions[i]), -Double(positions[i + 2]), Double(positions[i + 1]))
        case .fileCoordinatesZUp: SIMD3(Double(positions[i]), Double(positions[i + 1]), Double(positions[i + 2]))
        }
    }
    static func prepare(_ mesh: PrintMesh, sourceFrame: SourceFrame) async throws -> (mesh: PrintMesh, placement: Self) {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var low = [Double](repeating: .infinity, count: 3)
            var high = [Double](repeating: -.infinity, count: 3)
            for i in stride(from: 0, to: mesh.positions.count, by: 3) {
                if i % 12_288 == 0 { try Task.checkCancellation() }
                let value = oriented(mesh.positions, at: i, frame: sourceFrame)
                for axis in 0..<3 { low[axis] = min(low[axis], value[axis]); high[axis] = max(high[axis], value[axis]) }
            }
            let translation = [-(low[0] + high[0]) / 2, -(low[1] + high[1]) / 2, -low[2]]
            let placed = try transformed(mesh, frame: sourceFrame, translation: translation)
            let sourceDigest = mesh.sha256, digest = placed.sha256
            try Task.checkCancellation()
            return (placed, Self(version: 1, sourceFrame: sourceFrame, rotationRows: rotation(for: sourceFrame),
                translationMM: translation, sourceGeometrySHA256: sourceDigest, geometrySHA256: digest, geometryAsset: digest + ".mesh"))
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif
