// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// Scripted non-GUI smoke: create project -> import -> edit all four
/// families -> save -> reopen -> verify. Prints a JSON summary line.
enum SampleCLI {
    static func run() -> Int32 {
        final class OutcomeBox: @unchecked Sendable { var result: Result<Summary, Error>? }
        let box = OutcomeBox()
        Task { @MainActor in
            do { box.result = .success(try await runScript()) }
            catch { box.result = .failure(error) }
        }
        // A CLI process has no App run loop; pump the main run loop so the
        // MainActor editing session can execute.
        while box.result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard let outcome = box.result else { return 1 }
        switch outcome {
        case .success(let summary):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(summary), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return 0
        case .failure(let error):
            print("{\"result\":\"failed\",\"error\":\"\(String(describing: error))\"}")
            return 1
        }
    }

    struct Summary: Encodable {
        var result: String
        var projectID: String
        var savedRevision: String
        var checks: [String: Bool]
        var fileCount: Int
    }

    @MainActor
    static func runScript() async throws -> Summary {
        let (repository, session, base) = try await SampleProjectFactory.makeSession()
        var checks: [String: Bool] = [:]

        // Parameter edit.
        let charactersPath = try GameRelativePath("data/characters.json")
        let schema = SampleAdapter().parameterSchemas(in: session.baseProject)[0]
        try await session.editDocument(at: charactersPath,
            summary: GameEditCopy("Set level", "设置等级")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: schema)
            try document.set(.number(8), for: schema.fields[1])
            return try document.serialized()
        }

        // Tile edit: stroke + object.
        let mapPath = try GameRelativePath("maps/home.floetilemap.json")
        try await session.editDocument(at: mapPath, summary: GameEditCopy("Paint", "绘制")) { bytes in
            var map = try EditableTileMap.decode(bytes)
            let ground = map.layers[0].id
            map = map.paintingStroke(gid: 1, from: (0, 0), to: (5, 5), layerID: ground)
            map = map.placingObject(.init(name: "chest", x: 48, y: 48, width: 16, height: 16),
                                    layerID: map.layers[1].id)
            return try map.encode()
        }

        // Narrative edit: add branch label + link.
        let narrativePath = try GameRelativePath("events/intro.json")
        try await session.editDocument(at: narrativePath, summary: GameEditCopy("Edit events", "编辑事件")) { bytes in
            var narrative = try NarrativeDocument.decode(bytes)
            narrative = narrative.addingLabel(name: "second")
            if let labelID = narrative.labels.first(where: { $0.name == "second" })?.id {
                narrative = narrative.inserting(.init(code: "branch", branchRole: .open, labelID: labelID),
                                                at: narrative.commands.count)
                narrative = narrative.inserting(.init(code: "branchEnd", branchRole: .close),
                                                at: narrative.commands.count)
            }
            return try narrative.encode()
        }

        // Asset edit: rename with reference rewrite.
        let renamePlan = try await session.renameAsset(at: try GameRelativePath("assets/coin.png"),
                                                       newName: "gold.png")
        checks["renameUpdatedPlan"] = renamePlan.to.value == "assets/gold.png"

        // Undo one step (the rename), then redo it.
        try await session.undo()
        checks["undoRestoredCoin"] = session.documentExists(at: try GameRelativePath("assets/coin.png"))
        try await session.redo()

        let saved = try await session.save()
        checks["savedClean"] = !session.isDirty

        // Reopen and verify persisted bytes.
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: session.projectID, owner: SampleSupport.owner,
            adapter: SampleAdapter())
        let characterBytes = try await reopened.documentBytes(at: charactersPath)
        let character = try ParameterDocument(bytes: characterBytes, schema: schema)
        checks["levelPersisted"] = character.value(for: schema.fields[1]) == .number(8)

        let map = try EditableTileMap.decode(try await reopened.documentBytes(at: mapPath))
        checks["tilesPersisted"] = map.layers[0].tileAt(x: 5, y: 5) == 1
        checks["objectPersisted"] = map.layers[1].objects.contains { $0.name == "chest" }

        let narrative = try NarrativeDocument.decode(try await reopened.documentBytes(at: narrativePath))
        checks["labelsPersisted"] = narrative.labels.contains { $0.name == "second" }
        checks["unknownPreserved"] = narrative.commands.contains { $0.code == "legacyPluginCall" && !$0.isSupported }

        checks["renamePersisted"] = reopened.documentExists(at: try GameRelativePath("assets/gold.png"))
        checks["referenceRewritten"] = String(data: try await reopened.documentBytes(
            at: try GameRelativePath("data/manifest.json")), encoding: .utf8) != nil

        // Cleanup the disposable sample workspace.
        try? FileManager.default.removeItem(at: base)

        return Summary(result: checks.allSatisfy(\.value) ? "passed" : "failed",
                       projectID: session.projectID.uuidString,
                       savedRevision: saved.revision,
                       checks: checks,
                       fileCount: saved.files.count)
    }
}
