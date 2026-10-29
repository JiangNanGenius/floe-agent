//
//  CADMaterialRenderContractTests.swift
//  FloeCADKitTests (source-only in the shader lane; Tests/ is core-owned)
//
//  Deterministic checks for the engineering viewport's canonical material
//  contract: the Swift <-> MSL uniform ABI, slot bit/texture-unit mapping,
//  legacy no-map neutrality, six-map carry-through with per-slot colour space
//  and orientation, unavailable-map reporting, per-range (per-face) isolation,
//  shared project UVs and the bounded texture cache.
//
//  The GPU-dependent tests skip themselves when no Metal device exists; the
//  rest need no document package, simulator surface or localization.
//
//  Primary: move this file into FloeCADKit/Tests/FloeCADKitTests after the
//  core handoff and run the unified package test target.
//

import Metal
import OCCTShim
import UIKit
import XCTest
import simd

@testable import FloeCAD

@MainActor
final class CADMaterialRenderContractTests: XCTestCase {

    // MARK: Helpers

    private func png(_ color: UIColor, size: CGSize = CGSize(width: 2, height: 2)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func metadata(slot: MaterialTextureSlot,
                          data: Data,
                          colorSpace: MaterialTextureColorSpace,
                          orientation: MaterialTextureOrientation = .topLeft)
        -> CADMaterialTextureMetadata {
        CADMaterialTextureMetadata(
            assetID: UUID(),
            slot: slot,
            mimeType: "image/png",
            colorSpace: colorSpace,
            orientation: orientation,
            sha256: CADMaterialTexture.digest(data),
            byteCount: data.count)
    }

    private func fullSpec() -> (spec: BodyMaterialSpec, images: [MaterialTextureSlot: Data]) {
        let images: [MaterialTextureSlot: Data] = [
            .baseColor: png(.systemRed),
            .metallic: png(.white),
            .roughness: png(.gray),
            .normal: png(.blue),
            .emissive: png(.yellow),
            .opacity: png(.white),
        ]
        let spec = BodyMaterialSpec(
            baseColor: SIMD4(0.8, 0.2, 0.1, 1),
            metallic: 0.75,
            roughness: 0.4,
            baseColorTexture: images[.baseColor],
            opacity: 0.5,
            emissive: SIMD3(1, 0.5, 0),
            emissiveStrength: 3,
            roughnessTexture: images[.roughness],
            metallicTexture: images[.metallic],
            normalTexture: images[.normal],
            emissiveTexture: images[.emissive],
            opacityTexture: images[.opacity],
            uvMapping: CADMaterialUVMapping(source: .planarProjection),
            textureMetadata: [
                metadata(slot: .baseColor, data: images[.baseColor]!,
                         colorSpace: .srgb, orientation: .bottomLeft),
                metadata(slot: .metallic, data: images[.metallic]!,
                         colorSpace: .linear),
                metadata(slot: .roughness, data: images[.roughness]!,
                         colorSpace: .linear),
                metadata(slot: .normal, data: images[.normal]!,
                         colorSpace: .linear, orientation: .bottomLeft),
                metadata(slot: .emissive, data: images[.emissive]!,
                         colorSpace: .srgb),
                metadata(slot: .opacity, data: images[.opacity]!,
                         colorSpace: .linear),
            ])
        return (spec, images)
    }

    private func triangleMesh(texcoords: [SIMD2<Float>]? = nil) -> RenderMesh {
        // Two triangles, four vertices, +Y-facing, body-local millimetres.
        RenderMesh(
            positions: [[0, 0, 0], [10, 0, 0], [10, 0, 10], [0, 0, 10]],
            normals: [[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]],
            indices: [0, 1, 2, 0, 2, 3],
            texcoords: texcoords)
    }

    // MARK: 1. Uniform ABI / slot mapping

    func testBodyUniformsABIMatchesShaderContract() {
        XCTAssertEqual(MemoryLayout<BodyUniforms>.size, 128)
        XCTAssertEqual(MemoryLayout<BodyUniforms>.stride, 128)
        XCTAssertEqual(MemoryLayout<BodyUniforms>.alignment, 16)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 320)

        let expected: [(PartialKeyPath<BodyUniforms>, Int)] = [
            (\BodyUniforms.modelMatrix, 0),
            (\BodyUniforms.baseColor, 64),
            (\BodyUniforms.selectionState, 80),
            (\BodyUniforms.metallic, 84),
            (\BodyUniforms.roughness, 88),
            (\BodyUniforms.lineHalfWidthPx, 92),
            (\BodyUniforms.emissive, 96),
            (\BodyUniforms.textureFlags, 112),
            (\BodyUniforms.flipVFlags, 116),
            (\BodyUniforms.srgbFlags, 120),
            (\BodyUniforms.normalStrength, 124),
        ]
        for (keyPath, want) in expected {
            XCTAssertEqual(MemoryLayout<BodyUniforms>.offset(of: keyPath), want)
        }

        // New fields are neutral on a default body: a legacy/flat draw adds
        // nothing to the pre-material shading.
        let zero = BodyUniforms()
        XCTAssertEqual(zero.textureFlags, 0)
        XCTAssertEqual(zero.flipVFlags, 0)
        XCTAssertEqual(zero.srgbFlags, 0)
        XCTAssertEqual(zero.normalStrength, 0)
        XCTAssertEqual(zero.emissive, SIMD4<Float>(0, 0, 0, 0))
    }

    func testSlotFlagAndTextureUnitMapping() {
        // Declaration order is the bit order the header and shader use.
        XCTAssertEqual(MaterialTextureSlot.allCases,
                       [.baseColor, .metallic, .roughness, .normal, .emissive, .opacity])
        for (index, slot) in MaterialTextureSlot.allCases.enumerated() {
            XCTAssertEqual(slot.uniformFlag, UInt32(1) << UInt32(index))
            XCTAssertEqual(slot.textureUnit, index)
        }
        XCTAssertEqual(BodyTextureFlagBaseColor.rawValue, 1)
        XCTAssertEqual(BodyTextureFlagMetallic.rawValue, 2)
        XCTAssertEqual(BodyTextureFlagRoughness.rawValue, 4)
        XCTAssertEqual(BodyTextureFlagNormal.rawValue, 8)
        XCTAssertEqual(BodyTextureFlagEmissive.rawValue, 16)
        XCTAssertEqual(BodyTextureFlagOpacity.rawValue, 32)
        XCTAssertEqual(BodyTextureIndexBaseColor.rawValue, 0)
        XCTAssertEqual(BodyTextureIndexOpacity.rawValue, 5)
    }

    // MARK: 2. Legacy default / absence handling

    func testLegacyDefaultMaterialHasNoMapsAndNoEmission() {
        let material = BodyMaterial(spec: .default, meshHasTexcoords: false, revision: 7)
        XCTAssertTrue(material.maps.isEmpty)
        XCTAssertTrue(material.unavailableMapSlots.isEmpty)
        XCTAssertFalse(material.hasAnyMap)
        XCTAssertFalse(material.isTransparent)
        XCTAssertEqual(material.opacity, 1)
        XCTAssertEqual(material.emissive, .zero)
        XCTAssertEqual(material.emissiveStrength, 0)
        XCTAssertEqual(material.textureRevision, 7)
        XCTAssertNil(material.map(.normal))
    }

    func testMaterialEqualityIgnoresImageBytesButNotIdentity() {
        let (spec, _) = fullSpec()
        let first = BodyMaterial(spec: spec, meshHasTexcoords: false, revision: 1)
        let second = BodyMaterial(spec: spec, meshHasTexcoords: false, revision: 1)
        XCTAssertEqual(first, second)

        var changed = second
        changed.maps[0].cacheIdentity = "different-image"
        XCTAssertNotEqual(first, changed)
    }

    // MARK: 3. Six-map carry-through

    func testAllSixMapsCarryWithSlotColourSpaceAndOrientation() {
        let (spec, images) = fullSpec()
        let material = BodyMaterial(spec: spec, meshHasTexcoords: false, revision: 3)

        XCTAssertEqual(material.maps.map(\.slot), MaterialTextureSlot.allCases)
        XCTAssertTrue(material.unavailableMapSlots.isEmpty)
        XCTAssertEqual(material.metallic, 0.75, accuracy: 1e-6)
        XCTAssertEqual(material.roughness, 0.4, accuracy: 1e-6)
        XCTAssertEqual(material.opacity, 0.5, accuracy: 1e-6)
        XCTAssertEqual(material.emissive, SIMD3<Float>(1, 0.5, 0))
        XCTAssertEqual(material.emissiveStrength, 3, accuracy: 1e-6)
        XCTAssertEqual(material.uvMapping?.source, MaterialUVSource.planarProjection)

        XCTAssertEqual(material.map(.baseColor)?.colorSpace, MaterialTextureColorSpace.srgb)
        XCTAssertEqual(material.map(.baseColor)?.orientation, MaterialTextureOrientation.bottomLeft)
        XCTAssertTrue(material.map(.baseColor)?.flipsV == true)
        XCTAssertEqual(material.map(.roughness)?.colorSpace, MaterialTextureColorSpace.linear)
        XCTAssertEqual(material.map(.normal)?.orientation, MaterialTextureOrientation.bottomLeft)
        XCTAssertEqual(material.map(.opacity)?.colorSpace, MaterialTextureColorSpace.linear)

        // The identity is the persisted digest when metadata covers the bytes.
        for slot in MaterialTextureSlot.allCases {
            guard let map = material.map(slot), let data = images[slot] else {
                XCTFail("missing map for \(slot)")
                continue
            }
            XCTAssertEqual(map.cacheIdentity, CADMaterialTexture.digest(data))
            XCTAssertEqual(map.textureCacheKey,
                           "\(slot.rawValue)|\(map.colorSpace.rawValue)|\(map.cacheIdentity)")
            XCTAssertEqual(map.uniformFlag, slot.uniformFlag)
        }
        XCTAssertEqual(Set(material.maps.map(\.textureCacheKey)).count, 6)
    }

    func testMissingMetadataUsesDeterministicFingerprint() {
        let image = png(.green)
        let spec = BodyMaterialSpec(baseColorTexture: image)
        let first = BodyMaterial(spec: spec, meshHasTexcoords: true, revision: 1)
        let second = BodyMaterial(spec: spec, meshHasTexcoords: true, revision: 1)
        XCTAssertEqual(first.map(.baseColor)?.cacheIdentity,
                       second.map(.baseColor)?.cacheIdentity)
        XCTAssertEqual(first.map(.baseColor)?.colorSpace, MaterialTextureColorSpace.srgb)
        XCTAssertEqual(first.map(.baseColor)?.orientation, MaterialTextureOrientation.topLeft)

        let other = BodyMaterial(spec: BodyMaterialSpec(baseColorTexture: png(.purple)),
                                 meshHasTexcoords: true, revision: 1)
        XCTAssertNotEqual(first.map(.baseColor)?.cacheIdentity,
                          other.map(.baseColor)?.cacheIdentity)
    }

    func testStaleMetadataDigestFallsBackToFingerprint() {
        let image = png(.orange)
        let stale = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: String(repeating: "0", count: 64), byteCount: image.count)
        let identity = BodyMaterialMap.identity(for: image, metadata: stale)
        XCTAssertNotEqual(identity, stale.sha256)
        XCTAssertTrue(identity.hasPrefix("fnv1a-\(image.count)-"))
    }

    // MARK: 4. Unavailable maps / opacity

    func testMeshSourceWithoutUVsDropsMapsButKeepsScalars() {
        let (spec, _) = fullSpec()
        var meshMapping = spec
        meshMapping.uvMapping = .mesh
        let dropped = BodyMaterial(spec: meshMapping, meshHasTexcoords: false, revision: 1)
        XCTAssertTrue(dropped.maps.isEmpty)
        XCTAssertEqual(Set(dropped.unavailableMapSlots), Set(MaterialTextureSlot.allCases))
        XCTAssertEqual(dropped.metallic, 0.75, accuracy: 1e-6)

        // A projection makes the same six maps sampleable without mesh UVs.
        let projected = BodyMaterial(spec: spec, meshHasTexcoords: false, revision: 1)
        XCTAssertEqual(projected.maps.count, 6)
        XCTAssertTrue(projected.unavailableMapSlots.isEmpty)
    }

    func testOpacityIsTransparentForFactorOrMap() {
        XCTAssertFalse(BodyMaterial(baseColor: SIMD4(1, 1, 1, 1)).isTransparent)
        XCTAssertTrue(BodyMaterial(baseColor: SIMD4(1, 1, 1, 1), opacity: 0.5).isTransparent)

        let image = png(.white)
        let map = BodyMaterialMap(slot: .opacity, data: image, cacheIdentity: "opacity",
                                  colorSpace: .linear, orientation: .topLeft)
        XCTAssertTrue(BodyMaterial(baseColor: SIMD4(1, 1, 1, 1), maps: [map]).isTransparent)
    }

    // MARK: 5. Shared UVs

    func testProjectedUVsUseSharedProjectorAndAreNotFlippedOnCPU() throws {
        let mesh = triangleMesh()
        XCTAssertNil(BodyGPUResources.projectedTexcoords(mesh: mesh, material: nil))

        let projected = try XCTUnwrap(BodyGPUResources.projectedTexcoords(
            mesh: mesh,
            material: BodyMaterial(
                baseColor: SIMD4(1, 1, 1, 1),
                uvMapping: CADMaterialUVMapping(source: .planarProjection,
                                                axis: .y, scaleMM: SIMD2(10, 10)))))
        XCTAssertEqual(projected.count, mesh.positions.count)
        // +Y planar projection uses (x, z): 0…1 after the 10 mm tile.
        XCTAssertEqual(projected[0], SIMD2<Float>(0, 0))
        XCTAssertEqual(projected[2], SIMD2<Float>(1, 1))

        let authored = [SIMD2<Float>](repeating: SIMD2(0.25, 0.75),
                                      count: mesh.positions.count)
        let withAuthored = try XCTUnwrap(BodyGPUResources.projectedTexcoords(
            mesh: triangleMesh(texcoords: authored), material: nil))
        XCTAssertEqual(withAuthored, authored)
    }

    // MARK: 6. Per-face isolation / cache identity

    func testMaterialKeyTracksMapsAndFaceRangesButNotScalars() {
        let imageA = png(.red)
        let imageB = png(.blue)
        let mapA = BodyMaterialMap(slot: .baseColor, data: imageA, cacheIdentity: "A",
                                   colorSpace: .srgb, orientation: .topLeft)
        let face = BodyFaceMaterial(
            faceIndex: 1, triangles: [0],
            material: BodyMaterial(baseColor: SIMD4(1, 1, 1, 1),
                                   uvMapping: .mesh,
                                   maps: [mapA]))
        let drawable = BodyDrawable(
            id: BodyID(), renderMesh: triangleMesh(), meshRevision: 1,
            modelMatrix: matrix_identity_float4x4,
            baseColor: SIMD4(1, 1, 1, 1),
            material: BodyMaterial(baseColor: SIMD4(1, 1, 1, 1),
                                   uvMapping: .mesh,
                                   maps: [mapA]),
            faceMaterials: [face])
        let baseline = BodyGPUResources.materialKey(for: drawable)

        var scalarOnly = drawable
        scalarOnly.material?.metallic = 0.9
        XCTAssertEqual(BodyGPUResources.materialKey(for: scalarOnly), baseline,
                       "scalar factors only change uniforms, not cached buffers")

        var changedMap = drawable
        changedMap.faceMaterials[0].material.maps[0].cacheIdentity = "B"
        XCTAssertNotEqual(BodyGPUResources.materialKey(for: changedMap), baseline)

        var changedFace = drawable
        changedFace.faceMaterials[0].triangles = [1]
        XCTAssertNotEqual(BodyGPUResources.materialKey(for: changedFace), baseline)
    }

    func testBodyRangesSplitBaseAndFaceWithTheirOwnMaps() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        let albedo = png(.red)
        let normal = png(.blue)
        let faceMaterial = BodyMaterial(
            baseColor: SIMD4(1, 0.5, 0.5, 1),
            uvMapping: .mesh,
            maps: [BodyMaterialMap(slot: .baseColor, data: albedo,
                                   cacheIdentity: "face-albedo",
                                   colorSpace: .srgb, orientation: .topLeft),
                   BodyMaterialMap(slot: .normal, data: normal,
                                   cacheIdentity: "face-normal",
                                   colorSpace: .linear, orientation: .topLeft)])
        let bodyMaterial = BodyMaterial(
            baseColor: SIMD4(0.5, 0.5, 1, 1), uvMapping: .mesh,
            maps: [BodyMaterialMap(slot: .roughness, data: png(.gray),
                                   cacheIdentity: "body-roughness",
                                   colorSpace: .linear, orientation: .topLeft)])
        let drawable = BodyDrawable(
            id: BodyID(), renderMesh: triangleMesh(), meshRevision: 4,
            modelMatrix: matrix_identity_float4x4,
            baseColor: SIMD4(1, 1, 1, 1),
            material: bodyMaterial,
            faceMaterials: [BodyFaceMaterial(faceIndex: 7, triangles: [0],
                                             material: faceMaterial)])
        let resources = try XCTUnwrap(BodyGPUResources(drawable: drawable, device: device))

        XCTAssertEqual(resources.meshRevision, 4)
        XCTAssertEqual(resources.faceRanges.count, 1)
        let faceRange = try XCTUnwrap(resources.faceRanges.first)
        XCTAssertEqual(faceRange.faceIndex, 7)
        XCTAssertTrue(faceRange.isFaceRange)
        XCTAssertEqual(faceRange.triangles, [0])
        XCTAssertEqual(faceRange.materialIndex, 0)
        XCTAssertEqual(faceRange.material(in: drawable)?.baseColor,
                       SIMD4<Float>(1, 0.5, 0.5, 1))
        XCTAssertEqual(faceRange.maps.map(\.slot), [.baseColor, .normal])
        XCTAssertNotNil(faceRange.texcoordBuffer)

        let baseRange = try XCTUnwrap(resources.baseRange)
        XCTAssertNil(baseRange.faceIndex)
        XCTAssertEqual(baseRange.materialIndex, -1)
        XCTAssertEqual(baseRange.material(in: drawable)?.baseColor,
                       SIMD4<Float>(0.5, 0.5, 1, 1))
        XCTAssertEqual(baseRange.triangles, [1])
        XCTAssertEqual(baseRange.maps.map(\.slot), [.roughness])

        // A scalar-only edit must reach the uniforms through the SAME cached
        // range (no buffer rebuild, no stale material snapshot).
        var edited = drawable
        edited.faceMaterials[0].material.metallic = 0.9
        XCTAssertEqual(faceRange.material(in: edited)?.metallic, 0.9)

        // The face material is isolated: no body map leaks into the face range
        // and the two index ranges never overlap.
        XCTAssertTrue(Set(faceRange.maps.map(\.cacheKey))
            .isDisjoint(with: baseRange.maps.map(\.cacheKey)))
        XCTAssertTrue(Set(faceRange.triangles).isDisjoint(with: Set(baseRange.triangles)))
        XCTAssertEqual(faceRange.indexCount, 3)
        XCTAssertEqual(baseRange.indexCount, 3)
    }

    // MARK: 7. Texture cache bounds / isolation

    func testTextureCachePrunesAndReportsFailures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        let redMap = BodyMaterialMap(slot: .baseColor, data: png(.red),
                                     cacheIdentity: "red", colorSpace: .srgb,
                                     orientation: .topLeft)
        let blueMap = BodyMaterialMap(slot: .baseColor, data: png(.blue),
                                      cacheIdentity: "blue", colorSpace: .srgb,
                                      orientation: .topLeft)
        let brokenMap = BodyMaterialMap(slot: .normal, data: Data([0, 1, 2, 3, 4]),
                                        cacheIdentity: "broken", colorSpace: .linear,
                                        orientation: .topLeft)
        func drawable(_ maps: [BodyMaterialMap], id: BodyID) -> BodyDrawable {
            BodyDrawable(id: id, renderMesh: triangleMesh(), meshRevision: 1,
                         modelMatrix: matrix_identity_float4x4,
                         baseColor: SIMD4(1, 1, 1, 1),
                         material: BodyMaterial(baseColor: SIMD4(1, 1, 1, 1),
                                                maps: maps))
        }
        let first = drawable([redMap, brokenMap], id: BodyID())
        let second = drawable([blueMap], id: BodyID())
        let cache = BodyTextureCache()
        cache.sync(bodies: [first, second], device: device)
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertNotNil(cache.texture(forKey: redMap.textureCacheKey))
        XCTAssertNotNil(cache.texture(forKey: blueMap.textureCacheKey))
        XCTAssertNil(cache.texture(forKey: brokenMap.textureCacheKey))
        XCTAssertTrue(cache.failedKeys.contains(brokenMap.textureCacheKey))
        XCTAssertLessThanOrEqual(cache.decodedByteCount, BodyTextureCache.maximumDecodedBytes)
        XCTAssertLessThanOrEqual(cache.entryCount, BodyTextureCache.maximumEntries)

        // Switching documents/bodies prunes the maps they no longer reference.
        cache.sync(bodies: [second], device: device)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertNil(cache.texture(forKey: redMap.textureCacheKey))
        XCTAssertNotNil(cache.texture(forKey: blueMap.textureCacheKey))
        XCTAssertFalse(cache.failedKeys.contains(brokenMap.textureCacheKey))
    }

    // MARK: 8. Runtime shader compile (real MSL, real device)

    func testPackageShadersCompileWithAllMaterialBindings() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable in this environment.")
        }
        let context = try XCTUnwrap(RenderContext(),
                                    RenderContext.lastLibraryError ?? "RenderContext failed")
        for name in ["vertex_litTextured", "fragment_litTextured",
                     "vertex_lit", "fragment_lit"] {
            XCTAssertNotNil(context.library.makeFunction(name: name),
                            "\(name) missing from the package shader library")
        }
    }
}
