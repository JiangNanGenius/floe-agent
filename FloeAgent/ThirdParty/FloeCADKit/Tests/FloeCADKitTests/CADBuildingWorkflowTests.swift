// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
@testable import FloeCAD

@MainActor
final class CADBuildingWorkflowTests:XCTestCase {
    private func plan() throws -> CADSketchTransferEnvelope {
        let points=[[0.0,0],[6000,0],[6000,4000],[0,4000]]
        var text="0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n"
        var curves:[[String:Any]]=[]
        for i in 0..<4 {
            let a=points[i],b=points[(i+1)%4],handle=String(i+10,radix:16).uppercased()
            text+="0\nLINE\n5\n\(handle)\n8\nWALLS\n10\n\(a[0])\n20\n\(a[1])\n11\n\(b[0])\n21\n\(b[1])\n"
            curves.append(["kind":"line","handle":handle,"layer":"WALLS","sourceEntityType":"Line",
                "ocs":["normal":[0,0,1],"elevation":0],"start":a,"end":b])
        }
        text+="0\nENDSEC\n0\nEOF\n"
        let bytes=Data(text.utf8)
        let snapshot=try CADSketchTransferSnapshot.decodeValidated(JSONSerialization.data(withJSONObject:[
            "schemaVersion":1,"format":"dxf","drawingVersion":"AC1015","draftRevision":0,
            "insertionUnits":4,"unitName":"millimetres","unitScaleMM":1,
            "selectedHandles":curves.map {$0["handle"]!},"selectedLayers":["WALLS"],
            "sourcePlane":["origin":[0,0,0],"xAxis":[1,0,0],"yAxis":[0,1,0]],"curves":curves,"omissions":[]]))
        return try CADSketchTransferEnvelope(purpose:.buildingFloorplan,sourceName:"Floor.dxf",
            sourceSHA256:CADSketchTransferEnvelope.digest(bytes),sourceBytes:bytes,snapshot:snapshot)
    }
    private func fixture() async throws -> (URL,FloeCADDocument) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Building-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return (root,try await FloeCADDocument.create(at:root.appendingPathComponent("Building.floecad"),name:"Plan building"))
    }
    func testPlanToExactBuildingOpeningSingleUndoReopenAndDrawing() async throws {
        let (root,document)=try await fixture()
        defer { document.close();try? FileManager.default.removeItem(at:root) }
        let source=try plan(),floorID=UUID()
        var model=try document.buildingCandidate(from:source,storeyID:floorID)
        XCTAssertEqual(model.storeys[0].id,floorID)
        let count=document.session.undoStack.undoCommands.count
        try document.setBuilding(model,expectedChangeCount:document.buildingChangeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count,count+1)
        XCTAssertEqual(document.session.document.bodies.count,4)
        XCTAssertTrue(document.session.document.bodies.allSatisfy {$0.brep?.containsSolid == true})
        let wall=model.elements[0]
        let opening=CADBuildingElement(storeyID:floorID,kind:.door,name:"Door",a:wall.a,b:wall.b,
            thicknessMM:30,heightMM:2100,hostID:wall.id,offsetMM:500,widthMM:900)
        model.elements.append(opening)
        model.elements.append(CADBuildingElement(storeyID:floorID,kind:.slab,name:"Slab",a:[0,0],b:[6000,4000],thicknessMM:200,heightMM:200,baseOffsetMM:-200))
        try document.setBuilding(model)
        let exact=try XCTUnwrap(document.session.document.body(with:BodyID(raw:wall.bodyID))?.brep)
        XCTAssertEqual(OCCTKernel.volume(exact),6000*200*3000-900*200*2100,accuracy:1)
        document.session.undo();XCTAssertEqual(try document.building()?.elements.count,4)
        document.session.redo();XCTAssertEqual(try document.building()?.elements.count,6)
        let save=await document.save();XCTAssertTrue(save.succeeded,save.error ?? "")
        let reopened=try await FloeCADDocument.open(at:document.url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.building(),model)
        XCTAssertEqual(reopened.project.formatVersion,9)
        XCTAssertEqual(try reopened.building()?.sources.first?.sourceBytes,source.sourceBytes)
        _=try reopened.createBuildingDrawing(storeyID:floorID)
        let set=try JSONSerialization.jsonObject(with:XCTUnwrap(reopened.session.document.drawingsData)) as! [String:Any]
        let pages=try XCTUnwrap(set["pages"] as? [[String:Any]])
        XCTAssertFalse(pages.isEmpty)
        let id=try XCTUnwrap((pages.first?["id"] as? String).flatMap(UUID.init(uuidString:)))
        let drawing=CADDrawingService(document:reopened)
        let dxf=try drawing.exportData(pageID:id,format:"dxf")
        XCTAssertTrue(String(decoding:dxf,as:UTF8.self).contains("ENTITIES"))
        let pdf=try drawing.exportData(pageID:id,format:"pdf")
        XCTAssertTrue(pdf.starts(with:Data("%PDF".utf8)))
    }
    func testFailedOpeningAndStaleInspectorCannotCommitPartialBuilding() async throws {
        let (root,document)=try await fixture()
        defer { document.close();try? FileManager.default.removeItem(at:root) }
        var model=try document.buildingCandidate(from:plan())
        try document.setBuilding(model)
        let before=document.buildingChangeCount,bytes=document.session.document.buildingData
        let wall=model.elements[0]
        model.elements.append(CADBuildingElement(storeyID:wall.storeyID,kind:.door,name:"Entire-wall cut",
            a:wall.a,b:wall.b,thicknessMM:30,heightMM:wall.heightMM,hostID:wall.id,offsetMM:0,widthMM:wall.lengthMM))
        XCTAssertThrowsError(try document.setBuilding(model))
        XCTAssertEqual(document.buildingChangeCount,before)
        XCTAssertEqual(document.session.document.buildingData,bytes)
        XCTAssertEqual(document.session.document.bodies.count,4)
        var valid=try XCTUnwrap(document.building());valid.name="Renamed"
        try document.setBuilding(valid,expectedChangeCount:before)
        XCTAssertThrowsError(try document.setBuilding(valid,expectedChangeCount:before))
    }
    func testFutureNestedBuildingAndMissingRegionalRulesFailClosed() async throws {
        let (root,document)=try await fixture()
        defer { document.close();try? FileManager.default.removeItem(at:root) }
        let initialSchema=document.project.formatVersion
        let model=try document.buildingCandidate(from:plan())
        try document.setBuilding(model)
        XCTAssertTrue(try document.inspectBuilding().contains {$0.id == "jurisdiction" && $0.status == .notEvaluated})
        var raw=try JSONSerialization.jsonObject(with:model.encoded()) as! [String:Any]
        var elements=raw["elements"] as! [[String:Any]];elements[0]["futureWall"]=true;raw["elements"]=elements
        let unknown=try JSONSerialization.data(withJSONObject:raw)
        XCTAssertThrowsError(try CADBuildingDocument.decode(unknown))
        let assessment=try CADDocumentFormat.assess(planes:[],sketches:[],building:unknown)
        XCTAssertEqual(assessment.requiredVersion,9);XCTAssertTrue(assessment.isOpaqueReadOnly)
        XCTAssertLessThan(initialSchema,9)
        document.session.undo();XCTAssertNil(try document.building())
    }
    func testNamedVersionRestoresBuildingSemanticsAndExactGeometryTogether() async throws {
        let (root,document)=try await fixture()
        defer { document.close();try? FileManager.default.removeItem(at:root) }
        let original=try document.buildingCandidate(from:plan())
        try document.setBuilding(original)
        let version=try await document.createNamedVersion(name:"Imported plan")
        var changed=original;changed.name="Altered";changed.elements[0].thicknessMM=300
        try document.setBuilding(changed)
        let saved=await document.save();XCTAssertTrue(saved.succeeded,saved.error ?? "")
        _=try await document.restoreNamedVersion(version.version.id,expectedRevision:document.revision)
        XCTAssertEqual(try document.building(),original)
        let handle=try XCTUnwrap(document.session.document.body(with:BodyID(raw:original.elements[0].bodyID))?.brep)
        XCTAssertEqual(OCCTKernel.volume(handle),6000*200*3000,accuracy:1)
    }
}
