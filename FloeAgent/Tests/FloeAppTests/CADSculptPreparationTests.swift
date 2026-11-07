// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import simd
@testable import FloeCAD

@Suite("Imported mesh sculpt preparation", .serialized)
@MainActor struct CADSculptPreparationTests {
    private func directory() throws -> URL {
        let value=FileManager.default.temporaryDirectory.appendingPathComponent("SculptPreparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:value,withIntermediateDirectories:true);return value
    }
    private func object(_ outcome:CADCommandOutcome) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with:outcome.payload) as? [String:Any])
    }
    private func obj(textured:Bool=false) -> Data {
        var lines=["o ImportedSculptGrid"]
        for y in 0..<3 { for x in 0..<3 { lines.append("v \(x) \(y) 0") } }
        if textured {
            for y in 0..<3 { for x in 0..<3 { lines.append("vt \(Double(x)/2) \(Double(y)/2)") } }
        }
        for y in 0..<2 { for x in 0..<2 {
            let i=y*3+x+1
            let ids=[i,i+1,i+4,i+3].map { textured ? "\($0)/\($0)":"\($0)" }
            lines.append("f "+ids.joined(separator:" "))
        } }
        return Data((lines.joined(separator:"\n")+"\n").utf8)
    }
    private func imported(_ document:FloeCADDocument,source:URL,modern:Bool=false) async throws -> Body {
        let result:CADCommandOutcome
        if modern {
            // The real file-import UI/tool path retains UV/material data.
            let token=MeshImportCancellation()
            let plan=try await CADMeshImportService.parseOffMain(data:Data(contentsOf:source),
                fileName:source.lastPathComponent,unitScale:1,requireExplicitUnits:true,cancellation:token)
            result=try CADMeshImportService.apply(plan,to:document,cancellation:token)
        } else {
            // Retain the originally failing geometry-only legacy case. This
            // importer intentionally does not parse OBJ vt/material records.
            result=document.nativeImportData(try Data(contentsOf:source),format:"obj",fileName:"Imported sculpt grid",unitScale:1)
        }
        try #require(result.isOK)
        let rows=try #require(object(result)["imported"] as? [[String:Any]])
        let raw=try #require(rows.first?["bodyID"] as? String),uuid=try #require(UUID(uuidString:raw))
        return try #require(document.session.document.body(with:BodyID(raw:uuid)))
    }
    @Test func actualOBJCanBeCapturedSelectedSculptedAndReopenedWithoutChangingItsSource() async throws {
        try await assertOBJWorkflow(modern:false)
        try await assertOBJWorkflow(modern:true)
    }
    private func assertOBJWorkflow(modern:Bool) async throws {
        let root=try directory();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("grid.obj"),bytes=obj()
        try bytes.write(to:source)
        let url=root.appendingPathComponent("work.floecad"),document=try await FloeCADDocument.create(at:root.appendingPathComponent("work.floecad"),name:"Sculpt imported OBJ")
        defer { document.close() }
        let body=try await imported(document,source:source,modern:modern),id=body.id
        #expect(body.brep==nil && body.surfaceBRep==nil)
        #expect(CADPolygonMeshService.captureIssue(for:body)==nil)
        #expect(CADPolygonMeshService.currentCage(in:document.session,bodyID:id)==nil)
        let service=CADMeshService(document:document),captureDepth=document.session.undoStack.undoCommands.count
        let captured=await service.handleAsync(action:"topology.capture",args:["bodyID":id.raw.uuidString])
        try #require(captured["ok"] as? Bool == true)
        let capturedCage=try #require(CADPolygonMeshService.currentCage(in:document.session,bodyID:id))
        #expect(capturedCage.node.id.raw.uuidString==captured["featureID"] as? String)
        #expect(capturedCage.body.render == (try CADPolygonMeshKernel.evaluate(capturedCage.definition)).render)
        #expect(capturedCage.body.transform==body.transform)
        #expect(document.session.undoStack.undoCommands.count==captureDepth+1)
        document.session.undo()
        #expect(document.session.document.body(with:id)?.render==body.render)
        #expect(CADPolygonMeshService.currentCage(in:document.session,bodyID:id)==nil)
        document.session.redo()
        let current=try #require(CADPolygonMeshService.currentCage(in:document.session,bodyID:id))
        let begun=await service.handleAsync(action:"sculpt.begin",args:["bodyID":id.raw.uuidString,
            "cageDigest":current.definition.digest,"expectedChangeCount":document.session.changeCount])
        try #require(begun["ok"] as? Bool == true)
        let model=document.viewModel();defer { model.endSculptEditing() };model.beginSculptEditing(id)
        #expect(model.sculptEditingBody==id && model.activeSculptCage != nil)
        let active=try #require(CADPolygonMeshService.currentCage(in:document.session,bodyID:id))
        let render=active.body.render;try #require(render.triangleCount>0)
        let depth=document.session.undoStack.undoCommands.count
        // Triangle zero is selected from this exact current native render;
        // its corner weights and pressure are the real sculpt wire format.
        let changed=await service.handleAsync(action:"sculpt.stroke",args:["bodyID":id.raw.uuidString,
            "cageDigest":active.definition.digest,"expectedChangeCount":document.session.changeCount,
            "stroke":["brush":["mode":"inflate","radius":2.0,"strength":0.5,"inverted":false],
                      "samples":[["triangle":0,"barycentric":[1.0,0.0,0.0],"pressure":0.7]]]])
        try #require(changed["ok"] as? Bool == true)
        #expect(changed["mutated"] as? Bool == true)
        let sculpted=try #require(document.session.document.body(with:id)?.render)
        #expect(sculpted != render)
        #expect(document.session.undoStack.undoCommands.count==depth+1)
        model.endSculptEditing()
        try #require((await document.save()).succeeded)
        document.close()
        let reopened=try await FloeCADDocument.open(at:url);defer { reopened.close() }
        let stored=try #require(CADPolygonMeshService.currentCage(in:reopened.session,bodyID:id))
        #expect(stored.body.brep==nil && stored.body.render==sculpted)
        #expect(stored.definition.sculpt != nil)
        #expect(try Data(contentsOf:source)==bytes)
    }
    @Test func firstCaptureCannotBorrowOwnershipFromSuppressedOrRolledBackHistory() async throws {
        let root=try directory();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("raw.obj");try obj().write(to:source)
        let document=try await FloeCADDocument.create(at:root.appendingPathComponent("planner.floecad"),name:"Capture ownership")
        defer { document.close() }
        let raw=try await imported(document,source:source)
        let definition=CADPolygonMeshDefinition(cage:try .capture(raw.euclidMesh()))
        let expected=try CADPolygonMeshKernel.evaluate(definition).render
        try #require(expected != raw.render,"The real capture uses a different authoritative triangle layout")
        for history in ["none","suppressed","rolledBack"] {
            var previous=FeatureGraph()
            if history != "none" {
                var inactive=FeatureNode(name:"Earlier cage",kind:.polygonCage(definition:definition,placement:raw.transform),outputBodyIDs:[raw.id])
                inactive.suppressed=history == "suppressed";previous.nodes=[inactive]
                if history == "rolledBack" { previous.rollbackIndex=0 }
            }
            let node=FeatureNode(name:"Current capture",kind:.polygonCage(definition:definition,placement:raw.transform),outputBodyIDs:[raw.id])
            var edited=previous;edited.rollbackIndex=nil;edited.nodes.append(node)
            var state=document.session.document;state.features=previous
            var leading:[DocumentCommand]=[]
            if previous.rollbackIndex != nil { leading.append(SetRollbackCommand(before:previous.rollbackIndex,after:nil)) }
            leading.append(AppendFeatureCommand(node:node,title:"Capture"))
            var cache=EvalCache()
            let plan=RebuildPlanner.plan(editedGraph:edited,previousGraph:previous,document:state,
                sketches:state.sketches,planes:state.planes,naming:SignatureNaming(),cache:&cache,
                nextRevision:{ raw.meshRevision },leadingCommands:leading,title:"Capture")
            #expect(plan.errors.isEmpty && plan.referenceErrors.isEmpty)
            #expect(plan.commands.contains { $0 is ReplaceBodyCommand },Comment(rawValue:history))
            for command in plan.commands { command.apply(to:&state) }
            #expect(state.body(with:raw.id)?.render==expected,Comment(rawValue:history))
            for command in plan.commands.reversed() { command.revert(in:&state) }
            #expect(state.body(with:raw.id)?.render==raw.render)
            #expect(state.features.rollbackIndex==previous.rollbackIndex)
        }
    }
    @Test func texturedOBJHasASharedVisibleReasonAndCaptureRefusesWithoutChanges() async throws {
        let root=try directory();defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("textured.obj"),bytes=obj(textured:true)
        try bytes.write(to:source)
        let document=try await FloeCADDocument.create(at:root.appendingPathComponent("textured.floecad"),name:"Textured OBJ")
        defer { document.close() }
        let body=try await imported(document,source:source,modern:true)
        let uv=try #require(body.render.texcoords)
        #expect(uv.count==body.render.positions.count)
        #expect(uv.contains(SIMD2<Float>(0,1)) && uv.contains(SIMD2<Float>(1,0)))
        #expect(CADPolygonMeshService.captureIssue(for:body) == .faceAttributes)
        let count=document.session.changeCount,render=body.render,uvData=body.uvData,depth=document.session.undoStack.undoCommands.count
        let result=await CADMeshService(document:document).handleAsync(action:"topology.capture",args:["bodyID":body.id.raw.uuidString])
        #expect(result["ok"] as? Bool == false && result["mutated"] as? Bool == false)
        #expect(result["message"] as? String == CADPolygonMeshService.CaptureIssue.faceAttributes.message)
        #expect(document.session.changeCount==count && document.session.undoStack.undoCommands.count==depth)
        #expect(document.session.document.body(with:body.id)?.render==render)
        #expect(document.session.document.body(with:body.id)?.uvData==uvData)
        #expect(try Data(contentsOf:source)==bytes)
    }
}
#endif
