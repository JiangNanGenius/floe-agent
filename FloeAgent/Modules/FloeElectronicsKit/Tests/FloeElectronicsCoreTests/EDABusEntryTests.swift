// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

@Suite("Graphical bus entry and literal members")
struct EDABusEntryTests {
    @Test func undeclaredMembersHavePositionedERCInsteadOfAnEmptyPass() throws {
        var p = EDAProject(title: "unknown members")
        let bus = EDABus(name: "DATA", members: [], points: [.zero,.init(10,0)])
        p.sheets[0].buses = [bus]
        let result = try EDAERC.check(p)
        let issue = try #require(result.issues.first { $0.code == "bus_members_missing" })
        #expect(issue.objectIDs.contains(bus.id)); #expect(issue.position == .zero)
        #expect(issue.severity == .warning); #expect(result.netlist.nets.isEmpty)
    }
    private func project() -> EDAProject {
        var p = EDAProject(title:"literal bus")
        p.sheets[0].buses = [.init(name:"DISPLAY",members:["D0","D1"],points:[.zero,.init(0,20)])]
        return p
    }
    @Test func oldJSONAndCurrentManufacturingFieldsRemainCompatible() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"name\":\"DATA\",\"members\":[\"D0\"],\"points\":[{\"x\":0,\"y\":0},{\"x\":0,\"y\":10}]}".utf8)
        let bus = try JSONDecoder().decode(EDABus.self,from:data)
        #expect(bus.entries == nil); #expect(bus.members == ["D0"])
        let encoded = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(bus)) as? [String:Any])
        #expect(encoded["entries"] == nil)
        var p = project(); p.sheets[0].buses = [bus]
        p.boards[0].edgePlated = true
        var hole = EDAHole(position:.init(10,10),diameter:1)
        hole.endPosition = .init(12,10); p.boards[0].holes = [hole]
        let decoded = try JSONDecoder().decode(EDAProject.self,from:JSONEncoder().encode(p))
        #expect(decoded.boards[0].edgePlated == true); #expect(decoded.boards[0].holes[0].endPosition == .init(12,10))
        #expect(decoded.sheets[0].buses[0].entries == nil); try EDAValidation.validate(decoded)
    }
    @Test func globalEntryIDsFiniteNonzeroAndBudgetsAreValidated() throws {
        var p = project()
        let entry = EDABusEntry(busPosition:.init(0,4),wirePosition:.init(2,6))
        p.sheets[0].buses[0].entries = [entry]; try EDAValidation.validate(p)
        var other = EDASheet(name:"other"); other.buses = [.init(name:"D",members:["D0"],points:[.zero,.init(0,10)],entries:[entry])]
        p.sheets.append(other)
        #expect(throws:EDAError.self) { try EDAValidation.validate(p) }
        p.sheets.removeLast(); p.sheets[0].buses[0].entries![0].id = p.boards[0].id
        #expect(throws:EDAError.self) { try EDAValidation.validate(p) }
        p.sheets[0].buses[0].entries = [entry]; p.sheets[0].buses[0].entries![0].wirePosition = entry.busPosition
        #expect(throws:EDAError.self) { try EDAValidation.validate(p) }
        p.sheets[0].buses[0].entries![0].wirePosition = .init(.nan,1)
        #expect(throws:EDAError.self) { try EDAValidation.validate(p) }
        p.sheets[0].buses[0].entries = (0...EDABusEditing.maximumEntries).map { _ in EDABusEntry(busPosition:.zero,wirePosition:.init(1,1)) }
        #expect(throws:EDAError.self) { try EDAValidation.validate(p) }
    }
    @Test func explicitlyUnfoldedMembersHaveIndependentRealNets() throws {
        var editor = try EDAEditingSession(project:project())
        let sheet = editor.project.sheets[0].id, bus = editor.project.sheets[0].buses[0].id
        let a = try EDABusUnfold.newWire(project:editor.project,sheetID:sheet,busID:bus,member:"D0",busPosition:.init(0,4),wirePoints:[.init(2,6),.init(10,6)])
        try editor.applyBusUnfold(a); #expect(editor.project.revision == 1)
        let b = try EDABusUnfold.newWire(project:editor.project,sheetID:sheet,busID:bus,member:"D1",busPosition:.init(0,12),wirePoints:[.init(2,14),.init(10,14)])
        try editor.applyBusUnfold(b); #expect(editor.project.revision == 2)
        let result = try EDAERC.check(editor.project)
        #expect(result.issues.isEmpty); #expect(result.netlist.nets.count == 2)
        #expect(Set(result.netlist.nets.map(\.name)) == ["D0","D1"])
        #expect(result.netlist.nets.allSatisfy { $0.wireIDs.count == 1 })
        let entryIDs = Set(editor.project.sheets[0].buses[0].entries!.map(\.id))
        #expect(!result.netlist.nets.flatMap(\.wireIDs).contains { entryIDs.contains($0) })
        #expect(editor.project.sheets[0].labels.map(\.name) == ["D0","D1"])
        #expect(throws:EDAError.self) { try EDABusUnfold.newWire(project:editor.project,sheetID:sheet,busID:bus,member:"D2",busPosition:.init(0,2),wirePoints:[.init(2,4),.init(8,4)]) }
    }
    @Test func graphicalCrossingDoesNotCreateAJunctionAndAmbiguityIsNotOrderedAway() throws {
        var p = project()
        let a = EDAWire(points:[.init(-5,0),.init(5,0)]), b = EDAWire(points:[.init(0,-5),.init(0,5)])
        p.sheets[0].wires=[a,b];p.sheets[0].labels=[.init(name:"D0",position:.init(-5,0)),.init(name:"D1",position:.init(0,-5))]
        p.sheets[0].buses[0].points=[.init(10,-5),.init(10,10)]
        let entry=EDABusEntry(busPosition:.init(10,0),wirePosition:.zero)
        p.sheets[0].buses[0].entries=[entry]
        let result=try EDAERC.check(p)
        #expect(result.netlist.nets.count == 2)
        let issue=try #require(result.issues.first{$0.code=="bus_entry_ambiguous_nets"})
        #expect(issue.position == .zero);#expect(issue.objectIDs.contains(entry.id));#expect(issue.objectIDs.contains(a.id));#expect(issue.objectIDs.contains(b.id))
        #expect(throws:EDAError.self) { try EDABusUnfold.existingWire(project:p,sheetID:p.sheets[0].id,busID:p.sheets[0].buses[0].id,member:"D0",busPosition:.init(10,0),wireID:a.id,wirePosition:.zero) }
        p.sheets[0].junctions=[.init(position:.zero)]
        let short=try EDAERC.check(p)
        #expect(short.netlist.nets.count == 1);#expect(short.issues.contains{$0.code=="bus_member_short" && $0.severity == .error})
    }
    @Test func missingWireMemberAndDetachedBusEndHavePositionedDiagnostics() throws {
        var p=project();let entry=EDABusEntry(busPosition:.init(50,50),wirePosition:.init(2,6))
        p.sheets[0].buses[0].entries=[entry]
        let missing=try EDAERC.check(p)
        #expect(missing.issues.contains{$0.code=="bus_entry_no_wire" && $0.position==entry.wirePosition})
        #expect(missing.issues.contains{$0.code=="bus_entry_detached" && $0.position==entry.busPosition})
        p.sheets[0].wires=[.init(points:[.init(2,6),.init(10,6)])]
        p.sheets[0].labels=[.init(name:"UNRELATED",position:.init(2,6))]
        #expect(try EDAERC.check(p).issues.contains{$0.code=="bus_entry_member_unidentified"})
    }
    @Test func deletingAnEntryDoesNotDeleteOrDisconnectItsWireAndLabel() throws {
        var editor=try EDAEditingSession(project:project());let sheet=editor.project.sheets[0]
        let plan=try EDABusUnfold.newWire(project:editor.project,sheetID:sheet.id,busID:sheet.buses[0].id,member:"D0",busPosition:.init(0,4),wirePoints:[.init(2,6),.init(10,6)])
        try editor.applyBusUnfold(plan)
        let saved=editor.project.sheets[0], entry=try #require(saved.buses[0].entries?.first)
        let nets=try EDAConnectivity.derive(editor.project).nets
        try editor.apply([.removeSchematicObject(sheet:sheet.id,object:entry.id)],expectedRevision:1)
        #expect(editor.project.sheets[0].buses[0].entries?.isEmpty == true)
        #expect(editor.project.sheets[0].wires==saved.wires);#expect(editor.project.sheets[0].labels==saved.labels)
        #expect(try EDAConnectivity.derive(editor.project).nets==nets)
        try editor.undo(expectedRevision:2);#expect(editor.project.sheets[0].buses[0].entries?.first?.id==entry.id)
        try editor.redo(expectedRevision:3);#expect(editor.project.sheets[0].buses[0].entries?.isEmpty == true)
    }
    @Test func movesPreserveIDsAndCopiesRegenerateNestedEntryIDs() throws {
        var bus=project().sheets[0].buses[0];let entry=EDABusEntry(busPosition:.init(0,4),wirePosition:.init(2,6));bus.entries=[entry]
        let moved=EDABusEditing.transformed(bus){$0 + .init(10,20)}
        #expect(moved.id==bus.id);#expect(moved.entries?.first?.id==entry.id)
        #expect(moved.entries?.first?.busPosition == .init(10,24));#expect(moved.entries?.first?.wirePosition == .init(12,26))
        let copy=EDABusEditing.duplicate(moved)
        #expect(copy.id != moved.id);#expect(copy.entries?.first?.id != entry.id)
        #expect(copy.entries?.first?.busPosition == moved.entries?.first?.busPosition);#expect(copy.members==bus.members)
        var p=project();p.sheets[0].buses=[moved,copy];try EDAValidation.validate(p)
    }
    @Test func staleWrongSourceAndCancelledPlansDoNotMutateOrCreateUndo() throws {
        let p=project(),sheet=p.sheets[0]
        let plan=try EDABusUnfold.newWire(project:p,sheetID:sheet.id,busID:sheet.buses[0].id,member:"D0",busPosition:.init(0,4),wirePoints:[.init(2,6),.init(10,6)])
        var changed=p;changed.title="same ID and revision, different source"
        var wrong=try EDAEditingSession(project:changed)
        #expect(throws:EDAError.self){try wrong.applyBusUnfold(plan)};#expect(wrong.project==changed);#expect(!wrong.canUndo)
        var cancelled=try EDAEditingSession(project:p)
        #expect(throws:EDAError.cancelled){try cancelled.applyBusUnfold(plan,cancelled:{true})};#expect(cancelled.project==p);#expect(!cancelled.canUndo)
        var stale=try EDAEditingSession(project:p);try stale.apply([.rename("new")],expectedRevision:0)
        #expect(throws:EDAError.staleRevision(expected:0,actual:1)){try stale.applyBusUnfold(plan)}
    }
    @Test func actualStoreCASAndUndoUseOneNativeTransaction() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:project())
        let initial=try await store.load();var editor=try EDAEditingSession(project:initial.project,savedDigest:initial.digest)
        let sheet=editor.project.sheets[0]
        let plan=try EDABusUnfold.newWire(project:editor.project,sheetID:sheet.id,busID:sheet.buses[0].id,member:"D0",busPosition:.init(0,4),wirePoints:[.init(2,6),.init(10,6)])
        try editor.applyBusUnfold(plan)
        let saved=try await store.save(editor.project,expectedRevision:initial.project.revision,expectedDigest:initial.digest)
        #expect(saved.project.revision==1);#expect(saved.project.sheets[0].wires.count==1);#expect(saved.project.sheets[0].labels.count==1);#expect(saved.project.sheets[0].buses[0].entries?.count==1)
        let staleStore=try EDAProjectStore(root:root,projectID:saved.project.id)
        await #expect(throws:(any Error).self){try await staleStore.save(editor.project,expectedRevision:initial.project.revision,expectedDigest:initial.digest)}
        #expect(try await store.load().digest==saved.digest)
        try editor.undo(expectedRevision:1)
        let undone=try await store.save(editor.project,expectedRevision:1,expectedDigest:saved.digest)
        #expect(undone.project.sheets[0].wires.isEmpty);#expect(undone.project.sheets[0].labels.isEmpty);#expect(undone.project.sheets[0].buses[0].entries==nil)
    }

    @Test func SVGAndNativeRoundtripRetainActualEntryGeometryWithoutNewNets() throws {
        var p=project();let entry=EDABusEntry(busPosition:.init(0,4),wirePosition:.init(22,26))
        p.sheets[0].buses[0].entries=[entry]
        let before=try EDAConnectivity.derive(p)
        let svg=try #require(EDAExchange.export(p,format:.schematicSVG).files.first)
        let content=String(decoding:svg.data,as:UTF8.self)
        #expect(content.contains("<polyline points=\"0.000000,-4.000000 22.000000,-26.000000\" fill=\"none\" stroke=\"blue\" stroke-width=\"0.250000\""))
        let original=try #require(EDAExchange.export(p,format:.project).files.first)
        let decoded=try EDAExchange.decodeProject(original.data)
        #expect(decoded==p);#expect(decoded.sheets[0].buses[0].entries==[entry])
        #expect(try EDAConnectivity.derive(decoded)==before)
    }
    @Test func cancelledUnfoldPreparationDoesNotReturnACommitProposal() throws {
        let p=project(),sheet=p.sheets[0]
        #expect(throws:EDAError.cancelled){try EDABusUnfold.newWire(project:p,sheetID:sheet.id,busID:sheet.buses[0].id,member:"D0",busPosition:.init(0,4),wirePoints:[.init(2,6),.init(10,6)],cancelled:{true})}
        #expect(p.revision==0);#expect(p.sheets[0].buses[0].entries==nil)
    }

}
