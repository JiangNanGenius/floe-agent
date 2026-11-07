// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeMusicCore
import FloeMusicNative
import FloeChemistryCore
@testable import FloeApp

/// Real registered runners and the existing App service graph. The authored
/// examples go through the same JSON boundary as an ordinary assistant call.
@Suite("Typed music and chemistry tool contracts",.serialized)
@MainActor struct StudioMusicChemistryContractTests {
    private func json(_ output:ToolExecutionOutput) throws -> [String:Any] {
        try #require(JSONSerialization.jsonObject(with:Data((output.capturedOutput ?? output.summary).utf8)) as? [String:Any])
    }
    private func invoke(_ name:String,_ args:[String:Any],_ context:ToolContext) async throws -> ToolExecutionOutput {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named:name))
        return try await runner.execute(argumentsJSON:JSONSerialization.data(withJSONObject:args),context:context)
    }
    private func withSavedTask(_ body:@MainActor (ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let id = UUID(),runID = UUID(),now = Date()
        try await environment.conversationStore.saveConversation(.init(id:id,title:"Typed native contract",createdAt:now,updatedAt:now))
        _ = try await SQLiteWorkspaceStore(database:environment.database).ensureWorkspace(conversationID:id,title:"Typed native contract")
        try await environment.conversationStore.setArchived(id:id,archived:true)
        try await environment.runStore.saveRun(.init(id:runID,conversationID:id,state:"executing",goal:"Typed native contract",startedAt:now))
        var context = ToolContext(runID:runID,toolCallID:"create-contract",allowedToolNames:StudioCoordinator.names,
            cancellation:CancellationToken(),conversationID:id)
        context.frozenEffectiveCatalogNames = StudioCoordinator.names
        // Supplied by the trusted host test seam, never a model-authored grant.
        context.approvalGrantID = UUID()
        do { try await body(context) }
        catch { try? await environment.conversationStore.deleteConversation(id:id);throw error }
        try await environment.conversationStore.deleteConversation(id:id)
    }
    private func read(_ id:String,_ context:ToolContext) async throws -> [String:Any] {
        try json(try await invoke("studio.read",["projectID":id,"limit":12000],context))
    }
    private func example(_ page:[String:Any]) throws -> String {
        let guide = try #require(page["editFormat"] as? String)
        #expect(guide.contains("\nExample JSON:\n"))
        return try #require(guide.components(separatedBy:"\nExample JSON:\n").last)
    }
    private func chemistryProject(_ page:[String:Any]) throws -> ChemistryProject {
        try JSONDecoder().decode(StudioChemistryContractSnapshot.self,
            from:Data(try #require(page["contentJSON"] as? String).utf8)).project
    }
    private func graph(_ object:ChemicalObject) throws -> FloeChemistryCore.JSONValue {
        try JSONDecoder().decode(FloeChemistryCore.JSONValue.self,
            from:Data(try #require(object.facts?["cjson"]?.string).utf8))
    }
    @Test func publishedMusicExampleCommitsReopensAndRendersThroughRegisteredTools() async throws {
        try await withSavedTask { initial in
            var context = initial
            let created = try json(try await invoke("studio.create",["kind":"music","title":"Contract music \(UUID().uuidString.prefix(8))"],context))
            let record = try #require(created["record"] as? [String:Any]),id = try #require(record["id"] as? String)
            let before = try await read(id,context)
            let original = try JSONDecoder().decode(MusicDocument.self,from:Data(try #require(before["contentJSON"] as? String).utf8))
            let operations = try example(before)
            #expect(try JSONDecoder().decode([MusicEditOp].self,from:Data(operations.utf8)).count == 1)
            context.toolCallID = "commit-complete-music-example"
            _ = try await invoke("studio.edit",["projectID":id,"expectedRevision":try #require(before["revision"] as? String),"operationsJSON":operations],context)
            let after = try await read(id,context)
            let saved = try JSONDecoder().decode(MusicDocument.self,from:Data(try #require(after["contentJSON"] as? String).utf8))
            let track = try #require(saved.tracks.only),clip = try #require(track.clips.only)
            #expect(track.kind == .midi && track.instrument?.pluginID == MusicNativeBuiltins.synth)
            #expect(clip.trackID == track.id)
            guard case .midi(let midi) = clip.body else { Issue.record("Published example did not make a MIDI clip");return }
            #expect(midi.notes.map(\.pitch) == [60,64,67])
            #expect(midi.notes.map(\.startTick.value) == [0,Int64(original.tempoMap.ticksPerQuarter),Int64(original.tempoMap.ticksPerQuarter)*2])
            #expect(midi.durationTicks == Int64(original.tempoMap.ticksPerQuarter)*4)
            let location = try await PersonalContentService.shared.library().resolve(try #require(UUID(uuidString:id)))
            let repository = try NativeMusicRepository(root:location.url.appendingPathComponent("Music"))
            let reopened = try await repository.load(projectID:saved.id)
            #expect(reopened == saved)
            context.toolCallID = "render-committed-music-example"
            let rendered = try json(try await invoke("studio.run",["projectID":id,"action":"renderWAV"],context))
            #expect((rendered["bytes"] as? Int ?? 0)>44)
            let session = try await MusicProjectSession.open(id:try #require(UUID(uuidString:id)),directory:location.url.appendingPathComponent("Music"),environment:FloeAgentApp.liveEnvironment)
            let file = try #require(session.exportedFile),bytes = try Data(contentsOf:file)
            #expect(bytes.count == rendered["bytes"] as? Int)
            #expect(StudioToolOutput.hash(bytes) == rendered["sha256"] as? String)
        }
    }
    @Test func publishedBenzeneExampleRetainsItsGraphAndEditsAnExistingBond() async throws {
        try await withSavedTask { initial in
            var context = initial
            let created = try json(try await invoke("studio.create",["kind":"chemistry","title":"Contract chemistry \(UUID().uuidString.prefix(8))"],context))
            let record = try #require(created["record"] as? [String:Any]),id = try #require(record["id"] as? String)
            let before = try await read(id,context),operations = try example(before)
            let command = try JSONDecoder().decode(ChemistryHostEdit.self,from:Data(operations.utf8))
            #expect(command.source == "c1ccccc1" && command.format == "smiles")
            context.toolCallID = "import-real-benzene-graph"
            _ = try await invoke("studio.edit",["projectID":id,"expectedRevision":try #require(before["revision"] as? String),"operationsJSON":operations],context)
            let importedPage = try await read(id,context)
            let imported = try #require(chemistryProject(importedPage).objects.only)
            #expect(imported.facts?["atomCount"]?.number == 12)
            #expect(imported.facts?["bondCount"]?.number == 12)
            #expect(imported.facts?["coordinateSetCount"]?.number == 0)
            let sourceGraph = try graph(imported)
            let elements = try #require(sourceGraph["atoms"]?["elements"]?["number"]?.array)
            let edges = try #require(sourceGraph["bonds"]?["connections"]?["index"]?.array)
            #expect(elements.filter { $0.number == 6 }.count == 6)
            #expect(elements.filter { $0.number == 1 }.count == 6)
            #expect(edges.count == 24)
            #expect((sourceGraph["atoms"]?["coords"]?["3d"]?.array ?? []).isEmpty)
            context.toolCallID = "analyze-real-benzene-graph"
            let analysis = try json(try await invoke("studio.chemistry",["projectID":id,"action":"calculate",
                "inputJSON":try StudioTypedEditExamples.encode(StudioTypedEditExamples.chemistryAnalyze(imported))],context))
            #expect(analysis["status"] as? String == "succeeded")
            let result = try #require(analysis["result"] as? [String:Any])
            #expect(result["formula"] as? String == "C6H6")
            #expect((result["bondCount"] as? Int) == 12)
            #expect((result["coordinateSetCount"] as? Int) == 0)
            let currentPage = try await read(id,context),current = try #require(chemistryProject(currentPage).objects.only)
            let bond = try #require(StudioTypedEditExamples.firstCarbonBond(current)),replacement = bond.order == 1 ? 2 : 1
            context.toolCallID = "change-existing-carbon-bond"
            _ = try await invoke("studio.edit",["projectID":id,"expectedRevision":try #require(currentPage["revision"] as? String),
                "operationsJSON":try StudioTypedEditExamples.encode(StudioTypedEditExamples.chemistryBondOrder(current,index:bond.index,order:replacement))],context)
            let changedPage = try await read(id,context),changed = try #require(chemistryProject(changedPage).objects.only)
            #expect(changed.id == current.id && changed.revision>current.revision)
            #expect(try graph(changed)["bonds"]?["order"]?.array?[bond.index].number == Double(replacement))
            // Restore this test's original ring; no user original is touched.
            context.toolCallID = "restore-contract-bond-order"
            _ = try await invoke("studio.edit",["projectID":id,"expectedRevision":try #require(changedPage["revision"] as? String),
                "operationsJSON":try StudioTypedEditExamples.encode(StudioTypedEditExamples.chemistryBondOrder(changed,index:bond.index,order:bond.order))],context)
            let final = try #require(chemistryProject(try await read(id,context)).objects.only)
            #expect(try graph(final)["bonds"]?["order"] == sourceGraph["bonds"]?["order"])
            #expect(final.facts?["coordinateSetCount"]?.number == 0)
            let uuid = try #require(UUID(uuidString:id)),location = try await PersonalContentService.shared.library().resolve(uuid)
            let disk = try await ChemistryHostFactory.verifiedStore(id:uuid,directory:location.url)
            #expect(try await disk.load(uuid).objects.only == final)
        }
    }
}
private extension Array {
    var only:Element? { count == 1 ? first : nil }
}
#endif
