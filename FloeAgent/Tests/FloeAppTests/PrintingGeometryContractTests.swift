// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeTools
import FloePrintCore
import FloePersistence
@testable import FloeApp

@Suite("Printing dimensions through actual native tools", .serialized)
@MainActor struct PrintingGeometryContractTests {
    private func invoke(_ name: String, _ arguments: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: arguments), context: context)
        return try #require(JSONSerialization.jsonObject(with: Data((output.capturedOutput ?? output.summary).utf8)) as? [String: Any])
    }
    private func read(_ id: UUID, _ context: ToolContext) async throws -> (revision: String, state: [String: Any]) {
        var offset = 0, content = "", revision: String?
        repeat {
            let page = try await invoke("studio.read", ["projectID": id.uuidString, "offset": offset, "limit": 1000], context)
            let current = try #require(page["revision"] as? String)
            if let revision { #expect(revision == current) } else { revision = current }
            content += try #require(page["contentJSON"] as? String)
            guard let next = page["nextOffset"] as? Int else { break }
            offset = next
        } while true
        let result = try #require(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        return (try #require(revision), result)
    }
    private func measured(_ state: [String: Any]) throws -> [PrintObjectGeometryInspection] {
        let geometry = try #require(state["geometry"] as? [String: Any])
        #expect(geometry["complete"] as? Bool == true)
        #expect(geometry["units"] as? String == "mm")
        let rows = try #require(geometry["objects"])
        return try JSONDecoder().decode([PrintObjectGeometryInspection].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    @Test func aTenMillimetreCubeAndItsScaleLeaveTheOriginalTwentyMillimetresUntouched() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let projectID = UUID(), library = try await PersonalContentService.shared.library()
        let record = try await library.create(kind: .printing, title: "Contract print dimensions \(UUID().uuidString.prefix(8))", id: projectID) { directory, id in
            try await PrintProjectDisk(root: directory.appendingPathComponent("Printing")).create(PrintProjectDocument(projectID: id))
        }
        let location = try await library.resolve(projectID)
        let session = try await PrintProjectSession.open(id: projectID, directory: location.url.appendingPathComponent("Printing"))
        await session.addCube()
        #expect(session.objects.count == 1)
        let conversationID = try await environment.studioCoordinator.assistant(for: record), runID = UUID()
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "executing", goal: "Keep the original 20 mm cube and add a new 10 mm cube", startedAt: Date()))
        var context = ToolContext(runID: runID, toolCallID: "read-original-dimensions", allowedToolNames: StudioCoordinator.names,
            cancellation: CancellationToken(), conversationID: conversationID)
        context.frozenEffectiveCatalogNames = StudioCoordinator.names
        context.approvalGrantID = UUID() // Host-supplied test grant, never model-authored authority.
        do {
            let before = try await read(projectID, context), original = try #require(measured(before.state).first)
            #expect(original.sizeMM == [20, 20, 20] && original.triangleCount == 12)
            context.toolCallID = "add-exact-ten-millimetre-cube"
            _ = try await invoke("studio.edit", ["projectID": projectID.uuidString, "expectedRevision": before.revision,
                "operationsJSON": #"[{"action":"addCube","name":"New 10 mm cube","sizeMM":10}]"#], context)
            let added = try await read(projectID, context), objects = try measured(added.state)
            let second = try #require(objects.first { $0.objectID != original.objectID })
            #expect(objects.count == 2 && second.sizeMM == [10, 10, 10])
            #expect(objects.first { $0.objectID == original.objectID }?.meshSHA256 == original.meshSHA256)
            #expect(second.meshSHA256 != original.meshSHA256)
            context.toolCallID = "scale-only-the-new-object"
            let edit = "[{\"action\":\"transform\",\"objectID\":\"\(second.objectID.uuidString)\",\"scale\":0.5}]"
            _ = try await invoke("studio.edit", ["projectID": projectID.uuidString, "expectedRevision": added.revision, "operationsJSON": edit], context)
            let scaled = try await read(projectID, context), actual = try measured(scaled.state)
            #expect(actual.first { $0.objectID == second.objectID }?.sizeMM == [5, 5, 5])
            #expect(actual.first { $0.objectID == original.objectID }?.meshSHA256 == original.meshSHA256)
            #expect(actual.first { $0.objectID == original.objectID }?.sizeMM == [20, 20, 20])
            #expect(scaled.state["resultIsCurrent"] as? Bool == false)
            let bytes = try Data(contentsOf: location.url.appendingPathComponent("Printing/print.json"))
            context.toolCallID = "reject-invalid-new-cube-size"
            do {
                _ = try await invoke("studio.edit", ["projectID": projectID.uuidString, "expectedRevision": scaled.revision,
                    "operationsJSON": #"[{"action":"addCube","sizeMM":0}]"#], context)
                Issue.record("Invalid cube size was silently accepted")
            } catch PrintError.invalidSetting {}
            #expect(try Data(contentsOf: location.url.appendingPathComponent("Printing/print.json")) == bytes)
            let saved = try await session.disk.load()
            let old = try #require(saved.objects?.first { $0.id == original.objectID })
            #expect(try await session.disk.meshAsset(old.meshAsset).sha256 == original.meshSHA256)
            try await environment.conversationStore.deleteConversation(id: conversationID)
        } catch {
            try? await environment.conversationStore.deleteConversation(id: conversationID)
            throw error
        }
    }
}
#endif
