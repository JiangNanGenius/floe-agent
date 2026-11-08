// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
import FloeTools
import FloeElectronicsCore
@testable import FloeApp

@Suite("Electronics App contracts", .serialized)
@MainActor struct ElectronicsAppIntegrationTests {
    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data((output.capturedOutput ?? output.summary).utf8)) as? [String: Any])
    }
    private func invoke(_ name: String, _ arguments: [String: Any], _ initial: ToolContext) async throws -> ToolExecutionOutput {
        var context = initial; context.executionToolName = name
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: name))
        return try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: arguments), context: context)
    }
    private func text(_ value: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    @Test func explicitCommandsValidateTheWholeBatchAndReturnFieldPaths() throws {
        var project = EDAProject(title: "Contract original")
        let symbol = EDASymbolDefinition(name: "Resistor", referencePrefix: "R", pins: [.init(number: "1", position: .init(0, 0))])
        project.symbols = [symbol]
        let commands: [[String: Any]] = [
            ["op": "component.place", "sheetID": project.sheets[0].id.uuidString, "symbolID": symbol.id.uuidString, "x": 10, "y": 10],
            ["op": "wire.put", "sheetID": project.sheets[0].id.uuidString, "points": [["x": 0, "y": 0], ["x": 10, "y": 10]]]
        ]
        guard case .edits(let edits) = try StudioElectronicsContract.decode(text(commands), project: project) else { Issue.record("Expected edits"); return }
        var session = try EDAEditingSession(project: project)
        try session.apply(edits, expectedRevision: 0)
        #expect(session.project.revision == 1 && session.project.components.count == 1 && session.project.sheets[0].wires.count == 1)
        var invalid = commands; invalid[1]["points"] = [["x": 0, "y": 0], ["x": "wrong", "y": 10]]
        do { _ = try StudioElectronicsContract.decode(text(invalid), project: project); Issue.record("Invalid batch accepted") }
        catch { #expect(error.localizedDescription.contains("$[1].points[1].x")) }
        #expect(project.revision == 0 && project.components.isEmpty && project.sheets[0].wires.isEmpty)
        var native = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(symbol)) as? [String: Any])
        native["guess"] = true
        do { _ = try StudioElectronicsContract.decode(text([["op": "native.put", "kind": "symbolDefinition", "value": native]]), project: project); Issue.record("Unknown native field accepted") }
        catch { #expect(error.localizedDescription.contains("$[0].value.guess")) }
        var missing = native; missing["guess"] = nil; missing["pins"] = nil
        do { _ = try StudioElectronicsContract.decode(text([["op": "native.put", "kind": "symbolDefinition", "value": missing]]), project: project); Issue.record("Incomplete native record accepted") }
        catch { #expect(error.localizedDescription.contains("$[0].value.pins")) }
        let nativeExport = try #require(try EDAExchange.export(project, format: .project).files.first)
        #expect(try EDAExchange.decodeProject(nativeExport.data) == project)
        var envelope = try #require(JSONSerialization.jsonObject(with: nativeExport.data) as? [String: Any])
        var unfamiliar = try #require(envelope["project"] as? [String: Any]); unfamiliar["futureNativeField"] = ["owned": "preserve"]
        envelope["project"] = unfamiliar
        do { _ = try EDAExchange.decodeProject(JSONSerialization.data(withJSONObject: envelope)); Issue.record("Unfamiliar native content was silently dropped") }
        catch { #expect(String(describing: error).contains("$.project.futureNativeField")) }
    }
    @Test func registeredToolsSaveReopenSynchronizePreviewAndPublishActualFiles() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let conversation = UUID(), runID = UUID(), now = Date()
        try await environment.conversationStore.saveConversation(.init(id: conversation, title: "Electronics integration contract", createdAt: now, updatedAt: now))
        _ = try await SQLiteWorkspaceStore(database: environment.database).ensureWorkspace(conversationID: conversation, title: "Electronics integration contract")
        try await environment.conversationStore.setArchived(id: conversation, archived: true)
        try await environment.runStore.saveRun(.init(id: runID, conversationID: conversation, state: "executing", goal: "Electronics integration contract", startedAt: now))
        var context = ToolContext(runID: runID, toolCallID: "create-electronics-contract", allowedToolNames: StudioCoordinator.names, cancellation: CancellationToken(), conversationID: conversation)
        context.frozenEffectiveCatalogNames = StudioCoordinator.names; context.approvalGrantID = UUID()
        do {
            let created = try json(try await invoke("studio.create", ["kind": "electronics", "title": "QA Electronics \(UUID().uuidString.prefix(8))"], context))
            let record = try #require(created["record"] as? [String: Any]), raw = try #require(record["id"] as? String), id = try #require(UUID(uuidString: raw))
            FileHandle.standardOutput.write(Data("FLOE_ELECTRONICS_FIXTURE|\(id.uuidString)\n".utf8))
            let library = try await PersonalContentService.shared.library(), location = try await library.resolve(id)
            let original = try ElectronicsSavedSnapshot(id: id, directory: location.url)
            let before = try json(try await invoke("studio.read", ["projectID": raw, "limit": 12_000], context))
            let capabilities = try #require(before["electronicsCapabilities"] as? [String: Any])
            #expect(before["revision"] as? String == "0")
            #expect((capabilities["exportFormats"] as? [String])?.contains("positions") == true)
            let sheet = try #require(original.project.sheets.first), symbol = try #require(original.project.symbols.first { $0.referencePrefix == "R" }), footprint = try #require(original.project.footprints.first)
            let commands: [[String: Any]] = [["op": "component.place", "sheetID": sheet.id.uuidString, "symbolID": symbol.id.uuidString, "footprintID": footprint.id.uuidString, "reference": "R1", "value": "10k", "x": 25.4, "y": 25.4]]
            context.toolCallID = "save-component-contract"
            _ = try await invoke("studio.edit", ["projectID": raw, "expectedRevision": "0", "operationsJSON": text(commands)], context)
            let saved = try ElectronicsSavedSnapshot(id: id, directory: location.url)
            #expect(saved.project.revision == 1 && saved.project.components.first?.value == "10k")
            do { _ = try await invoke("studio.edit", ["projectID": raw, "expectedRevision": "0", "operationsJSON": text([["op": "rename", "title": "Stale"]])], context); Issue.record("Stale edit accepted") } catch { }
            #expect(try ElectronicsSavedSnapshot(id: id, directory: location.url).digest == saved.digest)
            context.toolCallID = "synchronize-board-contract"
            _ = try await invoke("studio.run", ["projectID": raw, "action": "eda.forwardAnnotation", "inputJSON": text(["expectedRevision": "1"])], context)
            var board = try ElectronicsSavedSnapshot(id: id, directory: location.url)
            #expect(board.project.boards.first?.footprints.count == 1)
            var physical = try #require(board.project.boards.first)
            let net = try #require(physical.footprints.first?.padNets.values.sorted().first)
            physical.holes = [.init(position: .init(40, 40), diameter: 1.2, plated: false)]
            physical.zones = [.init(netID: net, outline: [.init(5, 5), .init(95, 5), .init(95, 75), .init(5, 75)], thermal: false)]
            let nativeBoard = try JSONSerialization.jsonObject(with: JSONEncoder().encode(physical))
            context.toolCallID = "save-real-copper-and-drill-contract"
            _ = try await invoke("studio.edit", ["projectID": raw, "expectedRevision": String(board.project.revision),
                "operationsJSON": text([["op": "native.put", "kind": "board", "value": nativeBoard]])], context)
            board = try ElectronicsSavedSnapshot(id: id, directory: location.url)
            context.toolCallID = "refill-real-copper-contract"
            _ = try await invoke("studio.run", ["projectID": raw, "action": "eda.refillCopper",
                "inputJSON": text(["expectedRevision": String(board.project.revision), "boardID": physical.id.uuidString])], context)
            board = try ElectronicsSavedSnapshot(id: id, directory: location.url)
            let filled = try #require(board.project.boards.first?.zones.first), revision = String(board.project.revision)
            #expect(filled.fillState == .filled && filled.fillRevision == board.project.revision && !filled.filledPolygons.isEmpty)
            for format in ["gerber", "excellon"] {
                context.toolCallID = "publish-real-" + format
                let result = try await invoke("studio.run", ["projectID": raw, "action": "eda.export",
                    "inputJSON": text(["expectedRevision": revision, "boardID": physical.id.uuidString, "format": format])], context)
                #expect(result.outputFiles.contains { $0.displayName.lowercased().hasSuffix(format == "gerber" ? ".gbr" : ".drl") })
                for file in result.outputFiles {
                    let bytes = try Data(contentsOf: FloeArtifactStore.root().appendingPathComponent(file.relativePath))
                    #expect(bytes.count == file.byteCount && StudioToolOutput.hash(bytes) == file.sha256)
                    if file.mimeType == "application/json" {
                        let manifest = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                        #expect(manifest["sourceRevision"] as? String == revision)
                        #expect((manifest["projectID"] as? String).flatMap(UUID.init(uuidString:)) == id)
                    }
                }
            }
            for action in ["eda.erc", "eda.drc", "eda.netlist", "eda.export"] {
                context.toolCallID = "run-" + action
                var options: [String: Any] = ["expectedRevision": revision]
                if action == "eda.export" { options["format"] = "project" }
                let output = try await invoke("studio.run", ["projectID": raw, "action": action, "inputJSON": text(options)], context)
                let file = try #require(output.outputFiles.first)
                let bytes = try Data(contentsOf: FloeArtifactStore.root().appendingPathComponent(file.relativePath))
                #expect(bytes.count == file.byteCount && StudioToolOutput.hash(bytes) == file.sha256)
                if action == "eda.export" { #expect(try EDAExchange.decodeProject(bytes) == board.project) }
            }
            context.toolCallID = "inspect-saved-electronics"
            let frame = try await invoke("studio.run", ["projectID": raw, "action": "inspectFrame", "inputJSON": text(["expectedRevision": revision, "maximumPixelSize": 320])], context)
            #expect(frame.artifacts.count == 1 && frame.artifacts[0].mimeType == "image/png" && frame.artifacts[0].byteCount > 0)
            let currentRecord = try await library.resolve(id).record
            let preview = try await PersonalContentPreviewService.shared.preview(PersonalContentPreviewService.shared.request(for: currentRecord))
            guard case .image(let pixels) = preview.content else { Issue.record("Expected actual drawing preview"); return }
            #expect(!pixels.isEmpty)
            let native = try await ElectronicsProjectSession.open(id: id, directory: location.url)
            #expect(native.workbench.project == board.project)
            #expect(await native.flushForClose())
            let reopened = try await ElectronicsProjectSession.open(id: id, directory: location.url)
            #expect(reopened.workbench.project == board.project)
            #expect(await reopened.flushForClose())
            let share = try await PersonalLibraryFileActions.share(try await library.resolve(id).record)
            defer { share.finish() }
            let imported = try await PersonalContentService.shared.importFile(share.url, folders: [])
            let importedLocation = try await library.resolve(imported.id)
            let importedProject = try ElectronicsSavedSnapshot(id: imported.id, directory: importedLocation.url).project
            #expect(imported.kind == .electronics && imported.id != id && importedProject.revision == 0)
            #expect(importedProject.components == board.project.components)
            #expect(importedProject.boards.flatMap(\.zones).allSatisfy { $0.fillState == nil && $0.fillRevision == nil && $0.filledPolygons.isEmpty })
            let copy = try await PersonalLibraryFileActions.duplicate(try await library.resolve(id).record, title: "QA Electronics copy \(UUID().uuidString.prefix(8))", to: [])
            let folderName = "QA Electronics folder " + String(UUID().uuidString.prefix(8))
            try await library.createFolder(String(folderName), in: [])
            let moved = try await PersonalLibraryFileActions.move(copy, to: [String(folderName)])
            #expect(moved.id == copy.id && moved.folders == [String(folderName)])
            let movedLocation = try await library.resolve(copy.id)
            let movedSession = try await ElectronicsProjectSession.open(id: copy.id, directory: movedLocation.url)
            #expect(movedSession.workbench.project.components == board.project.components)
            #expect(movedSession.workbench.project.boards.flatMap(\.zones).allSatisfy { $0.fillState == nil && $0.fillRevision == nil && $0.filledPolygons.isEmpty })
            #expect(await movedSession.flushForClose())
            try await PersonalLibraryFileActions.delete(try await library.resolve(imported.id).record, environment: environment)
            let folder = try #require(try await library.folderSnapshots(in: []).first { $0.components == [String(folderName)] })
            try await PersonalLibraryFileActions.deleteFolder(folder, environment: environment)
            // Keep only this self-authored original for the immediate UI pass;
            // the coordinator cleans it through the ordinary Files lifecycle.
        } catch {
            try? await environment.conversationStore.deleteConversation(id: conversation)
            throw error
        }
        try await environment.conversationStore.deleteConversation(id: conversation)
    }
}
#endif
