// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeInteriorCore
@testable import FloeBuildingAssets

final class FurnitureAssetTestSpace {
    let root: URL
    let source: URL
    let libraryRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBuildingAssetsTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ text: String, to relativePath: String) throws -> URL {
        try write(Data(text.utf8), to: relativePath)
    }

    @discardableResult
    func write(_ data: Data, to relativePath: String) throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    func library(limits: FurnitureAssetLibraryLimits = .standard) -> FurnitureAssetLibrary {
        .init(rootURL: libraryRoot, limits: limits)
    }

    func removeLibrary() {
        try? FileManager.default.removeItem(at: libraryRoot)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    static func syntheticProvenance(
        source: String = "Synthetic test fixture",
        mayHost: FurniturePermission = .allowed,
        mayShareInProject: FurniturePermission = .allowed
    ) -> FurnitureAssetProvenance {
        .init(
            source: source,
            sourceReference: "https://example.invalid/synthetic",
            license: .init(
                identifier: "LicenseRef-Synthetic",
                evidence: .recordedStatement,
                mayHost: mayHost,
                mayShareInProject: mayShareInProject,
                basis: "Synthetic test fixture only; no real asset or license is represented."
            ),
            attribution: .init(author: "Test fixture", title: "Synthetic furniture", sourceURL: nil, notice: nil)
        )
    }

    static func catalogDimensions() -> FurnitureDeclaredDimensions {
        .init(width: 2_000, depth: 1_500, height: 1_000, unit: .millimetre)
    }

    static func pose() -> FurniturePose {
        .init(
            planXMM: 1_000,
            planYMM: 800,
            floorElevationMM: 0,
            elevationAboveFloorMM: 0,
            yawDegrees: 0,
            anchor: .bottomCenter
        )
    }
}

enum FurnitureAssetFixtures {
    static let textureData = Data("synthetic texture bytes, not a real image".utf8)
    static let materialLibraryName = "chair material.mtl"

    static func obj(
        mtllib: String? = "chair material.mtl",
        vertices: [String] = [
            "v 0 0 0",
            "v 2 0 0",
            "v 0 4 0",
            "v 0 0 1.5"
        ],
        face: String = "f 1 2 3"
    ) -> String {
        var lines = ["# Synthetic OBJ fixture; not a real furniture asset.", "o synthetic-chair"]
        if let mtllib {
            lines.append("mtllib \(mtllib)")
        }
        lines.append(contentsOf: vertices)
        lines.append("usemtl synthetic")
        lines.append(face)
        return lines.joined(separator: "\n") + "\n"
    }

    static func materialLibrary(texture: String = "textures/wood grain.png") -> String {
        """
        # Synthetic MTL fixture.
        newmtl synthetic
        Kd 0.5 0.4 0.3
        map_Kd -blendu on -blendv off -s 1 1 1 -o 0 0 0 -mm 0 1 -bm 0.5 "\(texture)"
        """
    }

    static func materialLibraryWithoutOptions(texture: String = "textures/wood grain.png") -> String {
        """
        newmtl synthetic
        Kd 0.5 0.4 0.3
        map_Kd \(texture)
        """
    }
}
