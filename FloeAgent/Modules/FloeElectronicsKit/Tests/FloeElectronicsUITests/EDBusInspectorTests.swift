// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@Suite("Bus and entry Inspector")
struct EDBusInspectorTests {
    private func fixture()->EDAProject{
        var p=EDAProject(title:"Inspector literal members")
        p.sheets[0].buses=[.init(name:"DATA",members:["DATA[0..7]","USB P","x{a,b}"],points:[.zero,.init(0,20)],entries:[.init(busPosition:.init(0,4),wirePosition:.init(2,6))])]
        p.sheets[0].wires=[.init(points:[.init(2,6),.init(10,6)])];p.sheets[0].labels=[.init(name:"DATA[0..7]",position:.init(2,6))]
        return p
    }
    @Test func selectedBusAndEntryResolveToTheirActualPropertyRecords()throws{
        let p=fixture(),sheet=p.sheets[0],bus=sheet.buses[0],entry=try #require(bus.entries?.first)
        #expect(EDBusInspectorSelection.read(p,sheetID:sheet.id,objectIDs:[bus.id]) == .bus(bus))
        #expect(EDBusInspectorSelection.read(p,sheetID:sheet.id,objectIDs:[entry.id]) == .entry(busID:bus.id,entry))
        #expect(EDBusInspectorSelection.read(p,sheetID:sheet.id,objectIDs:[UUID()])==nil)
        #expect(EDBusInspectorSelection.read(p,sheetID:UUID(),objectIDs:[entry.id])==nil)
    }
    @Test func namesRemainLiteralAndMemberEditsDoNotRewriteElectricalLabels()throws{
        let p=fixture(),sheet=p.sheets[0];var bus=sheet.buses[0];bus.name=" renamed ";bus.members[1]="USB.DP"
        let edits=try EDBusInspectorEdits.bus(bus,sheetID:sheet.id,project:p)
        #expect(edits.count==1);var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        #expect(editor.project.sheets[0].buses[0].members==["DATA[0..7]","USB.DP","x{a,b}"])
        #expect(editor.project.sheets[0].buses[0].entries==bus.entries)
        #expect(editor.project.sheets[0].wires==sheet.wires);#expect(editor.project.sheets[0].labels==sheet.labels)
        #expect(try EDAConnectivity.derive(editor.project).nets==EDAConnectivity.derive(p).nets)
        try editor.undo(expectedRevision:1);#expect(editor.project.sheets[0].buses==sheet.buses)
    }
    @Test func largeMemberPagesAreBoundedWithoutChangingHiddenNames()throws{
        var p=fixture();p.sheets[0].buses[0].members=(0..<10_000).map{"original.\($0)"}
        let members=p.sheets[0].buses[0].members
        #expect(EDBusMemberPage.range(count:members.count,page:0)==0..<50)
        #expect(EDBusMemberPage.range(count:members.count,page:Int.max)==9950..<10_000)
        var value=p.sheets[0].buses[0];value.members[9999]="changed last"
        let edits=try EDBusInspectorEdits.bus(value,sheetID:p.sheets[0].id,project:p)
        var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        #expect(Array(editor.project.sheets[0].buses[0].members.dropLast())==Array(members.dropLast()))
        value.members.append("overflow");#expect(throws:EDAError.self){try EDBusInspectorEdits.bus(value,sheetID:p.sheets[0].id,project:p)}
    }
    @MainActor @Test func entryEndpointEditSavesAndUndoesOnlyTheDrawingAndCannotRecreateRemovedEntry()async throws{
        let p=fixture(),sheet=p.sheets[0],bus=sheet.buses[0];var entry=try #require(bus.entries?.first);entry.wirePosition = .init(3,7)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:p),session=try await EDWorkbenchSession(store:store)
        let edits=try EDBusInspectorEdits.entry(entry,busID:bus.id,sheetID:sheet.id,project:session.project)
        try await session.apply(edits,expectedRevision:0)
        #expect(session.project.sheets[0].buses[0].entries?.first==entry)
        #expect(session.project.sheets[0].wires==sheet.wires);#expect(session.project.sheets[0].labels==sheet.labels)
        #expect(try await store.load().project==session.project)
        try await session.undo(expectedRevision:1);#expect(session.project.sheets[0].buses==sheet.buses)
        try await session.apply([.removeSchematicObject(sheet:sheet.id,object:entry.id)],expectedRevision:2)
        #expect(throws:EDAError.self){try EDBusInspectorEdits.entry(entry,busID:bus.id,sheetID:sheet.id,project:session.project)}
        #expect(session.project.sheets[0].wires==sheet.wires)
    }
}
