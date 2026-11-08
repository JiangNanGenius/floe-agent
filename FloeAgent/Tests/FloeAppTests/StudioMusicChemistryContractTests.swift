// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeMusicCore
import FloeMusicNative
import FloeChemistryCore
import AVFoundation
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
    private func completeMusic(_ id: String, _ context: ToolContext) async throws -> (page: [String: Any], document: MusicDocument) {
        let first = try await read(id, context)
        let revision = try #require(first["revision"] as? String)
        let digest = try #require(first["contentSHA256"] as? String)
        var page = first, text = ""
        while true {
            #expect(page["revision"] as? String == revision)
            #expect(page["contentSHA256"] as? String == digest)
            text += try #require(page["contentJSON"] as? String)
            guard let next = page["nextOffset"] as? Int else { break }
            page = try json(try await invoke("studio.read", ["projectID": id, "offset": next, "limit": 12_000], context))
        }
        #expect(StudioToolOutput.hash(Data(text.utf8)) == digest)
        return (first, try JSONDecoder().decode(MusicDocument.self, from: Data(text.utf8)))
    }
    private func musicFixture(_ context: ToolContext, muted: Bool) async throws -> (id: String, document: MusicDocument) {
        let created = try json(try await invoke("studio.create", ["kind": "music", "title": "Music JSON regression \(UUID().uuidString.prefix(8))"], context))
        let id = try #require((created["record"] as? [String: Any])?["id"] as? String)
        let before = try await completeMusic(id, context)
        guard case .insertTrack(var track) = try #require(StudioTypedEditExamples.musicOperations(ticksPerQuarter: 960).first),
              case .midi(let notes) = track.clips[0].body else {
            throw MusicError.invalidBatch(reason: "The real typed fixture must contain its three original notes")
        }
        track.name = "QA-Piano"
        track.instrument = try MusicPluginState(pluginID: MusicNativeBuiltins.synth, presetIndex: 2)
        track.clips[0].body = .midi(try MusicMIDIClipPayload(durationTicks: 15_360, notes: notes.notes))
        let map = try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
            segments: [.init(startTick: .init(0), bpm: 100, beatsPerBar: 4, beatUnit: 4)])
        let operations: [MusicEditOp] = [.setTempoMap(map), .insertTrack(track),
            .setMasterStrip(try .init(muted: muted))]
        _ = try await invoke("studio.edit", ["projectID": id, "expectedRevision": try #require(before.page["revision"] as? String),
            "operationsJSON": try StudioTypedEditExamples.encode(operations)], context)
        let saved = try await completeMusic(id, context)
        #expect(saved.document.masterStrip.muted == muted)
        FileHandle.standardOutput.write(Data("FLOE_MUSIC_REGRESSION_FIXTURE|\(id)|muted=\(muted)\n".utf8))
        return (id, saved.document)
    }
    @Test func thirtySecondPlainUpdateSavesReopensAndRendersTheExactMixThroughRegisteredTools() async throws {
        try await withSavedTask { initial in
            var context = initial
            for muted in [true, false] {
                let fixture = try await musicFixture(context, muted: muted)
                let original = fixture.document, track = try #require(original.tracks.only), clip = try #require(track.clips.only)
                guard case .midi(let originalMIDI) = clip.body else { Issue.record("MIDI original required"); return }
                #expect(originalMIDI.notes.count == 3 && originalMIDI.durationTicks == 15_360)
                let melody = [60, 64, 67, 72, 69, 67, 64, 62]
                var notes: [[String: Any]] = (3..<48).map { beat in
                    ["pitch": melody[beat % melody.count], "startTick": beat * 960, "durationTicks": 720, "velocity": 80 + beat % 12]
                }
                notes += [60, 64, 67].map { ["pitch": $0, "startTick": 46_080, "durationTicks": 1_920, "velocity": 90] }
                let commands: [[String: Any]] = [["op": "midi.clip.update", "clipID": clip.id.rawValue,
                    "durationTicks": 48_000, "notesMode": "append", "notes": notes]]
                context.toolCallID = "append-real-thirty-second-phrase-\(muted)"
                let operations = String(decoding: try JSONSerialization.data(withJSONObject: commands), as: UTF8.self)
                _ = try await invoke("studio.edit", ["projectID": fixture.id, "expectedRevision": String(original.revision), "operationsJSON": operations], context)
                let saved = try await completeMusic(fixture.id, context)
                #expect(saved.document.revision == original.revision + 1)
                #expect(saved.document.buses == original.buses)
                #expect(saved.document.masterStrip == original.masterStrip)
                #expect(saved.document.tracks[0].strip == track.strip)
                guard case .midi(let midi) = saved.document.tracks[0].clips[0].body else { Issue.record("Saved MIDI required"); return }
                #expect(Array(midi.notes.prefix(3)) == originalMIDI.notes)
                #expect(midi.durationTicks == 48_000 && midi.notes.count == 51)
                let location = try await PersonalContentService.shared.library().resolve(try #require(UUID(uuidString: fixture.id)))
                let disk = try NativeMusicRepository(root: location.url.appendingPathComponent("Music"))
                #expect(try await disk.load(projectID: saved.document.id) == saved.document)
                let capabilities = try #require(saved.page["musicCapabilities"] as? [String: Any])
                #expect((capabilities["presets"] as? [Any])?.count == 41)
                let guide = try #require(saved.page["editFormat"] as? String)
                #expect(guide.contains("midi.clip.update") && guide.contains("midi.clip.insert"))
                context.toolCallID = "render-exact-thirty-second-phrase-\(muted)"
                let rendered = try json(try await invoke("studio.run", ["projectID": fixture.id, "action": "renderWAV", "inputJSON": "{\"tailFrames\":0}"], context))
                #expect(rendered["outputFile"] != nil && rendered["audioObservation"] != nil)
                let session = try await MusicProjectSession.open(id: try #require(UUID(uuidString: fixture.id)), directory: location.url.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
                let url = try #require(session.exportedFile)
                let file = try AVAudioFile(forReading: url)
                #expect(file.processingFormat.sampleRate == 48_000 && file.length == 1_440_000)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
                var peak: Float = 0, finite = true
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    let channels = try #require(buffer.floatChannelData)
                    for channel in 0..<Int(buffer.format.channelCount) {
                        for frame in 0..<Int(buffer.frameLength) {
                            let sample = channels[channel][frame]
                            finite = finite && sample.isFinite
                            peak = max(peak, abs(sample))
                        }
                    }
                }
                #expect(finite)
                #expect(muted ? peak < 0.000_000_1 : peak > 0.001)
                let bytes = try Data(contentsOf: url)
                #expect(bytes.count == rendered["bytes"] as? Int)
                #expect(StudioToolOutput.hash(bytes) == rendered["sha256"] as? String)
                #expect(session.document.buses == original.buses)
                #expect(session.document.masterStrip == original.masterStrip)
                FileHandle.standardOutput.write(Data("FLOE_MUSIC_THIRTY_SECONDS|\(fixture.id)|muted=\(muted)|frames=\(file.length)|peak=\(peak)|file=\(url.path)\n".utf8))
            }
        }
    }
    @Test func thirtySecondPlainInsertPreservesTheOriginalClipAndSavedMix() async throws {
        try await withSavedTask { initial in
            var context = initial
            let fixture = try await musicFixture(context, muted: true)
            let original = fixture.document, track = try #require(original.tracks.only)
            let command: [[String: Any]] = [["op": "midi.clip.insert", "trackID": track.id.rawValue,
                "name": "New thirty-second phrase", "durationTicks": 48_000, "offsetSamples": 0,
                "notes": [60, 64, 67].map { ["pitch": $0, "startTick": 46_080, "durationTicks": 1_920, "velocity": 96] }]]
            context.toolCallID = "insert-new-thirty-second-phrase"
            _ = try await invoke("studio.edit", ["projectID": fixture.id, "expectedRevision": String(original.revision),
                "operationsJSON": String(decoding: try JSONSerialization.data(withJSONObject: command), as: UTF8.self)], context)
            let saved = try await completeMusic(fixture.id, context)
            #expect(saved.document.revision == original.revision + 1)
            #expect(saved.document.buses == original.buses)
            #expect(saved.document.masterStrip == original.masterStrip)
            let clips = try #require(saved.document.tracks.only).clips
            #expect(clips.count == 2 && clips.first == track.clips.first)
            let inserted = try #require(clips.last)
            #expect(inserted.id != track.clips.first?.id && inserted.trackID == track.id)
            guard case .midi(let midi) = inserted.body else { Issue.record("Inserted MIDI required"); return }
            #expect(midi.durationTicks == 48_000 && midi.notes.count == 3)
            #expect(midi.notes.allSatisfy { $0.startTick.value == 46_080 && $0.durationTicks == 1_920 })
            let location = try await PersonalContentService.shared.library().resolve(try #require(UUID(uuidString: fixture.id)))
            let repository = try NativeMusicRepository(root: location.url.appendingPathComponent("Music"))
            #expect(try await repository.load(projectID: saved.document.id) == saved.document)
        }
    }
    @Test func invalidMusicFieldReportsItsPathAndNoOpKeepsTheSavedRevision() async throws {
        try await withSavedTask { initial in
            var context = initial
            let fixture = try await musicFixture(context, muted: true)
            let clip = try #require(fixture.document.tracks.first?.clips.first)
            let before = try await completeMusic(fixture.id, context)
            let bad: [[String: Any]] = [["op": "midi.clip.update", "clipID": clip.id.rawValue, "durationTicks": "48000"]]
            context.toolCallID = "invalid-music-duration-field"
            do {
                _ = try await invoke("studio.edit", ["projectID": fixture.id, "expectedRevision": String(fixture.document.revision),
                    "operationsJSON": String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self)], context)
                Issue.record("Invalid integer field must not be accepted")
            } catch {
                let message = error.localizedDescription
                #expect(message.contains("operations[0].durationTicks"))
                #expect(message.contains("Expected:"))
            }
            let after = try await completeMusic(fixture.id, context)
            #expect(after.document == before.document)
            #expect(after.page["contentSHA256"] as? String == before.page["contentSHA256"] as? String)
            context.toolCallID = "recognized-music-transform-noop"
            let unchanged: [[String: Any]] = [["op": "midi.clip.quantize", "clipID": clip.id.rawValue, "gridTicks": 1]]
            _ = try await invoke("studio.edit", ["projectID": fixture.id, "expectedRevision": String(after.document.revision),
                "operationsJSON": String(decoding: try JSONSerialization.data(withJSONObject: unchanged), as: UTF8.self)], context)
            #expect(try await completeMusic(fixture.id, context).document == after.document)
        }
    }
    @Test func nativeMusicControlsUpdateFileRecencyAfterSaveAndUndo() async throws {
        try await withSavedTask { context in
            let fixture = try await musicFixture(context, muted: true)
            let id = try #require(UUID(uuidString: fixture.id))
            let library = try await PersonalContentService.shared.library()
            let location = try await library.resolve(id)
            let session = try await MusicProjectSession.open(id: id, directory: location.url.appendingPathComponent("Music"),
                environment: FloeAgentApp.liveEnvironment)
            let track = try #require(session.document.tracks.first)
            let beforeApply = Date()
            try await session.applyPreset(index: 3, trackID: track.id, expectedRevision: session.document.revision)
            let changed = try await library.resolve(id).record
            #expect(changed.modifiedAt >= beforeApply)
            #expect(changed.modifiedAt > location.record.modifiedAt)
            #expect(session.document.masterStrip.muted)
            let disk = try NativeMusicRepository(root: location.url.appendingPathComponent("Music"))
            #expect(try await disk.load(projectID: session.document.id) == session.document)
            let revision = session.document.revision
            do {
                try await session.apply([.setMasterStrip(session.document.masterStrip)], expectedRevision: revision - 1)
                Issue.record("A stale native edit must not update file recency")
            } catch MusicError.staleRevision { }
            #expect(session.document.revision == revision)
            #expect(try await library.resolve(id).record.modifiedAt == changed.modifiedAt)
            let beforeUndo = Date()
            await session.undo()
            #expect(session.document.revision == revision + 1)
            #expect(session.document.tracks.first?.instrument == track.instrument)
            #expect(try await library.resolve(id).record.modifiedAt >= beforeUndo)
            let beforeRedo = Date()
            await session.undo(redo: true)
            #expect(session.document.revision == revision + 2)
            #expect(session.document.tracks.first?.instrument?.presetIndex == 3)
            #expect(try await library.resolve(id).record.modifiedAt >= beforeRedo)
            #expect(try await disk.load(projectID: session.document.id) == session.document)
            #expect(session.document.masterStrip.muted)
        }
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
