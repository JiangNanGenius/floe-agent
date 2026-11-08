// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@Suite("Manufacturing layer native session")
struct EDATechnicalManufacturingUITests {
    @Test func newBuiltinPadsDeclareCommonOpeningsWithoutChangingModelDefaultsOrTHTPaste()throws{
        let definitions=EDABuiltinLibrary.makeFootprints()
        for name in ["0603","0805","SOT-23"]{
            let definition=try #require(definitions.first{$0.name==name})
            #expect(definition.pads.allSatisfy{Set($0.layers)==["F.Cu","F.Mask","F.Paste"]})
        }
        for name in ["DIP-8","Header 1x02"]{
            let definition=try #require(definitions.first{$0.name==name})
            #expect(definition.pads.allSatisfy{Set($0.layers)==["F.Cu","B.Cu","F.Mask","B.Mask"]})
            #expect(definition.pads.allSatisfy{!$0.layers.contains(where:{$0.hasSuffix(".Paste")})})
        }
        #expect(EDAPad(number:"old",position:.zero).layers==["F.Cu"])
    }
    @Test func flippingABlindViaCarriesExplicitMaskSideAndPreservesUnspecifiedState()throws{
        var p=EDAProject(title:"via side")
        p.boards[0].layers.insert(contentsOf:[.init("In1.Cu",kind:.copper),.init("In2.Cu",kind:.copper)],at:2)
        let via=EDAVia(netID:"A",position:.init(5,5),startLayer:"F.Cu",endLayer:"In1.Cu",maskLayers:["F.Mask"])
        p.boards[0].vias=[via]
        let context=EDADocumentContext.board(boardID:p.boards[0].id)
        let edits=try EDCanvasInteraction.edits(for:.flip,project:p,context:context,objectIDs:[via.id])
        var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        let flipped=editor.project.boards[0].vias[0]
        #expect(flipped.maskLayers==["B.Mask"]);#expect(flipped.startLayer=="In2.Cu");#expect(flipped.endLayer=="B.Cu")
        try EDAValidation.validate(editor.project)
        p.boards[0].vias[0].maskLayers=nil
        var legacy=try EDAEditingSession(project:p);try legacy.apply(EDCanvasInteraction.edits(for:.flip,project:p,context:context,objectIDs:[via.id]),expectedRevision:0)
        #expect(legacy.project.boards[0].vias[0].maskLayers==nil)
    }
    @MainActor @Test func savedSessionUsesTheSameRequestedLayersAndPreservesCASUndoForMaskEdits()async throws{
        var p=EDAProject(title:"surface session")
        let footprint=try #require(EDABuiltinLibrary.makeFootprints().first{$0.name=="0603"})
        p.footprints=[footprint];p.boards[0].footprints=[.init(definitionID:footprint.id,position:.init(10,10))]
        p.boards[0].vias=[.init(netID:"A",position:.init(20,10))]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let store=try await EDAProjectStore.create(root:root,project:p),session=try await EDWorkbenchSession(store:store)
        #expect(session.project.boards[0].vias[0].maskLayers==nil)
        // Paste-only does not manufacture a via tenting decision.
        let paste=try await session.export(format:.gerberTechnical,boardID:p.boards[0].id,variant:"Default",gerberLayers:["F.Paste"])
        #expect(Set(paste.files.map(\.name))==["Paste-Top.gbr","Gerber-surface-manifest.json"])
        #expect(session.revision==0);#expect(session.project.boards[0].vias[0].maskLayers==nil)
        var via=session.project.boards[0].vias[0];via.maskLayers=[]
        try await session.apply([.putVia(board:p.boards[0].id,via)],expectedRevision:0)
        let saved=try await store.load();#expect(saved.project.boards[0].vias[0].maskLayers==[])
        let selected=try await session.export(format:.gerberTechnical,boardID:p.boards[0].id,variant:"Default",gerberLayers:["F.Mask"])
        let core=try EDAExchange.export(saved.project,format:.gerberTechnical,boardID:p.boards[0].id,gerberLayers:["F.Mask"])
        #expect(selected.files==core.files);#expect(selected.revision==saved.project.revision)
        try await session.undo(expectedRevision:1)
        #expect(session.project.boards[0].vias[0].maskLayers==nil)
        #expect(try await store.load().project==session.project)
    }
}
