// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

@Suite("FloeElectronicsCore.Manufacturing")
struct EDAManufacturingTests {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private func fixture() -> EDAProject {
        var p = EDAProject(id: id(1), title: "Manufacturing fixture <not a filename>*")
        p.revision = 7
        var b = EDABoard(id: id(2), layers: [.init("F.Cu", kind: .copper), .init("core1", kind: .dielectric, thickness: 0.5),
            .init("In1.Cu", kind: .copper), .init("core2", kind: .dielectric, thickness: 0.5), .init("In2.Cu", kind: .copper),
            .init("core3", kind: .dielectric, thickness: 0.5), .init("B.Cu", kind: .copper)],
            outline: [.init(-5,-5),.init(60,-5),.init(60,40),.init(-5,40)])
        b.edgePlated = false
        b.cutouts = [[.init(40,20),.init(45,20),.init(45,25),.init(40,25)]]
        let front = EDAFootprintDefinition(id: id(10), name: "Actual pad shapes", pads: [
            .init(id: id(11), number: "1", position: .zero, size: .init(2,2), drill: 0.8, layers: ["F.Cu","B.Cu"], drillPlated: true),
            .init(id: id(12), number: "2", position: .init(5,0), size: .init(4,1), angle: 45, shape: .rectangle),
            .init(id: id(13), number: "3", position: .init(10,0), size: .init(4,2), angle: 45, shape: .oval)])
        let back = EDAFootprintDefinition(id: id(30), name: "Mirrored back pad", pads: [
            .init(id: id(31), number: "1", position: .init(2,0), size: .init(2,1), angle: 30, shape: .rectangle)])
        p.footprints = [front, back]
        b.footprints = [.init(id: id(20), definitionID: front.id, position: .init(10,10)),
                        .init(id: id(40), definitionID: back.id, position: .init(35,10), angle: 90, side: "B.Cu")]
        b.tracks = [.init(id: id(50), netID: "A", width: 0.25, points: [.init(10,15),.init(20,15)]),
                    .init(id: id(51), netID: "B", layer: "B.Cu", width: 0.4, points: [.init(30,15),.init(40,15)])]
        b.vias = [.init(id: id(60), netID: "A", position: .init(25,10), diameter: 1, drill: 0.4),
                  .init(id: id(61), netID: "A", position: .init(26,12), diameter: 0.8, drill: 0.3, endLayer: "In1.Cu"),
                  .init(id: id(62), netID: "A", position: .init(28,12), diameter: 0.7, drill: 0.2, startLayer: "In1.Cu", endLayer: "In2.Cu")]
        var zone = EDAZone(id: id(70), netID: "A", layer: "In1.Cu", outline: [.init(5,20),.init(15,20),.init(15,28),.init(5,28)])
        zone.fillRevision = p.revision
        zone.filledPolygons = [[.init(5,20),.init(15,20),.init(15,22),.init(7,22),.init(7,28),.init(5,28)]]
        b.zones = [zone]
        b.holes = [.init(id: id(80), position: .init(10,30), diameter: 1),
                   .init(id: id(81), position: .init(20,30), diameter: 1.2, endPosition: .init(24,33)),
                   .init(id: id(82), position: .init(30,30), diameter: 0.9, plated: true, endPosition: .init(35,30))]
        p.boards = [b]; return p
    }
    private func file(_ bundle: EDAExchangeBundle, _ name: String) throws -> EDAExchangeFile {
        try #require(bundle.files.first { $0.name == name })
    }
    private func manifest(_ bundle: EDAExchangeBundle) throws -> [String: Any] {
        let data = try #require(bundle.files.first { $0.name.hasSuffix("manifest.json") }?.data)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func saveEvidence(_ bundle: EDAExchangeBundle, folder: String) throws {
        guard let root = ProcessInfo.processInfo.environment["FLOE_MANUFACTURING_EVIDENCE_ROOT"] else { return }
        let dir = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in bundle.files { try file.data.write(to: dir.appendingPathComponent(file.name), options: .atomic) }
    }
    private func failureCode(_ expected: String, _ body: () throws -> EDAExchangeBundle) throws {
        do { _ = try body(); Issue.record("Manufacturing export unexpectedly succeeded: \(expected)") }
        catch let failure as EDAManufacturingFailure { #expect(failure.issues.contains { $0.code == expected && !$0.path.isEmpty }) }
    }

    @Test("Real board produces separate Gerber copper layers/profile and typed drilling spans, never SVG renamed")
    func goldenFourLayerGeometry() throws {
        let p = fixture(), before = p
        let copper = try EDAExchange.export(p, format: .gerber, boardID: p.boards[0].id)
        let drill = try EDAExchange.export(p, format: .excellon, boardID: p.boards[0].id)
        #expect(copper.files.map(\.name) == ["Copper-L01.gbr","Copper-L02.gbr","Copper-L03.gbr","Copper-L04.gbr","Outline.gbr","Gerber-manifest.json"])
        #expect(Set(drill.files.map(\.name)) == ["Drill-NPTH-L01-L04.drl","Drill-PTH-L01-L02.drl","Drill-PTH-L01-L04.drl","Drill-PTH-L02-L03.drl","Excellon-manifest.json"])
        let top = String(decoding: try file(copper,"Copper-L01.gbr").data, as: UTF8.self)
        #expect(top.contains("%FSLAX66Y66*%") && top.contains("%MOMM*%") && top.contains("%TF.FileFunction,Copper,L1,Top*%"))
        #expect(top.contains("21,1,4.000000,1.000000,0,0,45.000000000"))
        #expect(!top.contains("<svg") && !top.contains("%LR"))
        let bottom = String(decoding: try file(copper,"Copper-L04.gbr").data, as: UTF8.self)
        #expect(bottom.contains("X35000000Y8000000D03*"))
        #expect(bottom.contains("2.000000,1.000000,0,0,240.000000000"))
        let inner = String(decoding: try file(copper,"Copper-L02.gbr").data, as: UTF8.self)
        #expect(inner.contains("G36*") && inner.contains("X7000000Y22000000D01*"))
        let pth = String(decoding: try file(drill,"Drill-PTH-L01-L04.drl").data, as: UTF8.self)
        #expect(pth.contains("; #@! TF.FileFunction,Plated,1,4,PTH,Mixed"))
        #expect(pth.contains("G00X30.000000Y30.000000") && pth.contains("M15\nG01X35.000000Y30.000000\nM16"))
        #expect(pth.hasSuffix("M30\n") && !pth.contains("<svg"))
        #expect(p == before && copper.projectID == p.id && copper.revision == p.revision)
        try saveEvidence(copper, folder: "four-layer-gerber"); try saveEvidence(drill, folder: "four-layer-excellon")
    }

    @Test("Every manifest hash and original revision bind the exact generated bytes; ordering is deterministic")
    func manifestAndDeterminism() throws {
        var p = fixture(); p.revision = UInt64.max; p.boards[0].zones[0].fillRevision = p.revision
        let first = try EDAExchange.export(p, format: .gerber)
        let m = try manifest(first)
        #expect(m["sourceRevision"] as? String == String(UInt64.max))
        #expect(m["boardID"] as? String == p.boards[0].id.uuidString)
        #expect(m["completeFabricationSet"] as? Bool == false && m["unit"] as? String == "mm")
        for record in try #require(m["files"] as? [[String:Any]]) {
            let actual = try file(first, try #require(record["name"] as? String))
            #expect(record["sha256"] as? String == actual.sha256 && record["byteCount"] as? Int == actual.data.count)
        }
        let second = try EDAExchange.export(p, format: .gerber)
        #expect(first.files == second.files)
        p.boards[0].footprints.reverse(); p.boards[0].tracks.reverse(); p.boards[0].vias.reverse()
        #expect(try EDAExchange.export(p, format: .gerber).files == first.files)
    }

    @Test("Analytic rotated rectangle and capsule pad macros retain exact geometry for independent parser goldens")
    func isolatedPadGoldens() throws {
        for shape in [EDAPadShape.rectangle, .oval] {
            var p = EDAProject(id: id(100), title: "Isolated shape"); p.boards[0].id = id(101)
            let def = EDAFootprintDefinition(id: id(102), name: "Shape", pads: [
                .init(id: id(103), number: "1", position: .zero, size: shape == .rectangle ? .init(4,1) : .init(4,2), angle: 45, shape: shape)])
            p.footprints = [def]; p.boards[0].footprints = [.init(id: id(104), definitionID: def.id, position: .init(15,15))]
            let bundle = try EDAExchange.export(p, format: .gerber)
            try saveEvidence(bundle, folder: shape.rawValue + "-45-gerber")
            #expect(try file(bundle, "Copper-L01.gbr").data.count > 100)
            #expect(try manifest(bundle)["emptyCopperLayers"] as? [Int] == [2])
        }
    }

    @Test("Unknown profile plating never becomes an invented NP attribute")
    func profilePlatingIsExplicit() throws {
        var p = fixture(); p.boards[0].edgePlated = nil
        var bundle = try EDAExchange.export(p, format: .gerber)
        #expect(String(decoding: try file(bundle,"Outline.gbr").data, as: UTF8.self).contains("%TF.FileFunction,Other,ProfileGeometry*%"))
        #expect(bundle.limitations.contains { $0.contains("plating is unspecified") })
        p.boards[0].edgePlated = true; bundle = try EDAExchange.export(p, format: .gerber)
        #expect(String(decoding: try file(bundle,"Outline.gbr").data, as: UTF8.self).contains("%TF.FileFunction,Profile,P*%"))
        p.boards[0].edgePlated = false; bundle = try EDAExchange.export(p, format: .gerber)
        #expect(String(decoding: try file(bundle,"Outline.gbr").data, as: UTF8.self).contains("%TF.FileFunction,Profile,NP*%"))
    }

    @Test("Missing/stale zones, pad radius, library, layer and unassigned graphics fail instead of dropping geometry")
    func incompleteCopperCannotSucceed() throws {
        var p = fixture(); p.boards[0].zones[0].filledPolygons = []
        try failureCode("zone_fill_not_current") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.boards[0].zones[0].fillRevision = 0
        try failureCode("zone_fill_not_current") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.footprints[0].pads[0].shape = .roundRectangle
        try failureCode("round_rectangle_radius_missing") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.footprints[0].pads[0].size = .init(2,3)
        try failureCode("circle_pad_not_round") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.boards[0].footprints[0].definitionID = id(999)
        try failureCode("missing_footprint_definition") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.footprints[0].pads[0].layers = ["*.Cu"]
        try failureCode("pad_layer_unsupported") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.boards[0].graphics = [.line(.zero,.init(1,1),width:0.1)]
        try failureCode("graphic_layer_unspecified") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.footprints[0].graphics = [.line(.zero,.init(1,1),width:0.1)]
        try failureCode("graphic_layer_unspecified") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.preservedSource = ["unmapped":"retained original payload"]
        try failureCode("unmapped_preserved_source") { try EDAExchange.export(p, format: .gerber) }
    }

    @Test("Drill plating must be explicitly set; unknown pad plating cannot silently become plated or non-plated")
    func unspecifiedPadPlatingFailsDrillOnly() throws {
        var p = fixture(); p.footprints[0].pads[0].drillPlated = nil
        try failureCode("pad_drill_plating_unspecified") { try EDAExchange.export(p, format: .excellon) }
        #expect(try EDAExchange.export(p, format: .gerber).files.count == 6)
        p.footprints[0].pads[0].drillPlated = false
        let bundle = try EDAExchange.export(p, format: .excellon)
        let npth = String(decoding: try file(bundle,"Drill-NPTH-L01-L04.drl").data, as: UTF8.self)
        #expect(npth.contains("X10.000000Y10.000000"))
    }

    @Test("Hole/slot width equals the actual tool diameter; blind/buried spans are not emitted as through holes")
    func drillingToolsAndSpans() throws {
        let b = try EDAExchange.export(fixture(), format: .excellon)
        let npth = String(decoding: try file(b,"Drill-NPTH-L01-L04.drl").data, as: UTF8.self)
        #expect(npth.contains("T01C1.000000\nT02C1.200000") && npth.contains("G00X20.000000Y30.000000"))
        let blind = String(decoding: try file(b,"Drill-PTH-L01-L02.drl").data, as: UTF8.self)
        let buried = String(decoding: try file(b,"Drill-PTH-L02-L03.drl").data, as: UTF8.self)
        #expect(blind.contains("Plated,1,2,Blind,Drill") && buried.contains("Plated,2,3,Buried,Drill"))
        #expect(try manifest(b)["files"] as? [[String:Any]] != nil)
    }

    @Test("Slot endpoints reject nonfinite, out-of-range and zero-length values; no drill means no plating metadata")
    func newGeometryValidation() throws {
        for end in [EDAPoint(.nan,0), .init(.infinity,0), .init(200_000,0), .init(20,30)] {
            var p = fixture(); p.boards[0].holes[1].endPosition = end
            #expect(throws: EDAError.self) { try EDAValidation.validate(p) }
        }
        var p = fixture(); p.footprints[0].pads[0].drill = nil
        #expect(throws: EDAError.invalid("pad plating without drill")) { try EDAValidation.validate(p) }
    }

    @Test("No holes means an explicit no-drill result; missing boards, cancellation and sub-resolution sizes fail")
    func emptyAndBudgetBoundaries() throws {
        var p = EDAProject(title: "No drilling")
        try failureCode("no_drilling_geometry") { try EDAExchange.export(p, format: .excellon) }
        #expect(throws: EDAError.missing("manufacturing board")) { try EDAExchange.export(p, format: .gerber, boardID: id(999)) }
        #expect(throws: EDAError.cancelled) { try EDAExchange.export(p, format: .gerber, cancelled: { true }) }
        p.boards[0].tracks = [.init(netID:"A",width:0.000_000_1,points:[.init(10,10),.init(20,10)])]
        try failureCode("dimension_below_resolution_or_out_of_range") { try EDAExchange.export(p, format: .gerber) }
        p = fixture(); p.boards[0].layers.swapAt(0,6)
        try failureCode("copper_stack_surfaces_unspecified") { try EDAExchange.export(p, format: .gerber) }
    }

    @Test("Existing six formats remain available and slot SVG is a real capsule path")
    func originalFormatsAndSlotDrawing() throws {
        let p = fixture()
        for format in [EDAExportFormat.project,.netlist,.bom,.positions,.boardSVG,.schematicSVG] {
            #expect(try !EDAExchange.export(p, format: format).files.isEmpty)
        }
        let svg = String(decoding: try #require(EDAExchange.export(p, format: .boardSVG).files.first).data, as: UTF8.self)
        #expect(svg.contains("A 0.600000 0.600000 0 0 1"))
        let native = try #require(EDAExchange.export(p, format: .project).files.first)
        let reopened = try EDAExchange.decodeProject(native.data)
        #expect(reopened.boards[0].holes[1].endPosition == EDAPoint(24,33))
        #expect(reopened.boards[0].edgePlated == false && reopened.footprints[0].pads[0].drillPlated == true)
        #expect(EDAExportFormat(rawValue: "fabricationPackage") == nil)
        let encoded = try JSONEncoder().encode(p)
        var raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String:Any])
        var boards = try #require(raw["boards"] as? [[String:Any]])
        boards[0].removeValue(forKey:"edgePlated")
        var holes = try #require(boards[0]["holes"] as? [[String:Any]])
        for i in holes.indices { holes[i].removeValue(forKey:"endPosition") }; boards[0]["holes"] = holes
        raw["boards"] = boards
        var definitions = try #require(raw["footprints"] as? [[String:Any]])
        for i in definitions.indices {
            var pads = try #require(definitions[i]["pads"] as? [[String:Any]])
            for j in pads.indices { pads[j].removeValue(forKey:"drillPlated") }; definitions[i]["pads"] = pads
        }
        raw["footprints"] = definitions
        let legacy = try JSONSerialization.data(withJSONObject:["format":"org.floe.electronics.project","version":1,"project":raw],options:[.sortedKeys])
        let decoded = try EDAExchange.decodeProject(legacy)
        #expect(decoded.boards[0].edgePlated == nil && decoded.boards[0].holes.allSatisfy { $0.endPosition == nil })
        #expect(decoded.footprints.flatMap(\.pads).allSatisfy { $0.drillPlated == nil })
        #expect(decoded.boards[0].holes[0].position == p.boards[0].holes[0].position && !decoded.boards[0].holes[0].plated)
        try failureCode("pad_drill_plating_unspecified") { try EDAExchange.export(decoded,format:.excellon) }
        if let root=ProcessInfo.processInfo.environment["FLOE_MANUFACTURING_EVIDENCE_ROOT"] {try legacy.write(to:URL(fileURLWithPath:root).appendingPathComponent("legacy-v1-without-new-fields.floeeda"))}
    }
}
