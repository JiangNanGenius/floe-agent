//
//  ViewportRenderTests.swift
//  FloeCADKitTests
//
//  Real viewport initialization/render coverage: the RenderContext must build
//  its pipelines from the PACKAGE's shader resource (the CUA crash selected
//  the host app's unrelated default.metallib and then asserted), the library
//  must carry every function the pipelines use, and attaching an MTKView must
//  produce a live renderer — or a recoverable error, never a crash.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Metal
import MetalKit
import XCTest
@testable import FloeCAD

@MainActor
final class ViewportRenderTests: XCTestCase {

    func testRenderContextValidatesPackageShaderFunctions() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        guard let context = RenderContext() else {
            XCTFail("RenderContext failed to build: \(RenderContext.lastLibraryError ?? "unknown")")
            return
        }
        for name in Set(RenderContext.requiredFunctionNames) {
            XCTAssertNotNil(context.library.makeFunction(name: name),
                            "pipeline function \(name) missing from the selected library")
        }
        XCTAssertTrue(RenderContext.libraryValidates(context.library),
                      "the selected library must validate against the required function set")
    }

    func testAttachBuildsRendererAndSurvivesOneDraw() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-viewport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("v.floecad"),
                                                        name: "Viewport")
        defer { document.close() }

        let viewModel = document.viewModel()
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 256))
        let coordinator = ViewportCoordinator(viewModel: viewModel)
        coordinator.attach(to: view)

        XCTAssertNil(viewModel.errorMessage,
                     "attach must not surface a startup error with a working device")
        let renderer = try XCTUnwrap(coordinator.renderer, "attach must build a renderer")
        XCTAssertTrue(view.delegate === renderer, "the MTKView must be driven by the renderer")
        XCTAssertNotNil(renderer.scene, "the renderer must own the document scene")
        // A frame without a window/drawable must be a safe no-op.
        renderer.draw(in: view)
    }
}
