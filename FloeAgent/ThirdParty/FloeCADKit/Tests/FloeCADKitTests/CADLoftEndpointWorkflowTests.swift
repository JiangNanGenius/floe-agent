import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Actual OCCT BReps + independent delivered-surface derivative/finite-
/// difference oracle. This lane supplies source, not executed native evidence.
@MainActor final class CADLoftEndpointWorkflowTests:XCTestCase {
    private var directory:URL!
    private var documents:[FloeCADDocument]=[]
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent("EndpointLoft-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        #if DEBUG
        CADLoftSurfaceService.testBeforeGuidedPrepare=nil;CADLoftSurfaceService.testAfterGuidedPrepare=nil
        #endif
        for document in documents where !document.isClosed { document.close() }
        if let directory { try? FileManager.default.removeItem(at:directory) }
    }
    private struct Inputs { var doc:FloeCADDocument;var sections:[ProfileRef] }
    private func fixture(count:Int=2,holes:Bool=false,circles:Bool=false) async throws -> Inputs {
        let doc=try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Constrained native loft")
        documents.append(doc)
        for index in 0..<count {
            let plane=SketchPlane(origin:SIMD3(0,0,10*Double(index)/Double(count-1)),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0))
            var entities:[SketchEntity]=circles ? [.circle(id:UUID(),center:.zero,radius:5)]:[.rect(id:UUID(),min:SIMD2(-5,-5),max:SIMD2(5,5))]
            if holes { entities.append(circles ? .circle(id:UUID(),center:.zero,radius:1):.rect(id:UUID(),min:SIMD2(-1,-1),max:SIMD2(1,1))) }
            doc.session.perform(AddSketchCommand(sketch:Sketch(name:"Section \(index)",plane:plane,entities:entities)))
        }
        // A nested rectangle's outer-loop choice explicitly carries its hole.
        let choices=CADLoftSurfaceUIModel.closedSections(sketches:doc.session.document.sketches)
        let refs=doc.session.document.sketches.compactMap { sketch in
            choices.filter { $0.reference.sketchID==sketch.id }.max { $0.profile.area < $1.profile.area }?.reference
        }
        XCTAssertEqual(refs.count,count)
        if holes { XCTAssertTrue(refs.allSatisfy { $0.holeEntityIDs.count==1 }) }
        return Inputs(doc:doc,sections:refs)
    }
    private func boundary(_ tangent:SIMD3<Double>=SIMD3(0,0,1),_ curvature:SIMD3<Double>?=nil) -> LoftDefinition.BoundaryConstraint {
        .init(tangent:PointWrapper(tangent),curvature:curvature.map(PointWrapper.init),angularTolerance:1e-5,curvatureTolerance:1e-6)
    }
    private func json<T:Encodable>(_ value:T) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    private func create(_ input:Inputs,_ definition:LoftDefinition=LoftDefinition()) async throws -> FeatureNode {
        let reply=await CADParameterService(document:input.doc).handleAsync(action:"loft.create",args:["sections":try json(input.sections),"definition":try json(definition)])
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        return try XCTUnwrap(input.doc.session.document.features.nodes.last)
    }
    private func native(_ input:Inputs,_ node:FeatureNode) throws -> BRepHandle {
        let id=try XCTUnwrap(node.outputBodyIDs.first),body=try XCTUnwrap(input.doc.session.document.body(with:id)),solid=try XCTUnwrap(body.brep)
        XCTAssertNil(body.surfaceBRep)
        let health=OCCTKernel.healthReport(for:solid);XCTAssertTrue(health.isValid,health.findingsSummary)
        XCTAssertEqual(health.counts["solids"],1);XCTAssertEqual(OCCTKernel.surfaceDiagnostics(solid)["free_edges"] as? Int,0)
        XCTAssertGreaterThan(OCCTKernel.volume(solid),0)
        return solid
    }
    private func vector(_ row:[String:Any],_ key:String) throws -> SIMD3<Double> {
        let array=try XCTUnwrap(row[key] as? [Double]);XCTAssertEqual(array.count,3)
        return SIMD3(array[0],array[1],array[2])
    }
    private func assertBoundary(_ solid:BRepHandle,start:LoftDefinition.BoundaryConstraint?,end:LoftDefinition.BoundaryConstraint?,file:StaticString=#filePath,line:UInt=#line) throws {
        let rows=try XCTUnwrap(OCCTKernel.endpointLoftJets(solid)["jets"] as? [[String:Any]])
        XCTAssertGreaterThanOrEqual(rows.count,5*17,file:file,line:line)
        for (side,constraint) in [start,end].enumerated() {
            guard let constraint else { continue }
            let boundaryRows=rows.filter { $0["side"] as? Int==side };XCTAssertGreaterThanOrEqual(boundaryRows.count,17)
            for row in boundaryRows {
                let d1=try vector(row,"d1"),d2=try vector(row,"d2"),fd1=try vector(row,"finite_d1"),fd2=try vector(row,"finite_d2")
                let angle=atan2(simd_length(simd_cross(d1,constraint.tangent.point)),simd_dot(d1,constraint.tangent.point))
                XCTAssertLessThanOrEqual(angle,constraint.angularTolerance,file:file,line:line)
                // Independently differentiate delivered surface positions.
                XCTAssertLessThan(simd_length(fd1-d1),0.001,file:file,line:line)
                XCTAssertLessThan(simd_length(fd2-d2),0.02,file:file,line:line)
                if let expected=constraint.curvature?.point {
                    let actual=(d2-d1*(simd_dot(d1,d2)/simd_length_squared(d1)))/simd_length_squared(d1)
                    let finite=(fd2-fd1*(simd_dot(fd1,fd2)/simd_length_squared(fd1)))/simd_length_squared(fd1)
                    XCTAssertLessThanOrEqual(simd_length(actual-expected),constraint.curvatureTolerance,file:file,line:line)
                    XCTAssertLessThan(simd_length(finite-expected),0.0003,file:file,line:line)
                }
            }
        }
    }
    private func update(_ input:Inputs,_ node:FeatureNode,_ definition:LoftDefinition,sections:[ProfileRef]?=nil) async throws -> [String:Any] {
        return await input.doc.viewModel().applyNativeGuidedLoftSettings(node.id,sections:sections ?? input.sections,definition:definition,generation:input.doc.session.changeCount)
    }
    func testStartAndEndDirectionsActuallyChangeSameFeatureAndOneUndo() async throws {
        let input=try await fixture(),node=try await create(input),before=try XCTUnwrap(OCCTKernel.serialize(native(input,node)))
        let depth=input.doc.session.undoStack.undoCommands.count
        let definition=LoftDefinition(start:boundary(SIMD3(0.2,0,1)),end:boundary(SIMD3(-0.1,0,1)))
        let reply=try await update(input,node,definition);XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
        let solid=try native(input,node);try assertBoundary(solid,start:definition.start,end:definition.end)
        XCTAssertNotEqual(OCCTKernel.serialize(solid),before)
        XCTAssertEqual(input.doc.session.document.features.nodes.count,1);XCTAssertEqual(input.doc.session.document.features.nodes[0].id,node.id)
        XCTAssertEqual(input.doc.session.document.features.nodes[0].outputBodyIDs,node.outputBodyIDs)
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth+1)
        input.doc.session.undo();XCTAssertEqual(OCCTKernel.serialize(try native(input,node)),before)
        input.doc.session.redo();try assertBoundary(native(input,node),start:definition.start,end:definition.end)
    }
    func testNonzeroStartAndEndNormalCurvatureAreGeneratedNotFiltered() async throws {
        let input=try await fixture(),a=boundary(SIMD3(0,0,1),SIMD3(0.02,0,0)),b=boundary(SIMD3(0,0,1),SIMD3(-0.01,0,0))
        let node=try await create(input,LoftDefinition(start:a,end:b)),solid=try native(input,node)
        try assertBoundary(solid,start:a,end:b)
        XCTAssertEqual(OCCTKernel.volume(solid),1000,accuracy:0.02)
        let reply=CADParameterService(document:input.doc).handle(action:"loft.describe",args:["feature_id":node.id.raw.uuidString])
        let reports=try XCTUnwrap(reply["endpoint_validation"] as? [[String:Any]]);XCTAssertEqual(reports.count,1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(reports[0]["whole_boundary_angle_bound_rad"] as? Double),a.angularTolerance)
        XCTAssertLessThanOrEqual(try XCTUnwrap(reports[0]["whole_boundary_curvature_bound_per_mm"] as? Double),a.curvatureTolerance)
        let changed=LoftDefinition(start:boundary(SIMD3(0,0,1),SIMD3(-0.02,0,0)),end:b)
        let before=try XCTUnwrap(OCCTKernel.serialize(solid)),response=try await update(input,node,changed)
        XCTAssertEqual(response["ok"] as? Bool,true,"\(response)");XCTAssertNotEqual(OCCTKernel.serialize(try native(input,node)),before)
        try assertBoundary(native(input,node),start:changed.start,end:b)
    }
    func testZeroCurvatureAndPairedInnerLoopRemainExactClosedSolid() async throws {
        let input=try await fixture(holes:true),zero=boundary(SIMD3(0,0,1),.zero)
        let node=try await create(input,LoftDefinition(start:zero,end:zero)),solid=try native(input,node)
        XCTAssertEqual(OCCTKernel.volume(solid),960,accuracy:0.02)
        try assertBoundary(solid,start:zero,end:zero)
    }
    func testRationalConicSectionsKeepCircleAndInnerLoopPrecision() async throws {
        let input=try await fixture(holes:true,circles:true),zero=boundary(SIMD3(0,0,1),.zero)
        let node=try await create(input,LoftDefinition(start:zero,end:zero)),solid=try native(input,node)
        XCTAssertEqual(OCCTKernel.volume(solid),240*Double.pi,accuracy:1e-5)
        try assertBoundary(solid,start:zero,end:zero)
        let rows=try XCTUnwrap(OCCTKernel.endpointLoftJets(solid)["jets"] as? [[String:Any]])
        for row in rows where (row["side"] as? Int ?? -1)>=0 {
            let point=try vector(row,"point"),radius=hypot(point.x,point.y)
            XCTAssertTrue(abs(radius-5)<1e-8 || abs(radius-1)<1e-8,"Native rational conics must remain on the authored circles")
        }
    }
    func testReplacingAnEndpointSectionRebuildsAndIncompatibleTopologyRefuses() async throws {
        let input=try await fixture(),zero=boundary(SIMD3(0,0,1),.zero)
        let node=try await create(input,LoftDefinition(start:zero,end:zero))
        let plane=SketchPlane(origin:SIMD3(0,0,10),xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0))
        let replacement=Sketch(name:"Replacement",plane:plane,entities:[.rect(id:UUID(),min:SIMD2(-4,-4),max:SIMD2(4,4))])
        let triangle=Sketch(name:"Incompatible",plane:plane,entities:[.polygon(id:UUID(),center:.zero,radius:4,sides:3,rotation:0)])
        input.doc.session.perform(AddSketchCommand(sketch:replacement));input.doc.session.perform(AddSketchCommand(sketch:triangle))
        let choices=CADLoftSurfaceUIModel.closedSections(sketches:input.doc.session.document.sketches)
        let ref=try XCTUnwrap(choices.first { $0.reference.sketchID==replacement.id }?.reference)
        let bad=try XCTUnwrap(choices.first { $0.reference.sketchID==triangle.id }?.reference)
        let definition=LoftDefinition(start:zero,end:zero)
        let changed=try await update(input,node,definition,sections:[input.sections[0],ref]);XCTAssertEqual(changed["ok"] as? Bool,true,"\(changed)")
        try assertBoundary(native(input,node),start:zero,end:zero)
        let before=try XCTUnwrap(OCCTKernel.serialize(native(input,node))),depth=input.doc.session.undoStack.undoCommands.count
        let refused=try await update(input,node,definition,sections:[input.sections[0],bad]);XCTAssertEqual(refused["ok"] as? Bool,false,"\(refused)")
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(OCCTKernel.serialize(try native(input,node)),before)
        XCTAssertEqual(input.doc.session.document.features.nodes[0].id,node.id)
    }
    func testThreeSectionsAndReorderRetainActualMiddleSectionAndIdentity() async throws {
        let input=try await fixture(count:3),zero=boundary(SIMD3(0,0,1),.zero)
        let node=try await create(input,LoftDefinition(start:zero,end:zero)),solid=try native(input,node)
        let rows=try XCTUnwrap(OCCTKernel.endpointLoftJets(solid)["jets"] as? [[String:Any]])
        let middle=rows.filter { $0["v_fraction"] as? Double==0.5 };XCTAssertEqual(middle.count,4*17)
        for row in middle { XCTAssertEqual(try vector(row,"point").z,5,accuracy:1e-6) }
        let reverse=boundary(SIMD3(0,0,-1),.zero)
        let reply=try await update(input,node,LoftDefinition(start:reverse,end:reverse),sections:Array(input.sections.reversed()))
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)");try assertBoundary(native(input,node),start:reverse,end:reverse)
        XCTAssertEqual(input.doc.session.document.features.nodes[0].id,node.id)
    }
    func testRejectedCurvatureAndGuideCombinationPreserveDocumentAndUndo() async throws {
        let input=try await fixture(),node=try await create(input),depth=input.doc.session.undoStack.undoCommands.count
        let before=try XCTUnwrap(OCCTKernel.serialize(native(input,node)))
        let invalid=boundary(SIMD3(0,0,1),SIMD3(0,0,0.1))
        let edge=SweepPathDefinition(segments:[.init(sketchID:input.sections[0].sketchID,entityID:input.sections[0].entityIDs[0])])
        for definition in [LoftDefinition(start:invalid),LoftDefinition(ruled:true,start:boundary()),LoftDefinition(guides:[edge],start:boundary())] {
            let reply=try await update(input,node,definition);XCTAssertEqual(reply["ok"] as? Bool,false,"\(reply)")
        }
        XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth);XCTAssertEqual(OCCTKernel.serialize(try native(input,node)),before)
        XCTAssertEqual(input.doc.session.document.features.nodes[0].id,node.id)
    }
    func testEndpointDefinitionActualBRepSaveReopenAndForcedRebuild() async throws {
        let input=try await fixture(holes:true),a=boundary(SIMD3(0,0,1),SIMD3(0.01,0,0)),b=boundary(SIMD3(0,0,1),.zero)
        let node=try await create(input,LoftDefinition(start:a,end:b)),url=input.doc.url
        let saved=await input.doc.save();XCTAssertTrue(saved.succeeded,saved.error ?? "");input.doc.close()
        #if DEBUG
        CADLoftEndpointStore.shared.discardForTests()
        #endif
        let reopened=try await FloeCADDocument.open(at:url);documents.append(reopened)
        let same=Inputs(doc:reopened,sections:input.sections),restored=try XCTUnwrap(reopened.session.document.features.node(node.id))
        XCTAssertEqual(restored.outputBodyIDs,node.outputBodyIDs);XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
        try assertBoundary(native(same,restored),start:a,end:b)
        let reply=try await update(same,restored,LoftDefinition(start:boundary(SIMD3(0,0,1),SIMD3(-0.01,0,0)),end:b))
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)")
    }
    #if DEBUG
    func testCancelledEndpointWorkerJoinsAndDiscardsWithoutHistory() async throws {
        let input=try await fixture(),node=try await create(input),depth=input.doc.session.undoStack.undoCommands.count
        let before=try XCTUnwrap(OCCTKernel.serialize(native(input,node))),entered=XCTestExpectation(description:"Endpoint worker"),release=DispatchSemaphore(value:0)
        CADLoftSurfaceService.testBeforeGuidedPrepare={ entered.fulfill();_ = release.wait(timeout:.now()+30) }
        let definition=LoftDefinition(start:boundary(SIMD3(0,0,1),SIMD3(0.015,0,0)))
        let service=CADParameterService(document:input.doc),args:[String:Any]=["feature_id":node.id.raw.uuidString,"changes":["definition":try json(definition)]]
        let task=Task { @MainActor () -> String? in
            let response=await service.handleAsync(action:"loft.update",args:args)
            return response["error"] as? String
        }
        await fulfillment(of:[entered],timeout:10);task.cancel();release.signal();let reply=await task.value
        CADLoftSurfaceService.testBeforeGuidedPrepare=nil
        XCTAssertEqual(reply,"guided_loft_cancelled");XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth)
        XCTAssertEqual(OCCTKernel.serialize(try native(input,node)),before)
    }
    func testUserChangeDuringEndpointPreparationKeepsThatUserChange() async throws {
        let input=try await fixture(),node=try await create(input),depth=input.doc.session.undoStack.undoCommands.count
        CADLoftSurfaceService.testAfterGuidedPrepare={ input.doc.session.perform(AddSketchCommand(sketch:Sketch(name:"Concurrent user",plane:.ground,entities:[]))) }
        let reply=try await update(input,node,LoftDefinition(start:boundary(SIMD3(0,0,1),SIMD3(0.012,0,0))))
        CADLoftSurfaceService.testAfterGuidedPrepare=nil
        XCTAssertEqual(reply["error"] as? String,"stale_feature");XCTAssertEqual(input.doc.session.undoStack.undoCommands.count,depth+1)
        XCTAssertTrue(input.doc.session.document.sketches.contains { $0.name=="Concurrent user" })
    }
    #endif
}
