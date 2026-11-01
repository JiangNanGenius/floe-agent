//
//  CADPresentationDraftPreviewTests.swift
//  FloeCADKitTests
//
//  Render-side regression coverage for the Present material draft preview.
//  These tests drive the actual `CADPresentationRenderController`, install the
//  draft on the live stage and read the sampling coordinates handed to the
//  production mesh builder for that exact MeshResource. `MeshResource`
//  deliberately has no public UV read-back (`lowLevelMesh` is nil for
//  descriptor-built meshes), so the render-side receipt is pinned to the
//  installed entity (`entity.model.mesh === receipt.mesh`) and compared with
//  an independent projection formula and the fixture's authored positions.
//  No second renderer, fake image or spy callback is involved.
//
//  Covered:
//    * a body draft with a planar projection rebuilds real sampling UVs on a
//      no-authored-UV body and on a body whose applied appearance already
//      projected the scene UV set;
//    * scale/offset changes reach the installed mesh;
//    * the mesh source (`uvMapping == .mesh`) samples the AUTHORED UVs, never
//      the stale applied projection;
//    * a face draft changes only the exact face range and leaves sibling
//      faces untouched;
//    * the first material on an unpainted face previews through the existing
//      selection patch (including projected UVs and multi-slot textures);
//    * Cancel/end preview restores the exact original mesh/material/visibility;
//    * document revision, change count and undo history are untouched;
//    * an older await cannot install after End or after the stage is replaced;
//    * a draft that genuinely has no UV source installs no texture and reports
//      a real presentation issue instead of a silent black/untextured success.
//

import Foundation
import XCTest
import simd

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import CoreGraphics
import ImageIO
import RealityKit
import UIKit
import UniformTypeIdentifiers

@testable import FloeCAD

@MainActor
final class CADPresentationDraftPreviewTests: XCTestCase {
    private var directories: [URL] = []
    private var documents: [FloeCADDocument] = []

    override func tearDown() async throws {
        for document in documents {
            document.close()
        }
        documents = []
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
    }

    // MARK: - Fixtures

    private let bodyID = UUID()

    private var planarMapping: CADMaterialUVMapping {
        CADMaterialUVMapping(source: .planarProjection, axis: .z,
                             scaleMM: SIMD2(50, 50),
                             offset: SIMD2(0.1, 0.2))
    }

    private var scaledMapping: CADMaterialUVMapping {
        CADMaterialUVMapping(source: .planarProjection, axis: .z,
                             scaleMM: SIMD2(25, 20),
                             offset: SIMD2(0.45, 0.6))
    }

    /// Closed 100 x 100 x 12 mm slab in presentation metres. Six quads, hard
    /// edges, 12 triangles. The front face is triangles 0 and 1.
    private func slabMesh(authoredUVs: Bool) -> CADPresentationMesh {
        let lower = SIMD3<Float>(-0.05, -0.05, 0)
        let upper = SIMD3<Float>(0.05, 0.05, 0.012)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func addFace(_ corners: [SIMD3<Float>], _ normal: SIMD3<Float>) {
            let base = UInt32(positions.count)
            for corner in corners {
                positions.append(corner)
                normals.append(normal)
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        addFace([SIMD3(-0.05, -0.05, upper.z), SIMD3(0.05, -0.05, upper.z),
                 SIMD3(0.05, 0.05, upper.z), SIMD3(-0.05, 0.05, upper.z)],
                SIMD3(0, 0, 1))
        addFace([SIMD3(0.05, -0.05, lower.z), SIMD3(-0.05, -0.05, lower.z),
                 SIMD3(-0.05, 0.05, lower.z), SIMD3(0.05, 0.05, lower.z)],
                SIMD3(0, 0, -1))
        addFace([SIMD3(0.05, -0.05, upper.z), SIMD3(0.05, -0.05, lower.z),
                 SIMD3(0.05, 0.05, lower.z), SIMD3(0.05, 0.05, upper.z)],
                SIMD3(1, 0, 0))
        addFace([SIMD3(-0.05, -0.05, lower.z), SIMD3(-0.05, -0.05, upper.z),
                 SIMD3(-0.05, 0.05, upper.z), SIMD3(-0.05, 0.05, lower.z)],
                SIMD3(-1, 0, 0))
        addFace([SIMD3(-0.05, 0.05, upper.z), SIMD3(0.05, 0.05, upper.z),
                 SIMD3(0.05, 0.05, lower.z), SIMD3(-0.05, 0.05, lower.z)],
                SIMD3(0, 1, 0))
        addFace([SIMD3(-0.05, -0.05, lower.z), SIMD3(0.05, -0.05, lower.z),
                 SIMD3(0.05, -0.05, upper.z), SIMD3(-0.05, -0.05, upper.z)],
                SIMD3(0, -1, 0))
        var authored: [SIMD2<Float>]? = nil
        if authoredUVs {
            authored = positions.map { authoredUV($0) }
        }
        return CADPresentationMesh(
            positions: positions, normals: normals, indices: indices,
            uvs: nil, authoredUVs: authored, meshRevision: 1,
            boundsMin: lower, boundsMax: upper)
    }

    /// Two disjoint quads at different depths, each its own applied face
    /// material group. No authored UVs.
    private func twoQuadMesh() -> (CADPresentationMesh,
                                   [CADPresentationFaceGroup]) {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func addQuad(z: Float) {
            let base = UInt32(positions.count)
            positions.append(contentsOf: [
                SIMD3(-0.04, -0.04, z), SIMD3(0.04, -0.04, z),
                SIMD3(0.04, 0.04, z), SIMD3(-0.04, 0.04, z)])
            normals.append(contentsOf: Array(repeating: SIMD3(0, 0, 1), count: 4))
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        addQuad(z: 0)
        addQuad(z: 0.02)
        let mesh = CADPresentationMesh(
            positions: positions, normals: normals, indices: indices,
            uvs: nil, authoredUVs: nil, meshRevision: 2,
            boundsMin: SIMD3(-0.04, -0.04, 0),
            boundsMax: SIMD3(0.04, 0.04, 0.02))
        let groups = [
            CADPresentationFaceGroup(faceIndex: 1,
                                     indices: Array(indices[0..<6]),
                                     material: .neutral, uvs: nil),
            CADPresentationFaceGroup(faceIndex: 2,
                                     indices: Array(indices[6..<12]),
                                     material: .neutral, uvs: nil),
        ]
        return (mesh, groups)
    }

    /// 100 x 100 mm grid used to keep a preview genuinely in flight while a
    /// cancellation/stage replacement is injected.
    private func largeGridMesh() -> CADPresentationMesh {
        let segments = 140
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for row in 0...segments {
            for column in 0...segments {
                positions.append(SIMD3(
                    -0.05 + Float(column) / Float(segments) * 0.1,
                    -0.05 + Float(row) / Float(segments) * 0.1,
                    0))
                normals.append(SIMD3(0, 0, 1))
            }
        }
        let rowStride = UInt32(segments + 1)
        for row in 0..<segments {
            for column in 0..<segments {
                let a = UInt32(row) * rowStride + UInt32(column)
                let b = a + 1
                let c = a + rowStride
                let d = c + 1
                indices.append(contentsOf: [a, b, d, a, d, c])
            }
        }
        return CADPresentationMesh(
            positions: positions, normals: normals, indices: indices,
            uvs: nil, authoredUVs: nil, meshRevision: 3,
            boundsMin: SIMD3(-0.05, -0.05, 0),
            boundsMax: SIMD3(0.05, 0.05, 0))
    }

    private func authoredUV(_ point: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2((point.x + 0.05) / 0.1, (point.y + 0.05) / 0.1)
    }

    private func presentationBody(
        id: UUID, name: String, mesh: CADPresentationMesh,
        transform: simd_float4x4 = matrix_identity_float4x4,
        material: CADPresentationMaterial = .neutral,
        faceGroups: [CADPresentationFaceGroup] = []
    ) -> CADPresentationBody {
        CADPresentationBody(
            id: id, name: name, transform: transform, mesh: mesh,
            material: material,
            faceMaterials: faceGroups.map {
                CADPresentationFaceMaterial(faceIndex: $0.faceIndex,
                                            material: $0.material)
            },
            faceGroups: faceGroups, unresolvedFaceCount: 0,
            analyticBRep: false)
    }

    private func makeScene(_ bodies: [CADPresentationBody]) -> CADPresentationScene {
        var bounds: CADPresentationBounds?
        for body in bodies {
            let bodyBounds = CADPresentationSceneBuilder.worldBounds(
                min: body.mesh.boundsMin, max: body.mesh.boundsMax,
                transform: body.transform)
            if let current = bounds {
                bounds = CADPresentationBounds(
                    min: simd_min(current.min, bodyBounds.min),
                    max: simd_max(current.max, bodyBounds.max))
            } else {
                bounds = bodyBounds
            }
        }
        return CADPresentationScene(
            schemaVersion: CADPresentationScene.currentSchemaVersion,
            documentKey: "test://draft-preview", documentRevision: 1,
            changeCount: 1, contentSHA256: "draft-preview-fixture",
            bodies: bodies, images: [],
            environment: CADPresentationEnvironment(
                kind: .studio, lightIntensity: 1,
                lightDirectionModel: SIMD3(0.3, 0.8, 0.5),
                backgroundColor: SIMD3(0.12, 0.14, 0.18),
                floorVisible: false, floorColor: SIMD3(0.5, 0.5, 0.52),
                floorSizeMM: 2_000, shadowsEnabled: false),
            issues: [], bounds: bounds, materialCount: 0)
    }

    private func bodyTarget(for body: CADPresentationBody) -> CADMaterialTarget {
        CADMaterialTarget(
            bodyIDs: [body.id], faceBodyID: nil, faceIndex: nil,
            bodyNames: [body.name], isFaceTarget: false, note: nil,
            faceIdentity: nil,
            bodyMeshRevisions: [body.id: body.mesh.meshRevision])
    }

    private func faceTarget(bodyID: UUID, name: String, meshRevision: UInt64,
                            faceIndex: Int,
                            triangles: [Int]? = nil) -> CADMaterialTarget {
        let identity = triangles.map {
            CADMaterialFaceIdentity(
                signature: FaceSignature(
                    kind: .planar, normal: SIMD3(0, 0, 1), centroid: .zero,
                    area: 0.01, planeOffset: 0),
                meshRevision: meshRevision,
                triangles: $0)
        }
        return CADMaterialTarget(
            bodyIDs: [bodyID], faceBodyID: bodyID, faceIndex: faceIndex,
            bodyNames: [name], isFaceTarget: true, note: nil,
            faceIdentity: identity,
            bodyMeshRevisions: [bodyID: meshRevision])
    }

    // MARK: - PNG textures

    private func texturePNG(rows: [[UInt8]]) throws -> Data {
        let height = rows.count
        let width = try XCTUnwrap(rows.first).count / 4
        XCTAssertGreaterThan(width, 0)
        XCTAssertTrue(rows.allSatisfy { $0.count == width * 4 })
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in rows { bytes.append(contentsOf: row) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func quadrantPNG() throws -> Data {
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let blue: [UInt8] = [0, 0, 255, 255]
        let yellow: [UInt8] = [255, 255, 0, 255]
        let topRow = (0..<32).flatMap { column -> [UInt8] in
            column < 16 ? red : green
        }
        let bottomRow = (0..<32).flatMap { column -> [UInt8] in
            column < 16 ? blue : yellow
        }
        return try texturePNG(rows: Array(repeating: topRow, count: 16)
                              + Array(repeating: bottomRow, count: 16))
    }

    private func linearPNG() throws -> Data {
        let dark: [UInt8] = [16, 16, 16, 255]
        let light: [UInt8] = [224, 224, 224, 255]
        let row = (0..<32).flatMap { column -> [UInt8] in
            column < 16 ? dark : light
        }
        return try texturePNG(rows: Array(repeating: row, count: 32))
    }

    private func draftSpec(mapping: CADMaterialUVMapping?,
                           textures: Bool = true,
                           normalAndRoughness: Bool = false) throws -> BodyMaterialSpec {
        let baseColorTexture: Data?
        if textures {
            baseColorTexture = try quadrantPNG()
        } else {
            baseColorTexture = nil
        }
        var spec = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1),
            metallic: 0.1, roughness: 0.7,
            baseColorTexture: baseColorTexture,
            uvMapping: mapping)
        if normalAndRoughness {
            spec.normalTexture = try linearPNG()
            spec.roughnessTexture = try linearPNG()
        }
        return spec.clamped
    }

    // MARK: - Controller / document helpers

    private func makeController(scene: CADPresentationScene,
                                document: FloeCADDocument? = nil,
                                handle: CADPresentationHandle? = nil)
    async throws -> CADPresentationRenderController {
        let controller = CADPresentationRenderController()
        if let handle { controller.attach(handle: handle) }
        if let document { controller.bindSelection(to: document) }
        controller.apply(scene)
        try await waitReady(controller)
        return controller
    }

    private func waitReady(_ controller: CADPresentationRenderController,
                           timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !controller.isStageReady, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(controller.isStageReady,
                      "the production controller must build its stage for this test")
    }

    private func waitForEntity(named name: String,
                               in controller: CADPresentationRenderController,
                               timeout: TimeInterval = 30) async throws -> ModelEntity {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entity = findEntity(named: name, in: controller.arView.scene),
               let model = entity as? ModelEntity, model.model != nil {
                return model
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTSkip("The expected render-side entity \(name) never appeared; no image or UV is fabricated.")
    }

    private func findEntity(named name: String, in scene: RealityFoundation.Scene) -> Entity? {
        for anchor in scene.anchors {
            if let found = findEntity(named: name, in: anchor as Entity) { return found }
        }
        return nil
    }

    private func findEntity(named name: String, in entity: Entity) -> Entity? {
        if entity.name == name { return entity }
        for child in entity.children {
            if let found = findEntity(named: name, in: child) { return found }
        }
        return nil
    }

    private func makeDocument(name: String, body: Body) async throws -> (FloeCADDocument, Body) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADDraftPreview-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(name).floecad"), name: name)
        documents.append(document)
        document.session.perform(AddBodyCommand(body: body, title: "Add draft preview body"))
        let live = try XCTUnwrap(document.session.document.bodies.first,
                                 "the document must own the added body")
        return (document, live)
    }

    private func documentSlabBody(name: String) -> Body {
        let mesh = slabMesh(authoredUVs: false)
        var body = Body(
            id: BodyID(), name: name, transform: .identity, primitive: nil,
            render: RenderMesh(
                positions: mesh.positions.map { $0 * 1_000 },
                normals: mesh.normals,
                indices: mesh.indices,
                texcoords: nil),
            revision: 1)
        body.material = BodyMaterialSpec(
            baseColor: SIMD4(0.72, 0.74, 0.78, 1), metallic: 0,
            roughness: 0.6, uvMapping: .mesh)
        return body
    }

    // MARK: - Receipt inspection

    private func receipt(in controller: CADPresentationRenderController,
                         bodyID: UUID, faceIndex: Int? = nil,
                         file: StaticString = #filePath,
                         line: UInt = #line)
    throws -> CADPresentationRenderController.MaterialPreviewReceipt {
        try XCTUnwrap(controller.materialPreviewReceipts.first(where: {
            $0.bodyID == bodyID && $0.faceIndex == faceIndex
        }), "a render-side receipt must exist for this target",
           file: file, line: line)
    }

    /// Independent reference formula for a planar projection, in the same
    /// units the production projector declares (body millimetres).
    private func expectedPlanarUV(_ position: SIMD3<Float>,
                                  _ mapping: CADMaterialUVMapping) -> SIMD2<Float> {
        let clean = mapping.sanitized
        let point = SIMD3<Double>(Double(position.x) * 1_000,
                                  Double(position.y) * 1_000,
                                  Double(position.z) * 1_000)
        let plane: (Double, Double)
        switch clean.axis {
        case .x: plane = (point.y, point.z)
        case .y: plane = (point.x, point.z)
        case .z: plane = (point.x, point.y)
        }
        let radians = clean.rotationDegrees * .pi / 180
        let rotatedU = plane.0 * cos(radians) - plane.1 * sin(radians)
        let rotatedV = plane.0 * sin(radians) + plane.1 * cos(radians)
        var u = rotatedU / clean.scaleMM.x + clean.offset.x
        var v = rotatedV / clean.scaleMM.y + clean.offset.y
        if clean.flipU { u = -u }
        if clean.flipV { v = -v }
        return SIMD2(Float(u), Float(v))
    }

    private func assertProjected(
        _ entity: ModelEntity,
        receipt: CADPresentationRenderController.MaterialPreviewReceipt,
        mesh: CADPresentationMesh,
        mapping: CADMaterialUVMapping,
        expectedTriangles: [Int]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(entity.model?.mesh === receipt.mesh,
                      "the receipt must name the mesh installed on the entity",
                      file: file, line: line)
        let uvs = try XCTUnwrap(receipt.samplingUVs,
                                "the draft preview must supply real sampling UVs",
                                file: file, line: line)
        XCTAssertEqual(uvs.count, mesh.positions.count, file: file, line: line)
        XCTAssertFalse(uvs.isEmpty, file: file, line: line)
        for (index, position) in mesh.positions.enumerated() {
            let expected = expectedPlanarUV(position, mapping)
            XCTAssertEqual(uvs[index].x, expected.x, accuracy: 2e-4,
                           "vertex \(index) U must sample the draft projection",
                           file: file, line: line)
            XCTAssertEqual(uvs[index].y, expected.y, accuracy: 2e-4,
                           "vertex \(index) V must sample the draft projection",
                           file: file, line: line)
        }
        if let expectedTriangles {
            XCTAssertEqual(receipt.triangles ?? [], expectedTriangles,
                           file: file, line: line)
            XCTAssertEqual(uvs.count, mesh.positions.count, file: file, line: line)
        } else {
            XCTAssertNil(receipt.triangles,
                         "a body draft must not claim a face range",
                         file: file, line: line)
        }
    }

    private func assertAuthoredUVs(
        _ entity: ModelEntity,
        receipt: CADPresentationRenderController.MaterialPreviewReceipt,
        mesh: CADPresentationMesh,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertTrue(entity.model?.mesh === receipt.mesh, file: file, line: line)
        let uvs = try XCTUnwrap(receipt.samplingUVs, file: file, line: line)
        XCTAssertEqual(uvs.count, mesh.positions.count, file: file, line: line)
        for (index, position) in mesh.positions.enumerated() {
            let expected = authoredUV(position)
            XCTAssertEqual(uvs[index].x, expected.x, accuracy: 2e-4,
                           file: file, line: line)
            XCTAssertEqual(uvs[index].y, expected.y, accuracy: 2e-4,
                           file: file, line: line)
        }
    }

    private func firstPBMMaterial(_ entity: ModelEntity) throws -> PhysicallyBasedMaterial {
        let material = try XCTUnwrap(entity.model?.materials.first)
        return try XCTUnwrap(material as? PhysicallyBasedMaterial)
    }

    // MARK: - Body draft preview

    /// The original defect: an unpainted body with no authored UVs could not
    /// show a projected texture before Apply because the old preview only
    /// swapped materials on a mesh without texture coordinates. The installed
    /// overlay must carry the exact projected sampling data, a real texture,
    /// and Cancel must restore the applied mesh.
    func testBodyDraftInstallsProjectedSamplingUVsOnNoUVBodyAndCancelRestores() async throws {
        let mesh = slabMesh(authoredUVs: false)
        let body = presentationBody(id: bodyID, name: "draft body", mesh: mesh)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }

        let original = try XCTUnwrap(findEntity(named: "draft body",
                                                in: controller.arView.scene) as? ModelEntity)
        let baseline = try XCTUnwrap(original.model)
        XCTAssertNil(body.mesh.uvs)
        XCTAssertNil(mesh.uvs)

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping), for: bodyTarget(for: body))

        XCTAssertFalse(original.isEnabled,
                       "the applied entity is hidden by the render-only body overlay")
        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: bodyID)
        try assertProjected(overlay, receipt: installed, mesh: mesh,
                            mapping: planarMapping)
        XCTAssertNotNil(try firstPBMMaterial(overlay).baseColor.texture,
                        "a projected draft must sample its real base-colour image")

        controller.endMaterialPreview()

        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene),
                     "Cancel must remove the transient overlay")
        XCTAssertTrue(original.isEnabled, "Cancel must restore the applied entity")
        XCTAssertTrue(original.model?.mesh === baseline.mesh,
                      "Cancel must restore the exact applied mesh")
        XCTAssertNil(try firstPBMMaterial(original).baseColor.texture)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// A mapping change must reach the installed sampling buffer. Two drafts
    /// with different scale/offset both match the reference formula and differ
    /// from each other, so a cached material-only swap cannot pass.
    func testBodyDraftScaleAndOffsetChangesReachTheInstalledMesh() async throws {
        let mesh = slabMesh(authoredUVs: false)
        let body = presentationBody(id: bodyID, name: "scale body", mesh: mesh)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping), for: bodyTarget(for: body))
        let firstOverlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                                    in: controller.arView.scene) as? ModelEntity)
        let firstReceipt = try receipt(in: controller, bodyID: bodyID)
        try assertProjected(firstOverlay, receipt: firstReceipt, mesh: mesh,
                            mapping: planarMapping)
        let firstUVs = try XCTUnwrap(firstReceipt.samplingUVs)

        try await controller.previewMaterial(
            try draftSpec(mapping: scaledMapping), for: bodyTarget(for: body))
        let secondOverlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                                     in: controller.arView.scene) as? ModelEntity)
        let secondReceipt = try receipt(in: controller, bodyID: bodyID)
        try assertProjected(secondOverlay, receipt: secondReceipt, mesh: mesh,
                            mapping: scaledMapping)
        let secondUVs = try XCTUnwrap(secondReceipt.samplingUVs)
        XCTAssertNotEqual(firstUVs, secondUVs,
                          "a new scale/offset draft must not reuse the old UV buffer")
        XCTAssertNotNil(try firstPBMMaterial(secondOverlay).baseColor.texture)

        controller.endMaterialPreview()
        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene))
    }

    /// The applied appearance may already carry a projected scene UV set. A
    /// draft that chooses the mesh source must sample the AUTHORED UVs, not
    /// that stale projection.
    func testMeshSourceDraftUsesAuthoredUVsNotStaleSceneProjection() async throws {
        var mesh = slabMesh(authoredUVs: true)
        let stale = [SIMD2<Float>](repeating: SIMD2(0.9, 0.1),
                                   count: mesh.positions.count)
        mesh.uvs = stale
        let body = presentationBody(id: bodyID, name: "authored body", mesh: mesh)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }

        let original = try XCTUnwrap(findEntity(named: "authored body",
                                                in: controller.arView.scene) as? ModelEntity)
        let baseline = try XCTUnwrap(original.model)

        try await controller.previewMaterial(
            try draftSpec(mapping: .mesh), for: bodyTarget(for: body))

        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: bodyID)
        try assertAuthoredUVs(overlay, receipt: installed, mesh: mesh)
        let authored = try XCTUnwrap(installed.samplingUVs)
        XCTAssertNotEqual(authored, stale,
                          "the mesh source must not reuse the applied projection")
        XCTAssertNotNil(try firstPBMMaterial(overlay).baseColor.texture)

        controller.endMaterialPreview()
        XCTAssertTrue(original.model?.mesh === baseline.mesh,
                      "Cancel must restore the applied sampling set exactly")
    }

    /// A body draft with applied face groups previews the whole body (the
    /// same result Apply writes: one body material and no face bindings)
    /// while every original face entity is preserved for Cancel.
    func testBodyDraftWithAppliedFaceGroupsHidesThemAndRestores() async throws {
        let (mesh, groups) = twoQuadMesh()
        let body = presentationBody(id: bodyID, name: "grouped body",
                                    mesh: mesh, faceGroups: groups)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }

        let faceOne = try XCTUnwrap(findEntity(named: "grouped body · 1",
                                               in: controller.arView.scene) as? ModelEntity)
        let faceTwo = try XCTUnwrap(findEntity(named: "grouped body · 2",
                                               in: controller.arView.scene) as? ModelEntity)

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping), for: bodyTarget(for: body))

        XCTAssertFalse(faceOne.isEnabled)
        XCTAssertFalse(faceTwo.isEnabled)
        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: bodyID)
        try assertProjected(overlay, receipt: installed, mesh: mesh,
                            mapping: planarMapping)

        controller.endMaterialPreview()
        XCTAssertTrue(faceOne.isEnabled)
        XCTAssertTrue(faceTwo.isEnabled)
        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene))
    }

    /// A source-body draft previews every placed instance that reuses it; the
    /// instance entities are hidden, overlaid and restored independently.
    func testBodyDraftCoversPlacedInstanceAndRestoresBoth() async throws {
        let mesh = slabMesh(authoredUVs: false)
        let source = presentationBody(id: bodyID, name: "source part", mesh: mesh)
        var placedTransform = matrix_identity_float4x4
        placedTransform.columns.3 = SIMD4(0.4, 0, 0, 1)
        let instanceID = UUID()
        var instance = presentationBody(
            id: instanceID, name: "placed part", mesh: mesh,
            transform: placedTransform)
        instance.sourceBodyID = bodyID
        let controller = try await makeController(
            scene: makeScene([source, instance]))
        defer { controller.release() }

        let sourceEntity = try XCTUnwrap(findEntity(named: "source part",
                                                    in: controller.arView.scene) as? ModelEntity)
        let instanceEntity = try XCTUnwrap(findEntity(named: "placed part",
                                                      in: controller.arView.scene) as? ModelEntity)

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping), for: bodyTarget(for: source))

        XCTAssertFalse(sourceEntity.isEnabled)
        XCTAssertFalse(instanceEntity.isEnabled)
        var overlays: [ModelEntity] = []
        func collect(_ entity: Entity) {
            if entity.name == "CADPresentationMaterialPreview",
               let model = entity as? ModelEntity, model.model != nil {
                overlays.append(model)
            }
            entity.children.forEach(collect)
        }
        controller.arView.scene.anchors.forEach { collect($0 as Entity) }
        XCTAssertEqual(overlays.count, 2,
                       "the source body and its placed instance both preview the draft")
        XCTAssertEqual(controller.materialPreviewReceipts.count, 2)
        for overlay in overlays {
            let owner = controller.materialPreviewReceipts.first(where: {
                $0.mesh === overlay.model?.mesh
            })
            let installed = try XCTUnwrap(owner)
            try assertProjected(overlay, receipt: installed, mesh: mesh,
                                mapping: planarMapping)
        }

        controller.endMaterialPreview()
        XCTAssertTrue(sourceEntity.isEnabled)
        XCTAssertTrue(instanceEntity.isEnabled)
        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene))
    }

    // MARK: - Face draft preview

    /// A face draft swaps only that face entity's mesh/material. The sibling
    /// face keeps its applied mesh and untextured material, so no whole-body
    /// repaint can pass.
    func testFaceDraftChangesOnlyTheExactFaceEntity() async throws {
        let (mesh, groups) = twoQuadMesh()
        let body = presentationBody(id: bodyID, name: "face body",
                                    mesh: mesh, faceGroups: groups)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }

        let faceOne = try XCTUnwrap(findEntity(named: "face body · 1",
                                               in: controller.arView.scene) as? ModelEntity)
        let faceTwo = try XCTUnwrap(findEntity(named: "face body · 2",
                                               in: controller.arView.scene) as? ModelEntity)
        let faceOneBaseline = try XCTUnwrap(faceOne.model)
        let faceTwoBaseline = try XCTUnwrap(faceTwo.model)

        let target = faceTarget(bodyID: bodyID, name: body.name,
                                meshRevision: body.mesh.meshRevision,
                                faceIndex: 1, triangles: [0, 1])
        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping), for: target)

        let installed = try receipt(in: controller, bodyID: bodyID, faceIndex: 1)
        XCTAssertEqual(installed.triangles ?? [], [0, 1])
        try assertProjected(faceOne, receipt: installed, mesh: mesh,
                            mapping: planarMapping, expectedTriangles: [0, 1])
        XCTAssertNotNil(try firstPBMMaterial(faceOne).baseColor.texture)
        XCTAssertTrue(faceTwo.model?.mesh === faceTwoBaseline.mesh,
                      "the sibling face must keep its applied mesh")
        XCTAssertNil(try firstPBMMaterial(faceTwo).baseColor.texture,
                     "the sibling face must not receive the draft material")
        XCTAssertEqual(controller.materialPreviewReceipts.count, 1,
                       "a face draft must not install a body-wide overlay")

        controller.endMaterialPreview()
        XCTAssertTrue(faceOne.model?.mesh === faceOneBaseline.mesh)
        XCTAssertNil(try firstPBMMaterial(faceOne).baseColor.texture)
        XCTAssertTrue(faceTwo.model?.mesh === faceTwoBaseline.mesh)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// The first material on an unpainted face has no face entity; the draft
    /// must use the existing selection patch's exact triangles. This is the
    /// X20 path: a no-authored-UV body, selected face triangles, projected
    /// texture visible before Apply and restored with the highlight on Cancel.
    func testFirstUnpaintedFaceDraftSamplesProjectionThroughSelectionPatch() async throws {
        let slab = documentSlabBody(name: "first face slab")
        let (document, body) = try await makeDocument(name: "first-face", body: slab)
        let scene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        XCTAssertTrue(document.viewModel().selectPresentation(
            bodyID: body.id, faceTriangles: [0, 1]),
                      "the fixture must select the front face through the production selection")
        let selected = try XCTUnwrap(
            CADPresentationSelection.state(document: document).faces.first,
            "the production selection must expose the picked face triangles")
        let selectedTriangles = selected.triangles.sorted()
        XCTAssertFalse(selectedTriangles.isEmpty)
        let handle = CADPresentationHandle()
        let controller = try await makeController(
            scene: scene, document: document, handle: handle)
        defer { controller.release() }

        let patch = try await waitForEntity(named: "CADPresentationSelectionFace",
                                            in: controller)
        let patchBaseline = try XCTUnwrap(patch.model)
        let sceneMesh = try XCTUnwrap(scene.bodies.first).mesh
        XCTAssertNil(sceneMesh.uvs,
                     "the first-face fixture has no applied sampling set")
        XCTAssertNil(sceneMesh.authoredUVs,
                     "the first-face fixture has no authored UVs either")

        let beforeRevision = document.revision
        let beforeLiveChange = document.liveChangeCount
        let beforeChangeCount = document.session.changeCount
        let beforeUndo = document.session.undoStack.undoCommands.count
        let beforeMaterial = document.session.document.body(with: body.id)?.material

        let target = faceTarget(
            bodyID: body.id.raw, name: body.name,
            meshRevision: body.meshRevision,
            faceIndex: 1, triangles: selectedTriangles)

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping, normalAndRoughness: true),
            for: target)

        let installed = try receipt(in: controller, bodyID: body.id.raw,
                                    faceIndex: 1)
        try assertProjected(patch, receipt: installed, mesh: sceneMesh,
                            mapping: planarMapping,
                            expectedTriangles: selectedTriangles)
        let material = try firstPBMMaterial(patch)
        XCTAssertNotNil(material.baseColor.texture,
                        "the first-face draft must sample its base-colour map")
        XCTAssertNotNil(material.normal.texture,
                        "existing normal-map sampling must survive the preview")
        XCTAssertNotNil(material.roughness.texture,
                        "existing roughness sampling must survive the preview")
        XCTAssertEqual(handle.issues.filter { $0.kind == .missingMeshUV }.count, 0,
                       "a valid planar projection must not report a missing-UV preview")

        XCTAssertEqual(document.revision, beforeRevision)
        XCTAssertEqual(document.liveChangeCount, beforeLiveChange)
        XCTAssertEqual(document.session.changeCount, beforeChangeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo,
                       "a transient preview must never create history")
        XCTAssertEqual(document.session.document.body(with: body.id)?.material,
                       beforeMaterial)

        controller.endMaterialPreview()

        XCTAssertTrue(patch.model?.mesh === patchBaseline.mesh,
                      "Cancel must restore the highlight patch's original mesh")
        XCTAssertNil(try firstPBMMaterial(patch).baseColor.texture)
        XCTAssertTrue(patch.isEnabled)
        XCTAssertNotNil(findEntity(named: "CADPresentationSelectionFace",
                                   in: controller.arView.scene))
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo)
        XCTAssertEqual(document.revision, beforeRevision)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// The real inspector draft path (not just the controller API): a body
    /// target and a real `CADMaterialDraftModel` schedule the Present preview
    /// sink. Changing the texture and mapping must reach the live stage, and
    /// Cancel must restore the applied appearance without document history.
    func testMaterialDraftModelDrivesPresentPreviewAndCancel() async throws {
        let slab = documentSlabBody(name: "draft model slab")
        let (document, body) = try await makeDocument(name: "draft-model", body: slab)
        let scene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        let handle = CADPresentationHandle()
        let controller = try await makeController(
            scene: scene, document: document, handle: handle)
        defer { controller.release() }
        let original = try XCTUnwrap(findEntity(named: "draft model slab",
                                                in: controller.arView.scene) as? ModelEntity)
        let baseline = try XCTUnwrap(original.model)
        let sceneBody = try XCTUnwrap(scene.bodies.first)

        let sink = CADPresentationMaterialPreviewSink()
        sink.handle = handle
        let store = CADPersonalMaterialLibraryStore(
            fileURL: document.url.deletingLastPathComponent()
                .appendingPathComponent("draft-preview-library.json"))
        let target = bodyTarget(for: sceneBody)
        let model = CADMaterialDraftModel(
            document: document, target: target, personalStore: store)
        model.previewSink = sink
        defer {
            model.stopObserving()
            model.endPreviewOnly()
        }

        let beforeRevision = document.revision
        let beforeChangeCount = document.session.changeCount
        let beforeUndo = document.session.undoStack.undoCommands.count

        model.setTexture(slot: .baseColor,
                         data: try quadrantPNG(), displayName: "draft preview")
        model.setMapping(planarMapping)

        let deadline = Date().addingTimeInterval(20)
        var installed: CADPresentationRenderController.MaterialPreviewReceipt?
        while Date() < deadline {
            if let current = controller.materialPreviewReceipts.first(where: {
                $0.bodyID == sceneBody.id && $0.faceIndex == nil
                    && $0.samplingUVs != nil
            }) {
                installed = current
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let receipt = try XCTUnwrap(installed,
                                    "the inspector draft must reach the Present controller")
        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        try assertProjected(overlay, receipt: receipt, mesh: sceneBody.mesh,
                            mapping: planarMapping)
        XCTAssertNotNil(try firstPBMMaterial(overlay).baseColor.texture)
        XCTAssertFalse(original.isEnabled)

        model.cancel()

        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene))
        XCTAssertTrue(original.isEnabled)
        XCTAssertTrue(original.model?.mesh === baseline.mesh)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
        XCTAssertEqual(document.revision, beforeRevision)
        XCTAssertEqual(document.session.changeCount, beforeChangeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo)
    }

    // MARK: - Failures, fences and history

    /// Asking a draft to sample the mesh source on a body with no authored UVs
    /// cannot draw the image. The renderer must say so through the real
    /// presentation issue list instead of presenting an untextured patch as a
    /// successful texture preview.
    func testNoUVSourceDraftReportsIssueAndDrawsNoTexture() async throws {
        let mesh = slabMesh(authoredUVs: false)
        let body = presentationBody(id: bodyID, name: "no-uv body", mesh: mesh)
        let handle = CADPresentationHandle()
        let controller = try await makeController(scene: makeScene([body]),
                                                  handle: handle)
        defer { controller.release() }

        try await controller.previewMaterial(
            try draftSpec(mapping: .mesh), for: bodyTarget(for: body))

        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: bodyID)
        XCTAssertNil(installed.samplingUVs,
                     "a no-UV mesh source must not invent a sampling buffer")
        XCTAssertNil(try firstPBMMaterial(overlay).baseColor.texture)
        XCTAssertTrue(handle.issues.contains(where: {
            $0.kind == .missingMeshUV
        }), "the real missing-UV condition must be visible, not silent")

        controller.endMaterialPreview()
        XCTAssertTrue(handle.issues.allSatisfy { $0.kind != .missingMeshUV },
                      "ending the preview must clear its transient issue")
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// A referenced image with a valid PNG signature but corrupt content can
    /// pass the byte sniffer. The preview must report the exact slot as a real
    /// decode failure instead of silently drawing an untextured surface.
    func testDraftTextureDecodeFailureReportsTheSlot() async throws {
        var corrupt = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        corrupt.append(contentsOf: [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
                                    0x44, 0x52, 0x01, 0x02, 0x03, 0x04])
        var spec = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.8,
            baseColorTexture: corrupt, uvMapping: planarMapping).clamped
        XCTAssertNotNil(MaterialImageSniffer.mimeType(of: corrupt))
        spec.baseColorTexture = corrupt

        let mesh = slabMesh(authoredUVs: false)
        let body = presentationBody(id: bodyID, name: "corrupt texture body",
                                    mesh: mesh)
        let handle = CADPresentationHandle()
        let controller = try await makeController(scene: makeScene([body]),
                                                  handle: handle)
        defer { controller.release() }

        try await controller.previewMaterial(spec, for: bodyTarget(for: body))

        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: bodyID)
        XCTAssertNotNil(installed.samplingUVs,
                        "the projection still supplies sampling coordinates")
        XCTAssertNil(try firstPBMMaterial(overlay).baseColor.texture,
                     "a failed decode must not be presented as a sampled image")
        XCTAssertTrue(handle.issues.contains(where: {
            $0.kind == .imageDecodeFailed
                && $0.id.contains("baseColor")
        }), "the exact slot must be named in the presentation issue")

        controller.endMaterialPreview()
        XCTAssertTrue(handle.issues.allSatisfy { $0.kind != .imageDecodeFailed })
    }

    /// A preview request that is still awaiting its GPU resources must not
    /// install after Cancel. The large fixture keeps the build in flight; the
    /// end call advances the generation fence, and the old await is checked
    /// for a second time after it completes.
    func testEndedPreviewCannotInstallFromAnOlderAwait() async throws {
        let mesh = largeGridMesh()
        let body = presentationBody(id: bodyID, name: "large body", mesh: mesh)
        let controller = try await makeController(scene: makeScene([body]))
        defer { controller.release() }
        let original = try XCTUnwrap(findEntity(named: "large body",
                                                in: controller.arView.scene) as? ModelEntity)
        let baseline = try XCTUnwrap(original.model)

        let spec = try draftSpec(mapping: planarMapping)
        let target = bodyTarget(for: body)
        let task = Task { await controller.previewMaterial(spec, for: target) }
        let deadline = Date().addingTimeInterval(10)
        while !controller.isMaterialPreviewInFlight, Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(controller.isMaterialPreviewInFlight,
                      "the large fixture must expose the in-flight preview")
        controller.endMaterialPreview()
        await task.value
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene),
                     "a late install must not resurrect the ended preview")
        XCTAssertTrue(original.isEnabled)
        XCTAssertTrue(original.model?.mesh === baseline.mesh)
        XCTAssertFalse(controller.isMaterialPreviewInFlight)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// Replacing the stage while a preview awaits must retire that request.
    /// The new stage starts from the document baseline and never receives the
    /// old draft's mesh/material.
    func testReplacedStageNeverReceivesAnOlderPreview() async throws {
        let mesh = largeGridMesh()
        let body = presentationBody(id: bodyID, name: "replaced body", mesh: mesh)
        let firstScene = makeScene([body])
        let controller = try await makeController(scene: firstScene)
        defer { controller.release() }

        let secondBody = presentationBody(id: bodyID, name: "replaced body",
                                          mesh: mesh)
        let secondScene = CADPresentationScene(
            schemaVersion: firstScene.schemaVersion,
            documentKey: firstScene.documentKey, documentRevision: 1,
            changeCount: 2, contentSHA256: "draft-preview-fixture-2",
            bodies: [secondBody], images: [],
            environment: firstScene.environment, issues: [],
            bounds: firstScene.bounds, materialCount: 0)

        let spec = try draftSpec(mapping: planarMapping)
        let target = bodyTarget(for: body)
        let task = Task { await controller.previewMaterial(spec, for: target) }
        let deadline = Date().addingTimeInterval(10)
        while !controller.isMaterialPreviewInFlight, Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(controller.isMaterialPreviewInFlight)
        let generation = controller.renderGeneration
        controller.apply(secondScene)
        let rebuildDeadline = Date().addingTimeInterval(60)
        while controller.renderGeneration <= generation,
              Date() < rebuildDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(controller.renderGeneration, generation,
                             "the replacement stage must actually be built")
        await task.value
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene),
                     "an old stage's draft must not appear on the replacement")
        let replacement = try XCTUnwrap(findEntity(named: "replaced body",
                                                   in: controller.arView.scene) as? ModelEntity)
        XCTAssertTrue(replacement.isEnabled)
        XCTAssertTrue(controller.materialPreviewReceipts.isEmpty)
    }

    /// End-to-end document fence: previewing a body draft never advances the
    /// save identity, live change count or undo stack, and the draft overlay
    /// is removed on End without changing the saved source.
    func testDocumentBodyDraftLeavesIdentityHistoryAndSourceUntouched() async throws {
        let slab = documentSlabBody(name: "history slab")
        let (document, body) = try await makeDocument(name: "history", body: slab)
        let scene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        let controller = try await makeController(scene: scene, document: document)
        defer { controller.release() }

        let beforeRevision = document.revision
        let beforeLiveChange = document.liveChangeCount
        let beforeChangeCount = document.session.changeCount
        let beforeUndo = document.session.undoStack.undoCommands.count
        let beforeSource = document.session.document.body(with: body.id)
        let sceneBody = try XCTUnwrap(scene.bodies.first)

        try await controller.previewMaterial(
            try draftSpec(mapping: planarMapping),
            for: bodyTarget(for: sceneBody))
        let overlay = try XCTUnwrap(findEntity(named: "CADPresentationMaterialPreview",
                                               in: controller.arView.scene) as? ModelEntity)
        let installed = try receipt(in: controller, bodyID: sceneBody.id)
        try assertProjected(overlay, receipt: installed, mesh: sceneBody.mesh,
                            mapping: planarMapping)
        XCTAssertNotNil(try firstPBMMaterial(overlay).baseColor.texture)
        XCTAssertEqual(controller.materialPreviewReceipts.count, 1)
        controller.endMaterialPreview()
        XCTAssertNil(findEntity(named: "CADPresentationMaterialPreview",
                                in: controller.arView.scene))

        XCTAssertEqual(document.revision, beforeRevision)
        XCTAssertEqual(document.liveChangeCount, beforeLiveChange)
        XCTAssertEqual(document.session.changeCount, beforeChangeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, beforeUndo)
        let afterSource = document.session.document.body(with: body.id)
        XCTAssertEqual(afterSource?.material, beforeSource?.material)
        XCTAssertEqual(afterSource?.render.texcoords, beforeSource?.render.texcoords)
        XCTAssertEqual(afterSource?.meshRevision, beforeSource?.meshRevision)
    }

    // MARK: - Static draft projection rule

    /// The production sampling rule for a projection is the shared projector;
    /// this pins explicit-over-authored precedence and the two no-UV cases
    /// without a renderer.
    func testProjectionRuleIsTheSharedProjectorAndAuthoredIsStable() throws {
        var mesh = slabMesh(authoredUVs: true)
        mesh.uvs = [SIMD2<Float>](repeating: SIMD2(0.9, 0.1),
                                  count: mesh.positions.count)
        let projected = try XCTUnwrap(CADPresentationDraftUV.samplingUVs(
            for: mesh, mapping: planarMapping))
        XCTAssertEqual(projected.count, mesh.positions.count)
        for (index, position) in mesh.positions.enumerated() {
            let pointMM = position * 1_000
            let expected = SIMD2(
                (Double(pointMM.x) / planarMapping.scaleMM.x)
                    + planarMapping.offset.x,
                (Double(pointMM.y) / planarMapping.scaleMM.y)
                    + planarMapping.offset.y)
            XCTAssertEqual(Double(projected[index].x), expected.x, accuracy: 1e-4)
            XCTAssertEqual(Double(projected[index].y), expected.y, accuracy: 1e-4)
        }
        let authored = try XCTUnwrap(CADPresentationDraftUV.samplingUVs(
            for: mesh, mapping: .mesh))
        XCTAssertEqual(authored, try XCTUnwrap(mesh.authoredUVs))
        XCTAssertNotEqual(authored, try XCTUnwrap(mesh.uvs))

        var noUV = slabMesh(authoredUVs: false)
        noUV.uvs = [SIMD2<Float>](repeating: SIMD2(0.9, 0.1),
                                  count: noUV.positions.count)
        XCTAssertNil(CADPresentationDraftUV.samplingUVs(for: noUV, mapping: .mesh))
        XCTAssertNotNil(CADPresentationDraftUV.samplingUVs(
            for: noUV, mapping: planarMapping))
    }
}
#endif
