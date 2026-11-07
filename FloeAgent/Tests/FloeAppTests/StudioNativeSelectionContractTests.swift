// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
import FloeMusicCore
@testable import FloeApp

@Suite("Registered native selection targeting", .serialized)
@MainActor struct StudioNativeSelectionContractTests {
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

    private func mutate(_ id: UUID, _ toolID: String, _ input: [String: Any], context original: ToolContext) async throws {
        var context = original; context.approvalGrantID = UUID(); context.toolCallID = "n13-edit-" + UUID().uuidString
        _ = try await invoke("studio.media", ["projectID": id.uuidString, "toolID": toolID, "inputJSON": json(input)], context)
    }
    private func fence(_ id: UUID, context: ToolContext) async throws -> String {
        let read = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 1], context)
        let selection = try #require(read["liveSelection"] as? [String: Any])
        #expect(selection["status"] as? String == "existingNativeSession")
        return try #require((selection["media"] as? [String: Any])?["selectionFence"] as? String)
    }

    @Test func registeredMediaTargetsExplicitObjectAndRefusesUnknownOrChangedSelection() async throws {
        try await contexts { context, _ in
            try await withOriginal("image", context: context) { id, root, context in
                let session = try await PersonalMediaFactory.session(id: id, directory: root)
                for color in ["#112233", "#445566"] {
                    try await mutate(id, "image.fill", ["expectedRevision": String(session.document.revision), "color": color], context: context)
                }
                let first = try #require(session.document.layers.first), second = try #require(session.document.layers.last)
                #expect(first.id != second.id)
                session.select(first)
                let before = session.document
                let disk = session.store.projectURL(id: id), beforeBytes = try Data(contentsOf: disk)
                for extra in [[:], ["objectID": UUID().uuidString]] as [[String: Any]] {
                    var input: [String: Any] = ["expectedRevision": String(before.revision), "number": 45]
                    input.merge(extra) { _, new in new }
                    do { try await mutate(id, "image.rotate", input, context: context); Issue.record("An unbound/unknown target fell back to UI selection") } catch {}
                    let unchangedBytes = try Data(contentsOf: disk)
                    #expect(session.document == before && unchangedBytes == beforeBytes)
                }
                try await mutate(id, "image.rotate", ["expectedRevision": String(before.revision), "objectID": second.id.uuidString, "number": 45], context: context)
                #expect(session.document.layer(first.id)?.transform.rotationDegrees == first.transform.rotationDegrees)
                #expect(session.document.layer(second.id)?.transform.rotationDegrees == second.transform.rotationDegrees + 45)
                #expect(session.selectedLayerID == first.id, "Explicit model targeting must not select a different user layer")
                let oldFence = try await fence(id, context: context), current = session.document
                session.select(try #require(session.document.layer(second.id)))
                do {
                    try await mutate(id, "image.rotate", ["expectedRevision": String(current.revision), "selectionFence": oldFence, "number": 30], context: context)
                    Issue.record("A stale selection fence edited the newly selected layer")
                } catch {}
                #expect(session.document == current)
                let freshFence = try await fence(id, context: context)
                try await mutate(id, "image.rotate", ["expectedRevision": String(current.revision), "selectionFence": freshFence, "number": 30], context: context)
                #expect(session.document.layer(second.id)?.transform.rotationDegrees == second.transform.rotationDegrees + 75)
                let retained = session.document
                do {
                    try await mutate(id, "image.merge-layer", ["expectedRevision": String(retained.revision), "selectionFence": try await fence(id, context: context)], context: context)
                    Issue.record("A model merge implicitly picked the last two layers")
                } catch {}
                #expect(session.document == retained)
            }
        }
    }

    @Test func registeredMusicReadDoesNotCreateDefaultSelectionAndReportsActualNativeClip() async throws {
        try await contexts { context, _ in
            try await withOriginal("music", context: context) { id, root, context in
                for _ in 0..<2 {
                    let value = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 1], context)
                    #expect((value["liveSelection"] as? [String: Any])?["status"] as? String == "noExistingNativeSession")
                    #expect(try MusicProjectSession.existingForAudioObservation(id: id, directory: root.appendingPathComponent("Music")) == nil)
                }
                let session = try await MusicProjectSession.open(id: id, directory: root.appendingPathComponent("Music"), environment: FloeAgentApp.liveEnvironment)
                var editing = context; editing.approvalGrantID = UUID(); editing.toolCallID = "n13-insert-real-midi"
                let operations = try StudioTypedEditExamples.encode(StudioTypedEditExamples.musicOperations(ticksPerQuarter: session.document.tempoMap.ticksPerQuarter))
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": String(session.document.revision), "operationsJSON": operations], editing)
                let track = try #require(session.document.tracks.first), clip = try #require(track.clips.first)
                session.selectedTrack = track.id; session.selectedClip = clip.id; session.playheadSeconds = 0.25; session.looping = true
                let before = session.document
                let read = try await invoke("studio.read", ["projectID": id.uuidString, "limit": 1], context)
                let projection = try #require((read["liveSelection"] as? [String: Any])?["music"] as? [String: Any])
                #expect((projection["selectedTrackID"] as? [String: Any])?["rawValue"] as? String == track.id.rawValue)
                #expect((projection["selectedClipID"] as? [String: Any])?["rawValue"] as? String == clip.id.rawValue)
                #expect(projection["playheadSeconds"] as? Double == 0.25 && projection["looping"] as? Bool == true)
                #expect(session.document == before && !session.isPlaying && !session.isRendering)
                #expect(try await session.repository.load(projectID: before.id) == before)
            }
        }
    }
}
#endif
