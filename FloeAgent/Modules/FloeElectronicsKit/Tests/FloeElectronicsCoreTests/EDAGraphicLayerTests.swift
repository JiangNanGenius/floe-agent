// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

struct EDAGraphicLayerTests {
    private let fab=EDAGraphicLayerAssignment(layerID:"F.Fab",kind:.fabrication)
    private let cu=EDAGraphicLayerAssignment(layerID:"F.Cu",kind:.copper)
    private let silk=EDAGraphicLayerAssignment(layerID:"F.SilkS",kind:.silkscreen)
    private var rectangle:EDAGraphic {.rectangle(.init(-1,-2),.init(3,4),width:0.15)}
    private func project() throws -> EDAProject {
        var p=EDAProject(title:"Explicit graphic layer source")
        p.sheets[0].labels=[.init(name:"GND",position:.zero,scope:.global)]
        p.boards[0].outline=[.init(0,0),.init(30,0),.init(30,20),.init(0,20)]
        p.boards[0].graphics=[.line(.init(3,3),.init(8,4),width:0.2)]
        return p
    }
    private func exportFailure(_ code:String,_ p:EDAProject) throws {
        do{_ = try EDAExchange.export(p,format:.gerber);Issue.record("Expected \(code)")}
        catch let error as EDAManufacturingFailure{#expect(error.issues.contains{$0.code==code && $0.path.contains("graphics[0]") && $0.objectID != nil})}
    }
    private func manifest(_ bundle:EDAExchangeBundle) throws -> [String:Any] {
        let file=try #require(bundle.files.first{$0.name=="Gerber-manifest.json"})
        return try #require(JSONSerialization.jsonObject(with:file.data) as? [String:Any])
    }

    @Test func legacyJSONAndOriginalEnumEncodingArePreserved() throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let expected=#"{"rectangle":{"_0":{"x":-1,"y":-2},"_1":{"x":3,"y":4},"width":0.15}}"#
        #expect(String(decoding:try encoder.encode(rectangle),as:UTF8.self)==expected)
        #expect(try JSONDecoder().decode(EDAGraphic.self,from:Data(expected.utf8))==rectangle)
        var p=try project()
        p.footprints=[.init(name:"Legacy",graphics:[rectangle])]
        let bytes=try encoder.encode(p),raw=try #require(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
        let boards=try #require(raw["boards"] as? [[String:Any]]),defs=try #require(raw["footprints"] as? [[String:Any]])
        #expect(boards[0]["graphicLayers"]==nil && defs[0]["graphicLayers"]==nil)
        let old=try JSONDecoder().decode(EDAProject.self,from:bytes)
        #expect(old.boards[0].graphicLayers==nil && old.footprints[0].graphicLayers==nil)
        #expect(old.footprints[0].graphics==[rectangle])
        p.footprints[0].graphics.append(.circle(center:.zero,radius:1,width:0.1))
        p.footprints[0].graphicLayers=[nil,fab]
        p.boards[0].graphicLayers=[silk]
        let native=try #require(EDAExchange.export(p,format:.project).files.first)
        #expect(try EDAExchange.decodeProject(native.data)==p)
    }

    @Test func explicitNonCopperGraphicsAreIndividuallyReportedWithoutDeletingGeometry() throws {
        var p=try project();p.boards[0].graphicLayers=[silk]
        let net=try EDAConnectivity.derive(p).nets[0].id
        let def=EDAFootprintDefinition(name:"Placed explicit roles",pads:[.init(number:"1",position:.zero,size:.init(1.4,1.4))],
            graphics:[rectangle,.circle(center:.zero,radius:2,width:0.1),.text("REF",position:.zero,height:1,angle:0)],
            graphicLayers:[fab,.init(layerID:"B.Courtyard",kind:.courtyard),silk])
        p.footprints=[def]
        let fp=EDAFootprint(definitionID:def.id,position:.init(10,10),side:"B.Cu",padNets:["1":net])
        p.boards[0].footprints=[fp];let before=p
        let output=try EDAExchange.export(p,format:.gerber)
        #expect(p==before && p.footprints[0].graphics==def.graphics)
        let json=try manifest(output),excluded=try #require(json["excludedGraphics"] as? [[String:Any]])
        #expect(excluded.count==4 && (json["completeFabricationSet"] as? Bool)==false)
        let placed=excluded.filter{($0["footprintID"] as? String)==fp.id.uuidString}
        #expect(Set(placed.compactMap{$0["graphicIndex"] as? Int})==[0,1,2])
        #expect(Set(placed.compactMap{$0["resolvedLayerID"] as? String})==["B.Fab","F.Courtyard","B.SilkS"])
        #expect(placed.allSatisfy{($0["ownerID"] as? String)==def.id.uuidString && ($0["reason"] as? String)=="not_in_copper_profile_subset"})
        #expect(output.files.map(\.name)==["Copper-L02.gbr","Outline.gbr","Gerber-manifest.json"])
        let drc=try EDADRC.check(p,boardID:p.boards[0].id)
        #expect(!drc.issues.contains{$0.code.hasPrefix("graphic_") || $0.code=="copper_graphic_unsupported"})
    }

    @Test func unknownCopperMaskPasteProfileAndConflictsStillRefuseAndLimitDRC() throws {
        let cases:[(EDAGraphicLayerAssignment?,String)]=[
            (nil,"graphic_layer_unspecified"),(cu,"copper_graphic_unsupported"),
            (.init(layerID:"F.Mask",kind:.mask),"graphic_layer_kind_unsupported"),
            (.init(layerID:"F.Paste",kind:.paste),"graphic_layer_kind_unsupported"),
            (.init(layerID:"Edge.Cuts",kind:.fabrication),"graphic_profile_geometry_unsupported"),
            (.init(layerID:"Unknown.Fab",kind:.fabrication),"graphic_layer_unsupported"),
            (.init(layerID:"F.Cu",kind:.fabrication),"graphic_layer_kind_conflict")]
        for (assignment,code) in cases {
            var p=try project();p.boards[0].graphicLayers=assignment.map{[$0]}
            try exportFailure(code,p)
            do{_ = try EDACopperFill.plan(p,boardID:p.boards[0].id);Issue.record("Refill must refuse \(code)")}
            catch let error as EDACopperFillFailure{#expect(error.issues.contains{$0.code==code && $0.path.contains("graphics[0]")})}
            let drc=try EDADRC.check(p,boardID:p.boards[0].id)
            let issue=try #require(drc.issues.first{$0.code==code})
            #expect(issue.objects[0].objectID==p.boards[0].id && issue.objects[0].part==0 && issue.position == .init(3,3))
            #expect(!drc.isCompleteForSupportedChecks)
            for rule in [EDADRCRule.geometry,.copperClearance,.boardEdge,.keepout,.unconnectedNet] {
                #expect(drc.coverage.first{$0.rule==rule}?.limitationCodes.contains(code)==true)
            }
        }
    }

    @Test func relativeFootprintLayersSwapOnceAndBoardLayersStayAbsolute() throws {
        let p=try project(),board=p.boards[0]
        #expect(try EDAGraphicLayers.resolve(fab,index:0,board:board,footprintSide:"B.Cu").layerID=="B.Fab")
        #expect(try EDAGraphicLayers.resolve(fab,index:0,board:board).layerID=="F.Fab")
        let back=EDAGraphicLayerAssignment(layerID:"B.SilkS",kind:.silkscreen)
        #expect(try EDAGraphicLayers.resolve(back,index:0,board:board,footprintSide:"B.Cu").layerID=="F.SilkS")
        #expect(try EDAGraphicLayers.resolve(back,index:0,board:board).layerID=="B.SilkS")
        var conflicting=board;conflicting.layers.append(.init("B.Fab",kind:.copper))
        #expect(throws:EDAGraphicLayerFailure.self){try EDAGraphicLayers.resolve(fab,index:0,board:conflicting,footprintSide:"B.Cu")}
    }

    @Test func deleteCopyReorderReplaceAndAppendKeepTheLayerWithItsActualPrimitive() throws {
        let circle=EDAGraphic.circle(center:.init(7,8),radius:1,width:0.2)
        let line=EDAGraphic.line(.zero,.init(2,3),width:0.1)
        var g=[rectangle,circle,line],layers:[EDAGraphicLayerAssignment?]?=[fab,cu,silk]
        try EDAGraphicEditing.remove(at:0,graphics:&g,layers:&layers)
        #expect(g[0]==circle && layers?[0]==cu)
        try EDAGraphicEditing.duplicate(at:0,graphics:&g,layers:&layers)
        #expect(g==[circle,circle,line] && layers==[cu,cu,silk])
        try EDAGraphicEditing.move(from:2,to:0,graphics:&g,layers:&layers)
        #expect(g==[line,circle,circle] && layers==[silk,cu,cu])
        let moved=EDAGraphic.circle(center:.init(17,18),radius:1,width:0.2)
        try EDAGraphicEditing.replace(at:1,with:moved,graphics:&g,layers:layers)
        #expect(g[1]==moved && layers?[1]==cu)
        try EDAGraphicEditing.append(rectangle,graphics:&g,layers:&layers)
        #expect(layers?.count==4 && layers?[3]==nil)
        try EDAGraphicEditing.assign(fab,at:1,graphics:g,layers:&layers)
        #expect(g[1]==moved && layers?[1]==fab) // ordinary explicit Cu->Fab edit is permitted
        var unknown:[EDAGraphicLayerAssignment?]?,legacy=[line]
        try EDAGraphicEditing.append(circle,graphics:&legacy,layers:&unknown)
        #expect(unknown==nil)
        try EDAGraphicEditing.assign(fab,at:0,graphics:legacy,layers:&unknown)
        #expect(unknown==[fab,nil])
        try EDAGraphicEditing.duplicate(at:1,graphics:&legacy,layers:&unknown)
        #expect(unknown==[fab,nil,nil] && legacy==[line,circle,circle])
    }

    @Test func invalidSidecarsAndOutOfRangeEditsCannotPartlyMutateArrays() throws {
        var g=[rectangle],layers:[EDAGraphicLayerAssignment?]?=[];let original=g
        #expect(throws:EDAError.invalid("graphic layer count")){try EDAGraphicEditing.remove(at:0,graphics:&g,layers:&layers)}
        #expect(g==original && layers==[])
        layers=[fab];let before=layers
        #expect(throws:EDAError.invalid("graphic index")){try EDAGraphicEditing.move(from:0,to:1,graphics:&g,layers:&layers)}
        #expect(g==original && layers==before)
        for id in ["","\n",String(repeating:"x",count:257)] {
            #expect(throws:EDAError.invalid("graphic layer identifier")){
                try EDAGraphicEditing.assign(.init(layerID:id,kind:.fabrication),at:0,graphics:g,layers:&layers)
            }
            #expect(g==original && layers==before)
        }
        var p=try project();p.boards[0].graphicLayers=[]
        #expect(throws:EDAError.invalid("graphic layer count")){try EDAValidation.validate(p)}
    }

    @Test func explicitLayerEditsInvalidateDerivedCopperAndUndoRestoresMetadataAndFill() throws {
        var p=try project();p.boards[0].graphicLayers=[fab]
        let net=try EDAConnectivity.derive(p).nets[0].id
        p.boards[0].zones=[.init(netID:net,outline:p.boards[0].outline,thermal:false)]
        var s=try EDAEditingSession(project:p)
        try s.refillCopper(boardID:p.boards[0].id,expectedRevision:0)
        #expect(s.project.boards[0].zones[0].fillState == .filled)
        var b=s.project.boards[0];let geometry=b.graphics
        try EDAGraphicEditing.assign(cu,at:0,graphics:b.graphics,layers:&b.graphicLayers)
        try s.apply([.putBoard(b)],expectedRevision:1)
        #expect(s.project.boards[0].graphicLayers==[cu] && s.project.boards[0].graphics==geometry)
        #expect(s.project.boards[0].zones[0].fillRevision==nil && s.project.boards[0].zones[0].fillState==nil)
        try exportFailure("copper_graphic_unsupported",s.project)
        try s.undo(expectedRevision:2)
        #expect(s.project.boards[0].graphicLayers==[fab] && s.project.boards[0].zones[0].fillRevision==3)
        _ = try EDAExchange.export(s.project,format:.gerber)
        try s.redo(expectedRevision:3)
        #expect(s.project.boards[0].graphicLayers==[cu] && s.project.boards[0].zones[0].fillState==nil)
    }

    @Test func customLayerRequiresAnActualMatchingBoardDeclaration() throws {
        var p=try project();let custom=EDAGraphicLayerAssignment(layerID:"Body drawing",kind:.fabrication)
        p.boards[0].graphicLayers=[custom]
        try exportFailure("graphic_layer_unsupported",p)
        p.boards[0].layers.append(.init("Body drawing",kind:.fabrication))
        let json=try manifest(EDAExchange.export(p,format:.gerber))
        #expect((json["excludedGraphics"] as? [[String:Any]])?.first?["resolvedLayerID"] as? String=="Body drawing")
        var changed=p.boards[0].layers.removeLast();changed.kind = .copper
        let bottom=try #require(p.boards[0].layers.firstIndex{$0.id=="B.Cu"})
        p.boards[0].layers.insert(changed,at:bottom)
        try exportFailure("graphic_layer_kind_conflict",p)
    }
}
