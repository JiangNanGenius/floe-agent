// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeElectronicsCore
@testable import FloeApp

@Suite("Electronics selected Gerber surface contracts", .serialized)
@MainActor struct ElectronicsGerberSurfaceContractTests {
    private func text(_ value:Any)throws->String{String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self)}
    private func object(_ value:some Encodable)throws->Any{try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}
    private func invoke(_ name:String,_ arguments:[String:Any],_ initial:ToolContext)async throws->ToolExecutionOutput{
        var context=initial;context.executionToolName=name
        let runner=try #require(ToolRunnerRegistry.shared.runner(named:name))
        return try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:arguments),context:context)
    }
    @Test func discoveryGivesACompleteCurrentOriginalExportInstance()throws{
        let p=EDAProject(title:"Export instance"),capabilities=try StudioElectronicsContract.capabilities(p)
        #expect(capabilities.exportFormats.contains("gerberTechnical"))
        let description=try #require(capabilities.manufacturingFields["eda.export gerberTechnical"])
        let marker="Complete current-original studio.run arguments: "
        let range=try #require(description.range(of:marker))
        let example=Data(description[range.upperBound...].utf8)
        let call=try #require(JSONSerialization.jsonObject(with:example) as? [String:Any])
        #expect(call["projectID"] as? String==p.id.uuidString);#expect(call["action"] as? String=="eda.export")
        let input=try #require(call["inputJSON"] as? String),options=try #require(JSONSerialization.jsonObject(with:Data(input.utf8)) as? [String:Any])
        #expect(options["boardID"] as? String==p.boards[0].id.uuidString);#expect(options["expectedRevision"] as? String=="0")
        #expect(options["format"] as? String=="gerberTechnical");#expect(options["gerberLayers"] as? [String]==["F.Mask","F.Paste","F.SilkS"])
    }
    @Test func nativePutRetainsExplicitTentingAndRefusesAnUnreachableMaskSide()throws{
        var p=EDAProject(title:"Mask contract");var via=EDAVia(netID:"A",position:.init(5,5),maskLayers:[])
        let operation:[String:Any]=["op":"native.put","kind":"via","boardID":p.boards[0].id.uuidString,"value":try object(via)]
        guard case .edits(let edits)=try StudioElectronicsContract.decode(text([operation]),project:p) else{Issue.record("Expected native via edit");return}
        var editor=try EDAEditingSession(project:p);try editor.apply(edits,expectedRevision:0)
        #expect(editor.project.boards[0].vias[0].maskLayers==[])
        p.boards[0].layers.insert(.init("In1.Cu",kind:.copper),at:2);via.endLayer="In1.Cu";via.maskLayers=["B.Mask"]
        #expect(throws:(any Error).self){try StudioElectronicsContract.decode(text([["op":"native.put","kind":"via","boardID":p.boards[0].id.uuidString,"value":try object(via)]]),project:p)}
        #expect(p.boards[0].vias.isEmpty)
    }
    @Test func registeredExporterPublishesSelectedRealFilesAndIdempotentRetryFromTheSavedOriginal()async throws{
        let environment=FloeAgentApp.liveEnvironment;try await environment.ensureDurableAutomationReady()
        let library=try await PersonalContentService.shared.library()
        let conversation=UUID(),runID=UUID(),now=Date()
        try await environment.conversationStore.saveConversation(.init(id:conversation,title:"Surface Gerber contract",createdAt:now,updatedAt:now))
        _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:conversation,title:"Surface Gerber contract")
        try await environment.conversationStore.setArchived(id:conversation,archived:true)
        try await environment.runStore.saveRun(.init(id:runID,conversationID:conversation,state:"executing",goal:"Surface Gerber contract",startedAt:now))
        var context=ToolContext(runID:runID,toolCallID:"create-surface-contract",allowedToolNames:StudioCoordinator.names,cancellation:CancellationToken(),conversationID:conversation)
        context.frozenEffectiveCatalogNames=StudioCoordinator.names;context.approvalGrantID=UUID()
        var createdID:UUID?
        do{
            let created=try await invoke("studio.create",["kind":"electronics","title":"QA Surface Gerber \(UUID().uuidString.prefix(8))"],context)
            let json=try #require(JSONSerialization.jsonObject(with:Data((created.capturedOutput ?? created.summary).utf8)) as? [String:Any])
            let record=try #require(json["record"] as? [String:Any]),raw=try #require(record["id"] as? String),id=try #require(UUID(uuidString:raw));createdID=id
            let location=try await library.resolve(id),snapshot=try ElectronicsSavedSnapshot(id:id,directory:location.url)
            let definition=EDAFootprintDefinition(name:"Explicit surface fixture",pads:[.init(number:"1",position:.zero,size:.init(2,1),shape:.rectangle,layers:["F.Cu","F.Mask","F.Paste"])])
            var board=try #require(snapshot.project.boards.first)
            board.footprints=[.init(definitionID:definition.id,reference:"R1",position:.init(10,10))]
            board.graphics=[.line(.init(5,5),.init(8,5),width:0.2),.rectangle(.init(8,8),.init(12,12),width:0.1)]
            board.graphicLayers=[.init(layerID:"F.SilkS",kind:.silkscreen),.init(layerID:"F.Fab",kind:.fabrication)]
            board.vias=[.init(netID:"A",position:.init(20,10),maskLayers:[])]
            context.toolCallID="edit-surface-contract"
            _ = try await invoke("studio.edit",["projectID":raw,"expectedRevision":String(snapshot.project.revision),"operationsJSON":text([
                ["op":"native.put","kind":"footprintDefinition","value":try object(definition)],
                ["op":"native.put","kind":"board","value":try object(board)]])],context)
            let saved=try ElectronicsSavedSnapshot(id:id,directory:location.url)
            context.toolCallID="publish-selected-surface-contract"
            let options:[String:Any]=["expectedRevision":String(saved.project.revision),"boardID":board.id.uuidString,"format":"gerberTechnical","gerberLayers":["F.Mask","F.Paste","F.SilkS"]]
            let arguments:[String:Any]=["projectID":raw,"action":"eda.export","inputJSON":try text(options)]
            let first=try await invoke("studio.run",arguments,context),retry=try await invoke("studio.run",arguments,context)
            #expect(Set(first.outputFiles.map(\.displayName))==["Mask-Top.gbr","Paste-Top.gbr","Legend-Top.gbr","Gerber-surface-manifest.json"])
            #expect(first.outputFiles.map(\.outputID)==retry.outputFiles.map(\.outputID))
            let core=try EDAExchange.export(saved.project,format:.gerberTechnical,boardID:board.id,gerberLayers:["F.Mask","F.Paste","F.SilkS"])
            for output in first.outputFiles{
                let bytes=try Data(contentsOf:FloeArtifactStore.root().appendingPathComponent(output.relativePath))
                let expected=try #require(core.files.first{$0.name==output.displayName})
                #expect(bytes==expected.data);#expect(StudioToolOutput.hash(bytes)==output.sha256);#expect(bytes.count==output.byteCount)
            }
            #expect(try ElectronicsSavedSnapshot(id:id,directory:location.url).digest==saved.digest)
            context.toolCallID="publish-assembly-outline-contract"
            let assembly=try await invoke("studio.run",["projectID":raw,"action":"eda.export","inputJSON":text(["expectedRevision":String(saved.project.revision),"boardID":board.id.uuidString,"format":"gerberTechnical","gerberLayers":["F.Fab"]])],context)
            #expect(Set(assembly.outputFiles.map(\.displayName))==["AssemblyOutline-Top.gbr","Gerber-surface-manifest.json"])
            let session=try await ElectronicsProjectSession.open(id:id,directory:location.url)
            #expect(session.workbench.project==saved.project);#expect(await session.flushForClose())
            try await PersonalLibraryFileActions.delete(try await library.resolve(id).record,environment:environment);createdID=nil
        }catch{
            if let id=createdID{try? await PersonalLibraryFileActions.delete(try await library.resolve(id).record,environment:environment)}
            try? await environment.conversationStore.deleteConversation(id:conversation);throw error
        }
        try await environment.conversationStore.deleteConversation(id:conversation)
    }
}
#endif
