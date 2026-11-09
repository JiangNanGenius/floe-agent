// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime
import FloeElectronicsCore
@testable import FloeApp

/// Isolated catalog around the real native host. It deliberately does not
/// replace the App's global runner registry or create personal-library rows.
private nonisolated struct BackAnnotationNativeHostTool: AgentTool {
    struct Arguments: Decodable, Sendable { let projectID: UUID; let action: String; let inputJSON: String? }
    static let name = "studio.run"
    static let toolDescription = "Exercise the real source-bound electronics host."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string"},"action":{"type":"string"},"inputJSON":{"type":"string"}},"required":["projectID","action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    let record: PersonalContentRecord
    let directory: URL
    func validate(_ args: Arguments) throws {
        guard args.projectID == record.id, args.action == "eda.backAnnotation" else { throw FloeError.validationFailed("Wrong original") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await StudioElectronicsRuntime.run(record: record, directory: directory, action: args.action,
            inputJSON: args.inputJSON, context: context) {
                let current = try ElectronicsSavedSnapshot(id: record.id, directory: directory)
                guard current.project.id == record.id else { throw PersonalContentError.changedDocument }
            }
    }
}

@Suite("Electronics back annotation App contracts", .serialized)
@MainActor struct ElectronicsBackAnnotationAppTests {
    private func text(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func fixture() throws -> EDAProject {
        var p = EDAProject(title: "Owned back annotation fixture")
        p.revision = 7
        let symbol = EDASymbolDefinition(name: "One pin", pins: [.init(number: "1", position: .zero)])
        let footprint = EDAFootprintDefinition(name: "One pad", pads: [.init(number: "1", position: .zero)])
        p.symbols = [symbol]; p.footprints = [footprint]
        for index in 0..<52 {
            let component = EDAComponent(symbolID: symbol.id, footprintID: footprint.id, reference: "R\(index + 1)", value: "old", fields: ["owned": "preserve"])
            p.components.append(component)
            p.sheets[0].symbols.append(.init(componentID: component.id, position: .init(Double(index), 0)))
            p.boards[0].footprints.append(.init(definitionID: footprint.id, componentID: component.id,
                reference: "R\(index + 1000)", value: "new", position: .init(Double(index), 10)))
        }
        try EDAValidation.validate(p)
        return p
    }
    @Test func pagedPreviewSurvivesCatalogAndSourceBoundApplySavesTheSameNativeOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackAnnotation-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let original = try fixture()
        let store = try await EDAProjectStore.create(root: root.appendingPathComponent("Electronics"), project: original)
        let record = PersonalContentRecord(id: original.id, kind: .electronics, title: original.title,
            createdAt: original.createdAt, modifiedAt: original.modifiedAt, folders: [], relativePath: root.lastPathComponent)
        let registry = ToolRunnerRegistry(); registry.register(BackAnnotationNativeHostTool(record: record, directory: root))
        let executor = CatalogToolExecutor(runners: registry)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: UUID())
        func invoke(_ input: [String: Any]) async throws -> ToolResult {
            let callID = UUID().uuidString
            let raw = try JSONSerialization.data(withJSONObject: ["projectID": original.id.uuidString, "action": "eda.backAnnotation", "inputJSON": text(input)])
            let call = try ToolCall(id: callID, toolName: "studio.run", argumentsJSON: raw, scope: .local)
            var bound = context; bound.executionToolName = call.toolName; bound.toolCallID = callID
            return try await executor.execute(call, context: bound)
        }
        do {
            let before = try await store.load()
            let preview = try await invoke(["expectedRevision": "7", "limit": 50])
            #expect(preview.status == .ok)
            #expect(preview.outputSummary.utf8.count > 4_096)
            let receipt = try object(preview.outputSummary)
            let page = try object(try #require(receipt["resultJSON"] as? String))
            #expect(page["canApply"] as? Bool == true && page["totalChanges"] as? Int == 52)
            #expect((page["changes"] as? [[String: Any]])?.count == 50 && page["nextOffset"] as? Int == 50)
            let replay = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(preview))
            #expect(replay.outputSummary == preview.outputSummary)
            #expect(try await store.load() == before)
            #expect(try ElectronicsProjectSession.existing(id: original.id, directory: root) == nil)
            let tail = try await invoke(["expectedRevision": "7", "offset": 50, "limit": 50])
            let tailReceipt = try object(tail.outputSummary)
            let tailPage = try object(try #require(tailReceipt["resultJSON"] as? String))
            #expect((tailPage["changes"] as? [[String: Any]])?.count == 2 && tailPage["nextOffset"] == nil)
            for invalid: [String: Any] in [["preview": false], ["preview": false, "previewSourceSHA256": String(repeating: "0", count: 64)], ["preview": 0], ["limit": -1]] {
                var input = invalid; input["expectedRevision"] = "7"
                #expect(try await invoke(input).status == .failed)
                #expect(try await store.load() == before)
            }
            let applied = try await invoke(["expectedRevision": "7", "preview": false, "previewSourceSHA256": before.digest])
            #expect(applied.status == .ok)
            let saved = try await store.load()
            #expect(saved.project.revision == 8 && saved.project.components.map(\.reference) == original.boards[0].footprints.map(\.reference))
            #expect(saved.project.boards == original.boards && saved.project.sheets == original.sheets)
            #expect(saved.project.components.allSatisfy { $0.value == "new" && $0.fields == ["owned": "preserve"] })
            let native = try await ElectronicsProjectSession.open(id: original.id, directory: root)
            #expect(native.workbench.project == saved.project)
            try await native.workbench.undo(expectedRevision: 8)
            #expect(try await store.load().project.components == original.components)
            try await native.workbench.redo(expectedRevision: 9)
            let final = try await store.load()
            #expect(await native.flushForClose())
            let reopened = try await ElectronicsProjectSession.open(id: original.id, directory: root)
            #expect(reopened.workbench.project == final.project)
            #expect(await reopened.flushForClose())
            try FileManager.default.removeItem(at: root)
        } catch {
            if let session = try? ElectronicsProjectSession.existing(id: original.id, directory: root) { _ = await session.flushForClose() }
            print("FLOE_BACK_ANNOTATION_ORIGINAL_FAILURE_ROOT=\(root.path)")
            throw error
        }
    }
    @Test func actualRegisteredSchemaAndNativeMutationExtentDistinguishPreviewFromApply() async throws {
        try await FloeAgentApp.liveEnvironment.ensureDurableAutomationReady()
        let actual = try #require(ToolRunnerRegistry.shared.runner(named: "studio.run"))
        let id = UUID().uuidString
        func arguments(_ input: [String: Any]) throws -> [String: Any] {
            ["projectID": id, "action": "eda.backAnnotation", "inputJSON": try text(input)]
        }
        let preview = try arguments(["expectedRevision": "7"])
        try actual.validateArguments(JSONSerialization.data(withJSONObject: preview))
        #expect(TypedMutationContract.specs(for: "studio.run", arguments: preview).isEmpty)
        let apply = try arguments(["expectedRevision": "7", "preview": false, "previewSourceSHA256": String(repeating: "a", count: 64)])
        try actual.validateArguments(JSONSerialization.data(withJSONObject: apply))
        let specs = TypedMutationContract.specs(for: "studio.run", arguments: apply)
        #expect(specs.count == 1 && specs.first?.storeKey == TypedMutationContract.nativeStudioLibraryStoreKey)
        #expect(TypedMutationContract.specs(for: "studio.run", arguments: try arguments(["expectedRevision": "7", "preview": 0])).isEmpty)
    }
}
#endif
