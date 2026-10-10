//
//  CADThumbnailIsolationTests.swift
//  FloeCADKitTests
//
//  Regression for the canvas-apply CUA defect: capturing a Canvas viewport
//  thumbnail ("Apply to canvas", then closing the tools panel) abruptly
//  re-framed the LIVE viewport (the cube filled the view and the Top/Front/
//  Right orientation-cube labels disappeared until the document was
//  reopened). The old helper attached a SECOND `ViewportCoordinator` to the
//  shared cached view model; that transient coordinator installed itself as
//  the view model's `cameraControl`, replaced the thumbnail/screenshot
//  providers and fitted ITS camera. The fix renders the thumbnail with a
//  detached renderer over a value-type scene copy fitted by a LOCAL camera.
//
//  These tests pin that contract:
//    * thumbnail capture never changes the live coordinator/camera,
//    * it never hijacks the view model's camera control or providers,
//    * it never mutates selection/mode,
//    * the PNG is real render output that differs per scene (not a blank).
//
//  SPDX-License-Identifier: MPL-2.0
//

import Metal
import MetalKit
import XCTest
import simd
import Euclid
@testable import FloeCAD

@MainActor
final class CADThumbnailIsolationTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADThumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    @discardableResult
    private func addCube(_ document: FloeCADDocument, name: String) -> Body {
        let body = Body(name: name, transform: Transform3D.identity, primitive: nil,
                        euclidMesh: .cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10)),
                        revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Test \(name)"))
        return body
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(at: workDir.appendingPathComponent("\(name).floecad"),
                                         name: name)
    }

    /// A detached snapshot camera must not depend on, or touch, the live
    /// renderer camera; and the rendered bytes must actually reflect the
    /// scene (cube vs empty differ).
    func testSnapshotUsesIndependentCameraAndRendersScene() async throws {
        let empty = try await makeDocument("Empty")
        defer { empty.close() }
        let withCube = try await makeDocument("Cube")
        defer { withCube.close() }
        addCube(withCube, name: "C")

        // An attached LIVE renderer with a deliberately known camera.
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
        let liveModel = withCube.viewModel()
        let liveCoordinator = ViewportCoordinator(viewModel: liveModel)
        liveCoordinator.attach(to: view)
        let liveRenderer = try XCTUnwrap(liveCoordinator.renderer)
        // Orbit the live camera somewhere non-default.
        liveRenderer.camera.azimuth = 0.3
        liveRenderer.camera.elevation = 0.9
        liveRenderer.camera.distance = 77
        let cameraBefore = liveRenderer.camera
        let delegateBefore = view.delegate

        let cubePNG = try XCTUnwrap(withCube.viewportThumbnailPNG(width: 320, height: 240),
                                    "a Metal-capable device must produce a thumbnail")
        let emptyPNG = try XCTUnwrap(empty.viewportThumbnailPNG(width: 320, height: 240))
        XCTAssertFalse(cubePNG.isEmpty)
        XCTAssertEqual(cubePNG.prefix(2), Data([0x89, 0x50]), "PNG signature")
        XCTAssertNotEqual(cubePNG, emptyPNG,
                          "a cube scene and an empty scene must render different bytes")
        // The adopted-cube preview must contain actual shaded geometry, not
        // just background/grid: a substantial share of pixels differ from the
        // clear colour (lit faces + feature edges).
        let cubeCoverage = try Self.nonBackgroundCoverage(cubePNG)
        XCTAssertGreaterThan(cubeCoverage, 0.02,
                             "the cube thumbnail must rasterize real geometry (coverage \(cubeCoverage))")

        // THE regression: the live viewport is exactly where the user left it.
        XCTAssertEqual(liveRenderer.camera, cameraBefore,
                       "thumbnail capture must not re-frame the live camera")
        XCTAssertTrue(view.delegate === delegateBefore
                      && view.delegate === liveRenderer,
                      "the live MTKView must still be driven by its own renderer")
        XCTAssertTrue(liveModel.cameraControl === liveCoordinator,
                      "the transient snapshot must not hijack the view model's camera control")
        XCTAssertTrue(liveModel.selection.isEmpty)
        XCTAssertEqual(liveModel.mode, .idle)
        XCTAssertNil(liveModel.errorMessage)
    }

    /// Repeated captures (e.g. Apply, then reopen) must leave the live state
    /// bit-identical every time.
    func testRepeatedCapturesDoNotDriftLiveCamera() async throws {
        let document = try await makeDocument("Drift")
        defer { document.close() }
        addCube(document, name: "C")
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let model = document.viewModel()
        let coordinator = ViewportCoordinator(viewModel: model)
        coordinator.attach(to: view)
        let renderer = try XCTUnwrap(coordinator.renderer)
        renderer.camera.azimuth = 1.2
        renderer.camera.elevation = 0.4
        renderer.camera.distance = 42
        let original = renderer.camera

        for _ in 0..<3 {
            _ = document.viewportThumbnailPNG(width: 256, height: 256)
            XCTAssertEqual(renderer.camera, original)
        }
        XCTAssertTrue(model.cameraControl === coordinator)
        XCTAssertTrue(view.delegate === renderer)
    }

    /// The snapshot renderer's camera is fitted LOCALLY to the scene bounds;
    /// verifying the independent renderer path directly (no document/view
    /// model involvement).
    func testSnapshotCameraIsIndependentOfRendererCamera() async throws {
        let document = try await makeDocument("LocalCam")
        defer { document.close() }
        addCube(document, name: "C")
        let context = try XCTUnwrap(RenderContext(),
                                    RenderContext.lastLibraryError ?? "RenderContext failed")
        let renderer = Renderer(context: context)
        renderer.camera.azimuth = 2.0
        renderer.camera.elevation = 1.0
        renderer.camera.distance = 500
        let before = renderer.camera

        let snapshot = document.viewModel().scene
        let png = renderer.makeSceneSnapshotPNG(snapshot, width: 160, height: 120)
        XCTAssertNotNil(png)
        XCTAssertEqual(renderer.camera, before,
                       "a scene snapshot must never move the renderer's own camera")
    }

    /// Fraction of pixels that are clearly darker than the background
    /// gradient — shaded bodies/feature edges. Guards against a "successful"
    /// empty/background-only thumbnail masquerading as a geometry render.
    private static func nonBackgroundCoverage(_ png: Data) throws -> Double {
        guard let image = UIImage(data: png), let cgImage = image.cgImage else {
            XCTFail("thumbnail did not decode as an image")
            return 0
        }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { XCTFail("bitmap context failed"); return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0
        let count = width * height
        for i in 0..<count {
            let r = pixels[i * 4], g = pixels[i * 4 + 1], b = pixels[i * 4 + 2]
            // Lit default body ≈ (184,189,199), edges ≈ (33,38,43); the
            // gradient bottom is ≈ (209,214,224). A body face sits well below.
            if r < 200, g < 205, b < 212 { dark += 1 }
        }
        return Double(dark) / Double(count)
    }
}
