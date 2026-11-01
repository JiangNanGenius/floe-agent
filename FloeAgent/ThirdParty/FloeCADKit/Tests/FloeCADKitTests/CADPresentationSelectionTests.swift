import XCTest
import Foundation
import simd
import Euclid
@testable import FloeCAD

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import RealityKit
import UIKit

@MainActor
final class CADPresentationSelectionTests: XCTestCase {
    private var directory: URL!
    private var document: FloeCADDocument!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PresentPick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        document = try await FloeCADDocument.create(at: directory.appendingPathComponent("selection.floecad"), name: "Selection")
    }

    override func tearDown() async throws {
        document?.close()
        document = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func run(_ json: String) throws -> [String: Any] {
        let result = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(result.isOK, result.message ?? "command failed")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
    }

    private func box(hole: Bool = false) throws -> Body {
        let sketch = try XCTUnwrap(try run(#"{"op":"sketch.create","args":{"name":"Front"}}"#)["sketchID"] as? String)
        _ = try run("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketch)","entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        _ = try run("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketch)","seedPoint":[20,10],"distance":10}}
        """)
        let body = try XCTUnwrap(document.session.document.bodies.first)
        if hole {
            let holeSketch = try XCTUnwrap(try run(#"{"op":"sketch.create","args":{"name":"Bore"}}"#)["sketchID"] as? String)
            _ = try run("""
            {"op":"sketch.addEntities","args":{"sketchID":"\(holeSketch)","entities":[{"kind":"circle","center":[20,10],"radius":4}]}}
            """)
            _ = try run("""
            {"op":"feature.extrude","args":{"sketchID":"\(holeSketch)","seedPoint":[20,10],"distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(body.id.raw.uuidString)"]}}
            """)
        }
        return try XCTUnwrap(document.session.document.bodies.first)
    }

    private func scene() -> CADPresentationScene {
        CADPresentationSceneBuilder.build(snapshot: document.sceneSnapshot(), documentKey: document.url.standardizedFileURL.path)
    }

    private func stamp(_ scene: CADPresentationScene) -> CADPresentationSelectionStamp {
        CADPresentationSelectionStamp(documentKey: scene.documentKey, documentRevision: scene.documentRevision,
            changeCount: scene.changeCount, buildKey: scene.buildKey, renderGeneration: 7, interactionGeneration: 2)
    }

    private func apply(_ pick: CADPresentationPick?, scene: CADPresentationScene) -> Bool {
        let identity = stamp(scene)
        return CADPresentationSelection.apply(pick, stamp: identity, currentStamp: identity, scene: scene, document: document)
    }

    private func buildScene(_ scene: CADPresentationScene) async throws
        -> (result: CADPresentationBuildResult, view: ARView, anchor: AnchorEntity) {
        let result = try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: scene)
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                          cameraMode: .nonAR, automaticallyConfigureSession: false)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(result.stage)
        view.scene.addAnchor(anchor)
        return (result, view, anchor)
    }

    /// Real RealityKit collision query against the production collision shape.
    /// Waiting is bounded and yields, exactly like the existing hole witness.
    private func nearestHit(_ view: ARView, origin: SIMD3<Float>,
                            direction: SIMD3<Float>, length: Float = 1,
                            targets: [ObjectIdentifier: CADPresentationPick])
        async -> (CollisionCastHit, CADPresentationPick)? {
        for _ in 0..<50 {
            let hits = view.scene.raycast(origin: origin, direction: direction,
                                          length: length, query: .all)
            if let hit = hits.sorted(by: { $0.distance < $1.distance })
                .first(where: { targets[ObjectIdentifier($0.entity)] != nil }),
               let pick = targets[ObjectIdentifier(hit.entity)] {
                return (hit, pick)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func refine(_ hit: (CollisionCastHit, CADPresentationPick),
                        drawn: CADPresentationBody,
                        scene: CADPresentationScene) async -> CADPresentationPick? {
        let local = CADPresentationSelection.localPointMillimetres(
            worldPoint: hit.0.position,
            bodyTransform: drawn.transform,
            stageTransform: matrix_identity_float4x4)
        return await CADPresentationSelection.refinedFacePick(
            hit.1, localPointMillimetres: local,
            presentationBody: drawn, scene: scene, document: document)
    }

    /// A routine save advances the committed receipt (`revision`/`contentSHA256`)
    /// of unchanged live content, and an animation-only edit advances the
    /// document generation; neither changes a static-scene pixel. Both must
    /// leave the presentation build key unchanged, otherwise the Present
    /// poller rebuilds the stage, bumps `renderGeneration` and cancels an
    /// active animation/capture render lease (the run-16/run-18 stale class).
    /// A real rendered-material edit must still force a rebuild.
    func testSaveAndAnimationOnlyEditsKeepRenderBuildKey() async throws {
        let body = try box()
        let before = scene()
        let revisionBefore = document.revision
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "save failed")
        XCTAssertGreaterThan(document.revision, revisionBefore)

        let savedScene = scene()
        XCTAssertEqual(savedScene.documentRevision, document.revision)
        XCTAssertEqual(savedScene.buildKey, before.buildKey,
                       "a save-only identity advance must reuse the built stage")

        _ = try document.createAnimationClip(name: "Identity-only clip",
                                             duration: 1)
        XCTAssertGreaterThan(document.liveChangeCount, before.changeCount)
        XCTAssertEqual(scene().buildKey, before.buildKey,
                       "animation data is not a static-stage build input")

        document.session.perform(SetMaterialCommand(
            bodyIDs: [body.id],
            material: BodyMaterialSpec(baseColor: SIMD4(0.9, 0.1, 0.1, 1)),
            document: document.session.document))
        XCTAssertGreaterThan(document.liveChangeCount, before.changeCount)
        XCTAssertNotEqual(scene().buildKey, before.buildKey,
                          "a real rendered-material edit must rebuild the stage")
    }

    func testBodyBlankAndAdditiveSelectionUseLiveEditorWithoutGeometryEdit() async throws {
        let body = try box()
        let scene = scene()
        let drawn = try XCTUnwrap(scene.bodies.first { $0.id == body.id.raw })
        let model = document.viewModel()
        let generation = document.liveChangeCount
        let revision = document.revision
        let meshRevision = body.meshRevision
        let undoCount = document.session.undoStack.undoCommands.count
        model.selectedSketchEntityIDs = [UUID()]
        XCTAssertTrue(apply(CADPresentationSelection.pick(for: drawn), scene: scene))
        XCTAssertEqual(model.selection, [body.id])
        XCTAssertTrue(model.selectedSketchEntityIDs.isEmpty)
        XCTAssertEqual(document.assistantSelectionContext().bodies.map(\.id), [body.id.raw.uuidString])
        XCTAssertTrue(document.assistantSelectionContext().faces.isEmpty)
        model.selectionAdditive = true
        XCTAssertTrue(apply(nil, scene: scene))
        XCTAssertEqual(model.selection, [body.id], "additive blank keeps selection")
        XCTAssertTrue(apply(CADPresentationSelection.pick(for: drawn), scene: scene))
        XCTAssertTrue(document.assistantSelectionContext().isEmpty, "an additive second tap toggles the body off")
        model.selectionAdditive = false
        XCTAssertTrue(apply(CADPresentationSelection.pick(for: drawn), scene: scene))
        XCTAssertTrue(apply(nil, scene: scene))
        XCTAssertTrue(document.assistantSelectionContext().isEmpty)
        XCTAssertEqual(document.liveChangeCount, generation)
        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.session.document.body(with: body.id)?.meshRevision, meshRevision)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount)
    }

    func testStaleSceneRenderGestureDocumentAndMeshPicksPreserveSelection() async throws {
        let body = try box()
        let scene = scene()
        let pick = CADPresentationSelection.pick(for: try XCTUnwrap(scene.bodies.first))
        XCTAssertTrue(apply(pick, scene: scene))
        let original = document.assistantSelectionContext()
        let identity = stamp(scene)
        for updated in [
            CADPresentationSelectionStamp(documentKey: identity.documentKey, documentRevision: identity.documentRevision,
                changeCount: identity.changeCount, buildKey: identity.buildKey, renderGeneration: 8, interactionGeneration: 2),
            CADPresentationSelectionStamp(documentKey: identity.documentKey, documentRevision: identity.documentRevision,
                changeCount: identity.changeCount, buildKey: identity.buildKey, renderGeneration: 7, interactionGeneration: 3)
        ] {
            XCTAssertFalse(CADPresentationSelection.apply(nil, stamp: identity, currentStamp: updated, scene: scene, document: document))
            XCTAssertEqual(document.assistantSelectionContext(), original)
        }
        XCTAssertFalse(CADPresentationSelection.apply(nil, stamp: identity, currentStamp: nil, scene: scene, document: document),
                       "a rebuilding/released stage cannot clear selection")
        var wrongDocument = identity
        wrongDocument.documentKey += "-other"
        XCTAssertFalse(CADPresentationSelection.apply(nil, stamp: wrongDocument, currentStamp: wrongDocument, scene: scene, document: document))
        var staleMesh = pick
        staleMesh.meshRevision &+= 1
        XCTAssertFalse(apply(staleMesh, scene: scene))
        XCTAssertEqual(document.assistantSelectionContext(), original)
        var changed = body
        changed.transform.translation.x += 10
        document.session.perform(ReplaceBodyCommand(title: "Move", before: body, after: changed))
        XCTAssertFalse(apply(pick, scene: scene), "the live document fence rejects hits during scene polling")
        XCTAssertEqual(document.viewModel().selection, [body.id])
    }

    func testFaceMaterialGroupMapsExactTrianglesAndFallsBackOnAmbiguity() async throws {
        let body = try box()
        let index = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep)).first { $0.normal.y > 0.99 }?.index)
        let material = CADMaterialService(document: document)
        let created = material.handle(action: "create", args: ["name": "Top paint", "color": [0.2, 0.5, 0.8, 1.0]])
        let materialID = try XCTUnwrap(created["id"] as? String)
        let token = CADGeometryQueryGeneration(scope: "faces", bodyID: body.id.raw,
            documentRevision: document.revision, changeCount: document.liveChangeCount, meshRevision: body.meshRevision).token
        let applied = material.handle(action: "applyFaces", args: ["material_id": materialID,
            "bodyID": body.id.raw.uuidString, "faces": [index], "query_token": token])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        let scene = scene()
        let drawn = try XCTUnwrap(scene.bodies.first { $0.id == body.id.raw })
        let group = try XCTUnwrap(drawn.faceGroups.first)
        let result = try await CADPresentationEntityBuilder(cache: CADPresentationResourceCache()).build(scene: scene)
        let entity = try XCTUnwrap(result.bodyEntities[drawn.id]?.faceEntities[group.faceIndex])
        entity.name = "\(UUID().uuidString) — misleading label"
        let pick = try XCTUnwrap(result.pickTargets[ObjectIdentifier(entity)])
        XCTAssertFalse(pick.triangles.isEmpty)
        XCTAssertNotNil(entity.components[CollisionComponent.self])
        let generation = document.liveChangeCount
        XCTAssertTrue(apply(pick, scene: scene))
        let context = document.assistantSelectionContext()
        XCTAssertEqual(context.faces.count, 1)
        XCTAssertEqual(context.faces.first?.bodyID, body.id.raw.uuidString)
        XCTAssertEqual(context.faces.first?.triangleCount, pick.triangles.count)
        let target = CADPresentationSelection.materialTarget(document: document)
        XCTAssertTrue(target.isFaceTarget)
        XCTAssertEqual(target.faceIndex, index, "the inspector must resolve the current live face")
        XCTAssertNotNil(target.faceIdentity)
        XCTAssertEqual(document.liveChangeCount, generation)
        var ambiguous = drawn
        var overlap = group
        overlap.faceIndex += 100
        ambiguous.faceGroups.append(overlap)
        XCTAssertTrue(CADPresentationSelection.pick(for: ambiguous, group: group).triangles.isEmpty,
                      "overlapping groups select the body rather than invent a face")
        var unknown = drawn
        unknown.faceGroups[0].indices = [UInt32.max, 0, 1]
        XCTAssertTrue(CADPresentationSelection.pick(for: unknown, group: unknown.faceGroups[0]).triangles.isEmpty)
    }

    func testInstancesRemainDistinctAndMaterialTargetsHonorIndependentCopies() async throws {
        let body = try box()
        let service = CADAssemblyService(document: document)
        let shared = service.handle(action: "addInstance", args: ["bodyID": body.id.raw.uuidString,
            "name": "Shared", "transform": ["position": [60.0, 0.0, 0.0]]])
        let copied = service.handle(action: "addInstance", args: ["bodyID": body.id.raw.uuidString,
            "name": "Independent", "independentCopy": true,
            "transform": ["position": [120.0, 0.0, 0.0]]])
        let sharedID = try XCTUnwrap(UUID(uuidString: shared["id"] as? String ?? ""))
        let copyID = try XCTUnwrap(UUID(uuidString: copied["id"] as? String ?? ""))
        let copiedBodyID = try XCTUnwrap(UUID(uuidString: copied["copiedBodyID"] as? String ?? ""))
        let scene = scene()
        let sharedDrawn = try XCTUnwrap(scene.bodies.first { $0.id == sharedID })
        let copiedDrawn = try XCTUnwrap(scene.bodies.first { $0.id == copyID })
        let generation = document.liveChangeCount
        var placedFace = sharedDrawn
        let materialGroup = CADPresentationFaceGroup(faceIndex: 999,
            indices: Array(sharedDrawn.mesh.indices.prefix(3)), material: sharedDrawn.material, uvs: nil)
        placedFace.faceGroups = [materialGroup]
        XCTAssertTrue(CADPresentationSelection.pick(for: placedFace, group: materialGroup).triangles.isEmpty,
                      "a placed face must remain an instance pick until instance-face context carries placement")
        XCTAssertTrue(apply(CADPresentationSelection.pick(for: sharedDrawn), scene: scene))
        XCTAssertTrue(document.viewModel().selection.isEmpty)
        var context = document.assistantSelectionContext()
        XCTAssertTrue(context.bodies.isEmpty)
        XCTAssertEqual(context.instances.map(\.id), [sharedID.uuidString])
        var target = CADPresentationSelection.materialTarget(document: document)
        XCTAssertEqual(target.bodyIDs, [body.id.raw])
        XCTAssertNotNil(target.note, "shared material scope must be visible")
        XCTAssertTrue(apply(CADPresentationSelection.pick(for: copiedDrawn), scene: scene))
        context = document.assistantSelectionContext()
        XCTAssertEqual(context.instances.first?.bodyID, copiedBodyID.uuidString)
        target = CADPresentationSelection.materialTarget(document: document)
        XCTAssertEqual(target.bodyIDs, [copiedBodyID])
        XCTAssertNil(target.note, "an independent copy must not claim to repaint its original source")
        XCTAssertEqual(document.liveChangeCount, generation)
        XCTAssertTrue(apply(nil, scene: scene))
        XCTAssertTrue(document.assistantSelectionContext().isEmpty)
    }

    func testRealityKitTriangleCollisionSeesThroughHoleAndKeepsNearestOccluder() async throws {
        let front = try box(hole: true)
        let spec = PrimitiveSpec.box(width: 40, depth: 20, height: 10)
        var behind = Body(name: "Behind", euclidMesh: .primitive(spec), revision: 0)
        XCTAssertTrue(behind.adoptBRep(try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))))
        behind.transform.translation = SIMD3(20, -20, -10)
        document.session.perform(AddBodyCommand(body: behind, title: "Behind"))
        let scene = scene()
        let result = try await CADPresentationEntityBuilder(cache: CADPresentationResourceCache()).build(scene: scene)
        let view = ARView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), cameraMode: .nonAR,
                          automaticallyConfigureSession: false)
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(result.stage)
        view.scene.addAnchor(anchor)
        defer { anchor.removeFromParent() }
        func nearest(at x: Float, z: Float) async throws -> CADPresentationPick? {
            // Register the real scene's collision resources; do not substitute
            // a fabricated hit. Waiting is bounded and yields the main actor.
            for _ in 0..<50 {
                let hits = view.scene.raycast(origin: SIMD3(x, 0.08, z), direction: SIMD3(0, -1, 0), length: 1, query: .all)
                if let pick = hits.sorted(by: { $0.distance < $1.distance }).compactMap({ result.pickTargets[ObjectIdentifier($0.entity)] }).first {
                    return pick
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }
        let throughBoreResult = try await nearest(at: 0.02, z: -0.01)
        let throughBore = try XCTUnwrap(throughBoreResult)
        XCTAssertEqual(throughBore.bodyID, behind.id.raw, "a convex hull/AABB would falsely pick the front plate's empty bore")
        let occludedResult = try await nearest(at: 0.005, z: -0.005)
        let occluded = try XCTUnwrap(occludedResult)
        XCTAssertEqual(occluded.bodyID, front.id.raw, "the front solid must occlude the rear solid")
        XCTAssertTrue(apply(throughBore, scene: scene))
        XCTAssertEqual(document.assistantSelectionContext().bodies.map(\.id), [behind.id.raw.uuidString])
    }

    func testSelectionModeDefaultsToBodyAndKeepsNativeTitles() {
        let handle = CADPresentationHandle()
        XCTAssertEqual(handle.selectionMode, .body,
                       "Present must preserve whole-body selection by default")
        XCTAssertEqual(CADPresentationSelectionMode.allCases, [.body, .face])
        XCTAssertFalse(CADPresentationSelectionMode.body.title.isEmpty)
        XCTAssertFalse(CADPresentationSelectionMode.face.title.isEmpty)
        handle.setSelectionMode(.face)
        XCTAssertEqual(handle.selectionMode, .face)
        handle.setSelectionMode(.body)
        XCTAssertEqual(handle.selectionMode, .body)
    }

    /// The primary X20 gap: a genuine collision on an UNPAINTED regular body
    /// must refine to the live authoritative face range without any face
    /// material group, and must not advance the document/undo generation.
    func testUnpaintedBodyHitRefinesToAuthoritativeLiveFaceAndPublishesExactIdentity() async throws {
        let body = try box()
        let presentation = scene()
        let built = try await buildScene(presentation)
        defer { built.anchor.removeFromParent() }
        let drawn = try XCTUnwrap(presentation.bodies.first { $0.id == body.id.raw })
        XCTAssertTrue(try XCTUnwrap(built.result.bodyEntities[drawn.id]).faceEntities.isEmpty,
                      "the primary proof must be an unpainted body, not a pre-painted group")
        let hitResult = await nearestHit(
            built.view, origin: SIMD3(0.02, 0.08, -0.01),
            direction: SIMD3(0, -1, 0), targets: built.result.pickTargets)
        let hit = try XCTUnwrap(hitResult)
        XCTAssertTrue(hit.1.triangles.isEmpty, "an unpainted body starts as a whole-body pick")
        let localPoint = CADPresentationSelection.localPointMillimetres(
            worldPoint: hit.0.position,
            bodyTransform: drawn.transform,
            stageTransform: matrix_identity_float4x4)
        let authoritativeRegion = CADPresentationFaceHit.resolve(
            mesh: body.render, meshRevision: body.meshRevision,
            point: localPoint,
            tolerance: CADPresentationFaceHit.tolerance(
                diagonalMM: simd_length(drawn.mesh.boundsMax - drawn.mesh.boundsMin)
                    * CADPresentationAxes.millimetresPerMeter),
            faceTable: document.session.lastFaceTables[body.id],
            faceTableRevision: document.session.lastNamingRevisions[body.id])
        XCTAssertTrue(authoritativeRegion?.authoritative ?? false,
                      "a normal modeled body must resolve from the live face table")

        let revision = document.revision
        let generation = document.liveChangeCount
        let undo = document.session.undoStack.undoCommands.count
        let refinedResult = await refine(hit, drawn: drawn, scene: presentation)
        let refined = try XCTUnwrap(refinedResult)
        XCTAssertEqual(refined.entityID, body.id.raw)
        XCTAssertEqual(refined.bodyID, body.id.raw)
        XCTAssertNil(refined.instanceID)
        XCTAssertFalse(refined.triangles.isEmpty)
        XCTAssertTrue(refined.triangles.allSatisfy {
            $0 >= 0 && $0 < body.render.triangleCount
        })
        XCTAssertEqual(refined.meshRevision, body.meshRevision)

        XCTAssertTrue(apply(refined, scene: presentation))
        let context = document.assistantSelectionContext()
        XCTAssertEqual(context.bodies.map(\.id), [body.id.raw.uuidString])
        XCTAssertEqual(context.faces.count, 1)
        XCTAssertEqual(context.faces.first?.bodyID, body.id.raw.uuidString)
        XCTAssertEqual(context.faces.first?.triangleCount, refined.triangles.count)

        let target = CADPresentationSelection.materialTarget(document: document)
        XCTAssertTrue(target.isFaceTarget)
        XCTAssertEqual(target.faceBodyID, Optional(body.id.raw))
        XCTAssertNotNil(target.faceIndex, "the live inspector must name the exact kernel face")
        XCTAssertNotNil(target.faceIdentity)
        XCTAssertEqual(Set(target.faceIdentity?.triangles ?? [Int]()),
                       Set(refined.triangles))
        XCTAssertEqual(CADPresentationSelection.title(document: document) ?? "", target.title)
        XCTAssertFalse(CADPresentationSelection.title(document: document)?.isEmpty ?? true)

        XCTAssertEqual(document.revision, revision)
        XCTAssertEqual(document.liveChangeCount, generation)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)

        // A same-document presentation rebuild and the host observation key
        // keep the exact body + triangles target; no second selection cache.
        let rebuiltScene = scene()
        XCTAssertEqual(rebuiltScene.buildKey, presentation.buildKey)
        XCTAssertEqual(CADPresentationSelection.state(document: document)
            .faces.first?.triangles ?? [], refined.triangles)
        XCTAssertEqual(CADPresentationSelection.observationKey(document: document)
            .facePicks.first?.triangles ?? [], refined.triangles)
    }

    func testTwoUnpaintedFacesWithEqualTriangleCountsRemainDistinct() async throws {
        let body = try box()
        let presentation = scene()
        let built = try await buildScene(presentation)
        defer { built.anchor.removeFromParent() }
        let drawn = try XCTUnwrap(presentation.bodies.first { $0.id == body.id.raw })
        guard let topHit = await nearestHit(
            built.view, origin: SIMD3(0.02, 0.08, -0.01),
            direction: SIMD3(0, -1, 0), targets: built.result.pickTargets),
              let sideHit = await nearestHit(
                built.view, origin: SIMD3(0.2, 0.005, -0.01),
                direction: SIMD3(-1, 0, 0), targets: built.result.pickTargets) else {
            return XCTFail("the real top and side collision shapes must be queryable")
        }
        let topResult = await refine(topHit, drawn: drawn, scene: presentation)
        let top = try XCTUnwrap(topResult)
        let sideResult = await refine(sideHit, drawn: drawn, scene: presentation)
        let side = try XCTUnwrap(sideResult)
        XCTAssertEqual(top.triangles.count, side.triangles.count,
                       "this witness needs two faces with the same triangle count")
        XCTAssertNotEqual(Set(top.triangles), Set(side.triangles),
                          "face identity is actual triangles, not a count or a name")

        XCTAssertTrue(apply(top, scene: presentation))
        let firstContext = document.assistantSelectionContext().faces
        let firstIndex = CADPresentationSelection.materialTarget(document: document).faceIndex
        XCTAssertTrue(apply(side, scene: presentation))
        let secondContext = document.assistantSelectionContext().faces
        let secondIndex = CADPresentationSelection.materialTarget(document: document).faceIndex
        XCTAssertNotEqual(firstContext, secondContext)
        XCTAssertEqual(firstContext.first?.triangleCount, secondContext.first?.triangleCount)
        XCTAssertEqual(firstContext.first?.bodyID, secondContext.first?.bodyID)
        XCTAssertNotNil(firstIndex)
        XCTAssertNotNil(secondIndex)
        XCTAssertNotEqual(firstIndex, secondIndex)
    }

    func testFaceHitThroughBoreRefinesBehindSolidNotFrontPlate() async throws {
        let front = try box(hole: true)
        let spec = PrimitiveSpec.box(width: 40, depth: 20, height: 10)
        var behind = Body(name: "Behind", euclidMesh: .primitive(spec), revision: 0)
        XCTAssertTrue(behind.adoptBRep(try XCTUnwrap(
            OCCTKernel.primitiveShape(spec, placement: .identity))))
        behind.transform.translation = SIMD3(20, -20, -10)
        document.session.perform(AddBodyCommand(body: behind, title: "Behind"))
        let scene = scene()
        let built = try await buildScene(scene)
        defer { built.anchor.removeFromParent() }
        let drawn = try XCTUnwrap(scene.bodies.first { $0.id == behind.id.raw })
        let hitResult = await nearestHit(
            built.view, origin: SIMD3(0.02, 0.08, -0.01),
            direction: SIMD3(0, -1, 0), targets: built.result.pickTargets)
        let hit = try XCTUnwrap(hitResult)
        XCTAssertEqual(hit.1.bodyID, behind.id.raw,
                       "the exact collision shape must see through the empty bore")
        XCTAssertTrue(hit.1.triangles.isEmpty)

        let refinedResult = await refine(hit, drawn: drawn, scene: scene)
        let refined = try XCTUnwrap(refinedResult)
        XCTAssertEqual(refined.bodyID, behind.id.raw)
        XCTAssertFalse(refined.triangles.isEmpty)
        XCTAssertTrue(apply(refined, scene: scene))
        let context = document.assistantSelectionContext()
        XCTAssertEqual(context.bodies.map(\.id), [behind.id.raw.uuidString])
        XCTAssertEqual(context.faces.first?.bodyID, behind.id.raw.uuidString)
        XCTAssertFalse(context.faces.contains { $0.bodyID == front.id.raw.uuidString },
                       "the front plate's empty bore must not be selected")
    }

    func testRefinedFacePickRefusesStaleSceneAndPlacedOccurrence() async throws {
        let body = try box()
        let presentation = scene()
        let built = try await buildScene(presentation)
        defer { built.anchor.removeFromParent() }
        let drawn = try XCTUnwrap(presentation.bodies.first { $0.id == body.id.raw })
        let hitResult = await nearestHit(
            built.view, origin: SIMD3(0.02, 0.08, -0.01),
            direction: SIMD3(0, -1, 0), targets: built.result.pickTargets)
        let hit = try XCTUnwrap(hitResult)

        let service = CADAssemblyService(document: document)
        let reply = service.handle(action: "addInstance", args: [
            "bodyID": body.id.raw.uuidString,
            "name": "Placed",
            "transform": ["position": [60.0, 0.0, 0.0]],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let instanceID = try XCTUnwrap(UUID(uuidString: reply["id"] as? String ?? ""))
        let placedScene = scene()
        let placedDrawn = try XCTUnwrap(placedScene.bodies.first { $0.id == instanceID })
        let placedPick = CADPresentationSelection.pick(for: placedDrawn)
        XCTAssertEqual(placedPick.instanceID, Optional(instanceID))
        let placedRefinement = await CADPresentationSelection.refinedFacePick(
            placedPick, localPointMillimetres: .zero,
            presentationBody: placedDrawn, scene: placedScene, document: document)
        XCTAssertNil(placedRefinement,
                     "a placed occurrence face must not be promoted to a source-local face")

        var changed = body
        changed.transform.translation.x += 5
        document.session.perform(ReplaceBodyCommand(title: "Move",
                                                    before: body, after: changed))
        let staleRefinement = await refine(hit, drawn: drawn, scene: presentation)
        XCTAssertNil(staleRefinement, "a hit from a superseded document generation must not publish")
    }

    /// Two perpendicular triangles share one edge exactly. The measured hit
    /// point is genuinely ambiguous there; an interior point still resolves
    /// to one triangle. No AABB or material group participates.
    func testExactAmbiguousEdgeDoesNotInventAFace() {
        let mesh = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0),
                        SIMD3(0, 0, 1), SIMD3(0, 1, 0)],
            normals: Array(repeating: SIMD3(0, 1, 0), count: 4),
            indices: [0, 1, 2, 0, 2, 3])
        let edge = CADPresentationFaceHit.resolve(
            mesh: mesh, meshRevision: 1,
            point: SIMD3(0, 0, 0.5), tolerance: 0.01,
            faceTable: nil, faceTableRevision: nil)
        XCTAssertNil(edge, "two distinct faces meet exactly at this hit")
        let interior = CADPresentationFaceHit.resolve(
            mesh: mesh, meshRevision: 1,
            point: SIMD3(0.1, 0, 0.3), tolerance: 0.01,
            faceTable: nil, faceTableRevision: nil)
        XCTAssertEqual(interior?.triangles ?? [], [0])
        XCTAssertFalse(interior?.authoritative ?? true)
    }

    func testRefinedFaceTargetPreviewsAppliesCancelsAndKeepsSelectionIdentity() async throws {
        let body = try box()
        let scene = scene()
        let built = try await buildScene(scene)
        defer { built.anchor.removeFromParent() }
        let drawn = try XCTUnwrap(scene.bodies.first { $0.id == body.id.raw })
        let hitResult = await nearestHit(
            built.view, origin: SIMD3(0.02, 0.08, -0.01),
            direction: SIMD3(0, -1, 0), targets: built.result.pickTargets)
        let hit = try XCTUnwrap(hitResult)
        let refinedResult = await refine(hit, drawn: drawn, scene: scene)
        let refined = try XCTUnwrap(refinedResult)
        XCTAssertTrue(apply(refined, scene: scene))

        let target = CADPresentationSelection.materialTarget(document: document)
        XCTAssertTrue(target.isFaceTarget)
        let faceIndex = try XCTUnwrap(target.faceIndex)
        let faceIdentity = try XCTUnwrap(target.faceIdentity)
        XCTAssertEqual(Set(faceIdentity.triangles), Set(refined.triangles))

        let store = CADPersonalMaterialLibraryStore(
            fileURL: directory.appendingPathComponent("personal-materials.json"))
        let sink = RecordingPreviewSink()
        let model = CADMaterialDraftModel(document: document, target: target,
                                          personalStore: store)
        model.previewSink = sink
        defer { model.stopObserving() }
        let undoBefore = document.session.undoStack.undoCommands.count
        let generationBefore = document.liveChangeCount
        let revisionBefore = document.revision
        let preview = expectation(description: "uncommitted face preview reaches the live sink")
        sink.previewExpectation = preview
        model.update { definition in
            definition.name = "Face witness"
            definition.baseColor = SIMD4(0.8, 0.2, 0.1, 1)
        }
        await fulfillment(of: [preview], timeout: 10)
        XCTAssertEqual(sink.targets.last?.faceIndex, faceIndex)
        XCTAssertEqual(sink.targets.last?.faceBodyID, Optional(body.id.raw))
        XCTAssertEqual(sink.targets.last?.faceIdentity?.triangles ?? [Int](),
                       faceIdentity.triangles)
        XCTAssertEqual(document.liveChangeCount, generationBefore)
        XCTAssertEqual(document.revision, revisionBefore)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)

        model.apply()
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1,
                       "Apply must be exactly one undoable composite")
        XCTAssertGreaterThan(document.liveChangeCount, generationBefore)
        XCTAssertEqual(document.assistantSelectionContext().faces.first?.triangleCount,
                       refined.triangles.count)
        XCTAssertEqual(document.assistantSelectionContext().faces.first?.bodyID,
                       body.id.raw.uuidString)

        document.session.undo()
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore)
        XCTAssertTrue(document.session.undoStack.canRedo)
        XCTAssertEqual(document.assistantSelectionContext().faces.first?.triangleCount,
                       refined.triangles.count)
        XCTAssertEqual(CADMaterialTargetResolver.resolve(document: document).faceIndex,
                       faceIndex)

        let cancelGeneration = document.liveChangeCount
        let cancelUndo = document.session.undoStack.undoCommands.count
        let cancelModel = CADMaterialDraftModel(
            document: document,
            target: CADPresentationSelection.materialTarget(document: document),
            personalStore: store)
        let cancelSink = RecordingPreviewSink()
        cancelModel.previewSink = cancelSink
        defer { cancelModel.stopObserving() }
        cancelModel.update { $0.roughness = 0.12 }
        cancelModel.cancel()
        XCTAssertEqual(document.liveChangeCount, cancelGeneration)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, cancelUndo)
        XCTAssertGreaterThanOrEqual(cancelSink.endCount, 1)
    }
}

@MainActor
private final class RecordingPreviewSink: CADMaterialPreviewSink {
    var targets: [CADMaterialTarget] = []
    var endCount = 0
    var previewExpectation: XCTestExpectation?
    private var fulfilled = false

    func previewMaterial(_ spec: BodyMaterialSpec, for target: CADMaterialTarget) {
        targets.append(target)
        guard !fulfilled else { return }
        fulfilled = true
        previewExpectation?.fulfill()
    }

    func endMaterialPreview() {
        endCount += 1
    }
}
#endif
