// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeElectronicsCore

@Suite("Explicit manufacturing surface artwork")
struct EDATechnicalManufacturingTests {
    private func id(_ n:Int)->UUID{UUID(uuidString:String(format:"10000000-0000-0000-0000-%012d",n))!}
    private func fixture()->EDAProject{
        var p=EDAProject(id:id(1),title:"Actual surface artwork");p.revision=19
        var board=EDABoard(id:id(2),outline:[.zero,.init(60,0),.init(60,40),.init(0,40)])
        board.layers.insert(contentsOf:[.init("In1.Cu",kind:.copper),.init("In2.Cu",kind:.copper)],at:2)
        board.edgePlated=false
        let top=EDAFootprintDefinition(id:id(10),name:"Explicit pad layers",pads:[
            .init(id:id(11),number:"1",position:.zero,size:.init(4,1),angle:45,shape:.rectangle,layers:["F.Cu","F.Mask","F.Paste"]),
            .init(id:id(12),number:"2",position:.init(5,0),size:.init(2,2),drill:0.8,layers:["F.Cu","B.Cu","F.Mask","B.Mask"],drillPlated:true),
            .init(id:id(13),number:"3",position:.init(10,0),size:.init(1.2,1.2),drill:1.2,layers:["F.Mask","B.Mask"],drillPlated:false),
            .init(id:id(14),number:"4",position:.init(0,5),size:.init(4,2),angle:45,shape:.oval,layers:["F.Paste"])])
        let bottom=EDAFootprintDefinition(id:id(20),name:"Back transform",pads:[.init(id:id(21),number:"1",position:.init(2,0),size:.init(2,1),angle:30,shape:.rectangle,layers:["F.Cu","F.Mask","F.Paste"])],
            graphics:[.arc(center:.zero,radius:3,start:0,sweep:90,width:0.2)],graphicLayers:[.init(layerID:"F.SilkS",kind:.silkscreen)])
        p.footprints=[top,bottom];board.footprints=[.init(id:id(30),definitionID:top.id,position:.init(10,10)),.init(id:id(31),definitionID:bottom.id,position:.init(35,10),angle:90,side:"B.Cu")]
        board.graphics=[.line(.init(1,1),.init(4,1),width:0.2),.arc(center:.init(5,5),radius:2,start:0,sweep:90,width:0.3),.rectangle(.init(10,20),.init(14,22),width:0.1),.circle(center:.init(20,20),radius:2,width:0.2),.line(.init(25,2),.init(28,2),width:0.8)]
        board.graphicLayers=[.init(layerID:"F.SilkS",kind:.silkscreen),.init(layerID:"B.SilkS",kind:.silkscreen),.init(layerID:"F.Fab",kind:.fabrication),.init(layerID:"B.Fab",kind:.fabrication),.init(layerID:"F.Mask",kind:.mask)]
        board.vias=[.init(id:id(40),netID:"A",position:.init(40,10),diameter:1,drill:0.4,maskLayers:["F.Mask"]),.init(id:id(41),netID:"A",position:.init(42,10),startLayer:"F.Cu",endLayer:"In1.Cu",maskLayers:[]),.init(id:id(42),netID:"A",position:.init(44,10),startLayer:"In1.Cu",endLayer:"In2.Cu")]
        board.holes=[.init(id:id(50),position:.init(50,20),diameter:1.4,plated:false,endPosition:.init(53,20))]
        p.boards=[board];return p
    }
    private func output(_ p:EDAProject,_ layers:[String]?=nil)throws->EDAExchangeBundle{try EDAExchange.export(p,format:.gerberTechnical,gerberLayers:layers)}
    private func file(_ b:EDAExchangeBundle,_ name:String)throws->EDAExchangeFile{try #require(b.files.first{$0.name==name})}
    private func manifest(_ b:EDAExchangeBundle)throws->[String:Any]{try #require(JSONSerialization.jsonObject(with:file(b,"Gerber-surface-manifest.json").data) as? [String:Any])}
    private func failure(_ code:String,_ body:()throws->EDAExchangeBundle)throws{
        do{_ = try body();Issue.record("Expected explicit refusal: \(code)")}catch let value as EDAManufacturingFailure{#expect(value.issues.contains{$0.code==code && !$0.path.isEmpty})}
    }
    private func save(_ b:EDAExchangeBundle,_ name:String)throws{
        guard let root=ProcessInfo.processInfo.environment["FLOE_SURFACE_EVIDENCE_ROOT"] else{return}
        let dir=URL(fileURLWithPath:root).appendingPathComponent(name);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        for f in b.files{try f.data.write(to:dir.appendingPathComponent(f.name),options:.atomic)}
    }
    @Test func actualPadAndGraphicLayersProduceRealGerberWithCorrectPolarityAndBackTransform()throws{
        let p=fixture(),before=p,b=try output(p,EDAGerberTechnicalLayer.allCases.map(\.rawValue))
        #expect(Set(b.files.map(\.name))==["Mask-Top.gbr","Mask-Bot.gbr","Paste-Top.gbr","Paste-Bot.gbr","Legend-Top.gbr","Legend-Bot.gbr","AssemblyOutline-Top.gbr","AssemblyOutline-Bot.gbr","Gerber-surface-manifest.json"])
        for (name,function,polarity) in [("Mask-Top.gbr","Soldermask,Top","Negative"),("Mask-Bot.gbr","Soldermask,Bot","Negative"),("Paste-Top.gbr","Paste,Top","Positive"),("Legend-Top.gbr","Legend,Top","Positive"),("AssemblyOutline-Top.gbr","AssemblyDrawing,Top","Positive")]{
            let text=String(decoding:try file(b,name).data,as:UTF8.self)
            #expect(text.contains("%TF.FileFunction,\(function)*%"));#expect(text.contains("%TF.FilePolarity,\(polarity)*%"));#expect(text.contains("%LPD*%"));#expect(text.hasSuffix("M02*\n"));#expect(!text.contains("<svg"))
        }
        let back=String(decoding:try file(b,"Mask-Bot.gbr").data,as:UTF8.self)
        #expect(back.contains("X35000000Y8000000D03*"));#expect(back.contains("2.000000,1.000000,0,0,240.000000000"))
        #expect(p==before);try save(b,"all-explicit-layers")
    }
    @Test func THTAndNPTHUseOnlyTheirDeclaredMaskAndNeverInventPaste()throws{
        var p=fixture();p.boards[0].graphics=[];p.boards[0].graphicLayers=nil;p.boards[0].footprints.removeLast();p.footprints[0].pads.removeAll{$0.number=="1" || $0.number=="4"};p.boards[0].vias=[]
        let b=try output(p,["F.Mask","B.Mask","F.Paste","B.Paste"])
        #expect(Set(b.files.map(\.name))==["Mask-Top.gbr","Mask-Bot.gbr","Gerber-surface-manifest.json"])
        let m=try manifest(b),omitted=try #require(m["omittedLayers"] as? [[String:String]])
        #expect(omitted.contains{$0["layerID"]=="F.Paste" && $0["reason"]=="no_represented_artwork"})
        #expect(String(decoding:try file(b,"Mask-Top.gbr").data,as:UTF8.self).contains("C,1.200000"))
        // Aperture-only NPTH pads do not fabricate zero-width copper annuli.
        _ = try EDAExchange.export(p,format:.gerber)
        let drill=try EDAExchange.export(p,format:.excellon)
        #expect(drill.files.contains{$0.name=="Drill-NPTH-L01-L04.drl"})
        try save(b,"tht-npth-no-paste")
    }
    @Test func legacyPadAndViaJSONRemainDecodableWithoutInventingOpenings()throws{
        let p=fixture(),via=p.boards[0].vias[0]
        var raw=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(via)) as? [String:Any]);raw.removeValue(forKey:"maskLayers")
        let legacy=try JSONDecoder().decode(EDAVia.self,from:JSONSerialization.data(withJSONObject:raw))
        #expect(legacy.maskLayers==nil)
        let encoded=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as? [String:Any]);#expect(encoded["maskLayers"]==nil)
        #expect(EDAPad(number:"1",position:.zero).layers==["F.Cu"])
        var tented=legacy;tented.maskLayers=[];let roundtrip=try JSONDecoder().decode(EDAVia.self,from:JSONEncoder().encode(tented));#expect(roundtrip.maskLayers==[])
    }
    @Test func viaUnknownTentingRefusesOnlyARequestedReachableMaskAndExplicitTentingIsRetained()throws{
        var p=fixture();p.boards[0].vias[0].maskLayers=nil
        try failure("via_mask_unspecified"){try output(p,["F.Mask"])}
        _ = try output(p,["F.Paste"])
        p.boards[0].vias[0].maskLayers=[]
        let b=try output(p,["F.Mask","B.Mask"]),m=try manifest(b),sources=try #require(m["sources"] as? [[String:Any]])
        #expect(sources.contains{($0["ownerID"] as? String)==p.boards[0].vias[0].id.uuidString && $0["status"] as? String=="explicitly_tented"})
        #expect(!String(decoding:try file(b,"Mask-Top.gbr").data,as:UTF8.self).contains("X40000000Y10000000D03*"))
    }
    @Test func viaMaskConfigurationRejectsUnreachableDuplicateAndUnknownLayers()throws{
        var p=fixture();p.boards[0].vias[1].maskLayers=["B.Mask"]
        #expect(throws:EDAError.self){try EDAValidation.validate(p)}
        p.boards[0].vias[1].maskLayers=["F.Mask","F.Mask"];#expect(throws:EDAError.self){try EDAValidation.validate(p)}
        p.boards[0].vias[1].maskLayers=["Unknown.Mask"];#expect(throws:EDAError.self){try EDAValidation.validate(p)}
        p.boards[0].vias[1].maskLayers=[];try EDAValidation.validate(p)
    }
    @Test func selectedTextDimensionAndRoundrectFailButUnrequestedKnownGeometryIsNotPlotted()throws{
        var p=fixture();p.boards[0].graphics[0] = .text("R1",position:.init(1,1),height:1,angle:0)
        try failure("graphic_text_geometry_unspecified"){try output(p,["F.SilkS"])}
        let mask=try output(p,["F.Mask"]);#expect(!mask.files.contains{$0.name.hasPrefix("Legend")})
        let m=try manifest(mask),sources=try #require(m["sources"] as? [[String:Any]])
        #expect(sources.contains{$0["path"] as? String=="board.graphics[0]" && $0["status"] as? String=="not_requested"})
        p.boards[0].graphics[0] = .dimension(.zero,.init(5,0),offset:2)
        try failure("graphic_dimension_style_unspecified"){try output(p,["F.SilkS"])}
        p.footprints[0].pads[0].shape = .roundRectangle
        try failure("round_rectangle_radius_missing"){try output(p,["F.Mask"])}
        _ = try output(p,["F.Fab"])
    }
    @Test func unknownLayerAndUnassignedGraphicsNeverDisappearFromSuccessfulOutput()throws{
        var p=fixture();p.boards[0].graphicLayers![0]=nil
        try failure("graphic_layer_unspecified"){try output(p,["F.Mask"])}
        p.boards[0].graphicLayers![0] = .init(layerID:"Mystery",kind:.silkscreen)
        try failure("graphic_layer_unsupported"){try output(p,["F.Mask"])}
        p=fixture();p.footprints[0].pads[0].layers.append("Unknown.Layer")
        try failure("pad_layer_unsupported"){try output(p,["F.Mask"])}
    }
    @Test func exactCircleArcsAndMirroredArcDirectionsAreRetained()throws{
        let b=try output(fixture(),["B.SilkS","B.Fab"])
        let silk=String(decoding:try file(b,"Legend-Bot.gbr").data,as:UTF8.self)
        #expect(silk.contains("G75*"));#expect(silk.contains("G03*"));#expect(silk.contains("G02*"))
        #expect(silk.contains("X35000000Y7000000D02*"));#expect(silk.contains("X32000000Y10000000I0J3000000D01*"))
        let circle=String(decoding:try file(b,"AssemblyOutline-Bot.gbr").data,as:UTF8.self)
        #expect(circle.contains("X22000000Y20000000D02*"));#expect(circle.contains("X22000000Y20000000I-2000000J0D01*"))
        try save(b,"exact-arcs-and-circle")
    }
    @Test func allEmptyOrInvalidLayerRequestsReturnAnExplicitFailureNotBlankArt()throws{
        let p=fixture()
        for layers in [[],["F.Mask","F.Mask"],["Inner.Mask"],["F.Cu"]]{try failure("requested_gerber_layer_unsupported"){try output(p,layers)}}
        #expect(throws:EDAError.self){try EDAExchange.export(p,format:.gerber,gerberLayers:["F.Mask"])}
        var empty=EDAProject(title:"No apertures");empty.boards[0].vias=[]
        try failure("no_requested_layer_geometry"){try output(empty,["F.Mask"])}
    }
    @Test func manifestHashesSourceAndOrderingBindEveryActualFileAndEveryOmission()throws{
        var p=fixture();p.revision=UInt64.max
        let layers=EDAGerberTechnicalLayer.allCases.map(\.rawValue),a=try output(p,layers),other=try output(p,Array(layers.reversed()))
        #expect(a.files==other.files)
        let m=try manifest(a);#expect(m["sourceRevision"] as? String==String(UInt64.max));#expect(m["completeFabricationSet"] as? Bool==false)
        for record in try #require(m["files"] as? [[String:Any]]){
            let actual=try file(a,try #require(record["name"] as? String));#expect(record["sha256"] as? String==actual.sha256);#expect(record["byteCount"] as? Int==actual.data.count)
        }
        let partial=try manifest(output(p,["F.Mask"]))
        #expect((partial["requestedLayers"] as? [String])==["F.Mask"])
        #expect((partial["omittedLayers"] as? [[String:String]])?.contains{$0["layerID"]=="B.Fab" && $0["reason"]=="not_requested"}==true)
    }
    @Test func cancellationAndSubresolutionArcsNeverReturnPartialSuccess()throws{
        #expect(throws:EDAError.cancelled){try EDAExchange.export(fixture(),format:.gerberTechnical,cancelled:{true})}
        var p=fixture();p.boards[0].graphics[1] = .arc(center:.init(5,5),radius:2,start:0,sweep:0.000000001,width:0.3)
        try failure("graphic_arc_below_resolution"){try output(p,["B.SilkS"])}
    }
    @Test func explicitMaskPasteDoNotBecomeCopperAndApertureOnlyNPTHStillCutsTheActualFill()throws{
        var p=EDAProject(title:"No false annulus, no lost bore")
        p.boards[0].outline=[.zero,.init(20,0),.init(20,20),.init(0,20)];p.boards[0].boardEdgeClearance=0.01
        p.boards[0].netClasses[0].clearance=0.01
        // No technical-layer stack records; these standard explicit roles are still non-copper.
        p.boards[0].layers=[.init("F.Cu",kind:.copper),.init("B.Cu",kind:.copper)]
        let pad=EDAPad(number:"mechanical",position:.zero,size:.init(4,4),drill:4,layers:["F.Mask","B.Mask"],drillPlated:false)
        let def=EDAFootprintDefinition(name:"Aperture only",pads:[pad])
        p.footprints=[def];p.boards[0].footprints=[.init(definitionID:def.id,position:.init(10,10))]
        p.boards[0].graphics=[.line(.init(1,1),.init(3,1),width:0.2)]
        p.boards[0].graphicLayers=[.init(layerID:"F.Mask",kind:.mask)]
        p.sheets[0].labels=[.init(name:"GND",position:.zero)]
        let net=try #require(EDAConnectivity.derive(p).nets.first?.id)
        p.boards[0].zones=[.init(netID:net,outline:p.boards[0].outline,clearance:0.01,thermal:false)]
        let plan=try EDACopperFill.plan(p,boardID:p.boards[0].id)
        var editor=try EDAEditingSession(project:p);_ = try editor.applyCopperFill(plan,expectedRevision:p.revision)
        let polygons=editor.project.boards[0].zones[0].filledPolygons
        func area(_ points:[EDAPoint])->Double{abs(zip(points,Array(points.dropFirst())+[points[0]]).reduce(0){$0+$1.0.x*$1.1.y-$1.1.x*$1.0.y})/2}
        let total=polygons.reduce(0){$0+area($1)}
        let side=20-2*(p.boards[0].boardEdgeClearance+plan.report.clearanceSafetyMillimetres)
        #expect(abs(total-(side*side-4*Double.pi))<0.03)
        #expect(!polygons.contains{EDAGeometry.contains(.init(10,10),polygon:$0)})
        let drc=try EDADRC.check(editor.project,boardID:p.boards[0].id)
        #expect(!drc.issues.contains{$0.code=="pad_drill_exceeds_copper" || $0.code=="pad_shape_unsupported" || $0.code=="pad_layer_unsupported" || $0.code.hasPrefix("graphic_")})
        let copper=try EDAExchange.export(editor.project,format:.gerber)
        #expect(!copper.files.contains{$0.name=="Copper-L02.gbr"})
        let selected=try output(editor.project,["F.Mask"])
        #expect(selected.files.contains{$0.name=="Mask-Top.gbr"})
        try save(copper,"mask-only-hole-copper");try save(selected,"mask-only-hole-mask")
    }

    @Test func technicalExportBoundsWholeOriginalPolygonValidationBeforeDoingQuadraticWork()throws{
        var p=EDAProject(title:"bounded original validation")
        p.boards[0].outline=(0..<5000).map{index in let a=Double(index)*2*Double.pi/5000;return EDAPoint(cos(a)*10+20,sin(a)*10+20)}
        #expect(throws:EDAError.invalid("manufacturing polygon budget")){try output(p,["F.Mask"])}
    }

}
