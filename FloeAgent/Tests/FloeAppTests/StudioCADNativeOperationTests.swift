// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeCAD
@testable import FloeApp

@Suite("Managed CAD native Building and Mesh services", .serialized)
@MainActor struct StudioCADNativeOperationTests {
    private struct Page { let revision: String; let state: [String: Any] }
    private func call(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func read(_ id: UUID, _ context: ToolContext) async throws -> Page {
        var text = "", offset = 0, revision: String?
        for _ in 0..<128 {
            let page = try await call("studio.read", ["projectID": id.uuidString, "offset": offset, "limit": 12_000], context)
            let current = try #require(page["revision"] as? String)
            if let revision { try #require(current == revision) } else { revision = current }
            text += try #require(page["contentJSON"] as? String)
            guard let next = page["nextOffset"] as? Int else {
                return Page(revision: current, state: try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]))
            }
            try #require(next > offset); offset = next
        }
        throw PersonalContentError.changedDocument
    }
    private func edit(_ id: UUID, _ page: Page, _ op: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["op": op, "args": args]), as: UTF8.self)
        return try await call("studio.edit", ["projectID": id.uuidString, "expectedRevision": page.revision, "operationsJSON": text], context)
    }
    private func refuses(_ text: String, _ body: () async throws -> Void) async {
        do { try await body(); Issue.record("A refused native CAD request succeeded") }
        catch let FloeError.validationFailed(message) { #expect(message.contains(text)) }
        catch { Issue.record("Native CAD refusal failed for an unrelated reason: \(error)") }
    }
    private func building(_ page: Page) throws -> [String: Any] {
        let native = try #require(page.state["nativeCAD"] as? [String: Any])
        let services = try #require(native["nativeServices"] as? [String: Any])
        return try #require(services["building"] as? [String: Any])
    }
    private func room(_ page: Page, name: String = "Authored room") throws -> [String: Any] {
        let state = try building(page)
        return ["name": name, "min": [0,0], "max": [4000,3000], "heightMM": 3000,
            "wallThicknessMM": 200, "withWalls": true,
            "expected_revision": try #require(state["revision"]), "expected_change_count": try #require(state["change_count"]),
            "expected_source_sha256": try #require(state["content_sha256"])]
    }
    private func withWork(_ body: @MainActor (UUID, URL, FloeCADDocument, ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        var conversations: [UUID] = [], contexts: [ToolContext] = []
        var ownedDirectory: URL?, document: FloeCADDocument?
        func cleanupFiles() { document?.close(); if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) } }
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); conversations.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "Native CAD service contract", createdAt: now, updatedAt: now))
                _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "Native CAD service contract")
                try await environment.conversationStore.setArchived(id: id, archived: true)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "Native CAD service contract", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "native-cad-services", allowedToolNames: StudioCoordinator.names,
                    cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names; context.approvalGrantID = UUID(); contexts.append(context)
            }
            let created = try await call("studio.create", ["kind": "cad3D", "title": "Native service fixture \(UUID())"], contexts[0])
            let record = try #require(created["record"] as? [String: Any])
            let id = try #require((record["id"] as? String).flatMap(UUID.init(uuidString:)))
            let resolved = try await PersonalContentService.shared.library().resolve(id)
            ownedDirectory = resolved.url
            let value = try await PersonalCADSessions.open(id: id, directory: resolved.url); document = value
            try await body(id, resolved.url, value, contexts[0], contexts[1])
        } catch {
            cleanupFiles(); for id in conversations { try? await environment.conversationStore.deleteConversation(id: id) }; throw error
        }
        cleanupFiles(); for id in conversations { try await environment.conversationStore.deleteConversation(id: id) }
    }
    @Test func registeredBuildingRoomAndMeshMaterialTransformSaveTheSameOriginalWithReceipts() async throws {
        try await withWork { id, directory, document, context, _ in
            let first = try await read(id, context)
            #expect(try building(first)["hasBuilding"] as? Bool == false)
            let native = try #require(first.state["nativeCAD"] as? [String: Any])
            let operations = try #require(native["nativeOperations"] as? [String])
            #expect(operations.contains("building.addRoom") && operations.contains("mesh.material") && !operations.contains("mesh.text"))
            let result = try await edit(id, first, "building.addRoom", room(first), context)
            let receipt = try #require(result["operationResult"] as? [String: Any])
            #expect(receipt["saved"] as? Bool == true && receipt["operation"] as? String == "building.addRoom")
            #expect((receipt["createdElementIDs"] as? [String])?.count == 5)
            let built = try await read(id, context), state = try building(built)
            #expect(state["elementCount"] as? Int == 5 && state["complete"] as? Bool == true)
            let bodies = try #require(built.state["bodies"] as? [[String: Any]])
            let body = try #require(bodies.first), raw = try #require(body["id"] as? String)
            let bounds = try #require(body["bounds"] as? [[Double]])
            let material = try await edit(id, built, "mesh.material", ["bodyID": raw, "color": [0.1,0.2,0.8], "roughness": 0.4], context)
            let materialReceipt = try #require(material["operationResult"] as? [String: Any])
            #expect(materialReceipt["saved"] as? Bool == true && materialReceipt["exactness"] as? String == "preserved")
            let colored = try await read(id, context)
            let moved = try await edit(id, colored, "mesh.transform", ["bodyID": raw, "translate": [20,0,0]], context)
            #expect((moved["operationResult"] as? [String: Any])?["saved"] as? Bool == true)
            let after = try await read(id, context)
            let updated = try #require((after.state["bodies"] as? [[String: Any]])?.first(where: { $0["id"] as? String == raw }))
            let movedBounds = try #require(updated["bounds"] as? [[Double]])
            #expect(abs(movedBounds[0][0] - bounds[0][0] - 20) < 1e-8)
            #expect(updated["brep"] as? Bool == body["brep"] as? Bool)
            let savedURL = document.url; document.close()
            let reopened = try await PersonalCADSessions.open(id: id, directory: directory)
            defer { reopened.close() }
            #expect(reopened.url == savedURL)
            let saved = try await read(id, context)
            #expect(try building(saved)["elementCount"] as? Int == 5)
            let actual = try #require(reopened.session.document.bodies.first(where: { $0.id.raw.uuidString == raw }))
            #expect(actual.material?.baseColor.z == 0.8)
            reopened.close()
        }
    }
    @Test func staleForeignUnknownAndUnexpectedFieldRequestsDoNotAlterTheOriginal() async throws {
        try await withWork { id, _, document, context, foreign in
            let first = try await read(id, context)
            _ = try await edit(id, first, "building.addRoom", room(first), context)
            let fresh = try await read(id, context), bytes = document.contentSHA256, count = document.exchangeChangeCount
            do { _ = try await edit(id, first, "building.addRoom", room(first), context);Issue.record("A stale native edit succeeded") }
            catch PersonalContentError.changedDocument { }
            catch { Issue.record("Native CAD CAS failed for an unrelated reason: \(error)") }
            await refuses("Open this work") { _ = try await edit(id, fresh, "building.addRoom", room(fresh), foreign) }
            await refuses("nativeCAD.nativeOperations") { _ = try await edit(id, fresh, "mesh.arbitrary", [:], context) }
            let body = try #require((fresh.state["bodies"] as? [[String: Any]])?.first?["id"] as? String)
            await refuses("Unsupported native CAD fields") { _ = try await edit(id, fresh, "mesh.material", ["bodyID": body, "color": [0,0,1], "path": "/untrusted"], context) }
            await refuses("nativeCAD.nativeOperations") { _ = try await edit(id, fresh, "building.inspect", [:], context) }
            #expect(document.exchangeChangeCount == count && document.contentSHA256 == bytes)
            let repeatedRead = try await read(id, context)
            #expect(repeatedRead.revision == fresh.revision && document.exchangeChangeCount == count)
        }
    }
    #if DEBUG
    @Test func failedServiceSaveRestoresOnlyItsCheckpointAndNeverErasesANewerUICommand() async throws {
        try await withWork { id, _, document, context, _ in
            let first = try await read(id, context)
            _ = try await edit(id, first, "building.addRoom", room(first), context)
            let original = try await read(id, context), priorSHA = document.contentSHA256
            let body = try #require((original.state["bodies"] as? [[String: Any]])?.first?["id"] as? String)
            let bodyID = try #require(UUID(uuidString: body)), before = try #require(document.session.document.bodies.first(where: { $0.id.raw == bodyID }))
            document.saveFailureForTesting = "Native service save fixture"
            defer { document.saveFailureForTesting = nil; document.saveSuspensionForTesting = nil }
            await refuses("Native service save fixture") { _ = try await edit(id, original, "mesh.material", ["bodyID": body, "color": [1,0,0]], context) }
            #expect(document.contentSHA256 == priorSHA)
            #expect(document.session.document.bodies.first(where: { $0.id.raw == bodyID })?.material == before.material)
            #expect(document.saveFailureForTesting == nil, "The native save-failure fixture is consumed after one save.")
            let next = try await read(id, context)
            document.saveSuspensionForTesting = {
                #expect(document.renameExistingItem(kind: .body, id: bodyID, name: "Newer native UI name", expectedChangeCount: document.exchangeChangeCount).isOK)
            }
            // This is a second failed save; rearm the same one-shot native fixture.
            document.saveFailureForTesting = "Native service save fixture"
            await refuses("Native service save fixture") { _ = try await edit(id, next, "mesh.material", ["bodyID": body, "color": [0,0,1]], context) }
            #expect(document.session.document.bodies.first(where: { $0.id.raw == bodyID })?.name == "Newer native UI name")
            #expect(document.contentSHA256 == priorSHA)
        }
    }
    #endif
    @Test func cancellationAfterTheRealServiceAndBeforeSaveDoesNotPublishASavedEdit() async throws {
        try await withWork { id, _, document, context, _ in
            let first = try await read(id, context), before = document.contentSHA256
            let args = try room(first), command = try JSONSerialization.data(withJSONObject: ["op": "building.addRoom", "args": args])
            let identity = try StudioCADToolContract.Identity(snapshot: JSONSerialization.data(withJSONObject: first.state))
            var checks = 0
            await #expect(throws: (any Error).self) {
                _ = try await StudioCADToolContract.applyAndSave(command, to: document, expected: identity, context: context) {
                    checks += 1
                    if checks == 2 { context.cancellation.cancel() }
                }
            }
            #expect(checks == 2 && document.contentSHA256 == before)
            #expect(try document.building() == nil)
        }
    }
}
#endif
