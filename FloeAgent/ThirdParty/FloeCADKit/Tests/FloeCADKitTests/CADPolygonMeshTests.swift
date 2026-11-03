import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADPolygonMeshTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PolygonCages-\(UUID())")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        for document in documents { document.close() }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    private func document() async throws -> FloeCADDocument {
        let doc = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID()).floecad"),name: "Editable polygons")
        documents.append(doc); return doc
    }
    private func cage(_ doc: FloeCADDocument, _ id: BodyID) throws -> CADPolygonMeshDefinition {
        let node = try XCTUnwrap(doc.session.document.features.nodes.last { $0.outputBodyIDs.contains(id) })
        guard case let .polygonCage(value,_) = node.kind else { throw CADPolygonFailure.invalid("Expected polygon cage") }; return value
    }
    @discardableResult private func run(_ doc: FloeCADDocument, _ id: BodyID?, _ action: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        var args = fields
        if let id { args["bodyID"] = id.raw.uuidString; args["cageDigest"] = try cage(doc,id).digest }
        let result = await CADMeshService(document: doc).handleAsync(action: action,args: args)
        XCTAssertEqual(result["ok"] as? Bool,true,"\(result)"); return result
    }
    private func create(_ doc: FloeCADDocument) async throws -> BodyID {
        let result = try await run(doc,nil,"topology.create",["width":10,"height":10,"depth":10])
        return BodyID(raw: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(result["bodyID"] as? String))))
    }
    private func assertClosed(_ definition: CADPolygonMeshDefinition, volume: Double?, file: StaticString = #filePath, line: UInt = #line) throws {
        try definition.cage.validate()
        XCTAssertTrue(definition.cage.isClosed,file:file,line:line)
        let result = try CADPolygonMeshKernel.evaluate(definition)
        XCTAssertTrue(result.mesh.isWatertight,file:file,line:line)
        XCTAssertGreaterThan(result.mesh.signedVolume,0,file:file,line:line)
        if let volume { XCTAssertEqual(result.mesh.signedVolume,volume,accuracy:1e-5,file:file,line:line) }
        XCTAssertEqual(result.controlFaceIDs.count,result.controlRender.triangleCount,file:file,line:line)
        XCTAssertTrue(result.controlFaceIDs.allSatisfy { id in definition.cage.faces.contains { $0.id == id } },file:file,line:line)
    }
    func testStableCageExtrudeFullQuadRingUndoReopenContinueEditing() async throws {
        let doc = try await document(), id = try await create(doc)
        let source = try cage(doc,id)
        XCTAssertEqual(source.cage.vertices.count,8); XCTAssertEqual(source.cage.edges.count,12); XCTAssertEqual(source.cage.faces.count,6)
        try assertClosed(source,volume:1000)
        let face = try XCTUnwrap(try source.cage.faces.first { try source.cage.normal($0).y > 0.99 })
        let initialUndo = doc.session.undoStack.undoCommands.count
        _ = try await run(doc,id,"topology.extrude",["faceID":face.id.uuidString,"distance":5])
        let extruded = try cage(doc,id)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,initialUndo + 1)
        XCTAssertEqual(extruded.cage.faces.count,10); XCTAssertEqual(extruded.cage.vertices.count,12)
        XCTAssertTrue(extruded.cage.faces.contains { $0.id == face.id })
        XCTAssertTrue(Set(source.cage.vertices.map(\.id)).isSubset(of:Set(extruded.cage.vertices.map(\.id))))
        try assertClosed(extruded,volume:1500)
        let edge = try XCTUnwrap(extruded.cage.edges.first { edge in
            let p = extruded.cage.points; return abs(p[edge.a]!.y - p[edge.b]!.y) > 9.9
        })
        _ = try await run(doc,id,"topology.loopCut",["edgeID":edge.id.uuidString,"fraction":0.5])
        let cut = try cage(doc,id)
        XCTAssertEqual(cut.cage.faces.count,14); XCTAssertEqual(cut.cage.vertices.count,16)
        XCTAssertFalse(cut.cage.edges.contains { $0.id == edge.id },"A split edge must retire its old ID.")
        XCTAssertEqual(cut.cage.vertices.count - cut.cage.edges.count + cut.cage.faces.count,2)
        try assertClosed(cut,volume:1500)
        doc.session.undo(); XCTAssertEqual(try cage(doc,id),extruded); try assertClosed(cage(doc,id),volume:1500)
        let saved = await doc.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let identity = doc.modelSHA256; doc.close()
        let reopened = try await FloeCADDocument.open(at:doc.url); documents.append(reopened)
        XCTAssertEqual(reopened.modelSHA256,identity); XCTAssertEqual(try cage(reopened,id),extruded)
        _ = try await run(reopened,id,"topology.loopCut",["edgeID":edge.id.uuidString,"fraction":0.5])
        try assertClosed(cage(reopened,id),volume:1500)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
    }
    func testRealViewportFaceAndEdgeSelectionResolveStoredIDs() async throws {
        let doc = try await document(), id = try await create(doc), model = doc.viewModel()
        model.beginPolygonCageEditing(id)
        model.polygonPickMode = .face
        model.handle(.tap(ray:Ray(origin:SIMD3(5,40,5),direction:SIMD3(0,-1,0))))
        let faceID = try XCTUnwrap(model.polygonFaceSelection), definition = try cage(doc,id)
        let face = try XCTUnwrap(definition.cage.faces.first { $0.id == faceID })
        XCTAssertEqual(try definition.cage.normal(face).y,1,accuracy:1e-7)
        XCTAssertEqual(model.polygonSelectionDigest,definition.digest)
        let selection = try XCTUnwrap(doc.assistantSelectionContext().jsonObject()["polygon_cage"] as? [String:Any])
        XCTAssertEqual(selection["face_ids"] as? [String],[faceID.uuidString])
        XCTAssertEqual(selection["cage_digest"] as? String,definition.digest)
        XCTAssertNil(selection["triangle_indices"])

        _ = try await run(doc,id,"topology.extrude",["faceID":faceID.uuidString,"distance":5])
        model.refreshPolygonCageSelection(); model.polygonPickMode = .edge
        model.handle(.tap(ray:Ray(origin:SIMD3(-20,5,0.1),direction:SIMD3(1,0,0))))
        let edgeID = try XCTUnwrap(model.polygonEdgeSelection), changed = try cage(doc,id)
        XCTAssertTrue(changed.cage.edges.contains { $0.id == edgeID })
        let displayed = try XCTUnwrap(model.scene.bodies.first { $0.id == id })
        XCTAssertEqual(displayed.renderMesh.triangleCount,try CADPolygonMeshKernel.evaluate(changed).controlRender.triangleCount)
        model.endPolygonCageEditing()
        XCTAssertEqual(doc.session.document.body(with:id)?.meshRevision,model.scene.bodies.first { $0.id == id }?.meshRevision)
    }
    func testInsetMeasuresTrueEdgeDistanceAndWeldHasRealTopologyOrRefusesAtomically() throws {
        let source = try CADPolygonCage.box(width:10,height:10,depth:10)
        let top = try XCTUnwrap(try source.faces.first { try source.normal($0).y > 0.99 })
        let inset = try CADPolygonMeshKernel.inset(source,face:top.id,distance:1)
        let inner = try XCTUnwrap(inset.faces.first { $0.id == top.id }), p = inset.points
        let xs = inner.vertices.map { p[$0]!.x }, zs = inner.vertices.map { p[$0]!.z }
        XCTAssertEqual(try XCTUnwrap(xs.min()),1,accuracy:1e-7); XCTAssertEqual(try XCTUnwrap(xs.max()),9,accuracy:1e-7)
        XCTAssertEqual(try XCTUnwrap(zs.min()),1,accuracy:1e-7); XCTAssertEqual(try XCTUnwrap(zs.max()),9,accuracy:1e-7)
        try assertClosed(.init(cage:inset),volume:1000)
        let triangles = try CADPolygonCage.capture(CADPolygonMeshKernel.evaluate(.init(cage:source)).mesh)
        let a = try XCTUnwrap(triangles.vertices.first { $0.point == SIMD3(0,0,0) }?.id)
        let b = try XCTUnwrap(triangles.vertices.first { $0.point == SIMD3(0,10,0) }?.id)
        XCTAssertThrowsError(try CADPolygonMeshKernel.weld(triangles,vertices:[a,b],tolerance:0.1))
        let welded = try CADPolygonMeshKernel.weld(triangles,vertices:[a,b],tolerance:10.1)
        XCTAssertTrue(welded.vertices.contains { $0.id == a }); XCTAssertFalse(welded.vertices.contains { $0.id == b })
        try assertClosed(.init(cage:welded),volume:nil)
        XCTAssertLessThan(try CADPolygonMeshKernel.evaluate(.init(cage:welded)).mesh.signedVolume,1000)
    }
    func testCatmullClarkMovesCornersAndModifiersKeepCageSeparateAcrossToggleOrderReopen() async throws {
        let doc = try await document(), id = try await create(doc), original = try cage(doc,id).cage
        _ = try await run(doc,id,"modifier.add",["kind":"subdivision","levels":1])
        var value = try cage(doc,id)
        XCTAssertEqual(value.cage,original)
        let evaluated = try CADPolygonMeshKernel.evaluate(value)
        XCTAssertEqual(evaluated.controlRender.triangleCount,12); XCTAssertEqual(evaluated.render.triangleCount,48)
        XCTAssertTrue(evaluated.render.positions.contains { simd_distance($0,SIMD3<Float>(repeating:Float(20.0 / 9.0))) < 1e-5 },"A Catmull-Clark corner must move; triangle splitting alone cannot pass.")
        XCTAssertLessThan(evaluated.mesh.signedVolume,1000); XCTAssertTrue(evaluated.mesh.isWatertight)
        let subdivision = try XCTUnwrap(value.modifiers.first?.id)
        _ = try await run(doc,id,"modifier.update",["modifierID":subdivision.uuidString,"enabled":false])
        try assertClosed(cage(doc,id),volume:1000)
        _ = try await run(doc,id,"modifier.update",["modifierID":subdivision.uuidString,"enabled":true])
        _ = try await run(doc,id,"modifier.add",["kind":"mirror","axis":0,"offset":-5])
        value = try cage(doc,id); let mirror = try XCTUnwrap(value.modifiers.last?.id)
        let before = try CADPolygonMeshKernel.evaluate(value).mesh.signedVolume
        _ = try await run(doc,id,"modifier.move",["modifierID":mirror.uuidString,"index":0])
        let ordered = try cage(doc,id)
        XCTAssertEqual(ordered.modifiers.map(\.id),[mirror,subdivision]); XCTAssertEqual(ordered.cage,original)
        XCTAssertEqual(try CADPolygonMeshKernel.evaluate(ordered).mesh.signedVolume,before,accuracy:1e-5,"An outside-plane reflection commutes with subdivision of disconnected copies.")
        let finalRender = try XCTUnwrap(doc.session.document.body(with:id)?.render)
        XCTAssertEqual(finalRender,try CADPolygonMeshKernel.evaluate(ordered).render)
        let saved = await doc.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        doc.close(); CADPolygonMeshKernel.clearCachedEvaluationsForTesting()
        let reopened = try await FloeCADDocument.open(at:doc.url); documents.append(reopened)
        XCTAssertEqual(try cage(reopened,id),ordered)
        XCTAssertEqual(reopened.session.document.body(with:id)?.render,finalRender)
        XCTAssertEqual(try CADPolygonMeshKernel.evaluate(cage(reopened,id)).render,try CADPolygonMeshKernel.evaluate(ordered).render)
        _ = try await run(reopened,id,"modifier.update",["modifierID":subdivision.uuidString,"enabled":false])
        try assertClosed(cage(reopened,id),volume:2000)
    }
    func testScopedBevelUsesMeasuredExistingCSGAndBadOrderKeepsUndoRedo() async throws {
        let doc = try await document(), id = try await create(doc), original = try cage(doc,id)
        let edge = try XCTUnwrap(original.cage.edges.first)
        _ = try await run(doc,id,"modifier.add",["kind":"bevel","edgeID":edge.id.uuidString,"width":1])
        let bevel = try cage(doc,id)
        try assertClosed(bevel,volume:995)
        XCTAssertEqual(bevel.cage,original.cage)
        doc.session.undo(); let baseline = try cage(doc,id), undoCount = doc.session.undoStack.undoCommands.count
        XCTAssertTrue(doc.session.undoStack.canRedo)
        let refused = await CADMeshService(document:doc).handleAsync(action:"topology.loopCut",args:["bodyID":id.raw.uuidString,"cageDigest":"stale","edgeID":edge.id.uuidString,"fraction":0.5])
        XCTAssertEqual(refused["ok"] as? Bool,false); XCTAssertEqual(try cage(doc,id),baseline)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,undoCount); XCTAssertTrue(doc.session.undoStack.canRedo)
        doc.session.redo(); try assertClosed(cage(doc,id),volume:995)
        _ = try await run(doc,id,"modifier.add",["kind":"subdivision","levels":1])
        let before = try cage(doc,id), count = doc.session.undoStack.undoCommands.count
        let invalid = await CADMeshService(document:doc).handleAsync(action:"modifier.move",args:["bodyID":id.raw.uuidString,"cageDigest":before.digest,"modifierID":before.modifiers[0].id.uuidString,"index":1])
        XCTAssertEqual(invalid["ok"] as? Bool,false); XCTAssertEqual(try cage(doc,id),before)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,count)
        let finalRender = try XCTUnwrap(doc.session.document.body(with:id)?.render)
        let saved = await doc.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        doc.close(); CADPolygonMeshKernel.clearCachedEvaluationsForTesting()
        let reopened = try await FloeCADDocument.open(at:doc.url); documents.append(reopened)
        XCTAssertEqual(reopened.session.document.body(with:id)?.render,finalRender)
        XCTAssertEqual(try CADPolygonMeshKernel.evaluate(cage(reopened,id)).render,finalRender)
        XCTAssertNotNil(CADPolygonMeshService.currentCage(in:reopened.session,bodyID:id))
    }
    func testFutureModifierAndCageFieldsAreOpaqueAndWriterFloorIsRealIntent() async throws {
        let doc = try await document(), id = try await create(doc)
        let node = try XCTUnwrap(doc.session.document.features.nodes.last), bytes = try JSONEncoder().encode(node.kind)
        func assess(_ bytes: Data) throws -> CADDocumentFormat.Assessment {
            try CADDocumentFormat.assess(planes:[],sketches:[],features:[CADFeatureRecord(featureID:node.id.raw,orderIndex:0,name:node.name,suppressed:false,kind:bytes,outputBodyIDs:try JSONEncoder().encode([id]))])
        }
        XCTAssertEqual(try assess(bytes).requiredVersion,7); XCTAssertFalse(try assess(bytes).isOpaqueReadOnly)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        var payload = try XCTUnwrap(object["polygonCage"] as? [String:Any]), definition = try XCTUnwrap(payload["definition"] as? [String:Any])
        definition["modifiers"] = [["id":UUID().uuidString,"enabled":true,"operation":["futureAdaptiveRemesh":["version":2]]]]
        payload["definition"] = definition; object["polygonCage"] = payload
        XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).opaqueFeatures.contains(node.id.raw))
        definition["modifiers"] = []; var control = try XCTUnwrap(definition["cage"] as? [String:Any]); control["futureCreaseWeights"] = [0.5]
        definition["cage"] = control; payload["definition"] = definition; object["polygonCage"] = payload
        XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).isOpaqueReadOnly)
    }
    func testCancelledCallerAndDirectMeshChangesCannotOverwriteStoredCage() async throws {
        let doc = try await document(), id = try await create(doc), before = try cage(doc,id)
        let count = doc.session.undoStack.undoCommands.count
        let service = CADMeshService(document:doc)
        let operation = Task { @MainActor in
            let reply = await service.handleAsync(action:"modifier.add",args:["bodyID":id.raw.uuidString,"cageDigest":before.digest,"kind":"subdivision","levels":2])
            return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
        }
        operation.cancel()
        let cancelledBytes = await operation.value
        let cancelled = try XCTUnwrap(JSONSerialization.jsonObject(with: cancelledBytes) as? [String: Any])
        XCTAssertEqual(cancelled["ok"] as? Bool,false); XCTAssertEqual(try cage(doc,id),before)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,count)
        let originalBody = try XCTUnwrap(doc.session.document.body(with:id))
        var changed = originalBody
        changed.render.positions = changed.render.positions.map { $0 + SIMD3<Float>(1,0,0) }
        changed.edges = FeatureEdgeExtractor.edges(from:changed.render); changed.euclid = nil
        doc.session.perform(ReplaceBodyCommand(title:"Existing mesh edit",before:originalBody,after:changed))
        let refused = await service.handleAsync(action:"topology.inset",args:["bodyID":id.raw.uuidString,"cageDigest":before.digest,"faceID":before.cage.faces[0].id.uuidString,"distance":1])
        XCTAssertEqual(refused["ok"] as? Bool,false)
        XCTAssertEqual(doc.session.document.body(with:id)?.render,changed.render)
        _ = try await run(doc,id,"topology.capture")
        let captured = try cage(doc,id)
        XCTAssertNotEqual(captured.cage.vertices.map(\.id),before.cage.vertices.map(\.id))
        XCTAssertEqual(try XCTUnwrap(captured.cage.vertices.map(\.point.x).min()),1,accuracy:1e-5)
        try assertClosed(captured,volume:1000)
    }

}
