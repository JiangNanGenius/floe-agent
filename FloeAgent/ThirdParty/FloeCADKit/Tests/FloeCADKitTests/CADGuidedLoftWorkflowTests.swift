import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Real OCCT expectations. Source supplied only; no test was run by this lane.
/// A curved auxiliary rail must succeed in the real Contact builder and pass
/// actual-face residual gates; no fake native callback supplies geometry.
@MainActor final class CADGuidedLoftWorkflowTests:XCTestCase {
    private var directory:URL!
    private var documents:[FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("GuidedLoft-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        #if DEBUG
        CADLoftSurfaceService.testBeforeGuidedPrepare=nil;CADLoftSurfaceService.testAfterGuidedPrepare=nil
        #endif
        for doc in documents where !doc.isClosed { doc.close() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private func json<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    private struct Inputs {
        var doc:FloeCADDocument
        var sections:[ProfileRef]
        var bow:SweepPathDefinition
        var straight:SweepPathDefinition
    }
    private func fixture(middle:Bool=false) async throws -> Inputs {
        let doc=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Actual guided sections")
        documents.append(doc)
        for z in (middle ? [0.0,5.0,10.0] : [0.0,10.0]) {
            let radius=z == 5 ? 6.5 : 6.0,angle=acos(5/radius)
            let plane=SketchPlane(origin:SIMD3(0,0,z),xAxis:SIMD3(cos(angle),sin(angle),0),yAxis:SIMD3(-sin(angle),cos(angle),0))
            let sketch=Sketch(name:"Section \(z)",plane:plane,entities:[.rect(id:UUID(),min:SIMD2(-5,-5),max:SIMD2(5,5))])
            doc.session.perform(AddSketchCommand(sketch:sketch))
        }
        let sections=CADLoftSurfaceUIModel.closedSections(sketches:doc.session.document.sketches).map(\.reference)
        let a=UUID(),b=UUID(),angle=atan2(5.0,24.75)
        let rail=Sketch(name:"Rail",plane:SketchPlane(origin:.zero,xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,0,1)),entities:[
            .arc(id:a,center:SIMD2(-18.75,5),radius:25.25,startAngle:-angle,endAngle:angle),
            .line(id:b,a:SIMD2(6,0),b:SIMD2(6,10))])
        doc.session.perform(AddSketchCommand(sketch:rail))
        return Inputs(doc:doc,sections:sections,bow:.init(segments:[.init(sketchID:rail.id,entityID:a)]),straight:.init(segments:[.init(sketchID:rail.id,entityID:b)]))
    }
    private func create(_ input:Inputs,guide:SweepPathDefinition?) async throws -> FeatureNode {
        let reply=await CADParameterService(document:input.doc).handleAsync(action:"loft.create",args:[
            "sections":try json(input.sections),"definition":try json(LoftDefinition(guides:guide.map { [$0] } ?? [])),
            "expected_change_count":input.doc.session.changeCount])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        return try XCTUnwrap(input.doc.session.document.features.nodes.last)
    }
    private func body(_ input:Inputs,_ node:FeatureNode,expectedVolume:Double?=1000) throws -> BRepHandle {
        let id=try XCTUnwrap(node.outputBodyIDs.first),body=try XCTUnwrap(input.doc.session.document.body(with:id))
        XCTAssertNil(body.surfaceBRep)
        let solid=try XCTUnwrap(body.brep),health=OCCTKernel.healthReport(for:solid)
        XCTAssertTrue(health.isValid,health.findingsSummary);XCTAssertEqual(health.counts["solids"],1)
        XCTAssertEqual(OCCTKernel.surfaceDiagnostics(solid)["free_edges"] as? Int,0)
        if let expectedVolume { XCTAssertEqual(OCCTKernel.volume(solid),expectedVolume,accuracy:0.02) }
        else { XCTAssertGreaterThan(OCCTKernel.volume(solid),0) }
        return solid
    }
    func testCurvedGuideReplacementAndOrderRebuildSameFeatureWithOneUndo() async throws {
        let input=try await fixture(),node=try await create(input,guide:nil)
        let before=try XCTUnwrap(OCCTKernel.serialize(body(input,node))),depth=input.doc.session.undoStack.undoCommands.count
        let model=input.doc.viewModel()
        XCTAssertTrue(model.beginReferenceEdit(node.id))
        let changed=await model.applyNativeGuidedLoftSettings(node.id,sections:input.sections,
            definition:LoftDefinition(guides:[input.bow]),generation:input.doc.session.changeCount)
        XCTAssertEqual(changed["ok"] as? Bool,true,"\(changed)")
        XCTAssertEqual(changed["exactness"] as? String,"nativeToleranceBRep")
        let report=try XCTUnwrap(changed["guided_validation"] as? [String:Any])
        XCTAssertEqual(report["retained_section_count"] as? Int,2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["native_surface_error_mm"] as? Double),1e-5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["guide_sample_max_deviation_mm"] as? Double),2e-5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report["guide_sample_count"] as? Int),33)
        let bowed=try XCTUnwrap(OCCTKernel.serialize(body(input,node)))
        XCTAssertNotEqual(bowed,before,"An actually curved guide must change the generated boundary.")
        XCTAssertEqual(input.doc.session.document.features.nodes.count,1)
        XCTAssertEqual(input.doc.session.document.features.node(node.id)?.outputBodyIDs,node.outputBodyIDs)
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth+1)
        input.doc.session.undo();XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(body(input,node))),before)
        input.doc.session.redo();_=try body(input,node)
        let flat=await model.applyNativeGuidedLoftSettings(node.id,sections:input.sections,
            definition:LoftDefinition(guides:[input.straight]),generation:input.doc.session.changeCount)
        XCTAssertEqual(flat["ok"] as? Bool,true,"\(flat)")
        let straight=try XCTUnwrap(OCCTKernel.serialize(body(input,node)))
        XCTAssertNotEqual(straight,bowed)
        var reversed=input.straight;reversed.segments.reverse()
        reversed.segments=reversed.segments.map { var s=$0;s.reversed.toggle();return s }
        let reordered=await model.applyNativeGuidedLoftSettings(node.id,sections:Array(input.sections.reversed()),
            definition:LoftDefinition(guides:[reversed]),generation:input.doc.session.changeCount)
        XCTAssertEqual(reordered["ok"] as? Bool,true,"\(reordered)");_=try body(input,node)
        XCTAssertEqual(input.doc.session.document.features.nodes.count,1)
    }
    func testThreeActualSectionsAreRetainedAndGuideMeetsTheMiddleSection() async throws {
        let input=try await fixture(middle:true),node=try await create(input,guide:input.bow)
        _=try body(input,node,expectedVolume:nil)
        let described=CADParameterService(document:input.doc).handle(action:"loft.describe",args:["feature_id":node.id.raw.uuidString])
        let report=try XCTUnwrap(described["guided_validation"] as? [String:Any])
        XCTAssertEqual(report["retained_section_count"] as? Int,3,"ContactOnBorder would retain only the last profile; that mode is forbidden.")
        XCTAssertGreaterThan(try XCTUnwrap(report["section_sample_count"] as? Int),3*8)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report["section_sample_max_deviation_mm"] as? Double),2e-5)
    }
    func testIncompatibleGuideAndGuideEndpointCombinationsRejectAtomically() async throws {
        let input=try await fixture(middle:true),node=try await create(input,guide:input.bow)
        let before=try XCTUnwrap(OCCTKernel.serialize(body(input,node,expectedVolume:nil))),depth=input.doc.session.undoStack.undoCommands.count
        let service=CADParameterService(document:input.doc)
        let bad=await service.handleAsync(action:"loft.update",args:["feature_id":node.id.raw.uuidString,
            "changes":["definition":try json(LoftDefinition(guides:[input.straight]))]])
        XCTAssertEqual(bad["ok"] as? Bool,false,"The straight guide misses the rotated middle section boundary.")
        let endpoint=LoftDefinition.BoundaryConstraint(tangent:PointWrapper(SIMD3(0,0,1)),curvature:PointWrapper(.zero),angularTolerance:1e-3,curvatureTolerance:1e-3)
        for definition in [LoftDefinition(guides:[input.bow,input.straight]),LoftDefinition(guides:[input.bow],start:endpoint),LoftDefinition(guides:[input.bow],end:endpoint)] {
            let refused=await service.handleAsync(action:"loft.update",args:["feature_id":node.id.raw.uuidString,"changes":["definition":try json(definition)]])
            XCTAssertEqual(refused["ok"] as? Bool,false,"A guide/endpoint combination must reject instead of ignoring either constraint.")
        }
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(body(input,node,expectedVolume:nil))),before)
        XCTAssertEqual(input.doc.session.document.features.nodes.count,1)
    }
    #if DEBUG
    func testChangedOwnerAfterNativePreparationDropsResultWithoutUndoingUserEdit() async throws {
        let input=try await fixture(),node=try await create(input,guide:nil)
        let before=try XCTUnwrap(OCCTKernel.serialize(body(input,node))),depth=input.doc.session.undoStack.undoCommands.count
        CADLoftSurfaceService.testAfterGuidedPrepare={
            input.doc.session.perform(AddSketchCommand(sketch:Sketch(name:"User edit during native phase",plane:.ground,entities:[])))
        }
        let reply=await CADParameterService(document:input.doc).handleAsync(action:"loft.update",args:["feature_id":node.id.raw.uuidString,
            "changes":["definition":try json(LoftDefinition(guides:[input.bow]))]])
        CADLoftSurfaceService.testAfterGuidedPrepare=nil
        XCTAssertEqual(reply["error"] as? String,"stale_feature")
        XCTAssertTrue(input.doc.session.document.sketches.contains { $0.name == "User edit during native phase" })
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth+1,"Keep the real intervening user edit.")
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(body(input,node))),before)
    }
    func testCancelledPrepareIsJoinedAndCannotPublishOrConsumeHistory() async throws {
        let input=try await fixture(),node=try await create(input,guide:nil)
        let depth=input.doc.session.undoStack.undoCommands.count,before=try XCTUnwrap(OCCTKernel.serialize(body(input,node)))
        let entered=XCTestExpectation(description:"Serial native worker entered"),release=DispatchSemaphore(value:0)
        CADLoftSurfaceService.testBeforeGuidedPrepare={ entered.fulfill();_ = release.wait(timeout:.now()+30) }
        let args:[String:Any]=["feature_id":node.id.raw.uuidString,"changes":["definition":try json(LoftDefinition(guides:[input.bow]))]]
        let task=Task { @MainActor in await CADParameterService(document:input.doc).handleAsync(action:"loft.update",args:args) }
        await fulfillment(of:[entered],timeout:10)
        task.cancel();release.signal()
        let reply=await task.value
        CADLoftSurfaceService.testBeforeGuidedPrepare=nil
        XCTAssertEqual(reply["error"] as? String,"guided_loft_cancelled")
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(try XCTUnwrap(OCCTKernel.serialize(body(input,node))),before)
    }
    #endif
    func testGuidedDefinitionAndActualSolidSaveReopenWithoutMeshPromotion() async throws {
        let input=try await fixture(),node=try await create(input,guide:input.bow)
        _=try body(input,node)
        let url=input.doc.url,saved=await input.doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        input.doc.close()
        #if DEBUG
        CADGuidedLoftStore.shared.discardForTests()
        #endif
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        let restored=try XCTUnwrap(reopened.session.document.features.node(node.id))
        guard case let .loft(sections,_,definition)=restored.kind else { return XCTFail("Lost native Loft") }
        XCTAssertEqual(sections.count,2);XCTAssertEqual(definition?.guides,[input.bow])
        XCTAssertEqual(restored.outputBodyIDs,node.outputBodyIDs)
        let id=try XCTUnwrap(node.outputBodyIDs.first),body=try XCTUnwrap(reopened.session.document.body(with:id))
        XCTAssertNotNil(body.brep);XCTAssertNil(body.surfaceBRep)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep)),1000,accuracy:0.02)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
        let rebuilt=await CADParameterService(document:reopened).handleAsync(action:"loft.update",args:["feature_id":node.id.raw.uuidString,
            "changes":["definition":try json(LoftDefinition(guides:[input.straight]))]])
        XCTAssertEqual(rebuilt["ok"] as? Bool,true,"\(rebuilt)")
        XCTAssertEqual(reopened.session.document.features.nodes.last?.id,node.id)
    }
}
