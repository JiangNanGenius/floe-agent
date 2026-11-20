// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeBuildingEditor
import FloeBuildingProject
@testable import FloeApp

/// An ordinary task with a write binding works a closed Space building
/// original directly: current-revision reads, native edits that publish one
/// verified generation, cross-session and editor-mount fencing, cancellation
/// and durable persistence. Real runners, repository and document service.
@Suite("Ordinary task bound building originals", .serialized)
@MainActor struct StudioOrdinaryBuildingTests {
    private struct Fixture {
        let environment: AppEnvironment
        let ownerConversation: UUID
        let foreignConversation: UUID
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        let text = output.capturedOutput ?? output.summary
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func invoke(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        return try await json(try await runner.execute(
            argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context))
    }

    private func withFixture(_ body: @MainActor (Fixture, ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        var ids = [UUID]()
        do {
            var contexts = [ToolContext]()
            var conversations = [UUID]()
            for label in ["owner", "foreign"] {
                let conversation = UUID(), run = UUID(), now = Date()
                ids.append(conversation)
                conversations.append(conversation)
                try await environment.conversationStore.saveConversation(.init(
                    id: conversation, title: "Ordinary building \(label)", createdAt: now, updatedAt: now))
                _ = try await SQLiteWorkspaceStore(database: environment.database)
                    .ensureWorkspace(conversationID: conversation, title: "Ordinary building \(label)")
                try await environment.runStore.saveRun(.init(
                    id: run, conversationID: conversation, state: "executing", goal: "Ordinary building", startedAt: now))
                var context = ToolContext(runID: run, toolCallID: "ordinary-building-\(label)",
                    allowedToolNames: StudioCoordinator.names, cancellation: CancellationToken(), conversationID: conversation)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names
                context.approvalGrantID = UUID() // Trusted host fixture grant, never a model-authored permission.
                contexts.append(context)
            }
            let fixture = Fixture(environment: environment, ownerConversation: conversations[0],
                foreignConversation: conversations[1])
            try await body(fixture, contexts[0], contexts[1])
        } catch {
            for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }
            throw error
        }
        for id in ids { try await environment.conversationStore.deleteConversation(id: id) }
    }

    private func createBuilding(_ context: ToolContext) async throws -> (UUID, URL) {
        let output = try await invoke("studio.create",
            ["kind": "building", "title": "Ordinary building \(UUID().uuidString.prefix(8))"], context)
        let record = try #require(output["record"] as? [String: Any])
        let raw = try #require(record["id"] as? String)
        let id = try #require(UUID(uuidString: raw))
        let directory = try await PersonalContentService.shared.library().resolve(id).url
        return (id, directory)
    }

    private func building(_ context: ToolContext, _ id: UUID, action: String) async throws -> [String: Any] {
        try await invoke("studio.read", ["projectID": id.uuidString, "limit": 12_000,
            "building": ["action": action]], context)
    }

    private func manifestGeneration(_ directory: URL) throws -> String? {
        try BuildingProjectRepository.open(
            at: BuildingProjectSpaceOriginal.projectURL(directory: directory)).loadManifest()?.generationID
    }

    @Test func ordinaryTaskCreatesReadsEditsAndPersistsTheSameOriginal() async throws {
        try await withFixture { _, owner, _ in
            let (id, directory) = try await createBuilding(owner)
            let package = BuildingProjectSpaceOriginal.projectURL(directory: directory)
            let initial = try manifestGeneration(directory)
            let initialGeneration = try #require(initial)

            // The closed package reads its current published revision.
            let page = try await building(owner, id, action: "overview")
            #expect(page["kind"] as? String == "building")
            #expect(page["saveScope"] as? String == "publishedOriginal")
            let revision = try #require(page["revision"] as? String)
            #expect(Int(revision) != nil)
            #expect(page["generationID"] as? String == initialGeneration)
            #expect(page["editFormat"] as? String != nil)

            // Native record edit on the same original publishes a new generation.
            let room = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                "operationsJSON": #"{"action":"createRoom","name":"Study"}"#], owner)
            #expect(room["result"] as? String == "roomCreated")
            #expect(room["saveScope"] as? String == "publishedOriginal")
            let roomRevision = try #require(room["revision"] as? String)
            #expect(roomRevision != revision)
            let roomGeneration = try #require(room["generationID"] as? String)
            #expect(roomGeneration != initialGeneration)

            // Wall edits use the current wall counters and persist as well.
            let walls = try await building(owner, id, action: "walls")
            let changeCount = try #require(walls["buildingChangeCount"] as? Int)
            let wallRevision = try #require(walls["wallRevision"] as? Int)
            let wall = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": roomRevision,
                "operationsJSON": #"{"action":"addWall","a":[0,0],"b":[4000,0],"thicknessMM":220,"heightMM":2700,"name":"West","expectedChangeCount":\#(changeCount),"expectedWallRevision":\#(wallRevision)}"#], owner)
            #expect(wall["result"] as? String == "wallAdded")
            let publishedGeneration = try #require(wall["generationID"] as? String)
            #expect(publishedGeneration != initialGeneration)

            // Independent proof: the published manifest advanced and a fresh
            // document session sees the room and the wall.
            #expect(try manifestGeneration(directory) == publishedGeneration)
            let session = try await BuildingEditorProjectSession.open(at: package,
                assetLibraryDirectory: BuildingProjectSpaceOriginal.assetLibraryURL(directory: directory),
                spaceRecordID: id)
            let snapshot = try await session.recordsSnapshot()
            #expect(snapshot.rooms.contains { $0.name == "Study" })
            let wallSnapshot = try session.wallSnapshot()
            #expect(wallSnapshot.walls.contains { $0.name == "West" })
            try await session.close(discardWorkingCopy: true)
        }
    }

    @Test func foreignConversationAndMissingGrantAreRefused() async throws {
        try await withFixture { _, owner, foreign in
            let (id, _) = try await createBuilding(owner)
            // No binding: another ordinary task cannot read or edit the work.
            do {
                _ = try await building(foreign, id, action: "overview")
                Issue.record("An unbound conversation read a bound building original.")
            } catch let FloeError.validationFailed(message) {
                #expect(message.contains("Open this work"))
            }
            let page = try await building(owner, id, action: "overview")
            let revision = try #require(page["revision"] as? String)
            do {
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                    "operationsJSON": #"{"action":"createRoom","name":"Intrusion"}"#], foreign)
                Issue.record("An unbound conversation edited a bound building original.")
            } catch let FloeError.validationFailed(message) {
                #expect(message.contains("Open this work"))
            }
            // The binding alone is not enough: the task's approval grant is required.
            var ungranted = owner
            ungranted.approvalGrantID = nil
            do {
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                    "operationsJSON": #"{"action":"createRoom","name":"Intrusion"}"#], ungranted)
                Issue.record("A building edit ran without the task's approval grant.")
            } catch let FloeError.validationFailed(message) {
                #expect(message.contains("approval grant"))
            }
        }
    }

    @Test func staleRevisionRefusesAndMountedAssistantTakesPrecedence() async throws {
        try await withFixture { fixture, owner, _ in
            let (id, directory) = try await createBuilding(owner)
            let package = BuildingProjectSpaceOriginal.projectURL(directory: directory)
            let page = try await building(owner, id, action: "overview")
            let revision = try #require(page["revision"] as? String)
            let room = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                "operationsJSON": #"{"action":"createRoom","name":"Study"}"#], owner)
            #expect(room["result"] as? String == "roomCreated")

            // A stale revision cannot overwrite the saved original.
            do {
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                    "operationsJSON": #"{"action":"createRoom","name":"Duplicate"}"#], owner)
                Issue.record("A stale building edit replaced the saved original.")
            } catch PersonalContentError.changedDocument {}
            let fresh = try await building(owner, id, action: "overview")
            let current = try #require(fresh["revision"] as? String)

            // While the real project editor's assistant mount is active, the
            // closed binding stands down instead of preempting the editor.
            let editor = try await BuildingEditorProjectSession.open(at: package,
                assetLibraryDirectory: BuildingProjectSpaceOriginal.assetLibraryURL(directory: directory),
                spaceRecordID: id)
            let mount = try fixture.environment.studioCoordinator.buildingProjects.attach(
                editor.assistantContext(), directory: package, presenterID: UUID())
            do {
                _ = try await building(owner, id, action: "overview")
                Issue.record("The closed binding read over an active editor assistant.")
            } catch FloeError.unauthorized {}
            do {
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": current,
                    "operationsJSON": #"{"action":"createRoom","name":"Intrusion"}"#], owner)
                Issue.record("The closed binding edited over an active editor assistant.")
            } catch FloeError.unauthorized {}
            fixture.environment.studioCoordinator.buildingProjects.remove(mount)
            try await editor.close(discardWorkingCopy: true)

            // The closed binding works again once the editor assistant retires.
            let again = try await building(owner, id, action: "overview")
            #expect(again["revision"] as? String == current)
        }
    }

    @Test func cancelledEditLeavesThePublishedOriginalUnchanged() async throws {
        try await withFixture { _, owner, _ in
            let (id, directory) = try await createBuilding(owner)
            let page = try await building(owner, id, action: "overview")
            let revision = try #require(page["revision"] as? String)
            let beforeCancel = try manifestGeneration(directory)
            let generation = try #require(beforeCancel)
            var cancelled = owner
            let token = CancellationToken()
            token.cancel()
            cancelled.cancellation = token
            do {
                _ = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                    "operationsJSON": #"{"action":"createRoom","name":"Ghost"}"#], cancelled)
                Issue.record("A cancelled building edit reported success.")
            } catch FloeError.cancelled {}
            let after = try await building(owner, id, action: "overview")
            #expect(after["revision"] as? String == revision)
            #expect(try manifestGeneration(directory) == generation)
        }
    }

    @Test func saveAsBuildingPublishesAnIndependentSpaceCopy() async throws {
        try await withFixture { _, owner, _ in
            let (id, directory) = try await createBuilding(owner)
            let page = try await building(owner, id, action: "overview")
            let revision = try #require(page["revision"] as? String)
            let saved = try await invoke("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision,
                "operationsJSON": #"{"action":"saveAsBuilding","title":"Detached house"}"#], owner)
            #expect(saved["result"] as? String == "buildingCopySaved")
            let copies = try #require(saved["copies"] as? [[String: Any]])
            let copy = try #require(copies.first)
            let copyRaw = try #require(copy["id"] as? String)
            let copyID = try #require(UUID(uuidString: copyRaw))
            let copyHash = try #require(copy["contentSHA256"] as? String)
            // The original advanced to a fresh verified generation.
            let savedGeneration = try #require(saved["generationID"] as? String)
            #expect(try manifestGeneration(directory) == savedGeneration)
            // The independent copy is a real Space building work.
            let location = try await PersonalContentService.shared.library().resolve(copyID)
            #expect(location.record.kind == .building)
            let verified = try BuildingProjectRepository.verifyProjectDirectory(
                at: BuildingProjectSpaceOriginal.projectURL(directory: location.url))
            #expect(verified.contentDigest == copyHash)
        }
    }
}
#endif
