// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

@Suite("Explicit scalar label scope")
struct EDAScalarLabelScopeTests {
    private func namedWire(_ name: String, y: Double, scope: EDALabelScope) -> (EDAWire, EDANetLabel) {
        let wire = EDAWire(points: [.init(0,y),.init(20,y)])
        return (wire, .init(name: name, position: .init(0,y), scope: scope))
    }
    @Test func sameSheetMixedScopeLabelsShareOneNet() throws {
        var project = EDAProject(title: "same sheet")
        let rows = [namedWire("DATA0",y:0,scope:.local),namedWire("DATA0",y:10,scope:.global),namedWire("DATA0",y:20,scope:.hierarchical)]
        project.sheets[0].wires = rows.map(\.0); project.sheets[0].labels = rows.map(\.1)
        let before = project
        let nets = try EDAConnectivity.derive(project).nets
        #expect(nets.count == 1)
        #expect(nets.first?.wireIDs.count == 3)
        #expect(nets.first?.labels == ["DATA0"])
        #expect(project == before)
    }
    @Test func globalsCrossSheetsWithoutPullingAnUnrelatedLocalSheet() throws {
        var project = EDAProject(title: "global scope")
        let a = namedWire("DATA0",y:0,scope:.global), b = namedWire("DATA0",y:0,scope:.global), c = namedWire("DATA0",y:0,scope:.local)
        project.sheets = [EDASheet(name:"A",wires:[a.0],labels:[a.1]),EDASheet(name:"B",wires:[b.0],labels:[b.1]),EDASheet(name:"C",wires:[c.0],labels:[c.1])]
        let nets = try EDAConnectivity.derive(project).nets
        #expect(nets.count == 2)
        let global = try #require(nets.first { $0.wireIDs.contains(a.0.id) })
        #expect(global.wireIDs.contains(b.0.id)); #expect(!global.wireIDs.contains(c.0.id))
    }
    @Test func localsRemainSheetScoped() throws {
        var project = EDAProject(title:"local scope")
        let a = namedWire("DATA0",y:0,scope:.local), b = namedWire("DATA0",y:0,scope:.local)
        project.sheets = [EDASheet(name:"A",wires:[a.0],labels:[a.1]),EDASheet(name:"B",wires:[b.0],labels:[b.1])]
        let nets = try EDAConnectivity.derive(project).nets
        #expect(nets.count == 2); #expect(Set(nets.map(\.id)).count == 2)
        #expect(nets.allSatisfy { $0.wireIDs.count == 1 })
    }
    @Test func differentExplicitMembersNeverShortAndReorderingKeepsIdentities() throws {
        var project = EDAProject(title:"literal members")
        let rows = [namedWire("DATA0",y:0,scope:.local),namedWire("DATA0",y:10,scope:.global),
                    namedWire("DATA1",y:20,scope:.local),namedWire("DATA1",y:30,scope:.global)]
        project.sheets[0].wires=rows.map(\.0);project.sheets[0].labels=rows.map(\.1)
        project.sheets[0].buses=[.init(name:"DATA",members:["DATA0","DATA1"],points:[.init(10,-5),.init(10,35)])]
        let nets=try EDAConnectivity.derive(project).nets
        #expect(nets.count == 2)
        let d0=try #require(nets.first{$0.wireIDs.contains(rows[0].0.id)})
        let d1=try #require(nets.first{$0.wireIDs.contains(rows[2].0.id)})
        #expect(d0.id != d1.id);#expect(Set(d0.wireIDs) == [rows[0].0.id,rows[1].0.id]);#expect(Set(d1.wireIDs) == [rows[2].0.id,rows[3].0.id])
        project.sheets[0].labels.reverse();project.sheets[0].buses[0].members.reverse()
        project.sheets[0].buses[0].name="display name is not a net prefix"
        #expect(try EDAConnectivity.derive(project).nets == nets)
    }
}
