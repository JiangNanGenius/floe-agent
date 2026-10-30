//
//  CADMaterialUVConsistencyTests.swift
//  FloeCADKitTests
//
//  Focused source checks for X13/X14/X15:
//  - per-map image orientation is independent (colour vs normal);
//  - an explicit per-face projection wins over authored mesh UVs in Edit,
//    Present and GLB, with and without authored UVs;
//  - library materials are independent copies, and a batch reapply is an
//    explicit, undoable document change.
//
//  The expectations below use known UV/pixel/tangent arithmetic rather than
//  calling the same production helper twice.
//

import Foundation
import XCTest
import simd

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import CoreGraphics
import RealityKit
import UIKit
#endif

@testable import FloeCAD

// MARK: - Fixtures

private enum MaterialUVFixtures {
    static let red1x1 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg=="
    )!
    static let blue1x1 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNgYPj/HwADAgH/OSkZvgAAAABJRU5ErkJggg=="
    )!
    static let red2x2 = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR42mP4z8DwHwyBNBgAAEnICfcD2WTxAAAAAElFTkSuQmCC"
    )!

    static func metadata(slot: MaterialTextureSlot, data: Data,
                         colorSpace: MaterialTextureColorSpace,
                         orientation: MaterialTextureOrientation)
        -> CADMaterialTextureMetadata {
        CADMaterialTextureMetadata(
            assetID: UUID(), slot: slot,
            mimeType: "image/png",
            colorSpace: colorSpace,
            orientation: orientation,
            sha256: CADMaterialTexture.digest(data),
            byteCount: data.count)
    }

    static func planarZ(scale: SIMD2<Double>, offset: SIMD2<Double> = .zero)
        -> CADMaterialUVMapping {
        CADMaterialUVMapping(source: .planarProjection, axis: .z,
                             scaleMM: scale, offset: offset)
    }
}

private func assertUVs(_ actual: [SIMD2<Float>]?,
                       _ expected: [SIMD2<Float>],
                       file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else {
        XCTFail("missing UV array", file: file, line: line)
        return
    }
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (index, pair) in zip(actual, expected).enumerated() {
        XCTAssertEqual(pair.0.x, pair.1.x, accuracy: 1e-5,
                       "u[\(index)]", file: file, line: line)
        XCTAssertEqual(pair.0.y, pair.1.y, accuracy: 1e-5,
                       "v[\(index)]", file: file, line: line)
    }
}

private func glbJSON(_ glb: Data) throws -> [String: Any] {
    func u32(_ offset: Int) -> UInt32 {
        glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
    XCTAssertEqual(u32(0), GLBExporter.magic)
    let length = Int(u32(12))
    XCTAssertGreaterThan(length, 0)
    let json = glb.subdata(in: 20..<(20 + length))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
}

private func glbBinary(_ glb: Data) throws -> Data {
    func u32(_ offset: Int) -> UInt32 {
        glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
    var offset = 20 + Int(u32(12))
    while offset + 8 <= glb.count {
        let length = Int(u32(offset))
        let type = u32(offset + 4)
        let start = offset + 8
        guard start + length <= glb.count else { break }
        if type == 0x004E4942 { // BIN\0
            return glb.subdata(in: start..<(start + length))
        }
        offset = start + length
    }
    throw XCTSkip("GLB has no binary chunk")
}

// MARK: - Core UV / orientation

@MainActor
final class CADMaterialUVSourceContractTests: XCTestCase {
    func testExplicitProjectionWinsOverAuthoredMeshUVsWithKnownValues() {
        let positions = [SIMD3<Float>(0, 0, 0),
                         SIMD3<Float>(10, 0, 0),
                         SIMD3<Float>(0, 20, 0)]
        let normals = [SIMD3<Float>(0, 0, 1),
                       SIMD3<Float>(0, 0, 1),
                       SIMD3<Float>(0, 0, 1)]
        let indices: [UInt32] = [0, 1, 2]
        let authored = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
                        SIMD2<Float>(0, 1)]
        let mapping = CADMaterialUVMapping(
            source: .planarProjection, axis: .z,
            scaleMM: SIMD2(5, 10), rotationDegrees: 90,
            offset: SIMD2(0.25, 0.5), flipU: true)

        // Independent arithmetic: (x,y) rotated 90°, divided by 5/10,
        // translated, then mirrored in U.
        let expected = [SIMD2<Float>(-0.25, 0.5),
                        SIMD2<Float>(-0.25, 1.5),
                        SIMD2<Float>(3.75, 0.5)]
        let effective = MaterialUVProjector.effectiveUVs(
            meshTexcoords: authored, positions: positions,
            normals: normals, indices: indices, mapping: mapping)
        assertUVs(effective, expected)

        // The default/mesh source preserves the authored set exactly.
        let preserved = MaterialUVProjector.effectiveUVs(
            meshTexcoords: authored, positions: positions,
            normals: normals, indices: indices, mapping: .mesh)
        XCTAssertEqual(preserved, Optional(authored))

        let body = Body(
            id: BodyID(), name: "Triangle", transform: .identity,
            primitive: nil,
            render: RenderMesh(positions: positions, normals: normals,
                               indices: indices, texcoords: authored),
            revision: 1)
        let material = BodyMaterial(
            baseColor: SIMD4(1, 1, 1, 1), uvMapping: mapping)
        assertUVs(BodyGPUResources.projectedTexcoords(
            mesh: body.render, material: material), expected)
        assertUVs(MaterialUVProjector.renderUVs(
            for: body, material: BodyMaterialSpec(uvMapping: mapping)), expected)
    }

    func testPerMapOrientationSurvivesSnapshotAndLibraryRoundTrip() {
        let base = MaterialUVFixtures.red1x1
        let normal = MaterialUVFixtures.blue1x1
        let baseMeta = MaterialUVFixtures.metadata(
            slot: .baseColor, data: base,
            colorSpace: .srgb, orientation: .topLeft)
        let normalMeta = MaterialUVFixtures.metadata(
            slot: .normal, data: normal,
            colorSpace: .linear, orientation: .bottomLeft)
        let spec = BodyMaterialSpec(
            baseColorTexture: base, normalTexture: normal,
            textureMetadata: [baseMeta, normalMeta]).clamped

        XCTAssertEqual(spec.textureOrientation(for: .baseColor), .topLeft)
        XCTAssertEqual(spec.textureOrientation(for: .normal), .bottomLeft)
        XCTAssertEqual(spec.textureColorSpace(for: .normal), .linear)

        let material = BodyMaterial(spec: spec, meshHasTexcoords: true,
                                    revision: 1)
        XCTAssertEqual(material.map(.baseColor)?.orientation, .topLeft)
        XCTAssertEqual(material.map(.normal)?.orientation, .bottomLeft)
        XCTAssertEqual(material.map(.baseColor)?.flipsV ?? true, false)
        XCTAssertEqual(material.map(.normal)?.flipsV ?? false, true)

        // Saving the applied appearance to the library and applying that
        // definition again must not reset the normal map to topLeft.
        let definition = CADMaterialDefinition(spec: spec)
        XCTAssertEqual(definition.texture(for: .baseColor)?.orientation, .topLeft)
        XCTAssertEqual(definition.texture(for: .normal)?.orientation, .bottomLeft)
        XCTAssertEqual(definition.texture(for: .normal)?.colorSpace, .linear)
        let restored = definition.bodyMaterialSpec()
        XCTAssertEqual(restored.textureOrientation(for: .baseColor), .topLeft)
        XCTAssertEqual(restored.textureOrientation(for: .normal), .bottomLeft)
    }

    func testStaleTextureMetadataCannotRelabelCurrentPixels() {
        let normal = MaterialUVFixtures.blue1x1
        var spec = BodyMaterialSpec(
            normalTexture: normal,
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .normal, data: normal,
                colorSpace: .linear, orientation: .bottomLeft)])
        XCTAssertEqual(spec.textureOrientation(for: .normal), .bottomLeft)

        if var metadata = spec.textureMetadata {
            metadata[0].sha256 = String(repeating: "0", count: 64)
            spec.textureMetadata = metadata
        }
        XCTAssertNil(spec.verifiedTextureMetadata(for: .normal))
        XCTAssertEqual(spec.textureOrientation(for: .normal), .topLeft,
                       "a stale record must not relabel the bytes")
        let definition = CADMaterialDefinition(spec: spec)
        XCTAssertEqual(definition.texture(for: .normal)?.orientation, .topLeft)
    }
}

// MARK: - GLB orientation re-read

@MainActor
final class CADMaterialGLBOrientationTests: XCTestCase {
    func testOppositeColorAndNormalOriginsExportIndependentlyAndReimport() throws {
        let base = MaterialUVFixtures.red2x2
        let normal = MaterialUVFixtures.blue1x1
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0, 0),
                         SIMD3<Float>(0, 10, 0)]
        let normals = [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, 1),
                       SIMD3<Float>(0, 0, 1)]
        var body = Body(
            id: BodyID(), name: "Oriented",
            transform: .identity, primitive: nil,
            render: RenderMesh(positions: positions, normals: normals,
                               indices: [0, 1, 2]),
            revision: 1)
        let mapping = CADMaterialUVMapping(
            source: .planarProjection, axis: .z,
            scaleMM: SIMD2(10, 20), offset: SIMD2(0.25, 0))
        body.material = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1),
            baseColorTexture: base,
            materialName: "Opposite origins",
            normalTexture: normal,
            uvMapping: mapping,
            textureMetadata: [
                MaterialUVFixtures.metadata(slot: .baseColor, data: base,
                                            colorSpace: .srgb,
                                            orientation: .topLeft),
                MaterialUVFixtures.metadata(slot: .normal, data: normal,
                                            colorSpace: .linear,
                                            orientation: .bottomLeft),
            ])

        let glb = GLBExporter.glb(bodies: [body])
        let json = try glbJSON(glb)
        let materials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        let pbr = try XCTUnwrap(materials.first?["pbrMetallicRoughness"]
            as? [String: Any])
        let baseInfo = try XCTUnwrap(pbr["baseColorTexture"] as? [String: Any])
        XCTAssertNil(baseInfo["extensions"],
                     "a top-left colour map must not inherit the normal map's flip")
        let normalInfo = try XCTUnwrap(materials.first?["normalTexture"]
            as? [String: Any])
        let transform = try XCTUnwrap(
            ((normalInfo["extensions"] as? [String: Any])?["KHR_texture_transform"]
                as? [String: Any]))
        XCTAssertEqual(transform["offset"] as? [Double], [0, 1])
        XCTAssertEqual(transform["scale"] as? [Double], [1, -1])
        XCTAssertTrue((json["extensionsUsed"] as? [String] ?? [])
            .contains("KHR_texture_transform"))

        // Re-read the actual exported GLB: the two maps keep opposite
        // declarations while sharing the same mesh UV set.
        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let part = try XCTUnwrap(parts.first)
        XCTAssertEqual(part.material?.textureOrientation(for: .baseColor), .topLeft)
        XCTAssertEqual(part.material?.textureOrientation(for: .normal), .bottomLeft)
        let expected = [
            SIMD2<Float>(0.25, 0), SIMD2<Float>(1.25, 0),
            SIMD2<Float>(0.25, 0.5),
        ]
        assertUVs(part.mesh.texcoords, expected)

        // The exported image bufferViews still contain the exact authored
        // bytes; orientation is metadata/UV sampling, not a re-encode.
        let binary = try glbBinary(glb)
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        var imageBytes = Set<Data>()
        for image in images {
            guard let viewIndex = image["bufferView"] as? Int,
                  viewIndex < views.count else { continue }
            let view = views[viewIndex]
            let offset = (view["byteOffset"] as? Int) ?? 0
            let length = try XCTUnwrap(view["byteLength"] as? Int)
            imageBytes.insert(binary.subdata(in: offset..<(offset + length)))
        }
        XCTAssertEqual(imageBytes, Set([base, normal]))
    }
}

// MARK: - Per-face projection across Present and GLB

@MainActor
final class CADMaterialFaceProjectionTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADMaterialFaceProjection-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)")
        return (try? JSONSerialization.jsonObject(with: outcome.payload))
            as? [String: Any] ?? [:]
    }

    private func makeBox(_ document: FloeCADDocument) throws -> Body {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"Box"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,10],
         "distance":10}}
        """)
        return try XCTUnwrap(document.session.document.bodies.first)
    }

    private func expectedPlanar(_ p: SIMD3<Float>,
                                axis: MaterialProjectionAxis,
                                scale: SIMD2<Double>,
                                offset: SIMD2<Double>) -> SIMD2<Float> {
        let (u, v): (Double, Double)
        switch axis {
        case .x: (u, v) = (Double(p.y), Double(p.z))
        case .y: (u, v) = (Double(p.x), Double(p.z))
        case .z: (u, v) = (Double(p.x), Double(p.y))
        }
        return SIMD2(Float(u / scale.x + offset.x),
                     Float(v / scale.y + offset.y))
    }

    private func makeSnapshot(meshHasUVs: Bool) -> CADSceneSnapshot {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0, 0),
                         SIMD3<Float>(10, 10, 0), SIMD3<Float>(0, 10, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        let indices: [UInt32] = [0, 1, 2, 0, 2, 3]
        let authored: [SIMD2<Float>]? = meshHasUVs
            ? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            : nil
        let base = MaterialUVFixtures.red1x1
        let blue = MaterialUVFixtures.blue1x1

        let bodySpec = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1),
            baseColorTexture: base,
            materialName: "Body",
            uvMapping: MaterialUVFixtures.planarZ(
                scale: SIMD2(20, 40), offset: SIMD2(0.1, 0.2)),
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .baseColor, data: base,
                colorSpace: .srgb, orientation: .topLeft)])
        let face1Spec = BodyMaterialSpec(
            baseColor: SIMD4(0.8, 0.2, 0.2, 1),
            baseColorTexture: base,
            materialName: "Face 1",
            uvMapping: MaterialUVFixtures.planarZ(scale: SIMD2(10, 10)),
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .baseColor, data: base,
                colorSpace: .srgb, orientation: .topLeft)])
        let face2Spec = BodyMaterialSpec(
            baseColor: SIMD4(0.2, 0.2, 0.8, 1),
            materialName: "Face 2",
            normalTexture: blue,
            uvMapping: CADMaterialUVMapping(
                source: .planarProjection, axis: .y,
                scaleMM: SIMD2(5, 5), offset: SIMD2(0.5, 0.5)),
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .normal, data: blue,
                colorSpace: .linear, orientation: .bottomLeft)])

        let signature1 = FaceSignature(
            kind: .planar, normal: SIMD3(0, 0, 1),
            centroid: SIMD3(6.67, 3.33, 0), area: 50, planeOffset: 0)
        let signature2 = FaceSignature(
            kind: .planar, normal: SIMD3(0, 0, 1),
            centroid: SIMD3(3.33, 6.67, 0), area: 50, planeOffset: 0)
        let mesh = CADSceneMeshResource(
            positions: positions, normals: normals, indices: indices,
            texcoords: authored, renderTexcoords: nil,
            meshRevision: 1,
            boundsMin: SIMD3(0, 0, 0), boundsMax: SIMD3(10, 10, 0))
        let body = CADSceneBodyResource(
            id: UUID(), name: "FaceBody", isHidden: false,
            transform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            mesh: mesh, material: bodySpec,
            faceMaterials: [
                CADSceneFaceMaterial(faceIndex: 1, material: face1Spec,
                                     signature: signature1,
                                     triangleIndices: [0, 1, 2],
                                     triangleNumbers: [0]),
                CADSceneFaceMaterial(faceIndex: 2, material: face2Spec,
                                     signature: signature2,
                                     triangleIndices: [0, 2, 3],
                                     triangleNumbers: [1]),
            ],
            unresolvedFaceCount: 0, analyticBRep: false)

        return CADSceneSnapshot(
            schemaVersion: 1, documentRevision: 1, changeCount: 1,
            contentSHA256: "content", modelSHA256: "model",
            unit: "mm", coordinateSystem: "right-handed-y-up-mm",
            bodies: [body], materials: [], images: [],
            appearance: .default, unresolvedFaceBindings: [])
    }

    func testPresentUsesEachFacesProjectionWithAndWithoutAuthoredUVs() throws {
        let expectedBody = [SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.6, 0.2),
                            SIMD2<Float>(0.6, 0.45), SIMD2<Float>(0.1, 0.45)]
        let expectedFace1 = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
                             SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)]
        let expectedFace2 = [SIMD2<Float>(0.5, 0.5), SIMD2<Float>(2.5, 0.5),
                             SIMD2<Float>(2.5, 0.5), SIMD2<Float>(0.5, 0.5)]

        for hasUVs in [true, false] {
            let scene = CADPresentationSceneBuilder.build(
                snapshot: makeSnapshot(meshHasUVs: hasUVs),
                documentKey: "face-\(hasUVs)")
            let body = try XCTUnwrap(scene.bodies.first)
            assertUVs(body.mesh.uvs, expectedBody)
            let groups = Dictionary(uniqueKeysWithValues:
                body.faceGroups.map { ($0.faceIndex, $0) })
            let group1 = try XCTUnwrap(groups[1])
            let group2 = try XCTUnwrap(groups[2])
            assertUVs(group1.uvs, expectedFace1)
            assertUVs(group2.uvs, expectedFace2)
            XCTAssertNotEqual(group1.uvs, group2.uvs,
                              "different face scales must not share one UV set")
            XCTAssertEqual(group1.material.texture(for: .baseColor)?.orientation,
                           .topLeft)
            XCTAssertEqual(group2.material.texture(for: .normal)?.orientation,
                           .bottomLeft)
            XCTAssertTrue(scene.images.contains {
                $0.id == CADMaterialTexture.digest(MaterialUVFixtures.blue1x1)
            }, "a face-only map must be carried into the scene image table")
        }
    }

    func testFaceOnlyOrBodyOnlyMappingEditChangesTheBuildIdentity() throws {
        let first = CADPresentationSceneBuilder.build(
            snapshot: makeSnapshot(meshHasUVs: true), documentKey: "identity")
        let body = try XCTUnwrap(first.bodies.first)

        var changedFace = makeSnapshot(meshHasUVs: true)
        changedFace.bodies[0].faceMaterials[1].material.uvMapping =
            MaterialUVFixtures.planarZ(scale: SIMD2(7, 7))
        let changedFaceScene = CADPresentationSceneBuilder.build(
            snapshot: changedFace, documentKey: "identity")
        XCTAssertNotEqual(first.buildKey, changedFaceScene.buildKey,
                          "a face-only mapping edit must rebuild Present")

        var changedBody = makeSnapshot(meshHasUVs: true)
        changedBody.bodies[0].material?.uvMapping =
            MaterialUVFixtures.planarZ(scale: SIMD2(30, 30))
        let changedBodyScene = CADPresentationSceneBuilder.build(
            snapshot: changedBody, documentKey: "identity")
        let changedMesh = try XCTUnwrap(changedBodyScene.bodies.first?.mesh)
        XCTAssertNotEqual(body.mesh.cacheKey, changedMesh.cacheKey,
                          "a mapping-only edit must not reuse the old UV buffer")
    }

    func testGLBExportsEachFacesProjectionWithAndWithoutAuthoredUVs() async throws {
        let url = workDir.appendingPathComponent("faces.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Faces")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entries = table.entries.filter { !$0.triangles.isEmpty }
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        let entryA = entries[0]
        let entryB = entries[1]

        let mappingA = MaterialUVFixtures.planarZ(
            scale: SIMD2(20, 40), offset: SIMD2(0.1, 0.2))
        let mappingB = CADMaterialUVMapping(
            source: .planarProjection, axis: .y,
            scaleMM: SIMD2(5, 5), offset: SIMD2(0.5, 0.5))
        let materialA = BodyMaterialSpec(
            baseColor: SIMD4(0.9, 0.2, 0.1, 1),
            baseColorTexture: MaterialUVFixtures.red1x1,
            materialName: "Face A",
            uvMapping: mappingA,
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .baseColor, data: MaterialUVFixtures.red1x1,
                colorSpace: .srgb, orientation: .topLeft)])
        let materialB = BodyMaterialSpec(
            baseColor: SIMD4(0.1, 0.2, 0.9, 1),
            baseColorTexture: MaterialUVFixtures.blue1x1,
            materialName: "Face B",
            uvMapping: mappingB,
            textureMetadata: [MaterialUVFixtures.metadata(
                slot: .baseColor, data: MaterialUVFixtures.blue1x1,
                colorSpace: .srgb, orientation: .topLeft)])
        let bindingA = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entryA.signature, capturedIndex: 1),
            material: materialA)
        let bindingB = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entryB.signature, capturedIndex: 2),
            material: materialB)

        for hasUVs in [true, false] {
            var candidate = source
            candidate.material = nil
            candidate.materialFaceBindings = [bindingA, bindingB]
            if hasUVs {
                candidate.render.texcoords = (0..<source.render.positions.count)
                    .map { index in
                        SIMD2(Float(index % 7) / 7, Float((index * 3) % 11) / 11)
                    }
            } else {
                candidate.render.texcoords = nil
            }
            XCTAssertEqual(candidate.render.positions, source.render.positions)

            let glb = GLBExporter.glb(
                bodies: [candidate],
                faceTables: [candidate.id: table],
                faceTableRevisions: [candidate.id: candidate.meshRevision])
            let parts = try GLTFImporter.parts(
                from: glb, isBinary: true, siblings: [:], unitScale: 1)
            let partA = try XCTUnwrap(parts.first {
                $0.material?.materialName == "Face A"
            })
            let partB = try XCTUnwrap(parts.first {
                $0.material?.materialName == "Face B"
            })
            let expectedA = candidate.render.positions.map {
                expectedPlanar($0, axis: .z, scale: SIMD2(20, 40),
                               offset: SIMD2(0.1, 0.2))
            }
            let expectedB = candidate.render.positions.map {
                expectedPlanar($0, axis: .y, scale: SIMD2(5, 5),
                               offset: SIMD2(0.5, 0.5))
            }
            assertUVs(partA.mesh.texcoords, expectedA)
            assertUVs(partB.mesh.texcoords, expectedB)
            XCTAssertNotEqual(partA.mesh.texcoords, partB.mesh.texcoords)
            if hasUVs {
                XCTAssertNotEqual(partA.mesh.texcoords, candidate.render.texcoords,
                                  "an explicit face projection must override authored UVs")
            }
        }
    }
}

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)

// MARK: - Presentation pixels / tangents

@MainActor
final class CADPresentationSamplingTests: XCTestCase {
    private func image(rows: [[UInt8]], width: Int) throws -> CGImage {
        var bytes: [UInt8] = []
        for row in rows { bytes.append(contentsOf: row) }
        let provider = try XCTUnwrap(
            CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: rows.count, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: width, height: height))
        }
        return bytes
    }

    func testBottomLeftRowsAreFlippedPerImageNotPerSharedUVSet() throws {
        // Row 0 is red, row 1 is blue. A bottom-left authored map must become
        // blue/red after normalization; a top-left map stays red/blue.
        let source = try image(rows: [[255, 0, 0, 255], [0, 0, 255, 255]],
                               width: 1)
        XCTAssertEqual(pixels(source), [255, 0, 0, 255, 0, 0, 255, 255])
        let flipped = try XCTUnwrap(
            CADPresentationResourceCache.verticallyFlipped(source))
        XCTAssertEqual(pixels(flipped), [0, 0, 255, 255, 255, 0, 0, 255])
    }

    func testTangentBasisUsesKnownUVHandedness() {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
                         SIMD3<Float>(0, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3)
        let indices: [UInt32] = [0, 1, 2]

        let uvs = [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
        let tangent = CADPresentationResourceCache.tangents(
            positions: positions, normals: normals, uvs: uvs, indices: indices)
        XCTAssertEqual(tangent[0].x, 1, accuracy: 1e-6)
        XCTAssertEqual(tangent[0].y, 0, accuracy: 1e-6)

        // A mirrored U axis reverses the known tangent sign; row-origin
        // metadata does not change the surface tangent basis.
        let mirrored = [SIMD2<Float>(1, 0), SIMD2(0, 0), SIMD2(1, 1)]
        let mirroredTangent = CADPresentationResourceCache.tangents(
            positions: positions, normals: normals, uvs: mirrored,
            indices: indices)
        XCTAssertEqual(mirroredTangent[0].x, -1, accuracy: 1e-6)
    }
}

#endif

// MARK: - Library copy semantics

@MainActor
final class CADMaterialCopySemanticsTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADMaterialCopy-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)")
        return (try? JSONSerialization.jsonObject(with: outcome.payload))
            as? [String: Any] ?? [:]
    }

    private func makeBox(_ document: FloeCADDocument) throws -> (bodyID: String, face: Int) {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"Box"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        let extrude = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,10],
         "distance":10}}
        """)
        let bodyID = try XCTUnwrap(
            (extrude["producedBodyIDs"] as? [String])?.first
                ?? (extrude["changedBodyIDs"] as? [String])?.first)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep))
            .first(where: { $0.signature != nil })).index
        return (bodyID, face)
    }

    private func applyFaceMaterial(_ service: CADMaterialService,
                                   document: FloeCADDocument,
                                   bodyID: String, face: Int,
                                   materialID: String) -> [String: Any] {
        let body = document.session.document.bodies.first {
            $0.id.raw.uuidString == bodyID
        }!
        let token = CADGeometryQueryGeneration(
            scope: "faces", bodyID: body.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: body.meshRevision).token
        return service.handle(action: "applyFaces", args: [
            "material_id": materialID,
            "bodyID": bodyID,
            "faces": [face],
            "query_token": token,
        ])
    }

    func testLibraryEditsNeverRepaintAnAppliedCopy() async throws {
        let url = workDir.appendingPathComponent("copy.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Copy")
        let (bodyID, _) = try makeBox(document)
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: [
            "name": "Copy Paint",
            "color": [1.0, 0.0, 0.0, 1.0],
            "textures": [["slot": "baseColor",
                          "base64": MaterialUVFixtures.red1x1.base64EncodedString()]],
            "uv_mapping": ["source": "planarProjection", "axis": "z",
                           "scale_mm": [10.0, 10.0]],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let materialID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID])["ok"] as? Bool, true)

        let listed = service.handle(action: "list", args: [:])
        XCTAssertEqual(listed["link_semantics"] as? String, "independent_copy")
        XCTAssertEqual(listed["link_semantics_note"] as? String,
                       CADMaterialService.linkSemanticsNote)

        // Every library-only edit must leave the applied snapshot alone.
        XCTAssertEqual(service.handle(action: "update", args: [
            "material_id": materialID,
            "color": [0.0, 0.0, 1.0, 1.0],
        ])["ok"] as? Bool, true)
        XCTAssertEqual(service.handle(action: "mapping", args: [
            "material_id": materialID,
            "mapping": ["source": "planarProjection", "axis": "y",
                        "scale_mm": [99.0, 99.0]],
        ])["ok"] as? Bool, true)
        XCTAssertEqual(service.handle(action: "textures", args: [
            "material_id": materialID, "slot": "baseColor",
            "base64": MaterialUVFixtures.blue1x1.base64EncodedString(),
        ])["ok"] as? Bool, true)

        let applied = try XCTUnwrap(document.session.document.bodies.first?.material)
        XCTAssertEqual(applied.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(applied.uvMapping?.axis, .z)
        XCTAssertEqual(applied.uvMapping?.scaleMM, SIMD2(10, 10))
        XCTAssertEqual(applied.baseColorTexture, MaterialUVFixtures.red1x1)

        XCTAssertEqual(service.handle(action: "remove", args: [
            "material_id": materialID])["ok"] as? Bool, true)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let body = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertEqual(body.material?.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(body.material?.baseColorTexture, MaterialUVFixtures.red1x1)
        XCTAssertTrue(CADMaterialLibraryCodec.decode(
            reopened.session.document.materialLibraryData).entries.isEmpty)
        reopened.close()
    }

    func testExplicitBatchReapplyIsOneUndoAndSurvivesReopen() async throws {
        let url = workDir.appendingPathComponent("batch.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Batch")
        let (bodyID, face) = try makeBox(document)
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: [
            "name": "Batch Paint", "color": [1.0, 0.0, 0.0, 1.0],
        ])
        let materialID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID])["ok"] as? Bool, true)
        let faceReply = applyFaceMaterial(service, document: document,
                                          bodyID: bodyID, face: face,
                                          materialID: materialID)
        XCTAssertEqual(faceReply["ok"] as? Bool, true, "\(faceReply)")
        XCTAssertEqual(document.session.document.bodies.first?.materialFaceBindings.count, 1)

        let update = service.handle(action: "update", args: [
            "material_id": materialID,
            "color": [0.0, 0.0, 1.0, 1.0],
            "apply_to_applied": true,
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        var body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(body.material?.baseColor, SIMD4(0, 0, 1, 1))
        XCTAssertEqual(body.materialFaceBindings.first?.material.baseColor,
                       SIMD4(0, 0, 1, 1))

        // The library row and both applied snapshots are one undo step.
        document.session.undo()
        body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(body.material?.baseColor, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(body.materialFaceBindings.first?.material.baseColor,
                       SIMD4(1, 0, 0, 1))
        XCTAssertEqual(CADMaterialLibraryCodec.decode(
            document.session.document.materialLibraryData)
            .entry(MaterialID(raw: try XCTUnwrap(UUID(uuidString: materialID))))?
            .baseColor, SIMD4(1, 0, 0, 1))
        document.session.redo()
        body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(body.material?.baseColor, SIMD4(0, 0, 1, 1))
        XCTAssertEqual(body.materialFaceBindings.first?.material.baseColor,
                       SIMD4(0, 0, 1, 1))

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedBody = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertEqual(reopenedBody.material?.baseColor, SIMD4(0, 0, 1, 1))
        XCTAssertEqual(reopenedBody.materialFaceBindings.first?.material.baseColor,
                       SIMD4(0, 0, 1, 1))
        reopened.close()
    }
}
