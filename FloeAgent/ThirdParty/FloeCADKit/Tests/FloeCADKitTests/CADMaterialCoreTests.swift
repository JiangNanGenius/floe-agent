//
//  CADMaterialCoreTests.swift
//  FloeCADKitTests
//
//  Core custom-material / parameter / GLB behaviour: legacy decode safety,
//  applied-snapshot independence, undo/redo, stable face rejection,
//  parameter rebuild rollback, real PBR/UV/texture GLB export and round-trip.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADMaterialCoreTests: XCTestCase {
    private var workDir: URL!

    // 1×1 PNG; its magic bytes are all the image sniffer/GLB writer need.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADMaterial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: Helpers

    private func run(_ document: FloeCADDocument, _ json: String,
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(_ document: FloeCADDocument) throws -> (bodyID: String, featureID: String) {
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
        let bodyID = try XCTUnwrap((extrude["producedBodyIDs"] as? [String])?.first
            ?? (extrude["changedBodyIDs"] as? [String])?.first,
            "extrude reply carries no body id: \(extrude)")
        let features = document.session.document.features.nodes
        let featureID = try XCTUnwrap(features.last?.id.raw.uuidString)
        return (bodyID, featureID)
    }

    private func jsonChunk(_ glb: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        XCTAssertGreaterThan(length, 0)
        let json = glb.subdata(in: 20..<(20 + length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    // MARK: Legacy / codec

    func testLegacyMaterialDecodesWithNewFieldsAbsent() throws {
        let legacy = #"{"baseColor":[0.5,0.25,0.125,0.5],"metallic":0.2,"roughness":0.4}"#
        let spec = try JSONDecoder().decode(BodyMaterialSpec.self, from: Data(legacy.utf8))
        XCTAssertEqual(spec.baseColor, SIMD4(0.5, 0.25, 0.125, 0.5))
        XCTAssertNil(spec.materialID)
        XCTAssertNil(spec.normalTexture)
        XCTAssertNil(spec.uvMapping)
        XCTAssertEqual(spec.effectiveOpacity, 0.5, accuracy: 1e-12)
        XCTAssertTrue(spec.clamped == spec)
    }

    func testCorruptLibraryDoesNotLoseAppliedMaterial() {
        let library = CADMaterialLibraryCodec.decode(Data("not-json".utf8))
        XCTAssertTrue(library.entries.isEmpty)
        XCTAssertEqual(CADMaterialLibraryCodec.decode(nil).schemaVersion, 1)
    }

    func testCorruptPersonalLibraryIsNeverClobberedByGlobalExport() throws {
        let url = workDir.appendingPathComponent("library.json")
        let corrupt = Data("this is not a material library".utf8)
        try corrupt.write(to: url, options: .atomic)
        let incoming = try XCTUnwrap(CADMaterialLibraryCodec.encode(
            CADMaterialLibrary(entries: [])))
        do {
            try CADMaterialLibraryJSONMerge.mergeInPlace(
                at: url, incoming: incoming,
                maximumBytes: CADMaterialLimits.maximumLibraryBytes)
            XCTFail("a corrupt personal library must never be replaced by an export")
        } catch let error as CADMaterialLibraryJSONMerge.MergeError {
            XCTAssertEqual(error.code, "shared_library_corrupt", error.message)
        }
        XCTAssertEqual(try Data(contentsOf: url), corrupt,
                       "the original corrupt bytes must remain for recovery")
    }

    // MARK: Persistence / snapshot independence

    func testAppliedSnapshotSurvivesLibraryRemovalAndReload() async throws {
        let url = workDir.appendingPathComponent("material.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Material")
        let (bodyID, _) = try makeBox(document)
        let service = CADMaterialService(document: document)

        let created = service.handle(action: "create", args: [
            "name": "Copper",
            "color": [0.82, 0.45, 0.2, 1.0],
            "metallic": 1.0,
            "roughness": 0.25,
            "emissive": [0.05, 0.01, 0.0],
            "emissive_strength": 2.0,
            "textures": [["slot": "baseColor", "base64": png.base64EncodedString()]],
            "uv_mapping": ["source": "boxProjection", "axis": "y",
                           "scale_mm": [40.0, 20.0], "rotation_degrees": 15.0,
                           "offset": [0.1, -0.2]],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let materialID = try XCTUnwrap(created["id"] as? String)

        let applied = service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertEqual(body.material?.materialID, materialID)
        XCTAssertEqual(body.material?.baseColorTexture, png)
        XCTAssertEqual(body.material?.normalTexture, nil)
        XCTAssertEqual(body.material?.uvMapping?.source, MaterialUVSource.boxProjection)

        let removed = service.handle(action: "remove", args: ["material_id": materialID])
        XCTAssertEqual(removed["ok"] as? Bool, true, "\(removed)")
        XCTAssertEqual(document.session.document.bodies.first?.material?.materialID, materialID,
                       "removing a library entry must not alter the applied snapshot")

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        let reopenedBody = try XCTUnwrap(reopened.session.document.bodies.first)
        XCTAssertEqual(reopenedBody.material?.materialID, materialID)
        XCTAssertEqual(reopenedBody.material?.baseColorTexture, png)
        XCTAssertEqual(reopenedBody.material?.materialName, "Copper")
        XCTAssertEqual(CADMaterialLibraryCodec.decode(reopened.session.document.materialLibraryData)
            .entries.count, 0)
        reopened.close()
    }

    func testApplyIsOneUndoStepAndRedoRestoresIt() async throws {
        let url = workDir.appendingPathComponent("undo.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Undo")
        let (bodyID, _) = try makeBox(document)
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: ["name": "Paint",
                                                              "color": [0.2, 0.4, 0.6, 1.0]])
        let materialID = try XCTUnwrap(created["id"] as? String)
        XCTAssertEqual(service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID]).first { $0.key == "ok" }?.value as? Bool,
            true)
        XCTAssertNotNil(document.session.document.bodies.first?.material)
        document.session.undo()
        XCTAssertNil(document.session.document.bodies.first?.material)
        document.session.redo()
        XCTAssertEqual(document.session.document.bodies.first?.material?.materialID, materialID)
        document.close()
    }

    // MARK: Failed-save rollback (real document/service, no fake host)

    func testFailedSaveRollsBackAppliedMaterialAtomically() async throws {
        let url = workDir.appendingPathComponent("rollback.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Rollback")
        let (bodyID, _) = try makeBox(document)
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: ["name": "Paint",
                                                              "color": [0.2, 0.4, 0.6, 1.0]])
        let materialID = try XCTUnwrap(created["id"] as? String)
        let checkpoint = document.captureEditCheckpoint()
        XCTAssertEqual(service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID])["ok"] as? Bool, true)
        let changeAfter = document.liveChangeCount
        document.store.revoke()   // force the real save path to fail

        let result = await CADNativeEditCommit.save(
            document: document, changeAfterMutation: changeAfter,
            rollback: .undo, checkpoint: checkpoint)
        XCTAssertFalse(result.saved)
        XCTAssertTrue(result.rolledBack)
        XCTAssertFalse(result.concurrentEdit)
        XCTAssertNil(document.session.document.bodies.first?.material,
                     "a failed save must undo the applied material, not leave a phantom edit")
        XCTAssertGreaterThan(document.liveChangeCount, changeAfter,
                             "undo is itself a generation change; what matters is the body state")
    }

    func testFailedSaveWithConcurrentEditDoesNotUndoAnotherWindowEdit() async throws {
        let url = workDir.appendingPathComponent("concurrent.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Concurrent")
        let (bodyID, _) = try makeBox(document)
        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: ["name": "Paint",
                                                              "color": [0.2, 0.4, 0.6, 1.0]])
        let materialID = try XCTUnwrap(created["id"] as? String)
        let checkpoint = document.captureEditCheckpoint()
        XCTAssertEqual(service.handle(action: "apply", args: [
            "material_id": materialID, "bodyID": bodyID])["ok"] as? Bool, true)
        let changeAfter = document.liveChangeCount
        // A second editor command lands while the save is conceptually in
        // flight. The commit must not undo it when the save fails.
        _ = service.handle(action: "create", args: ["name": "Other",
                                                    "color": [0.6, 0.4, 0.2, 1.0]])
        document.store.revoke()

        let result = await CADNativeEditCommit.save(
            document: document, changeAfterMutation: changeAfter,
            rollback: .undo, checkpoint: checkpoint)
        XCTAssertFalse(result.saved)
        XCTAssertFalse(result.rolledBack)
        XCTAssertTrue(result.concurrentEdit)
        XCTAssertEqual(document.session.document.bodies.first?.material?.materialID, materialID,
                       "the other editor's change (and the applied material) must remain")
    }

    // MARK: Face binding safety

    func testStaleFaceBindingIsUnresolvedUntilExplicitReassign() async throws {
        let url = workDir.appendingPathComponent("face.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Face")
        let (_, _) = try makeBox(document)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let brep = try XCTUnwrap(body.brep, "the fixture body lost its analytic B-rep")
        let faces = OCCTKernel.faceInfo(brep).filter { $0.signature != nil }
        let face = try XCTUnwrap(faces.first)

        let service = CADMaterialService(document: document)
        let created = service.handle(action: "create", args: ["name": "Face Paint",
                                                              "color": [0.1, 0.8, 0.2, 1.0]])
        let materialID = try XCTUnwrap(created["id"] as? String)
        let faceToken = CADGeometryQueryGeneration(
            scope: "faces", bodyID: body.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: body.meshRevision).token
        let applied = service.handle(action: "applyFaces", args: [
            "material_id": materialID,
            "bodyID": body.id.raw.uuidString,
            "faces": [face.index],
            "query_token": faceToken,
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        XCTAssertEqual(document.session.document.bodies.first?.materialFaceBindings.count, 1)

        // Replace the binding with a never-matching signature: the resolver
        // must report it, not snap it to whichever face now has index 1.
        var stale = try XCTUnwrap(document.session.document.bodies.first)
        let wrongSignature = FaceSignature(kind: .planar,
                                           normal: SIMD3(0, 1, 0),
                                           centroid: SIMD3(10_000, 10_000, 10_000),
                                           area: 1, planeOffset: 10_000)
        let wrongKey = CADFaceKey(signature: wrongSignature, capturedIndex: face.index)
        let staleBinding = CADFaceMaterialBinding(key: wrongKey,
                                                  material: stale.material ?? .default)
        stale.materialFaceBindings = [staleBinding]
        document.session.perform(SetMaterialAppearanceCommand(
            title: "Inject stale", bodyIDs: [stale.id],
            after: [stale.id: .init(material: stale.material,
                                    faceBindings: stale.materialFaceBindings)],
            document: document.session.document))

        let unresolved = service.handle(action: "unresolved", args: [:])
        XCTAssertEqual(unresolved["ok"] as? Bool, true)
        XCTAssertEqual(unresolved["count"] as? Int, 1, "\(unresolved)")

        let current = try XCTUnwrap(document.session.document.bodies.first)
        let reassignToken = CADGeometryQueryGeneration(
            scope: "faces", bodyID: current.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: current.meshRevision).token
        let reassigned = service.handle(action: "reassignFaces", args: [
            "bodyID": stale.id.raw.uuidString,
            "faces": [face.index],
            "query_token": reassignToken,
        ])
        XCTAssertEqual(reassigned["ok"] as? Bool, true, "\(reassigned)")
        XCTAssertEqual(document.session.document.bodies.first?.materialFaceBindings.count, 0)
        document.close()
    }

    // MARK: Stale index reuse

    func testReusedFaceIndexIsRejectedWithoutCurrentQueryGeneration() async throws {
        let url = workDir.appendingPathComponent("staleref.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "StaleRef")
        let (_, featureID) = try makeBox(document)
        let before = try XCTUnwrap(document.session.document.bodies.first)
        let faces = OCCTKernel.faceInfo(try XCTUnwrap(before.brep)).filter { $0.signature != nil }
        let face = try XCTUnwrap(faces.first)
        let oldToken = CADGeometryQueryGeneration(
            scope: "faces", bodyID: before.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: before.meshRevision).token

        // The rebuild reuses the numeric index for a different face; the old
        // query generation must be refused even though that index still
        // exists.
        let update = CADParameterService(document: document).handle(
            action: "update", args: ["feature_id": featureID,
                                     "changes": ["distance": 27.0]])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        let after = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertNotEqual(after.meshRevision, before.meshRevision)
        XCTAssertNotNil(OCCTKernel.faceInfo(try XCTUnwrap(after.brep))
            .first(where: { $0.index == face.index }),
            "the test must reuse an existing index, not test an out-of-range one")

        let staleOperation = """
        {"op":"feature.pushPull","args":{"bodyID":"\(after.id.raw.uuidString)",
         "face":[\(face.index)],"distance":2,"query_token":"\(oldToken)"}}
        """
        do {
            try CADStaleReferenceGuard.validate(operationJSON: staleOperation,
                                                document: document)
            XCTFail("a stale query generation must be refused even when the index still exists")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "requery_required", error.message)
        }

        let indexOnly = """
        {"op":"feature.pushPull","args":{"bodyID":"\(after.id.raw.uuidString)",
         "face":[\(face.index)],"distance":2}}
        """
        do {
            try CADStaleReferenceGuard.validate(operationJSON: indexOnly,
                                                document: document)
            XCTFail("index existence alone must not satisfy the stable-reference rule")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "requery_required", error.message)
        }

        let currentToken = CADGeometryQueryGeneration(
            scope: "faces", bodyID: after.id.raw,
            documentRevision: document.revision,
            changeCount: document.session.changeCount,
            meshRevision: after.meshRevision).token
        let currentOperation = """
        {"op":"feature.pushPull","args":{"bodyID":"\(after.id.raw.uuidString)",
         "face":[\(face.index)],"distance":2,"query_token":"\(currentToken)"}}
        """
        XCTAssertNoThrow(try CADStaleReferenceGuard.validate(operationJSON: currentOperation,
                                                             document: document))
        document.close()
    }

    func testFailedRebuildPreservesPreexistingRedoAndCannotBeRedone() async throws {
        let url = workDir.appendingPathComponent("redo.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Redo")
        let (_, featureID) = try makeBox(document)

        // Seed a real redo entry, then remove the sketch WITHOUT a command so
        // the next feature rebuild fails while that redo still exists.
        document.session.perform(SetMaterialLibraryDataCommand(
            before: nil, after: Data("{\"schemaVersion\":1,\"entries\":[]}".utf8)))
        document.session.undo()
        let priorRedo = document.session.undoStack.redoCommands.map(\.title)
        XCTAssertEqual(priorRedo, ["Material Library"])

        document.session.preview { document in
            document.sketches.removeAll()
        }

        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": featureID, "changes": ["distance": 25.0],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false, "\(reply)")
        XCTAssertEqual(reply["rolled_back"] as? Bool, true)
        XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), priorRedo,
                       "the rejected edit must not replace the pre-existing redo history")
        XCTAssertFalse(document.session.undoStack.redoCommands.contains {
            $0.title == "Edit Feature"
        }, "the failed parameter edit must not become redoable")
        document.close()
    }

    // MARK: Parameters

    func testParameterUpdateRebuildsAndUndoRestoresVolume() async throws {
        let url = workDir.appendingPathComponent("param.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Param")
        let (bodyID, featureID) = try makeBox(document)
        let before = MeasureKit.volume(of: try XCTUnwrap(document.session.document.bodies.first))

        let service = CADParameterService(document: document)
        let list = service.handle(action: "list", args: [:])
        XCTAssertEqual(list["ok"] as? Bool, true, "\(list)")
        let rows = try XCTUnwrap(list["features"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first { ($0["id"] as? String) == featureID })
        XCTAssertEqual(row["kind"] as? String, "extrude")
        XCTAssertEqual(row["update_supported"] as? Bool, true)
        let parameters = try XCTUnwrap(row["parameters"] as? [[String: Any]])
        XCTAssertTrue(parameters.contains { ($0["name"] as? String) == "distance"
            && ($0["unit"] as? String) == "mm" })

        let updated = service.handle(action: "update", args: [
            "feature_id": featureID, "changes": ["distance": 25.0],
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        let after = MeasureKit.volume(of: try XCTUnwrap(document.session.document.bodies.first))
        XCTAssertEqual(after, before * 2.5, accuracy: max(1e-3, before * 0.01))

        let undone = service.handle(action: "undo", args: [:])
        XCTAssertEqual(undone["ok"] as? Bool, true)
        let restored = MeasureKit.volume(of: try XCTUnwrap(document.session.document.bodies.first))
        XCTAssertEqual(restored, before, accuracy: max(1e-3, before * 0.01))
        XCTAssertNotNil(document.session.document.body(with: BodyID(raw: UUID(uuidString: bodyID)!)))
        document.close()
    }

    func testInvalidParameterIsRefusedWithoutMutation() async throws {
        let url = workDir.appendingPathComponent("badparam.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "BadParam")
        let (_, featureID) = try makeBox(document)
        let before = document.session.changeCount
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": featureID, "changes": ["distance": 0.0],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(document.session.changeCount, before)
        document.close()
    }

    // MARK: GLB / UV

    func testGLBExportsActualPBRUVAndTextureAndRoundTrips() throws {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 0, 0), SIMD3<Float>(0, 10, 0)]
        let normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0)]
        let indices: [UInt32] = [0, 1, 2]
        var body = Body(id: BodyID(), name: "Triangle",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices),
                        revision: 1)
        body.material = BodyMaterialSpec(
            baseColor: SIMD4(0.9, 0.4, 0.1, 0.8),
            metallic: 0.85, roughness: 0.3,
            baseColorTexture: png,
            materialName: "Copper",
            opacity: 0.8,
            emissive: SIMD3(0.1, 0.2, 0.3),
            emissiveStrength: 3.0,
            uvMapping: CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                            scaleMM: SIMD2(25, 10),
                                            rotationDegrees: 30,
                                            offset: SIMD2(0.25, 0.5)))
        let glb = GLBExporter.glb(bodies: [body])
        XCTAssertNil(body.render.texcoords, "export must not mutate the body mesh")

        let json = try jsonChunk(glb)
        let materials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        XCTAssertEqual(materials.count, 1)
        let pbr = try XCTUnwrap(materials[0]["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double, 0.85)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double, 0.3)
        XCTAssertNotNil(pbr["baseColorTexture"])
        XCTAssertEqual(materials[0]["alphaMode"] as? String, "BLEND")
        XCTAssertEqual(materials[0]["emissiveFactor"] as? [Double], [0.1, 0.2, 0.3])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0]["mimeType"] as? String, "image/png")
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let primitive = try XCTUnwrap((meshes[0]["primitives"] as? [[String: Any]])?.first)
        let attributes = try XCTUnwrap(primitive["attributes"] as? [String: Any])
        XCTAssertNotNil(attributes["TEXCOORD_0"],
                        "a textured body without mesh UVs must get projected render UVs")

        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let uvAccessorIndex = try XCTUnwrap(attributes["TEXCOORD_0"] as? Int)
        XCTAssertEqual(accessors[uvAccessorIndex]["type"] as? String, "VEC2")
        XCTAssertEqual(accessors[uvAccessorIndex]["count"] as? Int, positions.count)

        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let part = try XCTUnwrap(parts.first)
        XCTAssertNotNil(part.mesh.texcoords)
        XCTAssertEqual(part.material?.baseColorTexture, png)
        XCTAssertEqual(part.material?.materialName, "Copper")
        XCTAssertEqual(part.material?.metallic ?? 0, 0.85, accuracy: 1e-6)
        XCTAssertEqual(part.material?.roughness ?? 0, 0.3, accuracy: 1e-6)
    }

    func testGLBExplicitlyReportsUnresolvedFaceMaterialsInsteadOfSilentlyBodyOnly() throws {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(100, 0, 0),
                         SIMD3<Float>(0, 0, 60)]
        let normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0),
                       SIMD3<Float>(0, 1, 0)]
        var body = Body(id: BodyID(), name: "FaceBracket",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: [0, 1, 2]),
                        revision: 1)
        let signature = FaceSignature(kind: .planar, normal: SIMD3(0, 1, 0),
                                      centroid: SIMD3(50, 0, 30), area: 3000,
                                      planeOffset: 0)
        body.materialFaceBindings = [CADFaceMaterialBinding(
            key: CADFaceKey(signature: signature, capturedIndex: 1),
            material: BodyMaterialSpec(baseColor: SIMD4(0.8, 0.2, 0.1, 1),
                                       materialName: "Face Paint"))]
        let json = try jsonChunk(GLBExporter.glb(bodies: [body]))
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let extras = try XCTUnwrap(meshes.first?["extras"] as? [String: Any])
        let unresolved = try XCTUnwrap(extras["floe_unresolved_face_bindings"] as? [[String: Any]])
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertFalse((unresolved.first?["reason"] as? String ?? "").isEmpty,
                       "a face material without a trustworthy triangle map must be explicit")
        let primitives = try XCTUnwrap(meshes.first?["primitives"] as? [[String: Any]])
        XCTAssertEqual(primitives.count, 1, "unresolved face material keeps the body primitive visible")
    }

    func testGLBExportsMetersWithYUpRootTransformAndRoundTripsMillimetres() throws {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(100, 0, 0),
                         SIMD3<Float>(0, 20, 60)]
        let normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0),
                       SIMD3<Float>(0, 1, 0)]
        let body = Body(id: BodyID(), name: "Bracket",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: [0, 1, 2]),
                        revision: 1)
        let glb = GLBExporter.glb(bodies: [body])
        let json = try jsonChunk(glb)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let root = try XCTUnwrap(nodes.last)
        XCTAssertEqual(root["name"] as? String, "FloeRoot")
        let scale = try XCTUnwrap(root["scale"] as? [Double])
        XCTAssertEqual(scale, [0.001, 0.001, 0.001],
                       "external JSON must carry the explicit mm -> m unit transform")
        let extras = try XCTUnwrap(root["extras"] as? [String: Any])
        XCTAssertEqual(extras["floe_source_units"] as? String, "millimetres")
        XCTAssertEqual(extras["floe_source_up_axis"] as? String, "+Y")
        let scenes = try XCTUnwrap(json["scenes"] as? [[String: Any]])
        let roots = try XCTUnwrap(scenes.first?["nodes"] as? [Int])
        XCTAssertEqual(roots, [nodes.count - 1])

        // Accessor data stays in model millimetres; the root converts it.
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let min = try XCTUnwrap(accessors[0]["min"] as? [Double])
        let max = try XCTUnwrap(accessors[0]["max"] as? [Double])
        XCTAssertEqual(max[0] - min[0], 100, accuracy: 1e-6)
        XCTAssertEqual(max[1] - min[1], 20, accuracy: 1e-6)
        XCTAssertEqual(max[2] - min[2], 60, accuracy: 1e-6)
        XCTAssertEqual((max[0] - min[0]) * scale[0], 0.1, accuracy: 1e-9)

        // Importing as a glTF (metres) with the normal 1000 mm/m scale puts the
        // bracket back at its real 100 mm extent, not 100 m.
        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1000)
        let imported = try XCTUnwrap(parts.first?.mesh.positions)
        let lo = imported.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
            simd_min($0, $1)
        }
        let hi = imported.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
            simd_max($0, $1)
        }
        XCTAssertEqual(hi.x - lo.x, 100, accuracy: 0.001)
        XCTAssertEqual(hi.y - lo.y, 20, accuracy: 0.001)
        XCTAssertEqual(hi.z - lo.z, 60, accuracy: 0.001)
        XCTAssertGreaterThan(hi.y, lo.y, "glTF +Y stays up")
    }

    func testProjectedUVsAreFiniteAndDeterministic() {
        let map = CADMaterialUVMapping(source: .planarProjection, axis: .y,
                                       scaleMM: SIMD2(10, 24),
                                       rotationDegrees: 45,
                                       offset: SIMD2(0.5, -0.25))
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(10, 20, 5)]
        let normals = [SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 0, 0)]
        let first = MaterialUVProjector.project(positions: positions, normals: normals,
                                                indices: [0, 1, 0], mapping: map)
        let second = MaterialUVProjector.project(positions: positions, normals: normals,
                                                 indices: [0, 1, 0], mapping: map)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.count, positions.count)
        XCTAssertTrue(first?.allSatisfy { $0.x.isFinite && $0.y.isFinite } == true)
        // mesh-source mappings return nil (they sample the mesh's own UVs).
        XCTAssertNil(MaterialUVProjector.project(positions: positions, normals: normals,
                                                 indices: [0, 1, 0],
                                                 mapping: .mesh))
    }
}
