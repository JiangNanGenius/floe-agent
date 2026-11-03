import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Actual native VM -> bound parameter handler -> exact graph/undo/storage.
/// These tests are supplied, not run by this UI source lane. No fake service
/// replies, fake meshes or success-string geometry assertions are used.
@MainActor final class CADLoftSurfaceNativeEntryTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("LoftSurfaceNative-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func fixture() async throws -> (FloeCADDocument,EditorViewModel) {
        let document=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Native inputs")
        documents.append(document)
        let model=EditorViewModel(session:document.session)
        model.datumActionHandler={ action,args in CADParameterService(document:document).handle(action:action,args:args) }
        return (document,model)
    }
    private func rings(_ document: FloeCADDocument) -> [CADLoftSectionChoice] {
        for z in [0.0,5.0,10.0] {
            let sketch=Sketch(name:"Ring \(z)",plane:SketchPlane(origin:SIMD3(0,0,z),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0)),
                entities:[.circle(id:UUID(),center:.zero,radius:5),.circle(id:UUID(),center:.zero,radius:2)])
            document.session.perform(AddSketchCommand(sketch:sketch))
        }
        return CADLoftSurfaceUIModel.closedSections(sketches:document.session.document.sketches).filter { !$0.holes.isEmpty }
    }
    private func openLines(_ document: FloeCADDocument,a: SIMD2<Double> = .zero,
                           b: SIMD2<Double> = SIMD2(20,0),height: Double = 10) -> [SweepPathDefinition] {
        [0.0,height].map { z in
            let id=UUID(),sketch=Sketch(plane:SketchPlane(origin:SIMD3(0,0,z),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0)),
                entities:[.line(id:id,a:a,b:b)])
            document.session.perform(AddSketchCommand(sketch:sketch))
            return SweepPathDefinition(segments:[.init(sketchID:sketch.id,entityID:id)])
        }
    }
    func testNativeLoftDraftPreviewCommitAndHistoryReorderUseOneTransaction() async throws {
        let (doc,model)=try await fixture(),choices=rings(doc)
        XCTAssertEqual(choices.count,3)
        let first=try XCTUnwrap(choices.first),depth=doc.session.undoStack.undoCommands.count
        model.toolContext=EditorViewModel.ToolContext(profile:first.profile,holes:first.holes,plane:first.plane,
            sketchID:first.reference.sketchID,sourceBody:nil,kind:.loft,booleanOverride:.newBody)
        model.mode = .pickingLoftProfiles
        model.beginLoftSurfaceEditor(.draftLoft)
        XCTAssertNotNil(model.loftSurfaceEditor)
        XCTAssertTrue(model.configureNativeLoftDraft(sections:choices.map(\.reference),ruled:true,expectedChangeCount:doc.session.changeCount))
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth,"Sheet draft must not commit history.")
        let preview=try XCTUnwrap(model.toolContext?.preview?.brep)
        XCTAssertEqual(OCCTKernel.volume(preview),210 * .pi,accuracy:1e-3)
        model.commitTool()
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertEqual(doc.session.document.features.nodes.count,1)
        let node=try XCTUnwrap(doc.session.document.features.nodes.first),body=try XCTUnwrap(node.outputBodyIDs.first)
        guard case let .loft(sections,_,definition)=node.kind else { return XCTFail("Missing real Loft") }
        XCTAssertTrue(try XCTUnwrap(definition).ruled)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(doc.session.document.body(with:body)?.brep)),210 * .pi,accuracy:1e-3)
        XCTAssertTrue(model.beginReferenceEdit(node.id))
        if case let .loft(id)?=model.loftSurfaceEditor { XCTAssertEqual(id,node.id) } else { XCTFail("History did not open Loft settings") }
        let response=model.applyNativeLoftSettings(node.id,sections:Array(sections.reversed()),ruled:false,generation:doc.session.changeCount)
        XCTAssertEqual(response["ok"] as? Bool,true,"\(response)")
        XCTAssertEqual(doc.session.document.features.nodes.count,1)
        XCTAssertEqual(doc.session.document.features.node(node.id)?.outputBodyIDs,[body])
        doc.session.undo()
        guard case let .loft(restored,_,restoredDefinition)?=doc.session.document.features.node(node.id)?.kind else { return XCTFail("Missing undo") }
        XCTAssertEqual(restored,sections);XCTAssertTrue(try XCTUnwrap(restoredDefinition).ruled)
    }
    func testNativeLoftServiceFailureKeepsEarlierUndoAndRedoInsteadOfMeshFallback() async throws {
        let (doc,model)=try await fixture(),choices=rings(doc)
        let depth=doc.session.undoStack.undoCommands.count,bodyCount=doc.session.document.bodies.count
        var sections=choices.map(\.reference);sections[1].holeEntityIDs=[[UUID()]]
        let beforeSketches=doc.session.document.sketches
        let reply=model.performLoftSurfaceAction("loft.create",args:["sections":model.loftSurfaceJSON(sections),
            "definition":model.loftSurfaceJSON(LoftDefinition(ruled:true)),"expected_change_count":doc.session.changeCount])
        XCTAssertEqual(reply["ok"] as? Bool,false,"\(reply)")
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(doc.session.document.bodies.count,bodyCount)
        XCTAssertEqual(doc.session.document.sketches,beforeSketches)
        XCTAssertTrue(doc.session.document.features.nodes.isEmpty)
        doc.session.undo()
        let redo=doc.session.undoStack.canRedo,undo=doc.session.undoStack.undoCommands.count
        let stale=model.performLoftSurfaceAction("loft.create",args:["sections":[],"expected_change_count":-1])
        XCTAssertEqual(stale["ok"] as? Bool,false)
        XCTAssertEqual(doc.session.undoStack.canRedo,redo);XCTAssertEqual(doc.session.undoStack.undoCommands.count,undo)
    }
    func testNativeCommitAfterDeletedHoleKeepsUserDeletionAndDraft() async throws {
        let (doc,model)=try await fixture(),choices=rings(doc)
        let first=try XCTUnwrap(choices.first)
        model.toolContext=EditorViewModel.ToolContext(profile:first.profile,holes:first.holes,plane:first.plane,
            sketchID:first.reference.sketchID,sourceBody:nil,kind:.loft,booleanOverride:.newBody)
        model.mode = .pickingLoftProfiles
        XCTAssertTrue(model.configureNativeLoftDraft(sections:choices.map(\.reference),ruled:true,expectedChangeCount:doc.session.changeCount))
        let middle=choices[1].reference,source=try XCTUnwrap(doc.session.document.sketches.first { $0.id == middle.sketchID })
        let deleted=Set(middle.holeEntityIDs.flatMap { $0 })
        doc.session.perform(RemoveSketchEntitiesCommand(ids:deleted,sketch:source))
        let depth=doc.session.undoStack.undoCommands.count
        model.commitTool()
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,depth,"A rejected commit may not undo the user's deletion.")
        XCTAssertTrue(doc.session.document.features.nodes.isEmpty)
        XCTAssertTrue(doc.session.document.bodies.isEmpty)
        let after=try XCTUnwrap(doc.session.document.sketches.first { $0.id == middle.sketchID })
        XCTAssertTrue(Set(after.entities.map(\.id)).isDisjoint(with:deleted))
        XCTAssertNotNil(model.toolContext,"The failed loft should remain editable.")
    }
    func testNativeSurfaceCreateTrimInspectThickenEditAndStaleApplyPreserveIdentity() async throws {
        let (doc,model)=try await fixture(),paths=openLines(doc)
        XCTAssertTrue(model.canBeginNativeSurfaceEditor)
        model.beginLoftSurfaceEditor(.surface(nil))
        let created=model.applyNativeSurface(CADSurfaceDefinition(operation:.loft,sections:paths,ruled:true),
            editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(created["ok"] as? Bool,true,"\(created)")
        let first=try XCTUnwrap(doc.session.document.features.nodes.first),body=try XCTUnwrap(first.outputBodyIDs.first)
        let snapshot=model.loftSurfaceUISnapshot(),source=try XCTUnwrap(snapshot.sources.first)
        XCTAssertTrue(source.valid);XCTAssertFalse(source.closed)
        let domain=try XCTUnwrap(source.domain)
        let trim=try CADLoftSurfaceUIModel.trim(domain:domain,across:25...75,along:25...75)
        let trimmed=model.applyNativeSurface(CADSurfaceDefinition(operation:.trim,sources:[source.reference],trim:trim),
            editing:nil,generation:snapshot.generation)
        XCTAssertEqual(trimmed["ok"] as? Bool,true,"\(trimmed)")
        let input=try XCTUnwrap(model.loftSurfaceUISnapshot().sources.first)
        let thickened=model.applyNativeSurface(CADSurfaceDefinition(operation:.thicken,sources:[input.reference],thickness:2),
            editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(thickened["ok"] as? Bool,true,"\(thickened)")
        let node=try XCTUnwrap(doc.session.document.features.nodes.last)
        XCTAssertEqual(node.outputBodyIDs,[body]);XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(doc.session.document.body(with:body)?.brep)),100,accuracy:1e-5)
        XCTAssertTrue(model.beginReferenceEdit(node.id))
        let editInputs=model.loftSurfaceUISnapshot(before:node.id)
        XCTAssertTrue(try XCTUnwrap(editInputs.sources.first).valid,"Edit must inspect the original surface, not its thickened solid output.")
        let inspectedInput=model.performLoftSurfaceAction("surface.inspect",args:["body_id":body.raw.uuidString,"before_feature_id":node.id.raw.uuidString])
        XCTAssertEqual(inspectedInput["scope"] as? String,"featureInput")
        XCTAssertEqual(inspectedInput["quality"] as? String,"exactBRepSurface")
        XCTAssertEqual(inspectedInput["authoring_input"] as? Bool,true)

        let beforeDepth=doc.session.undoStack.undoCommands.count, count=doc.session.document.features.nodes.count
        let updated=model.applyNativeSurface(CADSurfaceDefinition(operation:.thicken,sources:[input.reference],thickness:3),
            editing:node.id,generation:editInputs.generation)
        XCTAssertEqual(updated["ok"] as? Bool,true,"\(updated)")
        XCTAssertEqual(doc.session.document.features.nodes.count,count)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,beforeDepth+1)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(doc.session.document.body(with:body)?.brep)),150,accuracy:1e-5)
        let stale=model.applyNativeSurface(CADSurfaceDefinition(operation:.thicken,sources:[input.reference],thickness:4),
            editing:node.id,generation:editInputs.generation)
        XCTAssertEqual(stale["ok"] as? Bool,false)
        XCTAssertEqual(doc.session.undoStack.undoCommands.count,beforeDepth+1)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(doc.session.document.body(with:body)?.brep)),150,accuracy:1e-5)
    }
    func testNativeSourceUsesActualTransformWriterAndWorldTrimDomain() async throws {
        let (doc,model)=try await fixture(),paths=openLines(doc)
        let response=model.applyNativeSurface(CADSurfaceDefinition(operation:.loft,sections:paths,ruled:true),
            editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(response["ok"] as? Bool,true,"\(response)")
        let original=try XCTUnwrap(doc.session.document.features.nodes.first),body=try XCTUnwrap(original.outputBodyIDs.first)
        let transform=FeatureNode(name:"Placement",kind:.transform(body:.init(producer:original.id,bodyID:body),
            delta:Transform3D(translation:SIMD3(4,5,6),scale:2)),outputBodyIDs:[])
        XCTAssertTrue(doc.session.performAssociativeTransaction([AppendFeatureCommand(node:transform)],title:"Placement"))
        let snapshot=model.loftSurfaceUISnapshot(),source=try XCTUnwrap(snapshot.sources.first)
        XCTAssertEqual(source.reference.producer,transform.id,"Use the successful writer even when its declared output array is empty.")
        let inspect=model.performLoftSurfaceAction("surface.inspect",args:["body_id":body.raw.uuidString])
        XCTAssertEqual(inspect["authoring_input"] as? Bool,true)
        let sourceData=try JSONSerialization.data(withJSONObject:try XCTUnwrap(inspect["source"]))
        XCTAssertEqual(try JSONDecoder().decode(BodyRef.self,from:sourceData),source.reference)

        XCTAssertTrue(source.canTrim);XCTAssertFalse(source.canPatch,"A flat sheet is not a planar opening to cap.")
        let trim=try CADLoftSurfaceUIModel.trim(domain:try XCTUnwrap(source.domain),across:25...75,along:25...75)
        let trimmed=model.applyNativeSurface(CADSurfaceDefinition(operation:.trim,sources:[source.reference],trim:trim),
            editing:nil,generation:snapshot.generation)
        XCTAssertEqual(trimmed["ok"] as? Bool,true,"\(trimmed)")
        let input=try XCTUnwrap(model.loftSurfaceUISnapshot().sources.first)
        let thick=model.applyNativeSurface(CADSurfaceDefinition(operation:.thicken,sources:[input.reference],thickness:2),
            editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(thick["ok"] as? Bool,true,"\(thick)")
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(doc.session.document.body(with:body)?.brep)),400,accuracy:1e-4)
    }
    func testLegacyNilLoftRoundTripKeepsMeshMeaningUntilExplicitSameFeatureEdit() async throws {
        let (doc,model)=try await fixture(),choices=rings(doc)
        let floor=CADDocumentFormat.requiredFormat(document:doc.session.document)
        let body=BodyID(),node=FeatureNode(name:"Legacy ring",kind:.loft(sections:choices.map(\.reference),
            boolean:BooleanIntent(op:.newBody,resolvedTargets:[])),outputBodyIDs:[body])
        XCTAssertTrue(doc.session.performAssociativeTransaction([AppendFeatureCommand(node:node)],title:"Legacy fixture"))
        let legacy=try XCTUnwrap(doc.session.document.body(with:body))
        XCTAssertNil(legacy.brep);XCTAssertNil(legacy.surfaceBRep)
        XCTAssertFalse(legacy.render.positions.isEmpty)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:doc.session.document),floor)
        let url=doc.url,saved=await doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "");doc.close()
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        guard case let .loft(sections,_,definition)?=reopened.session.document.features.node(node.id)?.kind else { return XCTFail("Lost legacy kind") }
        XCTAssertNil(definition);XCTAssertNil(reopened.session.document.body(with:body)?.brep)
        let response=CADParameterService(document:reopened).handle(action:"loft.update",args:[
            "feature_id":node.id.raw.uuidString,"changes":["sections":model.loftSurfaceJSON(Array(sections.reversed()))]])
        XCTAssertEqual(response["ok"] as? Bool,true,"\(response)")
        guard case let .loft(_,_,upgraded)?=reopened.session.document.features.node(node.id)?.kind else { return XCTFail("Lost edited kind") }
        XCTAssertEqual(try XCTUnwrap(upgraded).version,1)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(reopened.session.document.body(with:body)?.brep)),210 * .pi,accuracy:1e-3)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),max(floor,7))
        reopened.session.undo()
        guard case let .loft(_,_,restored)?=reopened.session.document.features.node(node.id)?.kind else { return XCTFail("Lost legacy undo") }
        XCTAssertNil(restored);XCTAssertNil(reopened.session.document.body(with:body)?.brep)
    }
    func testClosedSurfaceThicknessCreatesRealCavityInsteadOfReturningOriginalSolid() async throws {
        let (doc,model)=try await fixture()
        let corners=[SIMD2<Double>(0,0),SIMD2(20,0),SIMD2(20,10),SIMD2(0,10)]
        for index in corners.indices {
            let reply=model.applyNativeSurface(CADSurfaceDefinition(operation:.loft,
                sections:openLines(doc,a:corners[index],b:corners[(index+1)%4],height:30),ruled:true),
                editing:nil,generation:doc.session.changeCount)
            XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        }
        let sources=model.loftSurfaceUISnapshot().sources.map(\.reference)
        let sewn=model.applyNativeSurface(CADSurfaceDefinition(operation:.sew,sources:sources),editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(sewn["ok"] as? Bool,true,"\(sewn)")
        let open=try XCTUnwrap(model.loftSurfaceUISnapshot().sources.first)
        XCTAssertTrue(open.canPatch)
        let patched=model.applyNativeSurface(CADSurfaceDefinition(operation:.patch,sources:[open.reference]),editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(patched["ok"] as? Bool,true,"\(patched)")
        let closed=try XCTUnwrap(model.loftSurfaceUISnapshot().sources.first)
        XCTAssertTrue(closed.closed)
        let thickened=model.applyNativeSurface(CADSurfaceDefinition(operation:.thicken,sources:[closed.reference],thickness:-1),
            editing:nil,generation:doc.session.changeCount)
        XCTAssertEqual(thickened["ok"] as? Bool,true,"\(thickened)")
        let solid=try XCTUnwrap(doc.session.document.body(with:closed.id)?.brep)
        let health=OCCTKernel.healthReport(for:solid)
        XCTAssertTrue(health.isValid,health.findingsSummary);XCTAssertEqual(health.counts["solids"],1)
        XCTAssertEqual(health.counts["shells"],2,"Outer and inner boundaries are required for a cavity.")
        XCTAssertEqual(OCCTKernel.volume(solid),20*10*30 - 18*8*28,accuracy:1e-3)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(solid)["free_edges"] as? Int,0)
    }
    func testSectionAndEdgeOrderingAndUnsupportedOptionsStayOutOfNativeChoices() async throws {
        let (doc,model)=try await fixture(),paths=openLines(doc)
        let snapshot=model.loftSurfaceUISnapshot()
        XCTAssertEqual(snapshot.openEdges.count,2)
        XCTAssertEqual(CADLoftSurfaceUIModel.operations(openEdges:snapshot.openEdges,sources:[]).map(\.rawValue),["loft"])
        let rows=paths.map { CADSurfaceSectionRow(path:$0) },moved=CADLoftSurfaceUIModel.moved(rows,from:0,by:1)
        XCTAssertEqual(moved.map(\.id),rows.reversed().map(\.id))
        XCTAssertEqual(moved.map { $0.path.segments },Array(rows.reversed()).map { $0.path.segments })
        let reply=model.performLoftSurfaceAction("surface.catalog",args:[:])
        XCTAssertEqual(reply["operations"] as? [String],["loft","trim","patch","sew","thicken"])
        XCTAssertFalse((reply["operations"] as? [String] ?? []).contains("guides"))
    }
}
