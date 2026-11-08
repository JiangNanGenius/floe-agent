// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor final class EDWorkbenchSessionTests:XCTestCase {
    private func temporary()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("floe-eda-session-"+UUID().uuidString)}
    func testNativeLibraryAndHostIdentitySaveUndoReopen() async throws {
        let root=temporary();defer{try? FileManager.default.removeItem(at:root)}
        let id=UUID(),project=EDABuiltinLibrary.makeProject(id:id,title:"Owned design")
        try EDAValidation.validate(project)
        XCTAssertEqual(project.id,id);XCTAssertEqual(project.symbols.count,8);XCTAssertEqual(project.footprints.count,5)
        let store=try await EDAProjectStore.create(root:root,project:project),session=try await EDWorkbenchSession(store:store)
        var callbacks:[UInt64]=[];session.onSaved={callbacks.append($0.project.revision)}
        XCTAssertFalse(session.fingerDrawingEnabled)
        try await session.apply([.rename("Saved design")],expectedRevision:0)
        let saved=try await store.load();XCTAssertEqual(saved.project,session.project);XCTAssertFalse(session.isDirty)
        try await session.undo(expectedRevision:1);XCTAssertEqual(session.project.title,"Owned design")
        try await session.redo(expectedRevision:2);XCTAssertEqual(session.project.title,"Saved design")
        XCTAssertEqual(callbacks,[1,2,3]);let reopened=try await EDWorkbenchSession(store:store)
        XCTAssertEqual(reopened.project,session.project)
        let closed=await session.flushForClose();XCTAssertTrue(closed);XCTAssertTrue(session.isClosed)
        do{try await session.apply([.rename("Late write")]);XCTFail("Closed session accepted edit")}catch EDAError.cancelled{}
        let final=try await store.load();XCTAssertEqual(final.project.title,"Saved design")
    }
    func testExpectedRevisionAndConcurrentCASKeepUncommittedProposal() async throws {
        let root=temporary();defer{try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:EDABuiltinLibrary.makeProject(title:"Initial"))
        let first=try await EDWorkbenchSession(store:store),second=try await EDWorkbenchSession(store:store)
        do{try await first.apply([.rename("Rejected")],expectedRevision:4);XCTFail("Stale edit accepted")}catch EDAError.staleRevision{}
        XCTAssertEqual(first.revision,0);XCTAssertFalse(first.isDirty)
        try await first.apply([.rename("First writer")],expectedRevision:0)
        do{try await second.apply([.rename("Second proposal")],expectedRevision:0);XCTFail("Concurrent overwrite accepted")}catch EDAError.staleRevision{}
        XCTAssertEqual(second.project.title,"Second proposal");XCTAssertTrue(second.isDirty);XCTAssertTrue(second.conflictWithOriginal)
        let actual=try await store.load();XCTAssertEqual(actual.project.title,"First writer")
        do{try await second.refresh();XCTFail("Implicit refresh discarded pending edits")}catch EDAError.invalid{}
        let couldClose=await second.flushForClose();XCTAssertFalse(couldClose);XCTAssertFalse(second.isClosed)
        try await second.refresh(discardChanges:true);XCTAssertEqual(second.project.title,"First writer");XCTAssertFalse(second.isDirty)
    }
    func testServiceOwnedCheckEndsBeforeClose() async throws {
        let root=temporary();defer{try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:EDABuiltinLibrary.makeProject(title:"Check owner")),session=try await EDWorkbenchSession(store:store)
        let check=Task{@MainActor in await session.runCheck()}
        await Task.yield()
        let closed=await session.flushForClose();await check.value
        XCTAssertTrue(closed);XCTAssertTrue(session.isClosed);XCTAssertFalse(session.isChecking)
    }
    func testNativeExportRoundtripCSVAndActualDrawing() throws {
        var project=EDABuiltinLibrary.makeProject(title:"Board <owned>")
        let symbol=try XCTUnwrap(project.symbols.first),footprint=try XCTUnwrap(project.footprints.first)
        let part=EDAComponent(symbolID:symbol.id,footprintID:footprint.id,reference:"R1",value:"=SUM(1,2)")
        project.components=[part];project.sheets[0].symbols=[.init(componentID:part.id,position:.init(20,30),angle:90)]
        project.boards[0].footprints=[.init(definitionID:footprint.id,componentID:part.id,reference:"R1",value:part.value,position:.init(-25,35),angle:-90,side:"B.Cu")]
        project.boards[0].graphics=[.text("Rotated",position:.init(12,20),height:2,angle:90)]
        let native=try EDAExchange.export(project,format:.project)
        XCTAssertEqual(try EDAExchange.decodeProject(try XCTUnwrap(native.files.first).data),project)
        let bom=try EDAExchange.export(project,format:.bom),csv=String(decoding:try XCTUnwrap(bom.files.first).data,as:UTF8.self)
        XCTAssertTrue(csv.contains("'=SUM(1,2)"));XCTAssertTrue(csv.contains("R1"))
        let position=try EDAExchange.export(project,format:.positions),positions=String(decoding:try XCTUnwrap(position.files.first).data,as:UTF8.self)
        XCTAssertTrue(positions.contains("\"-25.000000\""));XCTAssertTrue(positions.contains("\"-90.000000\""));XCTAssertFalse(positions.contains("'-25"));XCTAssertTrue(positions.contains("35.000000"));XCTAssertTrue(positions.contains("bottom"))
        let drawing=try EDAExchange.export(project,format:.boardSVG),svg=String(decoding:try XCTUnwrap(drawing.files.first).data,as:UTF8.self)
        XCTAssertTrue(svg.contains("Board &lt;owned&gt;"));XCTAssertTrue(svg.contains("R1"));XCTAssertTrue(svg.contains("<polygon"))
        XCTAssertFalse(svg.contains("<owned>"));XCTAssertEqual(try EDAExchange.export(project,format:.schematicSVG).files.count,1)
        XCTAssertTrue(svg.contains("rotate(-90.000000)"))
        XCTAssertThrowsError(try EDAExchange.export(project,format:.netlist,cancelled:{true}))
    }
    func testRoutingUsesTouchedPadAndRejectsCrossNetAndClearance() throws {
        var project=EDABuiltinLibrary.makeProject(title:"Routing")
        project.sheets[0].labels=[.init(name:"A",position:.init(0,0),scope:.global),.init(name:"B",position:.init(10,0),scope:.global)]
        let nets=try EDAConnectivity.derive(project),a=try XCTUnwrap(nets.nets.first{$0.name=="A"}?.id),b=try XCTUnwrap(nets.nets.first{$0.name=="B"}?.id)
        let definition=EDAFootprintDefinition(name:"Two distinct nets",pads:[.init(number:"1",position:.init(0,0)),.init(number:"2",position:.init(4,0))])
        project.footprints.append(definition)
        let placed=EDAFootprint(definitionID:definition.id,position:.init(10,10),padNets:["1":a,"2":b])
        project.boards[0].footprints=[placed]
        let board=project.boards[0].id
        XCTAssertEqual(try EDAInteractiveRouting.anchor(project,boardID:board,at:.init(14,10),layer:"F.Cu")?.netID,b)
        XCTAssertNil(try EDAInteractiveRouting.anchor(project,boardID:board,at:.init(14,10),layer:"B.Cu"))
        XCTAssertThrowsError(try EDAInteractiveRouting.track(project,boardID:board,from:.init(10,10),to:.init(14,10),layer:"F.Cu",width:0.25))
        let track=try EDAInteractiveRouting.track(project,boardID:board,from:.init(10,10),to:.init(20,16),layer:"F.Cu",width:0.25)
        XCTAssertEqual(track.netID,a);XCTAssertEqual(track.points,[.init(10,10),.init(16,16),.init(20,16)])
        project.boards[0].tracks=[.init(netID:b,width:0.25,points:[.init(15,8),.init(15,16)])]
        XCTAssertThrowsError(try EDAInteractiveRouting.track(project,boardID:board,from:.init(10,10),to:.init(20,16),layer:"F.Cu",width:0.25))
        XCTAssertEqual(project.boards[0].tracks.count,1)
        var bottom=placed;bottom.side="B.Cu";bottom.angle=90;project.boards[0].footprints=[bottom]
        XCTAssertEqual(try EDAInteractiveRouting.anchor(project,boardID:board,at:bottom.point(.init(4,0)),layer:"B.Cu")?.netID,b)
    }
}
