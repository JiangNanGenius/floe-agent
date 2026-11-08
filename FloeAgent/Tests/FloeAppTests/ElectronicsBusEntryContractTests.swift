// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeApp

@Suite("Electronics explicit bus member contract")
@MainActor struct ElectronicsBusEntryContractTests {
    private func fixture()->EDAProject{
        var p=EDAProject(title:"member contract")
        p.sheets[0].buses=[.init(name:"DATA",members:["D0","D1"],points:[.zero,.init(0,20)])]
        return p
    }
    private func command(_ p:EDAProject,_ member:String,_ y:Double)->[String:Any]{
        ["op":"bus.unfold","sheetID":p.sheets[0].id.uuidString,"busID":p.sheets[0].buses[0].id.uuidString,"member":member,
         "busPosition":["x":0,"y":y],"wirePoints":[["x":2,"y":y+2],["x":10,"y":y+2]]]
    }
    private func text(_ commands:[[String:Any]])throws->String{String(decoding:try JSONSerialization.data(withJSONObject:commands),as:UTF8.self)}
    @Test func explicitMembersShareOneBatchButNeverOneNet()throws{
        let p=fixture();let raw=try text([command(p,"D0",4),command(p,"D1",12)])
        guard case .edits(let edits)=try StudioElectronicsContract.decode(raw,project:p) else{Issue.record("expected ordinary edits");return}
        var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        #expect(editor.project.revision==1);#expect(editor.project.sheets[0].buses[0].entries?.count==2)
        let erc=try EDAERC.check(editor.project);#expect(erc.issues.isEmpty)
        #expect(Set(erc.netlist.nets.map(\.name))==["D0","D1"]);#expect(erc.netlist.nets.count==2)
        let capabilities=try StudioElectronicsContract.capabilities(editor.project)
        #expect(capabilities.editCommands.contains("bus.unfold"));#expect(capabilities.commandFormats["bus.unfold"] != nil)
    }
    @Test func unknownMemberOrHiddenMappingIsRejectedAtomically()throws{
        let p=fixture()
        #expect(throws:(any Error).self){try StudioElectronicsContract.decode(text([command(p,"D0",4),command(p,"D[0..1]",12)]),project:p)}
        var hidden=command(p,"D0",4);hidden["labelID"]=UUID().uuidString
        #expect(throws:(any Error).self){try StudioElectronicsContract.decode(text([hidden]),project:p)}
        var invalid=command(p,"D0",4);invalid["busPosition"]=["x":9,"y":4]
        #expect(throws:(any Error).self){try StudioElectronicsContract.decode(text([invalid]),project:p)}
        #expect(p.revision==0);#expect(p.sheets[0].wires.isEmpty)
    }
    @Test func nativePutPreservesEntriesAndGraphicalRemovalPreservesElectricalAuthority()throws{
        var p=fixture();let entry=EDABusEntry(busPosition:.init(0,4),wirePosition:.init(2,6))
        p.sheets[0].buses[0].entries=[entry]
        p.sheets[0].wires=[.init(points:[.init(2,6),.init(10,6)])];p.sheets[0].labels=[.init(name:"D0",position:.init(2,6))]
        let native=try JSONSerialization.jsonObject(with:JSONEncoder().encode(p.sheets[0].buses[0]))
        guard case .edits(let put)=try StudioElectronicsContract.decode(text([["op":"native.put","kind":"bus","sheetID":p.sheets[0].id.uuidString,"value":native]]),project:p) else{Issue.record("expected native bus edit");return}
        var editor=try EDAEditingSession(project:p);try editor.apply(put,expectedRevision:0)
        #expect(editor.project.sheets[0].buses[0].entries==[entry])
        guard case .edits(let remove)=try StudioElectronicsContract.decode(text([["op":"schematic.remove","sheetID":p.sheets[0].id.uuidString,"objectID":entry.id.uuidString]]),project:editor.project) else{Issue.record("expected graphical remove");return}
        try editor.apply(remove,expectedRevision:editor.project.revision)
        #expect(editor.project.sheets[0].wires==p.sheets[0].wires);#expect(editor.project.sheets[0].labels==p.sheets[0].labels)
        #expect(editor.project.sheets[0].buses[0].entries?.isEmpty==true)
    }
}
#endif
