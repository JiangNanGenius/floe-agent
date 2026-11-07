// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkbench
import FloeSecurity
import FloeCAD
@testable import FloeAgentRuntime
@testable import FloeApp

/// The production registrar, real task-workspace CAD host, genuine Building
/// rebuild and native package store; no fake host, cube stand-in or playback.
@Suite("Registered native building contracts", .serialized)
@MainActor struct CADBuildingToolContractTests {
    private struct Fixture {
        let root: URL
        let url: URL
        let runner: AnyAgentTool
        let context: ToolContext
        let other: ToolContext
    }
    private func call(_ f: Fixture, _ args: [String: Any], context: ToolContext? = nil) async throws -> [String: Any] {
        let output = try await f.runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context ?? f.context)
        let text = output.capturedOutput ?? output.summary
        #expect(FloeDigest.sha256Hex(Data(text.utf8)) == output.fullOutputSHA256)
        let start = try #require(text.firstIndex(of: "{"))
        return try #require(JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any])
    }
    private func parameter(_ f: Fixture, _ payload: [String: Any], context: ToolContext? = nil,
                           path: String = "Building.floecad") async throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try await call(f, ["action": "parameters", "path": path, "payload": String(decoding: bytes, as: UTF8.self)], context: context)
    }
    private func inspect(_ f: Fixture) async throws -> [String: Any] {
        try await parameter(f, ["action": "building.inspect", "limit": 16])
    }
    private func pinned(_ fields: [String: Any], from source: [String: Any]) throws -> [String: Any] {
        var payload = fields
        payload["expected_revision"] = try #require(source["revision"] as? Int)
        payload["expected_change_count"] = try #require(source["change_count"] as? Int)
        payload["expected_source_sha256"] = try #require(source["content_sha256"] as? String)
        return payload
    }
    private func wall() -> [String: Any] {
        ["action": "building.addWall", "name": "Authored wall", "a": [0,0], "b": [4000,0], "thicknessMM": 200, "heightMM": 3000]
    }
    private func room(withWalls: Bool = true) -> [String: Any] {
        ["action": "building.addRoom", "name": "Authored room", "min": [5000,0], "max": [9000,3000],
         "wallThicknessMM": 200, "heightMM": 3000, "withWalls": withWalls]
    }
    private func elements(_ result: [String: Any]) throws -> [[String: Any]] {
        try #require(result["elements"] as? [[String: Any]])
    }
    private func withFixture(_ body: @MainActor (Fixture) async throws -> Void) async throws {
        _ = FloeAgentApp.liveEnvironment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("C45-building-\(UUID())", isDirectory: true)
        let owner = root.appendingPathComponent("owner", isDirectory: true), otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let registry = ToolRunnerRegistry()
        registerCadDocumentTools(center: CadDocumentCenter(nativeProposalStoreFileURL: root.appendingPathComponent("proposals.json")), registry: registry)
        let runner = try #require(registry.runner(named: "cad.document"))
        func context(_ directory: URL) -> ToolContext {
            var value = ToolContext(runID: UUID(), toolCallID: "authorized-native-building", scope: .local,
                allowedToolNames: ["cad.document"], workspaceRootURL: directory, cancellation: CancellationToken(), conversationID: UUID())
            value.frozenEffectiveCatalogNames = ["cad.document"]
            value.approvalGrantID = UUID() // Trusted host fixture grant, never a model-authored permission.
            return value
        }
        let f = Fixture(root: root, url: owner.appendingPathComponent("Building.floecad"), runner: runner,
                        context: context(owner), other: context(otherRoot))
        do {
            _ = try await call(f, ["action": "create", "path": "Building.floecad", "name": "Native contract building"])
            try await body(f)
        } catch {
            await FloeCAD3DBridge.shared.releaseDocument(at: f.url)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await FloeCAD3DBridge.shared.releaseDocument(at: f.url)
        try FileManager.default.removeItem(at: root)
    }
    @Test func architectureWallAndRoomDiscoveryExposeTheRealTypedService() async throws {
        try await withFixture { f in
            for query in ["architecture", "wall", "room", "建筑", "墙体", "房间"] {
                #expect(ToolDiscovery.matches(query: query, descriptors: [f.runner.descriptor]).map(\.name) == ["cad.document"])
            }
            let caps = try await call(f, ["action": "capabilities", "path": "Building.floecad"])
            #expect(Set(try #require(caps["parameter_actions"] as? [String])).isSuperset(of: CadNativeEditActions.building))
            #expect(Set(CADBuildingToolService.actions) == CadNativeEditActions.building)
            #expect(CADBuildingToolService.reads == CadNativeEditActions.buildingReads)
            let catalog = try await parameter(f, ["action": "building.catalog"])
            let fields = try #require(catalog["building"] as? [String: Any]), examples = try #require(fields["examples"] as? [String: Any])
            let wallExample = try #require(examples["wall"] as? [String: Any]), roomExample = try #require(examples["room"] as? [String: Any])
            let typedWall = try JSONDecoder().decode(CADBuildingWallInput.self, from: JSONSerialization.data(withJSONObject: wallExample))
            let typedRoom = try JSONDecoder().decode(CADBuildingRoomInput.self, from: JSONSerialization.data(withJSONObject: roomExample))
            #expect(typedWall.thicknessMM == 200 && typedRoom.withWalls && typedRoom.max == [9000,3000])
            let help = try #require(CadDocumentHelp.fullText(for: "building"))
            #expect(help.contains("expected_change_count") && help.contains("FOUR actual native walls") && help.contains("projectID"))
            var page = 0, assembled = ""
            for _ in 0..<16 {
                let selector = String(decoding: try JSONSerialization.data(withJSONObject: ["documentation": "building", "page": page, "page_size": 1000]), as: UTF8.self)
                let response = try await call(f, ["action": "capabilities", "payload": selector])
                let part = try #require(response["documentation"] as? [String: Any])
                assembled += try #require(part["text"] as? String)
                guard let next = part["next_page"] as? Int else { break }
                try #require(next > page); page = next
            }
            #expect(assembled == help)
            let schema = try #require(JSONSerialization.jsonObject(with: Data(CadDocumentTool.parametersJSON.utf8)) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(((properties["payload"] as? [String: Any])?["description"] as? String)?.contains("building.addRoom") == true)
            for action in CADBuildingToolService.reads {
                let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["action": action]), as: UTF8.self)
                #expect(OrdinaryDocumentActionProfile.role(forToolName: "cad.document", arguments: ["action": "parameters", "path": "Building.floecad", "payload": payload]) == .readOnly)
            }
        }
    }
    @Test func registeredWallAndRoomAreOneNativeModelAndSaveReopenWithUndo() async throws {
        try await withFixture { f in
            let empty = try await inspect(f)
            #expect(empty["hasBuilding"] as? Bool == false)
            let wallResult = try await parameter(f, pinned(wall(), from: empty))
            #expect(wallResult["saved"] as? Bool == true)
            let wallID = try #require((wallResult["createdBodyIDs"] as? [String])?.first)
            let afterWall = try await inspect(f)
            #expect(try elements(afterWall).count == 1)
            let result = try await parameter(f, pinned(room(), from: afterWall))
            #expect(result["saved"] as? Bool == true)
            #expect((result["createdBodyIDs"] as? [String])?.count == 4)
            let after = try await inspect(f), rows = try elements(after)
            #expect(rows.count == 6)
            let paged = try await parameter(f, ["action": "building.inspect", "limit": 2])
            #expect((paged["elements"] as? [[String: Any]])?.count == 2 && paged["nextElementOffset"] as? Int == 2)
            let space = try #require(rows.first { $0["kind"] as? String == "space" })
            #expect(space["authoredAreaM2"] as? Double == 12)
            #expect((space["bodyIDs"] as? [String])?.isEmpty == true)
            #expect(space["representation"] as? String == "semanticSpace")
            #expect(rows.filter { $0["kind"] as? String == "wall" }.allSatisfy { $0["representedBodyCount"] as? Int == 1 })
            let document = try await FloeCAD3DBridge.shared.openDocument(at: f.url)
            let building = try document.building()
            let native = try #require(building)
            #expect(native.elements.count == 6 && native.elements.first?.bodyID.uuidString == wallID)
            let state = try #require(JSONSerialization.jsonObject(with: document.snapshotJSON()) as? [String: Any])
            let bodies = try #require(state["bodies"] as? [[String: Any]])
            #expect(bodies.count == 5 && bodies.allSatisfy { $0["brep"] as? Bool == true })
            let firstWall = try #require(bodies.first { $0["id"] as? String == wallID })
            #expect(abs((firstWall["volumeMM3"] as? Double ?? 0) - 4000*200*3000) < 1)
            let undone = try await parameter(f, ["action": "undo", "expected_revision": try #require(after["revision"] as? Int)])
            #expect(undone["saved"] as? Bool == true)
            let afterUndo = try await inspect(f)
            #expect(try elements(afterUndo).count == 1)
            let redone = try await parameter(f, ["action": "redo", "expected_revision": try #require(afterUndo["revision"] as? Int)])
            #expect(redone["saved"] as? Bool == true)
            let committed = try await inspect(f)
            let revision = try #require(committed["revision"] as? Int), hash = try #require(committed["content_sha256"] as? String)
            await FloeCAD3DBridge.shared.releaseDocument(at: f.url, expected: document)
            let reopened = try await FloeCADDocument.open(at: f.url)
            #expect(reopened.revision == revision && reopened.contentSHA256 == hash)
            #expect(try reopened.building() == native)
            reopened.close()
            let stored = try await inspect(f)
            #expect(stored["revision"] as? Int == revision && stored["content_sha256"] as? String == hash)
            #expect(try elements(stored).map { $0["id"] as? String } == rows.map { $0["id"] as? String })
        }
    }
    @Test func invalidFieldsStaleGenerationAndAnotherWorkspaceCannotMutateTheOriginal() async throws {
        try await withFixture { f in
            let empty = try await inspect(f)
            _ = try await parameter(f, pinned(wall(), from: empty))
            let before = try await inspect(f), identity = try #require(await FloeCADDocument.storedIdentity(at: f.url))
            var invalid = try pinned(room(), from: before); invalid["colour"] = "blue"
            do { _ = try await parameter(f, invalid); Issue.record("An unknown building field was silently ignored") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("unknown_building_field") && message.contains("colour")) }
            catch { Issue.record("Unknown-field rejection failed for an unrelated reason: \(error)") }
            var wrongType = try pinned(room(), from: before); wrongType["withWalls"] = 1
            do { _ = try await parameter(f, wrongType); Issue.record("A numeric flag was accepted as a Building boolean") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("invalid_building_input") && message.contains("withWalls")) }
            catch { Issue.record("Typed input failed for an unrelated reason: \(error)") }
            var stale = try pinned(room(), from: before); stale["expected_change_count"] = empty["change_count"]
            do { _ = try await parameter(f, stale); Issue.record("A stale Building generation committed") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("stale_building")) }
            catch { Issue.record("Stale generation failed for an unrelated reason: \(error)") }
            do { _ = try await parameter(f, pinned(room(), from: before), context: f.other, path: f.url.path); Issue.record("Another task workspace changed the original") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("inside the task workspace")) }
            catch { Issue.record("Workspace isolation failed for an unrelated reason: \(error)") }
            let now = try #require(await FloeCADDocument.storedIdentity(at: f.url))
            #expect(identity.revision == now.revision && identity.contentSHA256 == now.contentSHA256)
            let result = try await inspect(f)
            #expect(try elements(result).count == 1)
            let metadata = try await parameter(f, pinned(room(withWalls: false), from: result))
            #expect(metadata["saved"] as? Bool == true && (metadata["createdBodyIDs"] as? [String])?.isEmpty == true)
            let native = try await FloeCAD3DBridge.shared.openDocument(at: f.url)
            let snapshot = try #require(JSONSerialization.jsonObject(with: native.snapshotJSON()) as? [String: Any])
            #expect((snapshot["bodies"] as? [[String: Any]])?.count == 1)
        }
    }
    #if DEBUG
    @Test func failedNativeSaveKeepsTheExistingWallAndReturnsTheActualCause() async throws {
        try await withFixture { f in
            let initial = try await inspect(f)
            _ = try await parameter(f, pinned(wall(), from: initial))
            let before = try await inspect(f)
            let document = try await FloeCAD3DBridge.shared.openDocument(at: f.url)
            let model = try document.building(), revision = document.revision, hash = document.contentSHA256
            document.saveFailureForTesting = "C45 original native save failure"
            do { _ = try await parameter(f, pinned(room(), from: before)); Issue.record("A failed Building save was reported as complete") }
            catch let FloeError.validationFailed(message) { #expect(message.contains("C45 original native save failure")) }
            catch { Issue.record("Native save failed for an unrelated reason: \(error)") }
            #expect(document.revision == revision && document.contentSHA256 == hash)
            #expect(try document.building() == model)
            let after = try await inspect(f)
            #expect(try elements(after).count == 1)
            document.saveFailureForTesting = nil
        }
    }
    #endif
}
#endif
