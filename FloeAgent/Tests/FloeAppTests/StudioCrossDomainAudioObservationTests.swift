// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeMeetings
@testable import FloeApp

@Suite("Registered cross-domain audio observation", .serialized)
@MainActor struct StudioCrossDomainAudioObservationTests {
    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func json(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
    private func contexts(_ body: @MainActor (ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        var ids: [UUID] = [], contexts: [ToolContext] = [], leases: [WorkspaceCenter.TaskRootLease] = []
        func cleanup() async {
            for lease in leases { lease.release(); try? FileManager.default.removeItem(at: lease.url) }
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
        }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "N13 audio contract", createdAt: now, updatedAt: now))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                let workspace = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "N13 audio contract")
                let lease = try await environment.workspaceCenter.acquireTaskRoot(workspace, conversationID: id); leases.append(lease)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Observe native audio", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "n13-fixture", allowedToolNames: StudioCoordinator.names,
                    workspaceRootURL: lease.url, cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID() // Trusted fixture host only; never a model-minted grant.
                contexts.append(context)
            }
            try await body(contexts[0], contexts[1]); await cleanup()
        } catch { await cleanup(); throw error }
    }
    private func withOriginal(_ kind: String, context original: ToolContext,
                              body: @MainActor (UUID, URL, ToolContext) async throws -> Void) async throws {
        var context = original; context.toolCallID = "n13-create-" + UUID().uuidString
        let created = try await invoke("studio.create", ["kind": kind, "title": "N13 audio \(UUID().uuidString.prefix(8))"], context)
        let text = try #require((created["record"] as? [String: Any])?["id"] as? String), id = try #require(UUID(uuidString: text))
        let library = try await PersonalContentService.shared.library(), location = try await library.resolve(id)
        context.approvalGrantID = nil
        do {
            try await body(id, location.url, context)
            try await PersonalLibraryFileActions.delete(try await library.resolve(id).record, environment: FloeAgentApp.liveEnvironment)
        } catch {
            if let current = try? await library.resolve(id) { try? await PersonalLibraryFileActions.delete(current.record, environment: FloeAgentApp.liveEnvironment) }
            throw error
        }
    }
    private func wave(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048)); buffer.frameLength = 2_048
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<2_048 { samples[i] = i % 2 == 0 ? 0.125 : -0.25 }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    private func inspect(_ id: UUID, sourceID: String, context: ToolContext) async throws -> [String: Any] {
        try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio",
            "inputJSON": json(["sourceID": sourceID, "startSeconds": 0, "endSeconds": 0.25, "bins": 16])], context)
    }
    private func assertPCM(_ result: [String: Any], original: Data) throws {
        #expect(result["kind"] as? String == "waveform")
        let report = try #require(result["audioObservation"] as? [String: Any]), source = try #require(report["source"] as? [String: Any])
        #expect(source["contentSHA256"] as? String == StudioToolOutput.hash(original))
        #expect(source["sampleRate"] as? Double == 8_000 && source["channelCount"] as? Int == 1 && source["frameCount"] as? Int == 2_048)
        let channels = try #require(report["channels"] as? [[String: Any]])
        #expect((channels[0]["binMin"] as? [Double])?.count == 16 && (channels[0]["binMax"] as? [Double])?.count == 16)
        #expect((source["path"] as? String)?.hasPrefix("studio/") == true)
    }

    @Test func stoppedMeetingRecordingRunsRealDecoderAndRejectsForeignAndTemporaryContexts() async throws {
        try await contexts { first, other in
            try await withOriginal("meeting", context: first) { id, root, context in
                let file = root.appendingPathComponent("Meeting/Media/original.wav"); try wave(file)
                let bytes = try Data(contentsOf: file)
                let service = MeetingService(database: try MeetingDatabase(path: root.appendingPathComponent("Meeting/meeting.sqlite").path))
                let recording = try await service.importFile(meeting: MeetingID(id), file: file, kind: .importedAudio, duration: { url in
                    let duration = try await AVURLAsset(url: url).load(.duration).seconds
                    return try .init(start: 0, end: duration)
                })
                let listing = try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio", "inputJSON": "{}"], context)
                #expect(listing["kind"] as? String == "sources" && listing["audioObservation"] == nil)
                let descriptors = try #require(listing["sources"] as? [[String: Any]])
                let source = try #require(descriptors.first), sourceID = try #require(source["sourceID"] as? String)
                #expect(source["kind"] as? String == "meetingRecording" && source["state"] as? String == "stopped")
                try assertPCM(try await inspect(id, sourceID: sourceID, context: context), original: bytes)
                do { _ = try await inspect(id, sourceID: sourceID, context: other); Issue.record("Another task read a native recording") } catch {}
                var temporary = context; temporary.temporaryReadOnly = true
                do { _ = try await inspect(id, sourceID: sourceID, context: temporary); Issue.record("Temporary chat read a native recording") } catch {}
                var cancelled = context; cancelled.cancellation = CancellationToken(); cancelled.cancellation.cancel()
                do { _ = try await inspect(id, sourceID: sourceID, context: cancelled); Issue.record("A cancelled run read a native recording") } catch {}
                let after = try await service.sessions(meeting: MeetingID(id))
                #expect(after.first(where: { $0.id == recording })?.state == .stopped)
                #expect(try Data(contentsOf: file) == bytes)
            }
        }
    }

    @Test func nativeVideoProjectsAudioAssetUsesOpaqueSourceAndRejectsStaleRevisionAndLinks() async throws {
        try await contexts { first, _ in
            try await withOriginal("video", context: first) { id, root, context in
                let source = try #require(context.workspaceRootURL).appendingPathComponent("Attachments/native.wav"); try wave(source)
                let bytes = try Data(contentsOf: source)
                let session = try await PersonalMediaFactory.session(id: id, directory: root)
                await session.importFile(source)
                let asset = try #require(session.document.assets.first(where: { $0.kind == .audio }))
                let state = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 1], context)
                let discovery = try #require(state["audioSources"] as? [String: Any]), page = try #require(discovery["page"] as? [String: Any])
                let descriptor = try #require((page["sources"] as? [[String: Any]])?.first), sourceID = try #require(descriptor["sourceID"] as? String)
                #expect(descriptor["kind"] as? String == "mediaAsset")
                try assertPCM(try await inspect(id, sourceID: sourceID, context: context), original: bytes)
                let track = try #require(session.document.trackGraph.tracks.first(where: { $0.kind == .audio }))
                _ = try await session.apply([.init(action: .updateTrackFlags(id: track.id, expectedRevision: track.revision,
                    name: "Changed native source revision", isMuted: nil, isLocked: nil, volume: nil))],
                    expectedRevision: session.document.revision, actor: .user)
                do { _ = try await inspect(id, sourceID: sourceID, context: context); Issue.record("A stale source ID crossed project revisions") } catch {}
                let fresh = try await invoke("studio.run", ["projectID": id.uuidString, "action": "inspectAudio", "inputJSON": "{}"], context)
                let next = try #require((fresh["sources"] as? [[String: Any]])?.first?["sourceID"] as? String)
                let url = try #require(session.resolvedAssets()[asset.id])
                try FileManager.default.removeItem(at: url); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: source)
                do { _ = try await inspect(id, sourceID: next, context: context); Issue.record("A symlink replaced the original audio source") } catch {}
                try FileManager.default.removeItem(at: url); try bytes.write(to: url)
                #expect(try Data(contentsOf: source) == bytes)
            }
        }
    }

    @Test func strictAudioSourceInputRetainsLegacyMusicIDAndRejectsPathsAndAmbiguousSelectors() throws {
        let legacy = try StudioMediaSourceContracts.decodeAudio(#"{"assetID":"existing-music-id","bins":16}"#)
        #expect(legacy.assetID?.rawValue == "existing-music-id" && !legacy.listsSources)
        #expect(try StudioMediaSourceContracts.decodeAudio("{}").listsSources)
        for input in [#"{"sourceID":"/private/host.wav"}"#, #"{"sourceID":"audio_dead","assetID":"music"}"#,
                      #"{"assetID":"music","offset":0}"#, #"{"bins":16}"#, #"{"password":"ignored"}"#] {
            do { _ = try StudioMediaSourceContracts.decodeAudio(input); Issue.record("Invalid audio source input was accepted") } catch {}
        }
    }
}
#endif
