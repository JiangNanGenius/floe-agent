// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDAPolygonPadTests {
    private let outline: [EDAPoint] = [.init(-1,-2),.init(5,-2),.init(5,-1),.init(1,-1),.init(1,1),.init(5,1),.init(5,2),.init(-1,2)]
    private func fixture() throws -> (EDAProject, String, String) {
        var p = EDAProject(title: "Exact concave pad")
        p.sheets[0].labels = [.init(name:"A",position:.zero,scope:.global),.init(name:"B",position:.init(10,0),scope:.global)]
        let nets = try EDAConnectivity.derive(p)
        let a = try #require(nets.nets.first{$0.name == "A"}?.id), b = try #require(nets.nets.first{$0.name == "B"}?.id)
        let pad = try EDAPolygonPadGeometry.replacingOutline(of: EDAPad(number:"1",position:.zero,layers:["F.Cu","F.Mask","F.Paste"]),with:outline)
        let definition = EDAFootprintDefinition(name:"Concave U",pads:[pad])
        p.footprints = [definition]
        p.boards[0].footprints = [.init(definitionID:definition.id,position:.init(20,20),padNets:["1":a])]
        p.boards[0].drcConstraints = .init(minimumCopperClearance:0.2,minimumTrackWidth:0.1,minimumViaDiameter:0.4,minimumViaDrill:0.2,minimumViaAnnularWidth:0.1)
        p.boards[0].edgePlated = false
        return (p,a,b)
    }
    private func copperErrors(_ p: EDAProject) throws -> [EDADRCIssue] {
        try EDADRC.check(p,boardID:p.boards[0].id).issues.filter{$0.rule == .copperClearance && $0.severity == .error}
    }

    @Test func oldJSONDefaultsStayUnchangedAndNewPolygonRecordsRejectUnknownFields() throws {
        let legacy = EDAPad(number:"1",position:.zero)
        let encoded = try JSONEncoder().encode(legacy)
        let raw = try #require(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        #expect(raw["polygon"] == nil)
        let decoded = try JSONDecoder().decode(EDAPad.self,from:encoded)
        #expect(decoded.shape == .circle && decoded.polygon == nil && decoded.size == .init(1.5,1.5))
        let (p,_,_) = try fixture()
        let exported = try EDAExchange.export(p,format:.project)
        let bytes = try #require(exported.files.first?.data)
        #expect(try EDAExchange.decodeProject(bytes) == p)
        var envelope = try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        envelope["futurePadstack"] = true
        #expect(throws: EDAError.self) { try EDAExchange.decodeProject(JSONSerialization.data(withJSONObject:envelope)) }
    }

    @Test func polygonValidationRejectsFalseMetadataHolesBadLayersAndUnusableOrigins() throws {
        let (p,_,_) = try fixture(), pad = p.footprints[0].pads[0]
        #expect(abs(EDAGeometry.signedArea(outline)-16)<1e-9)
        #expect(pad.size == .init(6,4))
        var reversed = pad; reversed.polygon = Array(outline.reversed()); try EDAPolygonPadGeometry.validate(reversed)
        for points in [
            [.init(2,-1),.init(4,-1),.init(4,1),.init(2,1)], // origin in empty bounding-space
            [.init(0,-1),.init(2,-1),.init(2,1),.init(0,1)], // origin on an edge
            [.init(-1,-1),.init(1,1),.init(-1,1),.init(1,-1)],
            outline+[outline[0]],
            [.init(-1,0),.init(0,0),.init(1,0)],
            [.init(-1,-1),.init(.nan,1),.init(1,-1)]
        ] as [[EDAPoint]] {
            #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.replacingOutline(of:pad,with:points) }
        }
        var invalid = pad; invalid.size.x = 100
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        invalid = pad; invalid.drill = 0.8
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        invalid = pad; invalid.drillPlated = false
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        for layers in [["F.Cu","B.Cu"],["In1.Cu"],["F.Cu","B.Mask"],["F.Cu","F.Cu"],["F.Mask"]] {
            invalid = pad; invalid.layers = layers
            #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        }
        invalid = pad; invalid.shape = .rectangle
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        invalid = pad; invalid.polygon = nil
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
        invalid = pad; invalid.polygon = Array(repeating:.zero,count:257)
        #expect(throws: EDAError.self) { try EDAPolygonPadGeometry.validate(invalid) }
    }

    @Test func actualConcaveCopperDrivesClearanceNetIdentityAndRouteHit() throws {
        var (p,a,b) = try fixture()
        let fp = p.boards[0].footprints[0], pad = p.footprints[0].pads[0]
        let actual = try #require(EDADRCGeometry.pad(pad,in:fp))
        let notch = EDADRCShape(outer:.capsule(.init(23,20),.init(23,20),0.25))
        #expect(abs(try EDADRCGeometry.distance(actual,notch,budget:.init(cancelled:{false})).distance - 0.75)<1e-8)
        #expect(try EDAInteractiveRouting.anchor(p,boardID:p.boards[0].id,at:.init(23,20),layer:"F.Cu",tolerance:0.01) == nil)
        #expect(try EDAInteractiveRouting.anchor(p,boardID:p.boards[0].id,at:.init(23,21.5),layer:"F.Cu",tolerance:0.01)?.netID == a)
        let circle = EDAPad(number:"1",position:.zero,size:.init(0.5,0.5))
        let definition = EDAFootprintDefinition(name:"Notch neighbour",pads:[circle]);p.footprints.append(definition)
        p.boards[0].footprints.append(.init(definitionID:definition.id,position:.init(23,20),padNets:["1":b]))
        #expect(try copperErrors(p).isEmpty) // bbox would falsely short the notch neighbour
        p.boards[0].tracks = [.init(netID:b,width:0.2,points:[.init(23,20),.init(23,21.5)])]
        let errors = try copperErrors(p)
        #expect(errors.contains{$0.measured == 0 && $0.objects.contains(where:{$0.objectID == pad.id})})
        p.boards[0].tracks[0].netID = a
        p.boards[0].footprints.removeLast()
        #expect(try copperErrors(p).isEmpty) // same-net copper is not a spacing violation
        var placed = fp; placed.position = .init(40,30); placed.angle = 30; placed.side = "B.Cu"
        let mirrored = try #require(EDADRCGeometry.pad(pad,in:placed))
        let empty = placed.point(.init(3,0)), copper = placed.point(.init(3,1.5))
        #expect(try EDADRCGeometry.distance(mirrored,.init(outer:.capsule(empty,empty,0)),budget:.init(cancelled:{false})).distance > 0.99)
        #expect(try EDADRCGeometry.distance(mirrored,.init(outer:.capsule(copper,copper,0)),budget:.init(cancelled:{false})).distance < 1e-8)
    }

    @Test func zoneOffsetUsesTheConcaveContourAndUnsupportedThermalFailsAtThePad() throws {
        var (p,a,b) = try fixture()
        var zone = EDAZone(netID:b,outline:[.init(10,10),.init(35,10),.init(35,30),.init(10,30)],thermal:false)
        p.boards[0].zones = [zone]
        let plan = try EDACopperFill.plan(p,boardID:p.boards[0].id)
        let polygons = try #require(plan.polygons[zone.id])
        #expect(polygons.contains{EDAGeometry.contains(.init(23,20),polygon:$0)})
        #expect(!polygons.contains{EDAGeometry.contains(.init(23,21.5),polygon:$0)})
        zone.netID = a; p.boards[0].zones = [zone]
        #expect(!((try EDACopperFill.plan(p,boardID:p.boards[0].id)).report.zones.isEmpty))
        zone.thermal = true; zone.thermalRelief = .creationDefault; p.boards[0].zones = [zone]
        do { _ = try EDACopperFill.plan(p,boardID:p.boards[0].id); Issue.record("Polygon thermal must not invent spokes from bounding size") }
        catch let failure as EDACopperFillFailure {
            #expect(failure.issues.contains{$0.code == "polygon_pad_thermal_unsupported" && $0.objectID == p.footprints[0].pads[0].id && $0.position != nil && !$0.path.isEmpty})
        }
    }

    @Test func realRegionsKeepFrontBackOpeningsNoPasteAndDrillingSeparate() throws {
        var (p,_,_) = try fixture()
        p.boards[0].footprints[0].angle = 30
        let front = p.boards[0].footprints[0]
        p.boards[0].footprints.append(.init(definitionID:p.footprints[0].id,position:.init(50,20),angle:30,side:"B.Cu",padNets:front.padNets))
        p.boards[0].holes = [.init(position:.init(5,5),diameter:1,plated:false)]
        let copper = try EDAExchange.export(p,format:.gerber), openings = try EDAExchange.export(p,format:.gerberTechnical,gerberLayers:["F.Mask","B.Mask","F.Paste","B.Paste"])
        for bundle in [copper,openings] {
            for file in bundle.files where file.name != "Outline.gbr" && file.name.hasSuffix(".gbr") {
                let text = String(decoding:file.data,as:UTF8.self)
                #expect(text.contains("G36*\n") && text.contains("G37*\n") && !text.contains("<svg") && !text.contains("D03*"))
            }
        }
        let svg = try EDAExchange.export(p,format:.boardSVG)
        #expect(String(decoding:try #require(svg.files.first?.data),as:UTF8.self).contains("20.133975,-17.767949"))
        let drill = try EDAExchange.export(p,format:.excellon)
        #expect(drill.files.filter{$0.name.hasSuffix(".drl")}.count == 1)
        #expect(String(decoding:try #require(drill.files.first{$0.name.hasSuffix(".drl")}?.data),as:UTF8.self).contains("X5.000000Y5.000000"))
        p.footprints[0].pads[0].layers = ["F.Cu","F.Mask"]
        let noPaste = try EDAExchange.export(p,format:.gerberTechnical,gerberLayers:["F.Mask","F.Paste"])
        #expect(Set(noPaste.files.map(\.name)) == ["Mask-Top.gbr","Gerber-surface-manifest.json"])
        let manifest = try #require(JSONSerialization.jsonObject(with:noPaste.files.first{$0.name.hasSuffix("manifest.json")}!.data) as? [String:Any])
        #expect((manifest["omittedLayers"] as? [[String:String]])?.contains{$0["layerID"] == "F.Paste" && $0["reason"] == "no_represented_artwork"} == true)
    }
}
