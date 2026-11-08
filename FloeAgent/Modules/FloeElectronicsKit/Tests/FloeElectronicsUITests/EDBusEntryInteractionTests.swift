// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@Suite("Bus entry canvas operations")
struct EDBusEntryInteractionTests {
    private func fixture() -> EDAProject {
        var p=EDAProject(title:"entry canvas")
        p.sheets[0].buses=[.init(name:"DATA",members:["D0","D1"],points:[.zero,.init(0,20)],entries:[
            .init(busPosition:.init(0,4),wirePosition:.init(2,6)),.init(busPosition:.init(0,12),wirePosition:.init(2,14))])]
        p.sheets[0].wires=[.init(points:[.init(2,6),.init(10,6)]),.init(points:[.init(2,14),.init(10,14)])]
        p.sheets[0].labels=[.init(name:"D0",position:.init(2,6)),.init(name:"D1",position:.init(2,14))]
        return p
    }
    @Test func hitUsesEntrySegmentAndPlotIncludesItsEndpoints() throws {
        var p=fixture();let sheet=p.sheets[0],entry=try #require(sheet.buses[0].entries?.first),context=EDADocumentContext.schematic(sheetID:sheet.id)
        #expect(EDCanvasInteraction.hit(project:p,context:context,at:.init(1,5),tolerance:0.01)==entry.id)
        #expect(EDCanvasInteraction.hit(project:p,context:context,at:.init(1,12),tolerance:0.01)==nil)
        p.sheets[0].buses[0].entries![0].wirePosition = .init(100,200)
        let bounds=EDAPlot.bounds(p,context:context)
        #expect(bounds.contains(CGPoint(x:100,y:200)))
    }
    @Test func movingParentAndEntryTransformsOnceAndCopiesUseNewNestedIDs() throws {
        let p=fixture(),sheet=p.sheets[0],bus=sheet.buses[0],entry=try #require(bus.entries?.first),context=EDADocumentContext.schematic(sheetID:sheet.id)
        var editor=try EDAEditingSession(project:p)
        let edits=try EDCanvasInteraction.move(project:p,context:context,objectIDs:[bus.id,entry.id],by:.init(5,7))
        #expect(edits.count==1);try editor.apply(edits,expectedRevision:0)
        let moved=editor.project.sheets[0].buses[0]
        #expect(moved.id==bus.id);#expect(moved.entries?.first?.id==entry.id)
        #expect(moved.entries?.first?.wirePosition == .init(7,13))
        #expect(editor.project.sheets[0].wires==sheet.wires);#expect(editor.project.sheets[0].labels==sheet.labels)
        let copy=try EDCanvasInteraction.edits(for:.duplicate,project:editor.project,context:context,objectIDs:[bus.id,entry.id])
        try editor.apply(copy,expectedRevision:1)
        let copied=editor.project.sheets[0].buses[1]
        #expect(copied.id != bus.id)
        #expect(Set(copied.entries!.map(\.id)).isDisjoint(with:Set(bus.entries!.map(\.id))))
        #expect(copied.entries?.count==2);#expect(copied.members==bus.members)
    }
    @Test func twoEntryUpdatesCoalesceAndDeleteOnlyTheSelectedDrawing() throws {
        let p=fixture(),sheet=p.sheets[0],entries=try #require(sheet.buses[0].entries),context=EDADocumentContext.schematic(sheetID:sheet.id)
        let nets=try EDAConnectivity.derive(p).nets
        let edits=try EDCanvasInteraction.move(project:p,context:context,objectIDs:Set(entries.map(\.id)),by:.init(1,1))
        #expect(edits.count==1);var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        #expect(editor.project.sheets[0].buses[0].entries!.map(\.wirePosition)==[.init(3,7),.init(3,15)])
        let deletion=try EDCanvasInteraction.edits(for:.delete,project:editor.project,context:context,objectIDs:[entries[0].id])
        try editor.apply(deletion,expectedRevision:1)
        #expect(editor.project.sheets[0].buses[0].entries!.map(\.id)==[entries[1].id])
        #expect(editor.project.sheets[0].wires==sheet.wires);#expect(editor.project.sheets[0].labels==sheet.labels)
        #expect(try EDAConnectivity.derive(editor.project).nets==nets)
        try editor.undo(expectedRevision:2);#expect(editor.project.sheets[0].buses[0].entries?.count==2)
        #expect(EDCanvasInteraction.availableActions(project:p,context:context,objectIDs:[entries[0].id])==Set(EDCanvasInteraction.Action.allCases))
    }
    @Test func unfoldDraftProjectsOntoRealSegmentAndFencesItsOriginal() throws {
        var p=fixture();p.sheets[0].buses[0].points=[.zero,.init(10,10)]
        let sheet=p.sheets[0],bus=sheet.buses[0]
        let draft=try EDBusUnfoldDraft(project:p,sheetID:sheet.id,busID:bus.id,member:"D0",at:.init(1,7))
        #expect(draft.busPosition == .init(4,4))
        let plan=try draft.plan(wirePoints:[.init(20,4),.init(30,4)])
        try plan.validateSource(p)
        var changed=p;changed.sheets[0].buses[0].members=["OTHER"]
        #expect(throws:EDAError.self){try plan.validateSource(changed)}
        #expect(throws:EDAError.self){try EDBusUnfoldDraft(project:p,sheetID:sheet.id,busID:bus.id,member:"D2",at:.zero)}
        #expect(throws:EDAError.cancelled){try draft.plan(wirePoints:[.init(20,4),.init(30,4)],cancelled:{true})}
    }
    @MainActor @Test func preparedGestureUsesExistingSavedSessionAndUndo() async throws {
        var p=fixture();p.sheets[0].wires=[];p.sheets[0].labels=[];p.sheets[0].buses[0].entries=nil
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:p)
        let session=try await EDWorkbenchSession(store:store)
        let sheet=p.sheets[0],draft=try EDBusUnfoldDraft(project:p,sheetID:sheet.id,busID:sheet.buses[0].id,member:"D1",at:.init(0,12))
        let plan=try await Task.detached{try draft.plan(wirePoints:[.init(2,14),.init(10,14)])}.value
        try plan.validateSource(session.project)
        try await session.apply(plan.edits,expectedRevision:plan.revision,cancelBeforeCommit:true)
        #expect(session.revision==1);#expect(session.canUndo)
        let saved=try await store.load();#expect(saved.project==session.project)
        #expect(saved.project.sheets[0].labels.map(\.name)==["D1"])
        try await session.undo(expectedRevision:1)
        #expect(session.project.sheets[0].buses[0].entries==nil)
        #expect(session.project.sheets[0].wires.isEmpty);#expect(try await store.load().project==session.project)
    }
}
