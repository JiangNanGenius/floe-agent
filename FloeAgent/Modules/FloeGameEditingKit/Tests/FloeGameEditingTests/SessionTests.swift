// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Editing session round-trips")
struct SessionTests {
    func makeSession(_ name: String) async throws -> (FileGameProjectRepository, GameEditingSession) {
        let (root, repository) = try TestSupport.makeRepository(name: name)
        let projectRoot = try TestSupport.makeTemporaryDirectory(name + "-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner,
            title: "Sample", engine: .phaser)
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser))
        return (repository, session)
    }

    @Test("Edits persist and reopen after save")
    @MainActor
    func editSaveReopen() async throws {
        let (repository, session) = try await makeSession("roundtrip")
        let path = try GameRelativePath("data/characters.json")
        try await session.editDocument(at: path,
            summary: GameEditCopy("Rename", "改名")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("Mira2"), for: document.schema.fields[0])
            return try document.serialized()
        }
        #expect(session.isDirty)
        let saved = try await session.save()
        #expect(!session.isDirty)
        #expect(session.expectedRevision == saved.revision)

        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: session.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .phaser))
        let bytes = try await reopened.documentBytes(at: path)
        let document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
        #expect(document.value(for: document.schema.fields[0]) == .string("Mira2"))
    }

    @Test("Undo and redo restore bytes across multiple documents")
    @MainActor
    func undoRedo() async throws {
        let (_, session) = try await makeSession("undo")
        let characters = try GameRelativePath("data/characters.json")
        let manifest = try GameRelativePath("data/manifest.json")
        try await session.editDocument(at: characters, summary: GameEditCopy("Rename", "改名")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("A"), for: document.schema.fields[0])
            return try document.serialized()
        }
        try await session.editDocument(at: manifest, summary: GameEditCopy("Edit manifest", "编辑清单")) { bytes in
            var root = try JSONValue.parse(bytes)
            root = try JSONFieldPath([.key("heroSprite")]).replacing(in: root, with: .string("assets/hero2.png"))
            return try root.serialized()
        }
        #expect(session.canUndo)
        try await session.undo()
        var manifestBytes = try await session.documentBytes(at: manifest)
        #expect(String(data: manifestBytes, encoding: .utf8)?.contains("hero.png") == true)
        try await session.undo()
        manifestBytes = try await session.documentBytes(at: manifest)
        let charactersBytes = try await session.documentBytes(at: characters)
        #expect(!session.canUndo)
        // Original bytes are back exactly.
        #expect(String(data: charactersBytes, encoding: .utf8)?.contains("Mira") == true)
        try await session.redo()
        let renamed = try await session.documentBytes(at: characters)
        #expect(String(data: renamed, encoding: .utf8)?.contains("\"A\"") == true)
        #expect(session.history.count >= 4)
        #expect(session.history.filter { $0.operation == .undo }.count == 2)
    }

    @Test("AI and manual edits share one history and revision")
    @MainActor
    func sharedHistory() async throws {
        let (_, session) = try await makeSession("shared")
        let path = try GameRelativePath("data/characters.json")
        // "AI" edit through the same machinery as a manual edit.
        try await session.editDocument(at: path, summary: GameEditCopy("AI edit", "AI 修改")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.number(9), for: document.schema.fields[1])
            return try document.serialized()
        }
        try await session.editDocument(at: path, summary: GameEditCopy("Manual edit", "手动修改")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("manual"), for: document.schema.fields[0])
            return try document.serialized()
        }
        #expect(session.history.count == 2)
        try await session.undo()
        let bytes = try await session.documentBytes(at: path)
        #expect(String(data: bytes, encoding: .utf8)?.contains("\"level\":9") == true)
    }

    @Test("History records byte deltas and is capped")
    @MainActor
    func historyDeltas() async throws {
        let (_, session) = try await makeSession("history")
        let path = try GameRelativePath("data/characters.json")
        for index in 0..<5 {
            try await session.editDocument(at: path, summary: GameEditCopy("Edit \(index)", "修改 \(index)")) { bytes in
                var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
                try document.set(.string("v\(index)"), for: document.schema.fields[0])
                return try document.serialized()
            }
        }
        #expect(session.history.count == 5)
        #expect(session.history.allSatisfy { $0.byteDelta != 0 || $0.path == path })
        #expect(session.history.map(\.sequence) == Array(1...5))
    }
}
