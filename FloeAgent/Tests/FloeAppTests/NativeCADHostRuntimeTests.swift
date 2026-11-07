// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import UIKit
@testable import FloeCAD
import RealityKit
import FloeCore
@testable import FloeApp

/// New native host paths only. The original professional matrix is retained
/// as historical evidence and is not replayed by these small App checks.
@MainActor final class NativeCADHostRuntimeTests: XCTestCase {
    func testFittedTwoMillimetrePartProducesVisiblePresentationPixels() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 256, height: 256)
        let view = ARView(frame: window.bounds, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.black)
        let controller = UIViewController(); controller.view = view
        window.rootViewController = controller; window.makeKeyAndVisible(); view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let bounds = CADPresentationBounds(min: .zero, max: SIMD3(repeating: 0.002))
        let camera = CADPresentationCamera.fitted(to: bounds, aspect: 1)
        XCTAssertLessThan(camera.distance, 0.01, "The regression fixture must be nearer than the former fixed near plane.")
        let anchor = AnchorEntity(world: .zero), cameraEntity = Entity(), stage = Entity()
        cameraEntity.components.set(camera.perspectiveCameraComponent)
        let cube = ModelEntity(mesh: .generateBox(size: 0.002), materials: [UnlitMaterial(color: .red)])
        cube.position = bounds.center; stage.addChild(cube)
        stage.transform = Transform(matrix: camera.stageTransform)
        anchor.addChild(stage); anchor.addChild(cameraEntity); view.scene.addAnchor(anchor)
        try await Task.sleep(for: .milliseconds(700))
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            view.snapshot(saveToHDR: false) { image in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: NSError(domain: "CADPresentationSnapshot", code: 1)) }
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Fitted 2 mm presentation"; attachment.lifetime = .keepAlways; add(attachment)
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let red = try pixels.withUnsafeMutableBytes { raw -> Int in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return stride(from: 0, to: raw.count, by: 4).filter { raw[$0] > 150 && raw[$0+1] < 100 && raw[$0+2] < 100 }.count
        }
        XCTAssertGreaterThan(red, 1_000, "The fitted part must produce model pixels, not just a background.")
    }
    func testBundledWebGLRendererReturnsItsAccumulatedPixels() async throws {
        let positions: [Double] = [-0.5,-0.5,-0.5, 0.5,-0.5,-0.5, 0.5,0.5,-0.5, -0.5,0.5,-0.5,
                                    -0.5,-0.5,0.5, 0.5,-0.5,0.5, 0.5,0.5,0.5, -0.5,0.5,0.5]
        let indices: [UInt32] = [0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,1,2,6,1,6,5,2,3,7,2,7,6,3,0,4,3,4,7]
        let scene = CADOfflineRenderScene(camera: .init(eye: [2,2,3], target: [0,0,0]),
            meshes: [.init(positions: positions, indices: indices)])
        let package = try CADNativeSceneExporter.export(scene, settings: .init(quality: .preview, width: 64, height: 64))
        let host = CADNativeRenderHost(input: try XCTUnwrap(package.files["scene.json"]), settings: package.settings, progress: { _ in })
        defer { host.release() }
        let result = try await host.render()
        XCTAssertGreaterThanOrEqual(result.samples, package.settings.quality.samples)
        let image = try XCTUnwrap(UIImage(data: result.png)?.cgImage)
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 64)
        XCTAssertGreaterThan(result.png.count, 100)
    }

    func testBundledIFCWASMWritesAndReopensRealGeometry() async throws {
        var model = CADBuildingDocument(name: "本机 IFC ' quote \\ path")
        let wall = CADBuildingElement(storeyID: model.storeys[0].id, kind: .wall, name: "墙体",
            a: [0,0], b: [1000,0], thicknessMM: 200, heightMM: 3000)
        let body = try XCTUnwrap(wall.bodyIDs.first); model.elements = [wall]
        let modelObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model))
        let input = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "action": "ifc",
            "revision": 1, "changeCount": 1, "modelSHA256": String(repeating: "0", count: 64),
            "model": modelObject, "geometry": [["elementID": wall.id.uuidString, "bodyID": body.uuidString,
                "verticesM": [[0.0,0,0],[1,0,0],[0,1,0]], "indices": [0,1,2]]]], options: .sortedKeys)
        let result = try await CADBuildingLocalIFCHost().run(input: input)
        let text = try XCTUnwrap(String(data: result.ifc, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("ISO-10303-21;")); XCTAssertTrue(text.contains("IFCWALL"))
        XCTAssertTrue(text.range(of: #"FILE_NAME\('model\.ifc','\d{4}-\d{2}-\d{2}T[^']+'"#, options: .regularExpression) != nil)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: result.metadata) as? [String: Any])
        XCTAssertEqual((metadata["backendVersions"] as? [String: String])?["web-ifc"], "0.0.75")
        XCTAssertGreaterThan(metadata["triangles"] as? Int ?? 0, 0)
    }
}
#endif
