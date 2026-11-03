import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Actual OCCT solids, independently measured end planes/radii/areas/volume.
/// These source tests are supplied for the integration owner's native/App gate.
@MainActor
final class CADMechanicalTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Mechanical-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDown() async throws {
        for d in documents { d.close() }
        if let directory { try FileManager.default.removeItem(at:directory) }
    }
    private func document() async throws -> FloeCADDocument {
        let d = try await FloeCADDocument.create(at:directory.appendingPathComponent("\(UUID()).floecad"),name:"Manufactured parts")
        documents.append(d); return d
    }
    private func run(_ d: FloeCADDocument, _ action: String, _ fields: [String:Any] = [:]) throws -> [String:Any] {
        let reply = CADParameterService(document:d).handle(action:action,args:fields)
        XCTAssertEqual(reply["ok"] as? Bool,true,"\(reply)"); return reply
    }
    private func feature(_ d: FloeCADDocument, _ reply: [String:Any]) throws -> FeatureNode {
        let id = try XCTUnwrap(UUID(uuidString:try XCTUnwrap(reply["feature_id"] as? String)))
        return try XCTUnwrap(d.session.document.features.node(FeatureID(raw:id)))
    }
    private func handle(_ d: FloeCADDocument, _ id: BodyID) throws -> BRepHandle {
        try XCTUnwrap(d.session.document.body(with:id)?.brep)
    }
    private func health(_ solid: BRepHandle, volume: Double, file: StaticString = #filePath, line: UInt = #line) {
        let h = OCCTKernel.healthReportDictionary(for:solid,runBOPCheck:true)
        XCTAssertTrue(solid.containsSolid,file:file,line:line)
        XCTAssertEqual(h["valid"] as? Bool,true,"\(h)",file:file,line:line)
        XCTAssertEqual((h["counts"] as? [String:Int])?["solids"],1,file:file,line:line)
        XCTAssertEqual(h["openFreeWires"] as? Int,0,file:file,line:line)
        XCTAssertEqual(h["closedFreeWires"] as? Int,0,file:file,line:line)
        XCTAssertEqual(OCCTKernel.volume(solid),volume,accuracy:max(1e-4,volume*1e-7),file:file,line:line)
    }
    private func planeSpan(_ solid: BRepHandle, axis: Int) throws -> Double {
        let coordinates = OCCTKernel.faceInfo(solid).filter {
            $0.signature?.kind == .planar && abs(abs($0.normal[axis])-1) < 1e-8
        }.map { $0.centroid[axis] }
        return try XCTUnwrap(coordinates.max()) - XCTUnwrap(coordinates.min())
    }
    private func verifySheet(_ outputs: [CADMechanicalKernel.Output], degrees: Double, k: Double,
                             a: Double = 40, b: Double = 30, width: Double = 25, t: Double = 2, r: Double = 4) throws {
        XCTAssertEqual(outputs.count,2)
        let formed = outputs[0].handle, flat = outputs[1].handle, theta = degrees * .pi/180
        let rows = OCCTKernel.faceInfo(formed)
        let cylinders = rows.compactMap { face -> (Double,Double)? in
            guard case let .cylindrical(radius)? = face.signature?.kind else { return nil }
            return (radius,face.area)
        }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(cylinders.count,2)
        if cylinders.count == 2 {
            XCTAssertEqual(cylinders[0].0,r,accuracy:1e-7); XCTAssertEqual(cylinders[1].0,r+t,accuracy:1e-7)
            XCTAssertEqual(cylinders[1].0-cylinders[0].0,t,accuracy:1e-7)
            XCTAssertEqual(cylinders[0].1,r*theta*width,accuracy:1e-5)
            XCTAssertEqual(cylinders[1].1,(r+t)*theta*width,accuracy:1e-5)
        }
        XCTAssertEqual(try planeSpan(formed,axis:2),width,accuracy:1e-7)
        XCTAssertEqual(try planeSpan(flat,axis:0),a+b+theta*(r+k*t),accuracy:1e-6)
        XCTAssertEqual(try planeSpan(flat,axis:1),t,accuracy:1e-7)
        XCTAssertEqual(try planeSpan(flat,axis:2),width,accuracy:1e-7)
        let flankAreas = rows.filter { $0.signature?.kind == .planar && abs($0.normal.z) < 1e-8 }.map(\.area)
        XCTAssertTrue(flankAreas.filter { abs($0-a*width) < 1e-5 }.count >= 2)
        XCTAssertTrue(flankAreas.filter { abs($0-b*width) < 1e-5 }.count >= 2)
        let outward = SIMD3<Double>(sin(theta),-cos(theta),0)
        XCTAssertTrue(rows.contains { $0.signature?.kind == .planar && simd_dot($0.normal,outward) > 1-1e-8 })
        health(formed,volume:width*(t*(a+b)+theta*(r*t+t*t/2)))
        health(flat,volume:width*t*(a+b+theta*(r+k*t)))
        if k == 0.5 { XCTAssertEqual(OCCTKernel.volume(formed),OCCTKernel.volume(flat),accuracy:1e-4) }
        // A user-supplied non-mid-plane K changes neutral-axis stock length;
        // volume conservation would be a false assertion for that empirical model.
    }
    func testAnalyticBendRadiusThicknessAngleBlankDimensionsAndClosedNativeHealth() throws {
        for degrees in [30.0,90,135] {
            for k in [0.25,0.5] {
                var spec = CADSheetMetalSpec(); spec.bendDegrees = Expr(value:degrees); spec.kFactor = Expr(value:k)
                try verifySheet(CADMechanicalKernel.build(.init(sheet:spec),placement:.identity),degrees:degrees,k:k)
            }
        }
    }
    func testSameFeatureFormedFlatIdentityOneUndoReopenAndContinueEditing() async throws {
        let d = try await document(), before = d.session.undoStack.undoCommands.count
        let created = try run(d,"sheetMetal.create"), node = try feature(d,created), ids = node.outputBodyIDs
        XCTAssertEqual(d.session.undoStack.undoCommands.count,before+1)
        XCTAssertEqual(ids.count,2)
        let names = ids.map { d.session.lastKernelNames[$0] ?? [:] }
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty && $0.values.allSatisfy(\.isStableFaceIdentity) })
        _ = try run(d,"sheetMetal.update",["feature_id":node.id.raw.uuidString,"changes":["thickness":3,"inner_radius":5,"bend_degrees":60,"k_factor":0.4]])
        XCTAssertEqual(d.session.undoStack.undoCommands.count,before+2)
        XCTAssertEqual(try feature(d,created).outputBodyIDs,ids)
        for (i,id) in ids.enumerated() { XCTAssertEqual(d.session.lastKernelNames[id],names[i]) }
        XCTAssertEqual(try planeSpan(handle(d,ids[1]),axis:0),70+Double.pi/3*(5+0.4*3),accuracy:1e-6)
        health(try handle(d,ids[0]),volume:25*(3*70+Double.pi/3*(5*3+9.0/2)))
        d.session.undo()
        XCTAssertEqual(try planeSpan(handle(d,ids[1]),axis:0),70+5*Double.pi/2,accuracy:1e-6)
        let saved = await d.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url = d.url; d.close()
        let reopened = try await FloeCADDocument.open(at:url); documents.append(reopened)
        XCTAssertEqual(try feature(reopened,created).outputBodyIDs,ids)
        _ = try run(reopened,"update",["feature_id":node.id.raw.uuidString,"changes":["flange_b":45]])
        XCTAssertEqual(try planeSpan(handle(reopened,ids[1]),axis:0),85+5*Double.pi/2,accuracy:1e-6)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:reopened.session.document),7)
    }
    func testAllFourStraightStockProfilesUseExactVolumesAndMeasuredEndPlanes() throws {
        for profile in CADWeldmentMember.Stock.allCases {
            var m = CADWeldmentMember(); m.profile = profile
            let output = try XCTUnwrap(CADMechanicalKernel.build(.init(members:[m]),placement:.identity).first)
            let area: Double
            switch profile {
            case .flatBar: area = 200
            case .rectangularTube: area = 200-16*6
            case .roundBar: area = Double.pi*100
            case .roundTube: area = Double.pi*(100-64)
            }
            health(output.handle,volume:area*100)
            XCTAssertEqual(try CADMechanicalKernel.measuredLength(output.handle),100,accuracy:1e-7)
            if profile == .roundBar || profile == .roundTube {
                let radii = OCCTKernel.faceInfo(output.handle).compactMap { face -> Double? in
                    if case let .cylindrical(r)? = face.signature?.kind { return r }; return nil
                }.sorted()
                XCTAssertEqual(radii,profile == .roundTube ? [8,10] : [10])
            } else {
                XCTAssertEqual(try planeSpan(output.handle,axis:0),20,accuracy:1e-7)
                XCTAssertEqual(try planeSpan(output.handle,axis:1),10,accuracy:1e-7)
            }
        }
    }
    func testWeldmentGroupedCutListStableMemberEditUndoAndReopen() async throws {
        let d = try await document()
        let created = try run(d,"weldment.create",["members":[
            ["profile":"rectangularTube","width":20,"depth":10,"wall":2,"length":100,"material":"S235"],
            ["profile":"rectangularTube","width":20,"depth":10,"wall":2,"length":100,"material":"S235",
             "placement":["translation":[30,0,0],"rotation":[0,0,0,1],"scale":1]],
            ["profile":"roundTube","width":20,"wall":2,"length":80,"material":"S235",
             "placement":["translation":[60,0,0],"rotation":[0,0,0,1],"scale":1]]]])
        let node = try feature(d,created), key = node.id.raw.uuidString, ids = node.outputBodyIDs
        guard case let .mechanical(definition,_) = node.kind else { return XCTFail("Missing manufacturing intent") }
        let member = definition.members[1].id
        let report = try run(d,"weldment.cutList",["feature_id":key])
        let groups = try XCTUnwrap(report["groups"] as? [[String:Any]])
        XCTAssertEqual(groups.count,2)
        XCTAssertEqual(groups.first?["quantity"] as? Int,2)
        XCTAssertEqual(groups.first?["total_length"] as? Double,200)
        let undo = d.session.undoStack.undoCommands.count
        _ = try run(d,"weldment.update",["feature_id":key,"changes":["member_id":member.uuidString,"length":125]])
        XCTAssertEqual(d.session.undoStack.undoCommands.count,undo+1)
        XCTAssertEqual(try feature(d,created).outputBodyIDs,ids)
        XCTAssertEqual(try CADMechanicalKernel.measuredLength(handle(d,ids[1])),125,accuracy:1e-7)
        health(try handle(d,ids[1]),volume:104*125)
        d.session.undo(); XCTAssertEqual(try CADMechanicalKernel.measuredLength(handle(d,ids[1])),100,accuracy:1e-7)
        let saved = await d.save(); XCTAssertTrue(saved.succeeded,saved.error ?? "")
        let url = d.url; d.close(); let reopened = try await FloeCADDocument.open(at:url); documents.append(reopened)
        _ = try run(reopened,"weldment.update",["feature_id":key,"changes":["member_id":member.uuidString,"length":110]])
        XCTAssertEqual(try CADMechanicalKernel.measuredLength(handle(reopened,ids[1])),110,accuracy:1e-7)
        let list = try run(reopened,"weldment.cutList",["feature_id":key])
        XCTAssertEqual((list["rows"] as? [[String:Any]])?[1]["member_id"] as? String,member.uuidString)
        // A direct mesh edit may leave an old BRep attached; the cut list must fence both representations.
        let originalBody = try XCTUnwrap(reopened.session.document.body(with:ids[1]))
        var body = originalBody
        body.render.positions = body.render.positions.map { $0 + SIMD3<Float>(1,0,0) }
        body.edges = FeatureEdgeExtractor.edges(from:body.render); body.euclid = nil
        reopened.session.perform(ReplaceBodyCommand(title:"Direct mesh edit",before:originalBody,after:body))
        let refused = CADParameterService(document:reopened).handle(action:"weldment.cutList",args:["feature_id":key])
        XCTAssertEqual(refused["ok"] as? Bool,false)
    }
    func testRejectedDimensionsPreserveExactBodiesUndoAndRedo() async throws {
        let d = try await document(), created = try run(d,"sheetMetal.create"), node = try feature(d,created)
        _ = try run(d,"sheetMetal.update",["feature_id":node.id.raw.uuidString,"changes":["thickness":3]])
        d.session.undo()
        let snapshots = try node.outputBodyIDs.map { try XCTUnwrap(OCCTKernel.serialize(handle(d,$0))) }
        let undo = d.session.undoStack.undoCommands.count, redo = d.session.undoStack.redoCommands.count
        for changes: [String:Any] in [["inner_radius":-1],["k_factor":0.9],["bend_degrees":180],["bend_count":2]] {
            let result = CADParameterService(document:d).handle(action:"sheetMetal.update",args:["feature_id":node.id.raw.uuidString,"changes":changes])
            XCTAssertEqual(result["ok"] as? Bool,false); XCTAssertEqual(result["mutated"] as? Bool,false)
            XCTAssertEqual(d.session.undoStack.undoCommands.count,undo); XCTAssertEqual(d.session.undoStack.redoCommands.count,redo)
            XCTAssertEqual(try node.outputBodyIDs.map { try XCTUnwrap(OCCTKernel.serialize(handle(d,$0))) },snapshots)
        }
        d.session.redo(); XCTAssertEqual(try planeSpan(handle(d,node.outputBodyIDs[1]),axis:1),3,accuracy:1e-7)
    }
    func testVariableFanoutRebuildsBothActualSolidsAsOneUndoStep() async throws {
        let d = try await document()
        let variable = try run(d,"variable.create",["name":"flange","expression":"40"])
        let created = try run(d,"sheetMetal.create"), node = try feature(d,created)
        _ = try run(d,"feature.setExpression",["feature_id":node.id.raw.uuidString,"parameter":"flange_a","expression":"flange"])
        let variableID = try XCTUnwrap((variable["variable"] as? [String:Any])?["id"] as? String)
        let undo = d.session.undoStack.undoCommands.count
        _ = try run(d,"variable.update",["variable_id":variableID,"expression":"55"])
        XCTAssertEqual(d.session.undoStack.undoCommands.count,undo+1)
        XCTAssertEqual(try planeSpan(handle(d,node.outputBodyIDs[1]),axis:0),85+5*Double.pi/2,accuracy:1e-6)
        health(try handle(d,node.outputBodyIDs[0]),volume:25*(2*85+10*Double.pi/2))
        d.session.undo(); XCTAssertEqual(try planeSpan(handle(d,node.outputBodyIDs[1]),axis:0),70+5*Double.pi/2,accuracy:1e-6)
    }
    func testWriterFloorAndUnknownMechanicalSemanticsRemainOpaque() throws {
        let definition = CADMechanicalDefinition(sheet:CADSheetMetalSpec())
        let node = FeatureNode(name:"Bend",kind:.mechanical(definition:definition,placement:.identity),outputBodyIDs:[BodyID(),BodyID()])
        let bytes = try JSONEncoder().encode(node.kind)
        func assess(_ bytes: Data) throws -> CADDocumentFormat.Assessment {
            try CADDocumentFormat.assess(planes:[],sketches:[],features:[CADFeatureRecord(featureID:node.id.raw,orderIndex:0,
                name:node.name,suppressed:false,kind:bytes,outputBodyIDs:try JSONEncoder().encode(node.outputBodyIDs))])
        }
        XCTAssertEqual(try assess(bytes).requiredVersion,7); XCTAssertFalse(try assess(bytes).isOpaqueReadOnly)
        for futureField in ["version","springback"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
            var payload = try XCTUnwrap(object["mechanical"] as? [String:Any])
            var spec = try XCTUnwrap(payload["definition"] as? [String:Any])
            spec[futureField] = 2; payload["definition"] = spec; object["mechanical"] = payload
            XCTAssertTrue(try assess(JSONSerialization.data(withJSONObject:object)).opaqueFeatures.contains(node.id.raw))
        }
        var ordinary = DesignDocument()
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document:ordinary),1)
        ordinary.features.nodes = [node]; XCTAssertEqual(CADDocumentFormat.requiredFormat(document:ordinary),7)
    }
}
