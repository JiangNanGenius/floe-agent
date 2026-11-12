// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeCAD
@testable import FloeApp

@Suite("Managed native CAD rename and save", .serialized)
@MainActor struct StudioCADRenameSaveContractTests {
    private let registry = ToolRunnerRegistry()
    private struct Page { let revision: String; let state: [String: Any]; let guide: String }
    private func call(_ name: String, _ args: [String: Any], _ context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(registry.runner(named: name))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func read(_ id: UUID, _ context: ToolContext, cad: [String: Any]? = nil) async throws -> Page {
        var offset = 0, text = "", revision: String?, contentHash: String?, guide = ""
        for _ in 0..<256 {
            var arguments: [String: Any] = ["projectID": id.uuidString, "offset": offset, "limit": 1024]
            if let cad { arguments["cad"] = cad }
            let page = try await call("studio.read", arguments, context)
            let current = try #require(page["revision"] as? String)
            if let revision { try #require(revision == current) } else { revision = current }
            let currentHash = try #require(page["contentSHA256"] as? String)
            if let contentHash { try #require(contentHash == currentHash) } else { contentHash = currentHash }
            text += try #require(page["contentJSON"] as? String); guide = try #require(page["editFormat"] as? String)
            guard let next = page["nextOffset"] as? Int else {
                try #require(StudioToolOutput.hash(Data(text.utf8)) == currentHash)
                return Page(revision: current, state: try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]), guide: guide)
            }
            try #require(next > offset); offset = next
        }
        throw PersonalContentError.changedDocument
    }
    private func edit(_ id: UUID, revision: String, command: String, context: ToolContext) async throws {
        _ = try await call("studio.edit", ["projectID": id.uuidString, "expectedRevision": revision, "operationsJSON": command], context)
    }
    private func withTasks(_ body: @MainActor (ToolContext, ToolContext) async throws -> Void) async throws {
        let environment = FloeAgentApp.liveEnvironment; try await environment.ensureDurableAutomationReady()
        registerStudioAgentTools(environment: environment, registry: registry)
        var ids: [UUID] = [], contexts: [ToolContext] = []
        do {
            for _ in 0..<2 {
                let id = UUID(), runID = UUID(), now = Date(); ids.append(id)
                try await environment.conversationStore.saveConversation(.init(id: id, title: "CAD rename contract", createdAt: now, updatedAt: now))
                _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: id, title: "CAD rename contract")
                try await environment.conversationStore.setArchived(id: id, archived: true)
                try await environment.runStore.saveRun(.init(id: runID, conversationID: id, state: "executing", goal: "CAD rename contract", startedAt: now))
                var context = ToolContext(runID: runID, toolCallID: "create-native-work", allowedToolNames: StudioCoordinator.names,
                    cancellation: CancellationToken(), conversationID: id)
                context.frozenEffectiveCatalogNames = StudioCoordinator.names; context.approvalGrantID = UUID(); contexts.append(context)
            }
            try await body(contexts[0], contexts[1])
        } catch { for id in ids { try? await environment.conversationStore.deleteConversation(id: id) }; throw error }
        for id in ids { try await environment.conversationStore.deleteConversation(id: id) }
    }
    private func create(_ kind: String, _ context: ToolContext) async throws -> (UUID, URL, FloeCADDocument) {
        let result = try await call("studio.create", ["kind": kind, "title": "Contract CAD \(UUID().uuidString.prefix(8))"], context)
        let record = try #require(result["record"] as? [String: Any])
        let rawID = try #require(record["id"] as? String)
        let id = try #require(UUID(uuidString: rawID))
        let location = try await PersonalContentService.shared.library().resolve(id)
        return (id, location.url, try await PersonalCADSessions.open(id: id, directory: location.url))
    }
    @discardableResult private func sketch(_ document: FloeCADDocument, name: String, min: [Double], max: [Double], height: Double? = nil) throws -> UUID {
        let created = document.execute(["op": "sketch.create", "args": ["name": name]])
        try #require(created.isOK)
        let object = try #require(JSONSerialization.jsonObject(with: created.payload) as? [String: Any])
        let raw = try #require(object["sketchID"] as? String), id = try #require(UUID(uuidString: raw))
        try #require(document.execute(["op": "sketch.addEntities", "args": ["sketchID": raw, "entities": [["kind": "rect", "min": min, "max": max]]]]).isOK)
        if let height {
            try #require(document.execute(["op": "feature.extrude", "args": ["sketchID": raw,
                "seedPoint": [(min[0]+max[0])/2, (min[1]+max[1])/2], "distance": height]]).isOK)
        }
        return id
    }
    private func rows(_ page: Page, sketches: Bool = false) throws -> [[String: Any]] {
        if sketches { return try #require((page.state["nativeCAD"] as? [String: Any])?["sketches"] as? [[String: Any]]) }
        return try #require(page.state["bodies"] as? [[String: Any]])
    }
    private func unchangedGeometry(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) throws {
        func data(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: rows.map { row in var value = row; value.removeValue(forKey: "name"); return value }, options: [.sortedKeys])
        }
        #expect(try data(lhs) == data(rhs))
    }
    private func actualTriangles(_ document: FloeCADDocument) throws -> Data {
        switch document.nativePrintGeometrySnapshot(expectedRevision: document.revision,
            expectedChangeCount: document.exchangeChangeCount, expectedContentSHA256: document.contentSHA256) {
        case .success(let data, _, _): return data
        default: throw PersonalContentError.invalidProject
        }
    }
    @Test func nativeBodyRenameSavesSameWorkKeepsGeometryAndUsesTheExistingUndoStack() async throws {
        try await withTasks { context, other in
            let (id, directory, document) = try await create("cad3D", context)
            try sketch(document, name: "Exact part", min: [0,0], max: [2,2], height: 2)
            try sketch(document, name: "Other part", min: [4,0], max: [6,2], height: 2)
            try #require((await document.save()).succeeded)
            let triangles = try actualTriangles(document)
            let before = try await read(id, context), bodies = try rows(before)
            try #require(bodies.count == 2)
            let target = try #require(bodies.first(where: { $0["brep"] as? Bool == true })), raw = try #require(target["id"] as? String)
            let example = try #require(before.guide.components(separatedBy: "ACTUAL item ID:\n").last?.components(separatedBy: "\nSave example").first)
            var command = try JSONDecoder().decode(StudioCADRenameCommand.self, from: Data(example.utf8))
            #expect(command.args.id.uuidString == raw)
            command = .init(op: .body, args: .init(id: command.args.id, name: "Renamed exact part"))
            let rename = try StudioTypedEditExamples.encode(command)
            try await edit(id, revision: before.revision, command: rename, context: context)
            let renamed = try await read(id, context), renamedRows = try rows(renamed)
            #expect(renamedRows.first(where: { $0["id"] as? String == raw })?["name"] as? String == "Renamed exact part")
            for body in bodies where body["id"] as? String != raw {
                #expect(renamedRows.first(where: { $0["id"] as? String == body["id"] as? String })?["name"] as? String == body["name"] as? String)
            }
            try unchangedGeometry(bodies, renamedRows)
            #expect(try actualTriangles(document) == triangles)
            #expect((renamed.state["nativeCAD"] as? [String: Any])?["hasUnsavedChanges"] as? Bool == false)
            #expect(renamed.state["undoTitle"] as? String == "Rename")
            let nativeURL = document.url
            do { try await edit(id, revision: before.revision, command: rename, context: context); Issue.record("A stale native rename committed") }
            catch PersonalContentError.changedDocument {}
            catch { Issue.record("Stale CAS failed for an unrelated reason: \(error)") }
            do { try await edit(id, revision: renamed.revision, command: rename, context: other); Issue.record("Another task renamed an unbound native work") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("Open this work")) }
            catch { Issue.record("Task isolation failed for an unrelated reason: \(error)") }
            let afterDenials = try await read(id, context)
            #expect(afterDenials.revision == renamed.revision)
            let undo = CADViewOverlayService(document: document).handle(action: "undo", args: ["expected_change_count": document.exchangeChangeCount])
            #expect(undo["ok"] as? Bool == true)
            let undone = try await read(id, context)
            #expect(try rows(undone).first(where: { $0["id"] as? String == raw })?["name"] as? String == target["name"] as? String)
            let redo = CADViewOverlayService(document: document).handle(action: "redo", args: ["expected_change_count": document.exchangeChangeCount])
            #expect(redo["ok"] as? Bool == true)
            let latest = try await read(id, context)
            try await edit(id, revision: latest.revision, command: StudioTypedEditExamples.encode(StudioCADSaveCommand()), context: context)
            document.close()
            let reopened = try await PersonalCADSessions.open(id: id, directory: directory)
            #expect(reopened.url == nativeURL)
            let saved = try await read(id, context)
            #expect(try rows(saved).first(where: { $0["id"] as? String == raw })?["name"] as? String == "Renamed exact part")
            try unchangedGeometry(bodies, rows(saved))
            #expect(try actualTriangles(reopened) == triangles)
            let record = try await PersonalContentService.shared.library().resolve(id)
            #expect(record.record.id == id && record.url == directory)
            reopened.close()
        }
    }
    @Test func native2DSketchReadRenameAndSaveReopensTheActualRectangle() async throws {
        try await withTasks { context, _ in
            let (id, directory, document) = try await create("cad2D", context)
            let sketchID = try sketch(document, name: "2D rectangle", min: [0,0], max: [3.5,3])
            try #require((await document.save()).succeeded)
            let query: [String: Any] = ["sketchID": sketchID.uuidString]
            let before = try await read(id, context, cad: query), initial = try rows(before, sketches: true)
            let authored = try #require(initial.first { $0["id"] as? String == sketchID.uuidString })
            #expect(authored["entityTotal"] as? Int == 1)
            let initialEntities = try #require((before.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            let entity = try #require((initialEntities["rows"] as? [[String: Any]])?.first)
            #expect(entity["widthMM"] as? Double == 3.5 && entity["heightMM"] as? Double == 3)
            #expect(before.guide.contains("CURRENT managed Space 2D sketch") && before.guide.contains("Do not guess"))
            let rename = try StudioTypedEditExamples.encode(StudioCADRenameCommand(op: .sketch, args: .init(id: sketchID, name: "Renamed drawing")))
            try await edit(id, revision: before.revision, command: rename, context: context)
            let after = try await read(id, context, cad: query)
            try unchangedGeometry(initial, rows(after, sketches: true))
            let afterEntities = try #require((after.state["nativeCAD"] as? [String: Any])?["entities"] as? [String: Any])
            try unchangedGeometry((initialEntities["rows"] as? [[String: Any]]) ?? [],
                                  (afterEntities["rows"] as? [[String: Any]]) ?? [])
            #expect(try rows(after, sketches: true).first(where: { $0["id"] as? String == sketchID.uuidString })?["name"] as? String == "Renamed drawing")
            let savedChangeCount = document.exchangeChangeCount
            try await edit(id, revision: after.revision, command: StudioTypedEditExamples.encode(StudioCADSaveCommand()), context: context)
            #expect(document.exchangeChangeCount == savedChangeCount)
            document.close(); let reopened = try await PersonalCADSessions.open(id: id, directory: directory)
            let stored = try await read(id, context, cad: query)
            #expect(try rows(stored, sketches: true).first(where: { $0["id"] as? String == sketchID.uuidString })?["name"] as? String == "Renamed drawing")
            try unchangedGeometry(initial, rows(stored, sketches: true)); reopened.close()
        }
    }
    @Test func managedWrapperRefusesTheFileRouteWithTheCurrentOriginalRoute() async throws {
        try await FloeAgentApp.liveEnvironment.ensureDurableAutomationReady()
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "cad.document"))
        #expect(runner.descriptor.toolDescription.contains("studio.read/studio.edit"))
        do { try runner.validateArguments(Data(#"{"action":"read","path":"QA-existing.floeproject"}"#.utf8)); Issue.record("A managed work wrapper was accepted as a CAD file") }
        catch let FloeError.validationFailed(message) {
            #expect(message.contains("studio.read/studio.edit") && message.contains("projectID") && message.contains("Do not create a replacement"))
        }
        catch { Issue.record("Wrong CAD route failed for an unrelated reason: \(error)") }
    }
    #if DEBUG
    @Test func failedSaveRollsBackOnlyItsOwnedRenameAndDoesNotEraseANewerUIEdit() async throws {
        try await withTasks { context, _ in
            let (id, _, document) = try await create("cad3D", context)
            try sketch(document, name: "Target", min: [0,0], max: [2,2], height: 2)
            try sketch(document, name: "Other", min: [4,0], max: [6,2], height: 2)
            try #require((await document.save()).succeeded)
            let before = try await read(id, context), original = try rows(before)
            let rawA = try #require(original[0]["id"] as? String)
            let rawB = try #require(original[1]["id"] as? String)
            let a = try #require(UUID(uuidString: rawA))
            let b = try #require(UUID(uuidString: rawB))
            let rename = try StudioTypedEditExamples.encode(StudioCADRenameCommand(op: .body, args: .init(id: a, name: "Assistant rename")))
            let savedRevision = document.revision, savedSHA = document.contentSHA256
            document.saveFailureForTesting = "C42 original save failure"
            do { try await edit(id, revision: before.revision, command: rename, context: context); Issue.record("An injected native save failure was reported as saved") }
            catch { #expect(error.localizedDescription.contains("C42 original save failure")) }
            #expect(document.revision == savedRevision && document.contentSHA256 == savedSHA)
            let rolledBack = try await read(id, context)
            #expect(try rows(rolledBack).map { $0["name"] as? String } == original.map { $0["name"] as? String })
            let current = try await read(id, context)
            document.saveFailureForTesting = "C42 later UI save failure"
            document.saveSuspensionForTesting = {
                let ui = document.renameExistingItem(kind: .body, id: b, name: "Newer UI name", expectedChangeCount: document.exchangeChangeCount)
                #expect(ui.isOK)
            }
            do { try await edit(id, revision: current.revision, command: rename, context: context); Issue.record("A competing failed save was reported as successful") }
            catch { #expect(error.localizedDescription.contains("C42 later UI save failure")) }
            let live = try await read(id, context)
            #expect(try rows(live).first(where: { $0["id"] as? String == b.uuidString })?["name"] as? String == "Newer UI name")
            try unchangedGeometry(original, rows(live))
            document.saveSuspensionForTesting = nil; document.saveFailureForTesting = nil
            document.close()
        }
    }
    #endif
}
#endif
