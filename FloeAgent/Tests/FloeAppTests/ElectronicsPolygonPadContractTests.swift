// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeElectronicsCore
@testable import FloeApp

@Suite("Electronics polygon pad registered tools", .serialized)
@MainActor struct ElectronicsPolygonPadContractTests {
    private func text(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self) }
    private func object(_ value: some Encodable) throws -> Any { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) }
    private func json(_ value: ToolExecutionOutput) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with:Data((value.capturedOutput ?? value.summary).utf8)) as? [String:Any])
    }
    private func invoke(_ name: String, _ arguments: [String:Any], _ initial: ToolContext) async throws -> ToolExecutionOutput {
        var context=initial;context.executionToolName=name
        let runner=try #require(ToolRunnerRegistry.shared.runner(named:name))
        return try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:arguments),context:context)
    }

    @Test func registeredPutReadDRCAndBothManufacturingExportsConsumeTheSameSavedPolygon() async throws {
        let environment=FloeAgentApp.liveEnvironment;try await environment.ensureDurableAutomationReady()
        let library=try await PersonalContentService.shared.library(),conversation=UUID(),runID=UUID(),now=Date()
        try await environment.conversationStore.saveConversation(.init(id:conversation,title:"Polygon pad contract",createdAt:now,updatedAt:now))
        _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:conversation,title:"Polygon pad contract")
        try await environment.conversationStore.setArchived(id:conversation,archived:true)
        try await environment.runStore.saveRun(.init(id:runID,conversationID:conversation,state:"executing",goal:"Polygon pad contract",startedAt:now))
        var context=ToolContext(runID:runID,toolCallID:"create-polygon-pad",allowedToolNames:StudioCoordinator.names,cancellation:CancellationToken(),conversationID:conversation)
        context.frozenEffectiveCatalogNames=StudioCoordinator.names;context.approvalGrantID=UUID()
        var createdID:UUID?
        do {
            let created=try json(await invoke("studio.create",["kind":"electronics","title":"QA Polygon Pad \(UUID().uuidString.prefix(8))"],context))
            let record=try #require(created["record"] as? [String:Any]),raw=try #require(record["id"] as? String),id=try #require(UUID(uuidString:raw));createdID=id
            FileHandle.standardOutput.write(Data("FLOE_POLYGON_PAD_FIXTURE|\(id.uuidString)\n".utf8))
            let location=try await library.resolve(id),original=try ElectronicsSavedSnapshot(id:id,directory:location.url)
            var definition=try #require(original.project.footprints.first{$0.name=="0603"})
            let old=try #require(definition.pads.first)
            let vertices:[EDAPoint]=[.init(-0.45,-0.45),.init(0.45,-0.45),.init(0.45,0.45),.init(0,0.1),.init(-0.45,0.45)]
            definition.pads[0]=try EDAPolygonPadGeometry.replacingOutline(of:old,with:vertices)
            let expected=definition.pads[0]
            #expect(expected.id==old.id && expected.number==old.number && expected.position==old.position && expected.angle==old.angle && expected.layers==old.layers)
            var board=try #require(original.project.boards.first);board.edgePlated=false
            board.footprints=[.init(definitionID:definition.id,reference:"R1",position:.init(20,20),angle:30),.init(definitionID:definition.id,reference:"R2",position:.init(50,20),angle:30,side:"B.Cu")]
            var badValue=try #require(object(definition) as? [String:Any])
            var badPads=try #require(badValue["pads"] as? [[String:Any]])
            var badPoints=try #require(badPads[0]["polygon"] as? [[String:Any]])
            badPoints[0]["z"]=1;badPads[0]["polygon"]=badPoints;badValue["pads"]=badPads
            do {
                _ = try StudioElectronicsContract.decode(text([["op":"native.put","kind":"footprintDefinition","value":badValue]]),project:original.project)
                Issue.record("Unknown polygon vertex fields must not be dropped")
            } catch { #expect(error.localizedDescription.contains("z")) }
            context.toolCallID="put-polygon-pad"
            _ = try await invoke("studio.edit",["projectID":raw,"expectedRevision":String(original.project.revision),"operationsJSON":text([
                ["op":"native.put","kind":"footprintDefinition","value":try object(definition)],
                ["op":"native.put","kind":"board","value":try object(board)]])],context)
            let saved=try ElectronicsSavedSnapshot(id:id,directory:location.url)
            #expect(saved.project.footprints.first{$0.id==definition.id}?.pads.first==expected)
            var content="",offset=0,finished=false
            for _ in 0..<64 {
                context.toolCallID="read-polygon-pad-"+String(offset)
                let page=try json(await invoke("studio.read",["projectID":raw,"offset":offset,"limit":12_000],context))
                #expect(page["revision"] as? String==String(saved.project.revision))
                #expect(page["contentSHA256"] as? String==saved.digest)
                content += try #require(page["contentJSON"] as? String)
                if let next=page["nextOffset"] as? Int{offset=next}else{finished=true;break}
            }
            #expect(finished)
            let read=try JSONDecoder().decode(EDAProject.self,from:Data(content.utf8));#expect(read==saved.project)
            #expect(read.footprints.first{$0.id==definition.id}?.pads.first?.polygon==vertices)
            context.toolCallID="drc-polygon-pad"
            let checked=try await invoke("studio.run",["projectID":raw,"action":"eda.drc","inputJSON":text(["expectedRevision":String(saved.project.revision),"boardID":board.id.uuidString])],context)
            let reportFile=try #require(checked.outputFiles.first{$0.displayName=="DRC.json"})
            let reportBytes=try Data(contentsOf:FloeArtifactStore.root().appendingPathComponent(reportFile.relativePath))
            let report=try JSONDecoder().decode(EDADRCReport.self,from:reportBytes)
            #expect(report.projectID==id && report.revision==saved.project.revision && StudioToolOutput.hash(reportBytes)==reportFile.sha256)
            #expect(!report.issues.contains{$0.code=="pad_shape_unsupported" || $0.code=="pad_layer_unsupported"})
            for format in [EDAExportFormat.gerber,.gerberTechnical] {
                context.toolCallID="export-polygon-"+format.rawValue
                var options:[String:Any]=["expectedRevision":String(saved.project.revision),"boardID":board.id.uuidString,"format":format.rawValue]
                let layers=["F.Mask","B.Mask","F.Paste","B.Paste"]
                if format == .gerberTechnical{options["gerberLayers"]=layers}
                let arguments:[String:Any]=["projectID":raw,"action":"eda.export","inputJSON":try text(options)]
                let first=try await invoke("studio.run",arguments,context),retry=try await invoke("studio.run",arguments,context)
                #expect(first.outputFiles.map(\.outputID)==retry.outputFiles.map(\.outputID))
                let core=try EDAExchange.export(saved.project,format:format,boardID:board.id,gerberLayers:format == .gerberTechnical ? layers:nil)
                #expect(Set(first.outputFiles.map(\.displayName))==Set(core.files.map(\.name)))
                for output in first.outputFiles {
                    let bytes=try Data(contentsOf:FloeArtifactStore.root().appendingPathComponent(output.relativePath)),expectedFile=try #require(core.files.first{$0.name==output.displayName})
                    #expect(bytes==expectedFile.data && bytes.count==output.byteCount && StudioToolOutput.hash(bytes)==output.sha256)
                }
            }
            #expect(try ElectronicsSavedSnapshot(id:id,directory:location.url).digest==saved.digest)
            let session=try await ElectronicsProjectSession.open(id:id,directory:location.url)
            #expect(session.workbench.project==saved.project)
            #expect(await session.flushForClose())
            try await PersonalLibraryFileActions.delete(try await library.resolve(id).record,environment:environment);createdID=nil
        } catch {
            if let id=createdID{try? await PersonalLibraryFileActions.delete(try await library.resolve(id).record,environment:environment)}
            try? await environment.conversationStore.deleteConversation(id:conversation);throw error
        }
        try await environment.conversationStore.deleteConversation(id:conversation)
    }
}
#endif
