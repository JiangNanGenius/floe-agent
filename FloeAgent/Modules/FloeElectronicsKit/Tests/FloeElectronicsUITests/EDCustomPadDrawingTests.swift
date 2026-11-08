// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

@MainActor struct EDCustomPadDrawingTests {
    private let outline: [EDAPoint] = [.init(-1,-2),.init(5,-2),.init(5,-1),.init(1,-1),.init(1,1),.init(5,1),.init(5,2),.init(-1,2)]
    private func fixture() throws -> EDAProject {
        var p = EDAProject(title:"Canvas polygon SMD")
        p.sheets[0].labels = [.init(name:"A",position:.zero,scope:.global),.init(name:"A",position:.init(10,0),scope:.global)]
        let definition = EDAFootprintDefinition(name:"Editable pad",pads:[.init(number:"1",position:.zero,size:.init(2,2),shape:.rectangle,layers:["F.Cu","F.Mask","F.Paste"])])
        let symbol = EDASymbolDefinition(name:"Bound component",pins:[.init(number:"1",position:.zero)])
        let component = EDAComponent(symbolID:symbol.id,footprintID:definition.id,reference:"U1")
        let second = EDAComponent(symbolID:symbol.id,footprintID:definition.id,reference:"U2")
        p.footprints = [definition];p.symbols=[symbol];p.components=[component,second]
        p.sheets[0].symbols=[.init(componentID:component.id,position:.zero),.init(componentID:second.id,position:.init(10,0))]
        let net = try #require(EDAConnectivity.derive(p).nets.first{$0.name == "A"}?.id)
        p.boards[0].footprints=[.init(definitionID:definition.id,componentID:component.id,position:.init(20,20),angle:30,padNets:["1":net]),
            .init(definitionID:definition.id,componentID:second.id,position:.init(50,20),angle:30,side:"B.Cu",padNets:["1":net])]
        p.boards[0].holes=[.init(position:.init(5,5),diameter:1,plated:false)]
        p.boards[0].edgePlated=false
        p.boards[0].drcConstraints = .init(minimumCopperClearance:0.2,minimumTrackWidth:0.1,minimumViaDiameter:0.4,minimumViaDrill:0.2,minimumViaAnnularWidth:0.1)
        return p
    }
    private func draft(_ p: EDAProject, local: [EDAPoint]? = nil) throws -> EDCustomPadDrawingDraft {
        let pad=p.footprints[0].pads[0]
        var draft=try EDCustomPadDrawingDraft(project:p,definitionID:p.footprints[0].id,padID:pad.id)
        for point in local ?? outline { try draft.append(point.transformed(origin:pad.position,angle:pad.angle)) }
        return draft
    }
    private func root() throws -> URL {
        URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["FLOE_POLYGON_TEST_TEMP"])).appendingPathComponent(UUID().uuidString)
    }
    private func edited(_ p: EDAProject, _ edits: [EDAEdit]) throws -> EDAProject {
        var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:p.revision);return editor.project
    }

    @Test func drawPreservesPadIdentityNumberAnchorRotationLayersAndSupportsUndoCancel() throws {
        var p=try fixture();p.footprints[0].pads[0].position = .init(2,1);p.footprints[0].pads[0].angle=35
        let old=p.footprints[0].pads[0]
        var d=try draft(p);let plan=try d.plan()
        #expect(plan.pad.id == old.id && plan.pad.number == old.number && plan.pad.position == old.position && plan.pad.angle == old.angle && plan.pad.layers == old.layers)
        #expect(plan.pad.shape == .polygon && plan.edits.count == 1)
        for (a,b) in zip(try #require(plan.pad.polygon),outline){#expect(a.distance(to:b)<1e-10)}
        #expect(abs(plan.pad.size.x-6)<1e-10 && abs(plan.pad.size.y-4)<1e-10)
        #expect(plan.selection == .init(context:.footprint(definitionID:p.footprints[0].id),objectIDs:[old.id]))
        d.undoLastPoint();#expect(d.points.count == 7)
        d.cancel();#expect(!d.canFinish && d.points.isEmpty)
        #expect(throws:EDAError.cancelled){try d.plan()}
        let outside=try draft(p,local:[.init(2,-1),.init(4,-1),.init(4,1),.init(2,1)])
        do{_ = try outside.plan();Issue.record("An unusable external pad anchor must refuse")}
        catch{#expect(EDCustomPadDrawingDraft.message(for:error).contains("center") || EDCustomPadDrawingDraft.message(for:error).contains("中心"))}
        #expect(p.footprints[0].pads[0] == old && p.revision == 0)
    }

    @Test func realFinishSavesReopensChecksExportsAndUndoesOneOriginalTransaction() async throws {
        let p=try fixture(),dir=try root();defer{try? FileManager.default.removeItem(at:dir)}
        let store=try await EDAProjectStore.create(root:dir,project:p),session=try await EDWorkbenchSession(store:store)
        let plan=try draft(p).plan(),before=try await store.load()
        var callbacks=0;session.onSaved={_ in callbacks+=1}
        #expect(before.project == p && !session.canUndo)
        try await plan.apply(to:session)
        #expect(session.revision == 1 && callbacks == 1 && session.canUndo && !session.isDirty)
        let reopened=try await EDWorkbenchSession(store:store)
        #expect(reopened.project == session.project && reopened.project.footprints[0].pads[0] == plan.pad)
        #expect(reopened.project.boards[0].footprints.map(\.padNets) == p.boards[0].footprints.map(\.padNets))
        let report=try EDADRC.check(reopened.project,boardID:p.boards[0].id)
        #expect(!report.issues.contains{$0.code == "pad_shape_unsupported" || $0.code == "pad_layer_unsupported"})
        let copper=try await session.export(format:.gerber,boardID:p.boards[0].id,variant:"Default")
        let surface=try await session.export(format:.gerberTechnical,boardID:p.boards[0].id,variant:"Default",gerberLayers:["F.Mask","B.Mask","F.Paste","B.Paste"])
        let drilling=try await session.export(format:.excellon,boardID:p.boards[0].id,variant:"Default")
        let snapshot=try await store.load()
        #expect(snapshot.project == session.project && snapshot.project.revision == 1 && callbacks == 1)
        #expect(copper.revision == 1 && surface.revision == 1 && drilling.revision == 1)
        if let path=ProcessInfo.processInfo.environment["FLOE_POLYGON_GOLDEN_ROOT"] {
            let output=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for (name,bundle) in [("gerber",copper),("surface",surface),("drilling",drilling)] {
                let folder=output.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                for file in bundle.files{try file.data.write(to:folder.appendingPathComponent(file.name))}
            }
            try Data(contentsOf:dir.appendingPathComponent("project.json")).write(to:output.appendingPathComponent("source.json"))
            try JSONEncoder().encode(report).write(to:output.appendingPathComponent("drc.json"))
        }
        try await session.undo(expectedRevision:1)
        #expect(session.project.footprints[0].pads[0] == p.footprints[0].pads[0] && session.project.footprints[0].pads[0].polygon == nil)
        try await session.redo(expectedRevision:2)
        #expect(session.project.footprints[0].pads[0] == plan.pad && session.revision == 3)
        #expect(try await store.load().project == session.project)
    }

    @Test func cancellationClosedOldSourceAndActualExternalCASCannotOverwriteTheOriginal() async throws {
        let p=try fixture(),dir=try root();defer{try? FileManager.default.removeItem(at:dir)}
        let store=try await EDAProjectStore.create(root:dir,project:p),session=try await EDWorkbenchSession(store:store),plan=try draft(p).plan()
        var replacement=p;replacement.title="same-revision replacement"
        #expect(throws:EDAError.self){try plan.validateSource(replacement)}
        let cancelled=Task{@MainActor in try await plan.apply(to:session)};cancelled.cancel()
        await #expect(throws:CancellationError.self){try await cancelled.value}
        #expect(try await store.load().project == p && !session.canUndo)
        await session.close()
        await #expect(throws:EDAError.cancelled){try await plan.apply(to:session)}
        let current=try await EDWorkbenchSession(store:store),before=try await store.load()
        var external=before.project;external.title="independent writer";external.revision+=1
        let saved=try await store.save(external,expectedRevision:before.project.revision,expectedDigest:before.digest)
        await #expect(throws:EDAError.staleRevision(expected:0,actual:1)){try await plan.apply(to:current)}
        #expect(try await store.load() == saved)
        #expect(current.conflictWithOriginal && current.isDirty && current.canUndo && current.project.footprints[0].pads[0] == plan.pad)
        await #expect(throws:EDAError.staleRevision(expected:0,actual:1)){try await plan.apply(to:current)}
        #expect(try await store.load() == saved)
    }

    @Test func actualHitTransformDuplicateAndFocusUseVerticesInsteadOfTheSizeRectangle() throws {
        let original=try fixture(),p=try edited(original,draft(original).plan().edits)
        let definition=p.footprints[0],pad=definition.pads[0],context=EDADocumentContext.footprint(definitionID:definition.id)
        #expect(EDCanvasInteraction.hit(project:p,context:context,at:.init(3,0),tolerance:0.01) == nil)
        #expect(EDCanvasInteraction.hit(project:p,context:context,at:.init(3,1.5),tolerance:0.01) == pad.id)
        #expect(EDLibraryEditing.hitFootprint(definition,at:.init(3,0),tolerance:0.01) == nil)
        #expect(EDLibraryEditing.hitFootprint(definition,at:.init(3,1.5),tolerance:0.01) == .pad(pad.id))
        for action in [EDCanvasInteraction.Action.rotate,.flip,.duplicate] {
            let transformed=try edited(p,EDCanvasInteraction.edits(for:action,project:p,context:context,objectIDs:[pad.id]))
            try EDAValidation.validate(transformed)
            if action == .duplicate {
                let copy=try #require(transformed.footprints[0].pads.first{$0.id != pad.id})
                #expect(copy.number != pad.number && copy.polygon == pad.polygon && copy.layers == pad.layers)
            } else if action == .flip {
                #expect(transformed.footprints[0].pads[0].polygon == outline.map{.init(-$0.x,$0.y)})
            } else {#expect(transformed.footprints[0].pads[0].angle == 90 && transformed.footprints[0].pads[0].polygon == pad.polygon)}
        }
        let moved=try edited(p,EDCanvasInteraction.move(project:p,context:context,objectIDs:[pad.id],by:.init(10,-2)))
        #expect(moved.footprints[0].pads[0].position == .init(10,-2) && moved.footprints[0].pads[0].polygon == pad.polygon)
        let resolution=try EDACrossProbe.resolve(p,selection:.init(context:.schematic(sheetID:p.sheets[0].id),objectIDs:[p.sheets[0].symbols[0].id]))
        #expect(resolution.targets.count == 1)
        for target in resolution.targets {
            let fp=try #require(p.boards[0].footprints.first{$0.id == target.objectID})
            for point in try #require(EDAPolygonPadGeometry.vertices(pad,in:fp)) {#expect(target.bounds.rect.contains(CGPoint(x:point.x,y:point.y)))}
        }
    }
}
