// SPDX-License-Identifier: MPL-2.0
// Small exchange/receipt contracts. These do not claim WebKit GPU execution.
#if canImport(UIKit) && DEBUG
import XCTest
import UIKit
import FloeCAD
import FloeCore
@testable import FloeApp

@MainActor
final class CADLocalRenderContractTests: XCTestCase {
    private func scene() -> CADOfflineRenderScene {
        .init(camera: .init(eye: [0,1,2], target: [0,0,0]), meshes: [
            .init(positions: [0,0,0, 1,0,0, 0,1,0], indices: [0,1,2])
        ])
    }
    func testLocalSceneHasTypedJSONAndNoProcessInputs() throws {
        let package = try CADNativeSceneExporter.export(scene(), settings: .init(quality:.preview,width:64,height:64))
        XCTAssertEqual(Set(package.files.keys), ["scene.json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(package.files["scene.json"])) as? [String:Any])
        XCTAssertEqual(object["backend"] as? String, CADNativeSceneExporter.backendID)
        let decoded = try JSONDecoder().decode(CADOfflineRenderScene.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["scene"])))
        XCTAssertEqual(decoded.meshes[0].positions, [0,0,0,1,0,0,0,1,0])
        var invalid = scene(); invalid.meshes[0].indices[0] = 100
        XCTAssertThrowsError(try CADNativeSceneExporter.export(invalid, settings:.init(width:64,height:64)))
        invalid = scene(); invalid.assets["assets/../../outside.png"] = Data([1])
        XCTAssertThrowsError(try CADNativeSceneExporter.export(invalid, settings:.init(width:64,height:64)))
    }
    func testBundledRendererIsPinnedAndRasterFallbackIsDisabled() throws {
        let files = try CADNativeRenderResources.files()
        XCTAssertEqual(Set(files.keys), ["index.html","engine.js"])
        let html = String(decoding: try XCTUnwrap(files["index.html"]), as:UTF8.self)
        XCTAssertTrue(html.contains("connect-src 'none'"))
        guard let folder = Bundle.main.url(forResource:"CADNativeRender",withExtension:nil) else { return XCTFail("The folder resource must be present") }
        let source = try String(contentsOf:folder.appendingPathComponent("engine-source.js"),encoding:.utf8)
        XCTAssertTrue(source.contains("tracer.rasterizeScene = false"))
        XCTAssertTrue(source.contains("completedSamples >= samples"))
        XCTAssertFalse(source.contains("https://"))
    }
    func testLocalReceiptRequiresSamplesAndRealDecodedPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalRender-\(UUID())")
        let input = root.appendingPathComponent("input")
        try FileManager.default.createDirectory(at:input,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let package = try CADNativeSceneExporter.export(scene(), settings:.init(quality:.preview,width:64,height:64))
        let data = try XCTUnwrap(package.files["scene.json"])
        try data.write(to:input.appendingPathComponent("scene.json"))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size:CGSize(width:64,height:64),format:format).pngData { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x:0,y:0,width:64,height:64))
        }
        try png.write(to:input.appendingPathComponent("render.png"))
        let operation = CADOfflineRenderOperation(id:UUID(),documentURL:root.appendingPathComponent("Scene.floecad"),
            relativeDirectory:"input",payload:Data(),settings:package.settings,revision:0,changeCount:0,sourceSHA256:"saved-source",
            inputHashes:["scene.json":FloeDigest.sha256Hex(data)],warnings:[],state:.rendering,createdAt:Date(),backendID:CADNativeSceneExporter.backendID)
        func receipt(_ samples: Int) throws {
            try CADOfflineRenderCommands.receipt(sceneSHA256:FloeDigest.sha256Hex(data),imageSHA256:FloeDigest.sha256Hex(png),samples:samples)
                .write(to:input.appendingPathComponent("result.json"),options:.atomic)
        }
        try receipt(0)
        XCTAssertThrowsError(try CADOfflineRenderCenter.verifyAndArchive(operation,archive:root))
        try receipt(16)
        XCTAssertEqual(try CADOfflineRenderCenter.verifyAndArchive(operation,archive:root),FloeDigest.sha256Hex(png))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("render.png")),png)
    }
}
#endif
