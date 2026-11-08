// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor struct EDAGraphicLayerSessionTests {
    private let fab=EDAGraphicLayerAssignment(layerID:"F.Fab",kind:.fabrication)
    private let cu=EDAGraphicLayerAssignment(layerID:"F.Cu",kind:.copper)
    private func project() throws -> EDAProject {
        var p=EDABuiltinLibrary.makeProject(title:"Actual default 0603 output")
        p.sheets[0].labels=[.init(name:"A",position:.zero,scope:.global),.init(name:"B",position:.init(10,0),scope:.global)]
        let nets=try EDAConnectivity.derive(p).nets
        let a=try #require(nets.first{$0.name=="A"}),b=try #require(nets.first{$0.name=="B"})
        let passive=try #require(p.footprints.first{$0.name=="0603"})
        p.boards[0].footprints=[.init(definitionID:passive.id,reference:"R1",position:.init(10,10),padNets:["1":a.id,"2":b.id])]
        return p
    }
    private func root() throws -> URL {
        let path=try #require(ProcessInfo.processInfo.environment["FLOE_GRAPHIC_TEST_TEMP"])
        return URL(fileURLWithPath:path).appendingPathComponent(UUID().uuidString)
    }
    private func record(_ folder:String,_ bundle:EDAExchangeBundle,_ project:EDAProject) throws {
        guard let root=ProcessInfo.processInfo.environment["FLOE_GRAPHIC_EVIDENCE_ROOT"] else{return}
        let dir=URL(fileURLWithPath:root).appendingPathComponent(folder)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        for file in bundle.files{try file.data.write(to:dir.appendingPathComponent(file.name))}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(project).write(to:dir.appendingPathComponent("actual-project.json"))
        let native=try #require(EDAExchange.export(project,format:.project).files.first)
        try native.data.write(to:dir.appendingPathComponent("Project.floeeda"))
    }
    private func exportFailure(_ code:String,_ session:EDWorkbenchSession) async throws {
        do{_ = try await session.export(format:.gerber,boardID:session.project.boards[0].id,variant:"Default");Issue.record("Expected \(code)")}
        catch let error as EDAManufacturingFailure{#expect(error.issues.contains{$0.code==code})}
        #expect(!session.isExporting)
    }

    @Test func actualDefault0603OutputsCopperThenRefillsWithoutDeletingItsBodyDrawing() async throws {
        let source=try project(),directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let def=try #require(source.footprints.first{$0.name=="0603"})
        #expect(def.graphics==[.rectangle(.init(-1.8,-1),.init(1.8,1),width:0.15)])
        #expect(def.graphicLayers==[fab])
        for name in ["0603","0805","DIP-8"]{#expect(source.footprints.first{$0.name==name}?.graphicLayers==[fab])}
        let store=try await EDAProjectStore.create(root:directory,project:source),session=try await EDWorkbenchSession(store:store)
        let before=session.project
        let copper=try await session.export(format:.gerber,boardID:source.boards[0].id,variant:"Default")
        #expect(copper.files.map(\.name)==["Copper-L01.gbr","Outline.gbr","Gerber-manifest.json"])
        #expect(session.project==before)
        let manifest=try #require(copper.files.first{$0.name=="Gerber-manifest.json"})
        let json=try #require(JSONSerialization.jsonObject(with:manifest.data) as? [String:Any])
        let excluded=try #require(json["excludedGraphics"] as? [[String:Any]])
        #expect(excluded.count==1 && excluded[0]["declaredLayerID"] as? String=="F.Fab")
        #expect(excluded[0]["ownerID"] as? String==def.id.uuidString && excluded[0]["graphicIndex"] as? Int==0)
        #expect(json["completeFabricationSet"] as? Bool==false)
        try record("default-0603-copper",copper,session.project)
        let net=try #require(EDAConnectivity.derive(session.project).nets.first{$0.name=="A"})
        try await session.createCopperZone(boardID:source.boards[0].id,netID:net.id,layer:"F.Cu",outline:source.boards[0].outline,expectedRevision:0)
        let filled=try await session.refillCopper(boardID:source.boards[0].id,expectedRevision:1)
        #expect(filled.zones[0].thermals[0].connectedSpokes==4)
        #expect(session.project.footprints.first{$0.id==def.id}?.graphics==def.graphics)
        let output=try await session.export(format:.gerber,boardID:source.boards[0].id,variant:"Default")
        let image=try #require(output.files.first{$0.name=="Copper-L01.gbr"})
        #expect(String(decoding:image.data,as:UTF8.self).contains("G36*"))
        #expect(try await store.load().project==session.project)
        try record("default-0603-refilled",output,session.project)
        await session.close()
    }

    @Test func legacyLayerAssignmentIsAnOrdinaryEditAndLegitimateCopperAssignmentCanBeSaved() async throws {
        var source=try project();let index=try #require(source.footprints.firstIndex{$0.name=="0603"})
        source.footprints[index].graphicLayers=nil
        let directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let store=try await EDAProjectStore.create(root:directory,project:source),session=try await EDWorkbenchSession(store:store)
        try await exportFailure("graphic_layer_unspecified",session)
        #expect(try session.drc(boardID:source.boards[0].id).coverage.contains{$0.limitationCodes.contains("graphic_layer_unspecified")})
        var def=session.project.footprints[index];let drawing=def.graphics
        try EDAGraphicEditing.assign(fab,at:0,graphics:def.graphics,layers:&def.graphicLayers)
        try await session.apply([.putFootprintDefinition(def)],expectedRevision:0)
        let output=try await session.export(format:.gerber,boardID:source.boards[0].id,variant:"Default")
        #expect(session.project.footprints[index].graphics==drawing)
        try record("legacy-explicit-fab",output,session.project)
        def=session.project.footprints[index]
        try EDAGraphicEditing.assign(cu,at:0,graphics:def.graphics,layers:&def.graphicLayers)
        try await session.apply([.putFootprintDefinition(def)],expectedRevision:1)
        #expect(try await store.load().project.footprints[index].graphicLayers==[cu])
        try await exportFailure("copper_graphic_unsupported",session)
        #expect(try !session.drc(boardID:source.boards[0].id).isCompleteForSupportedChecks)
        try await session.undo(expectedRevision:2)
        #expect(session.project.footprints[index].graphicLayers==[fab])
        _ = try await session.export(format:.gerber,boardID:source.boards[0].id,variant:"Default")
        try await session.redo(expectedRevision:3)
        #expect(session.project.footprints[index].graphicLayers==[cu] && session.project.footprints[index].graphics==drawing)
        await session.close()
    }

    @Test func pairedHelperEditsPersistAtomicallyAndStaleWriterCannotMoveTheCopperTag() async throws {
        var source=try project();let index=try #require(source.footprints.firstIndex{$0.name=="0603"})
        source.footprints[index].graphics.append(.circle(center:.init(2,0),radius:0.5,width:0.1))
        source.footprints[index].graphicLayers=[fab,cu]
        let directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let store=try await EDAProjectStore.create(root:directory,project:source)
        let a=try await EDWorkbenchSession(store:store),b=try await EDWorkbenchSession(store:store)
        var def=a.project.footprints[index]
        try EDAGraphicEditing.remove(at:0,graphics:&def.graphics,layers:&def.graphicLayers)
        try EDAGraphicEditing.duplicate(at:0,graphics:&def.graphics,layers:&def.graphicLayers)
        let moved=EDLibraryEditing.translated(def.graphics[1],by:.init(5,2))
        try EDAGraphicEditing.replace(at:1,with:moved,graphics:&def.graphics,layers:def.graphicLayers)
        try await a.apply([.putFootprintDefinition(def)],expectedRevision:0)
        let actual=try await store.load().project.footprints[index]
        #expect(actual.graphics==def.graphics && actual.graphicLayers==[cu,cu])
        var stale=b.project.footprints[index]
        try EDAGraphicEditing.move(from:1,to:0,graphics:&stale.graphics,layers:&stale.graphicLayers)
        do{try await b.apply([.putFootprintDefinition(stale)],expectedRevision:0);Issue.record("A stale paired edit must not overwrite the original")}
        catch{#expect(b.conflictWithOriginal && b.isDirty)}
        #expect(try await store.load().project.footprints[index]==actual)
        try await b.refresh(discardChanges:true);await b.close()
        try await a.undo(expectedRevision:1)
        #expect(a.project.footprints[index].graphics==source.footprints[index].graphics && a.project.footprints[index].graphicLayers==[fab,cu])
        await a.close()
    }
}
