// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench
@testable import FloeApp

@Suite("Typed native media calls", .serialized)
@MainActor struct StudioMediaContractTests {
    private func invoke(_ name: String, _ arguments: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: arguments), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    @Test func publishedCaptionInputUsesReadRevisionAndKeepsSavedStyleAndText() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let taskID = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: taskID, title: "Native video contract", createdAt: now, updatedAt: now))
        _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: taskID, title: "Native video contract")
        try await environment.conversationStore.setArchived(id: taskID, archived: true)
        try await environment.runStore.saveRun(.init(id: runID, conversationID: taskID, state: "executing", goal: "Native video contract", startedAt: now))
        var context = ToolContext(runID: runID, toolCallID: "create-contract-video", allowedToolNames: StudioCoordinator.names,
            cancellation: CancellationToken(), conversationID: taskID)
        context.frozenEffectiveCatalogNames = StudioCoordinator.names
        context.approvalGrantID = UUID() // Trusted host seam; never model-authored authority.
        do {
            let created = try await invoke("studio.create", ["kind": "video", "title": "Contract video \(UUID().uuidString.prefix(8))"], context)
            let record = try #require(created["record"] as? [String: Any])
            let id = try #require(record["id"] as? String), uuid = try #require(UUID(uuidString: id))
            let initial = try await invoke("studio.read", ["projectID": id, "limit": 1000], context)
            let revision = try #require(initial["revision"] as? String)
            let guide = try #require(initial["editFormat"] as? String)
            let example = try #require(guide.components(separatedBy: "\nExample inputJSON:\n").last)
            var input = try #require(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
            #expect((input["expectedRevision"] as? Int64) == Int64(revision))
            // The outer read contract uses a string. The native media boundary
            // must accept that exact value without requiring model guesswork.
            input["expectedRevision"] = revision
            context.toolCallID = "create-caption-with-published-style"
            _ = try await invoke("studio.media", ["projectID": id, "toolID": "video.caption",
                "inputJSON": String(decoding: JSONSerialization.data(withJSONObject: input), as: UTF8.self)], context)
            let location = try await PersonalContentService.shared.library().resolve(uuid)
            let session = try await PersonalMediaFactory.session(id: uuid, directory: location.url)
            let captions = session.document.trackGraph.tracks.filter { $0.kind == .caption }.flatMap(\.clips)
            #expect(captions.count == 1 && captions.first?.captionText == "Caption")
            #expect(captions.first?.timelineRange.startSeconds == 0)
            #expect(captions.first?.timelineRange.durationSeconds == 3)
            #expect(session.document.trackGraph.captionStyle?.positionY == 0.5)
            #expect(session.document.trackGraph.captionStyle?.colorHex == "#FFFFFFFF")
            let savedRevision = session.document.revision
            let savedBytes = try StudioToolOutput.data(session.project)
            for (call, invalid, field) in [
                ("missing-revision", #"{"text":"wrong"}"#, "expectedRevision"),
                ("wrong-duration-type", "{\"expectedRevision\":\(savedRevision),\"duration\":\"3\",\"text\":\"wrong\"}", "inputJSON.duration"),
                ("unknown-field", "{\"expectedRevision\":\(savedRevision),\"madeUpStyle\":0.5}", "madeUpStyle")
            ] {
                context.toolCallID = call
                do {
                    _ = try await invoke("studio.media", ["projectID": id, "toolID": "video.caption", "inputJSON": invalid], context)
                    Issue.record("Malformed native media input committed")
                } catch let FloeError.validationFailed(message) { #expect(message.contains(field)) }
                #expect(try StudioToolOutput.data(session.project) == savedBytes)
            }
            context.toolCallID = "style-only-legacy-fields"
            let style = "{\"expectedRevision\":\"\(savedRevision)\",\"color\":\"#00FF00FF\",\"property\":\"positionY\",\"number\":0.4}"
            _ = try await invoke("studio.media", ["projectID": id, "toolID": "video.caption", "inputJSON": style], context)
            #expect(session.document.trackGraph.tracks.filter { $0.kind == .caption }.flatMap(\.clips) == captions)
            #expect(session.document.trackGraph.captionStyle?.positionY == 0.4)
            #expect(session.document.trackGraph.captionStyle?.colorHex == "#00FF00FF")
            let latestBytes = try StudioToolOutput.data(session.project)
            context.toolCallID = "reject-stale-media-revision"
            do {
                _ = try await invoke("studio.media", ["projectID": id, "toolID": "video.caption", "inputJSON": style], context)
                Issue.record("A stale media writer was accepted")
            } catch MediaPreparedCoreError.documentChanged {}
            #expect(try StudioToolOutput.data(session.project) == latestBytes)
            let restored = try #require(try await session.store.loadProject(id: uuid))
            #expect(restored.prepared == session.document)
            #expect(restored.preparedJournal?.entries.last?.actor == .model)
            try await environment.conversationStore.deleteConversation(id: taskID)
        } catch {
            try? await environment.conversationStore.deleteConversation(id: taskID)
            throw error
        }
    }
}
#endif
