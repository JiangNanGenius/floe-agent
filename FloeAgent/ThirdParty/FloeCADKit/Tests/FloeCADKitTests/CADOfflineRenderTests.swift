// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeCAD

final class CADOfflineRenderTests: XCTestCase {
    private func scene() -> CADOfflineRenderScene {
        .init(camera: .init(eye: [1, 1, 2], target: [0, 0, 0]), meshes: [
            .init(positions: [-1,0,-1, -1,0,1, 1,0,1, 1,0,-1], indices: [0,1,2, 0,2,3])
        ], lights: [.init(kind: .directional, intensity: 2000)])
    }
    func testRejectsInvalidGeometryCameraAndUnconfinedAssets() throws {
        let settings = CADOfflineRenderSettings(width: 64, height: 64)
        var input = scene(); input.meshes[0].indices[1] = 10
        XCTAssertThrowsError(try CADPBRTSceneExporter.export(input, settings: settings))
        input = scene(); input.meshes[0].positions[0] = .nan
        XCTAssertThrowsError(try CADPBRTSceneExporter.export(input, settings: settings))
        input = scene(); input.camera.target = input.camera.eye
        XCTAssertThrowsError(try CADPBRTSceneExporter.export(input, settings: settings))
        input = scene(); input.assets["assets/../../outside.png"] = Data([1])
        XCTAssertThrowsError(try CADPBRTSceneExporter.export(input, settings: settings))
    }
    func testPortraitFramingUsesNarrowAxisAndPreservesImmutableReceipt() throws {
        let input = scene()
        let package = try CADPBRTSceneExporter.export(input, settings: .init(quality: .preview, width: 64, height: 128),
            revision: 4, changeCount: 12, sourceSHA256: String(repeating: "a", count: 64))
        let text = try XCTUnwrap(String(data: try XCTUnwrap(package.files["scene.pbrt"]), encoding: .utf8))
        XCTAssertTrue(text.contains("\"float fov\" [32.2042275]"))
        XCTAssertTrue(text.contains("Integrator \"volpath\""))
        XCTAssertEqual(package.revision, 4); XCTAssertEqual(package.changeCount, 12)
        XCTAssertEqual(input.meshes[0].positions[0], -1)
    }
    func testAlphaCoverageAndPartialMetalHaveVisibleConversionLimit() throws {
        var input = scene()
        input.meshes[0].material.metallic = 0.4; input.meshes[0].material.opacity = 0.5
        let package = try CADPBRTSceneExporter.export(input, settings: .init(width: 64, height: 64))
        let text = try XCTUnwrap(String(data: try XCTUnwrap(package.files["scene.pbrt"]), encoding: .utf8))
        XCTAssertTrue(text.contains("Material \"mix\"")); XCTAssertTrue(text.contains("\"float alpha\" [0.5]"))
        XCTAssertEqual(package.warnings.count, 1)
        XCTAssertTrue(package.warnings[0].contains("glass refraction"))
    }
    func testIndependentOrthographicWindowAndQualityBounds() throws {
        var input = scene(); input.camera.orthographicHalfHeight = 3
        let package = try CADPBRTSceneExporter.export(input, settings: .init(width: 128, height: 64))
        let text = try XCTUnwrap(String(data: try XCTUnwrap(package.files["scene.pbrt"]), encoding: .utf8))
        XCTAssertTrue(text.contains("\"float screenwindow\" [-6 6 -3 3]"))
        var settings = CADOfflineRenderSettings(width: 4096, height: 4096)
        XCTAssertThrowsError(try settings.validate())
        settings.width = 128; settings.height = 64; settings.exposureEV = .infinity
        XCTAssertThrowsError(try settings.validate())
    }
    func testShadowCoverageFollowsPartAndBuildingScaleWithoutNonfiniteValues() {
        XCTAssertEqual(CADPresentationLightingScale.shadowDistance(radiusMetres: 0.01), 0.1)
        XCTAssertEqual(CADPresentationLightingScale.shadowDistance(radiusMetres: 30), 120)
        XCTAssertEqual(CADPresentationLightingScale.shadowDistance(radiusMetres: .infinity), 20)
        XCTAssertEqual(CADPresentationLightingScale.shadowDistance(radiusMetres: 1000), 2000)
    }
}

@MainActor
final class CADAnimationRevealTests: XCTestCase {
    func testRevealPreservesFinalCameraAndPersistsThroughUndoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Reveal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Scene.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Reveal")
        defer { document.close() }
        let base = CADAnimationCameraValue(target: .init(10, 3, -4), distance: 40, azimuthRadians: 0.7, elevationRadians: 0.2)
        let old = try document.applyAnimationPreset(.turntable, camera: base)
        let reveal = try document.applyAnimationPreset(.reveal, clipID: old.id, camera: base)
        XCTAssertFalse(CADAnimationPreset.reveal(base: base).isLooping)
        XCTAssertEqual(reveal.isLooping, old.isLooping)
        XCTAssertEqual(reveal.tracks.first?.keyframes.last?.camera, base)
        XCTAssertTrue(reveal.tracks[0].keyframes.allSatisfy { $0.camera?.isValid == true })
        document.session.undo()
        XCTAssertEqual(document.animationLoadState().animation.activeClip, old)
        document.session.redo()
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.animationLoadState().animation.activeClip, reveal)
    }
}
