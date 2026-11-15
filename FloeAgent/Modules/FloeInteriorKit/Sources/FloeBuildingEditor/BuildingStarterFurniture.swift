// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import CryptoKit
import FloeInteriorCore
import FloeBuildingAssets
import FloeBuildingResources

/// A small real source package, not a pre-admitted native model. The same
/// asset library and native admission path used for user imports must process
/// it before it can be placed in a project.
struct BuildingStarterFurniture {
    let directory: URL
    let assetID = "floe.starter.absfrm.armchair"
    let version = "1.9.3"
    let primaryRelativePath = "armchair.obj"
    let licenseRelativePath = "BLENDSWAP_LICENSE.txt"
    let dimensions = FurnitureDeclaredDimensions(width: 594, depth: 627, height: 1050, unit: .millimetre)
    let orientation: FurnitureSourceOrientation = .cadYUp

    var provenance: FurnitureAssetProvenance {
        .init(source: "Sweet Home 3D BlendSwap CC0 subset 1.9.3",
              sourceReference: "http://www.blendswap.com/blends/view/54641",
              license: .init(identifier: "CC0-1.0", evidence: .licenseFile,
                             mayHost: .allowed, mayShareInProject: .allowed,
                             basis: "Original Blend Swap CC0 notice retained with the source files."),
              attribution: .init(author: "absfrm", title: "chair",
                                 sourceURL: "http://www.blendswap.com/blends/view/54641"))
    }

    func importInto(_ library: FurnitureAssetLibrary) async throws -> FurnitureAssetVersion {
        try await library.importOBJ(sourceRootURL: directory, relativePath: primaryRelativePath,
                                    assetID: assetID, version: version, name: "Armchair", category: "seating",
                                    provenance: provenance, declaredDimensions: dimensions,
                                    sourceBoundsUnit: nil, sourceOrientation: orientation,
                                    licenseFileRelativePath: licenseRelativePath)
    }

    static func armchair() throws -> Self {
        let directory=try BuildingResourceCatalog.starterArmchairDirectory()
        let expected = [
            "armchair.obj": "4da2ca4ee1b573dfd5feaee4b689794a362f8da6df2f89adb79886c4ab8cd0ce",
            "armchair.mtl": "84bc77ecd7fff853255c51c5022707814e8a588dc53cb22be5db63b74e445223"
        ]
        for (name, hash) in expected {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= 512 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let actual = SHA256.hash(data: try Data(contentsOf: url)).map {String(format: "%02x", $0)}.joined()
            guard actual == hash else {throw CocoaError(.fileReadCorruptFile)}
        }
        let notice = try String(contentsOf: directory.appendingPathComponent("BLENDSWAP_LICENSE.txt"), encoding: .utf8)
        guard notice.contains("Creative Commons Zero (Public Domain)") else {throw CocoaError(.fileReadCorruptFile)}
        return .init(directory: directory)
    }
}
#endif
