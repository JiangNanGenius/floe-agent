// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeBuildingAssets
import FloeInteriorCore

final class FurnitureRelativePackageTests:XCTestCase {
    func testModelAndMaterialMayReferenceSiblingDirectoriesInsideSelectedRoot() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source"),library=FurnitureAssetLibrary(rootURL:root.appendingPathComponent("library"))
        for dir in ["Models","Materials","Textures/Wood","Textures/Metal"] {
            try FileManager.default.createDirectory(at:source.appendingPathComponent(dir),withIntermediateDirectories:true)
        }
        let obj="mtllib ../Materials/chair.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\nf 1 2 3\nf 1 3 4\n"
        let mtl="newmtl wood\nmap_Kd ../Textures/Wood/map.png\nnewmtl metal\nmap_Kd ../Textures/Metal/map.png\n"
        try Data(obj.utf8).write(to:source.appendingPathComponent("Models/chair.obj"))
        try Data(mtl.utf8).write(to:source.appendingPathComponent("Materials/chair.mtl"))
        // Distinct synthetic dependency bytes; this checks package identity,
        // not image decoding or native texture rendering.
        try Data([1,2,3]).write(to:source.appendingPathComponent("Textures/Wood/map.png"))
        try Data([4,5,6]).write(to:source.appendingPathComponent("Textures/Metal/map.png"))
        let version=try await library.importOBJ(sourceRootURL:source,relativePath:"Models/chair.obj",
            assetID:"relative-package",version:"1",name:"Chair",provenance:.userProvided(source:"synthetic"),
            sourceBoundsUnit:.millimetre,sourceOrientation:.cadYUp)
        XCTAssertEqual(version.admission,.ready)
        XCTAssertEqual(Set(version.manifest.dependencySHA256.keys),["Materials/chair.mtl","Textures/Wood/map.png","Textures/Metal/map.png"])
        XCTAssertNotEqual(version.manifest.dependencySHA256["Textures/Wood/map.png"],version.manifest.dependencySHA256["Textures/Metal/map.png"])
        let bundle=try await library.open(pin:version.pin())
        XCTAssertEqual(try bundle.verify().verifiedDependencyCount,3)
    }

    func testRelativeResolutionNeverEscapesTheSelectedRoot() throws {
        XCTAssertEqual(try FurnitureAssetPathName.resolve("../Textures/map.png",relativeTo:"Materials",maxBytes:1024),"Textures/map.png")
        XCTAssertEqual(try FurnitureAssetPathName.resolve("./chair.mtl",relativeTo:"Models",maxBytes:1024),"Models/chair.mtl")
        XCTAssertThrowsError(try FurnitureAssetPathName.resolve("../../outside.png",relativeTo:"Materials",maxBytes:1024))
        XCTAssertThrowsError(try FurnitureAssetPathName.resolve("/outside.png",relativeTo:"Materials",maxBytes:1024))
        XCTAssertThrowsError(try FurnitureAssetPathName.resolve("C:/outside.png",relativeTo:"Materials",maxBytes:1024))
        XCTAssertThrowsError(try FurnitureAssetPathName.normalise("Materials/../outside.png",maxBytes:1024))
    }
}
