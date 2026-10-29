//
//  CADPresentationUITests.swift
//  FloeCADKitTests (source-only in this lane; Tests/ is core-owned)
//
//  Deterministic checks for the presentation/material UI lane. They do not
//  require a document package, GPU, simulator surface or host localization.
//  Primary moves this file into FloeCADKit/Tests/FloeCADKitTests and runs it
//  with the unified package test target.
//

import XCTest
import simd
@testable import FloeCAD

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)

@MainActor
final class CADPresentationCoordinateTests: XCTestCase {
    func testMillimetresBecomeMetresWithoutAxisRotation() {
        // The live model and RealityKit are both +Y up: only scale changes.
        let converted = CADPresentationAxes.point(SIMD3(1_000, 2_000, 3_000))
        XCTAssertEqual(converted.x, 1, accuracy: 1e-5)
        XCTAssertEqual(converted.y, 2, accuracy: 1e-5)
        XCTAssertEqual(converted.z, 3, accuracy: 1e-5)
    }

    func testDirectionConversionPreservesHandedness() {
        let x = CADPresentationAxes.direction(SIMD3(1, 0, 0))
        let y = CADPresentationAxes.direction(SIMD3(0, 1, 0))
        let z = CADPresentationAxes.direction(SIMD3(0, 0, 1))
        XCTAssertEqual(x, SIMD3(1, 0, 0))
        XCTAssertEqual(y, SIMD3(0, 1, 0))
        XCTAssertEqual(z, SIMD3(0, 0, 1))
        XCTAssertEqual(simd_dot(simd_cross(x, y), z), 1, accuracy: 1e-5)
    }

    func testTranslationConvertsWithMillimetres() {
        let columns: [Double] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            1_000, 2_000, 3_000, 1,
        ]
        let matrix = CADPresentationAxes.matrix(columns)!
        let translation = matrix.columns.3
        XCTAssertEqual(translation.x, 1, accuracy: 1e-5)
        XCTAssertEqual(translation.y, 2, accuracy: 1e-5)
        XCTAssertEqual(translation.z, 3, accuracy: 1e-5)
    }

    func testMalformedMatrixIsRejected() {
        XCTAssertNil(CADPresentationAxes.matrix([1, 0, 0]))
        var nanColumns = [Double](repeating: 0, count: 16)
        nanColumns[0] = .nan
        XCTAssertNil(CADPresentationAxes.matrix(nanColumns))
    }

    func testCameraStageMapsTargetInFrontOfOrigin() {
        let bounds = CADPresentationBounds(min: SIMD3(-1, -1, -1),
                                           max: SIMD3(1, 1, 1))
        let camera = CADPresentationCamera.fitted(to: bounds)
        let target = camera.stageTransform * SIMD4(bounds.center, 1)
        XCTAssertEqual(target.x, 0, accuracy: 1e-4)
        XCTAssertEqual(target.y, 0, accuracy: 1e-4)
        XCTAssertEqual(target.z, -camera.distance, accuracy: 1e-3)
    }
}

@MainActor
final class CADPresentationMaterialResolverTests: XCTestCase {
    private let tinyPNG = Data([0x89, 0x50, 0x4E, 0x47,
                                0x0D, 0x0A, 0x1A, 0x0A])

    func testOpacityAndColorMapAreCarried() {
        let spec = BodyMaterialSpec(
            baseColor: SIMD4(0.5, 0.25, 0.125, 1),
            metallic: 1,
            roughness: 0.2,
            baseColorTexture: tinyPNG,
            opacity: 0.4)
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: spec, bodyID: UUID(), bodyName: "Part",
            hasMeshUVs: true, hasProjectedUVs: false)
        XCTAssertEqual(resolved.material.opacity, 0.4, accuracy: 1e-5)
        XCTAssertEqual(resolved.material.metallic, 1, accuracy: 1e-5)
        XCTAssertEqual(resolved.material.textures.first?.slot, .baseColor)
        XCTAssertEqual(resolved.material.textures.first?.colorSpace, .srgb)
        XCTAssertTrue(resolved.issues.isEmpty)
    }

    func testMissingUVsAreReportedNotInvented() {
        let spec = BodyMaterialSpec(baseColorTexture: tinyPNG)
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: spec, bodyID: UUID(), bodyName: "Part",
            hasMeshUVs: false, hasProjectedUVs: false)
        XCTAssertTrue(resolved.issues.contains { $0.kind == .missingMeshUV })
        XCTAssertEqual(resolved.material.textures.count, 1)
    }

    func testMetadataWithoutBytesReportsMissingTexture() {
        let metadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .normal, mimeType: "image/png",
            colorSpace: .linear, orientation: .topLeft,
            sha256: "abc", byteCount: 10)
        let spec = BodyMaterialSpec(textureMetadata: [metadata])
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: spec, bodyID: UUID(), bodyName: "Part",
            hasMeshUVs: true, hasProjectedUVs: false)
        XCTAssertTrue(resolved.issues.contains { $0.kind == .missingTexture })
        XCTAssertTrue(resolved.material.textures.isEmpty)
    }

    func testNoMaterialUsesNeutralAppearance() {
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: nil, bodyID: nil, bodyName: nil,
            hasMeshUVs: false, hasProjectedUVs: false)
        XCTAssertEqual(resolved.material, .neutral)
        XCTAssertTrue(resolved.issues.isEmpty)
    }
}

@MainActor
final class CADPersonalLibraryContractTests: XCTestCase {
    func testSharedFileMatchesHostContract() {
        let path = CADPersonalMaterialLibraryStore.defaultFileURL().path
        XCTAssertTrue(path.hasSuffix("/FloeAgent/CADMaterials/library.json"))
    }

    func testLibraryRoundTripPreservesTextures() {
        let texture = CADMaterialTexture(slot: .baseColor,
                                         bytes: Data([0x89, 0x50, 0x4E, 0x47,
                                                      0x0D, 0x0A, 0x1A, 0x0A]))
        let definition = CADMaterialDefinition(
            name: "Matte Aluminum", baseColor: SIMD4(0.8, 0.82, 0.84, 1),
            metallic: 1, roughness: 0.35, textures: [texture])
        let library = CADMaterialLibrary(entries: [definition])
        let data = CADMaterialLibraryCodec.encode(library)!
        let decoded = CADMaterialLibraryCodec.decode(data)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries.first?.name, "Matte Aluminum")
        XCTAssertEqual(decoded.entries.first?.textures.first?.slot, .baseColor)
    }
}
#endif
