// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Conflict and rebase behavior")
struct ConflictTests {
    @Test("Saving after an external commit fails closed with a conflict")
    @MainActor
    func conflictOnSave() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "conflict")
        let projectRoot = try TestSupport.makeTemporaryDirectory("conflict-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        try await session.editDocument(at: try GameRelativePath("data/characters.json"),
            summary: GameEditCopy("Rename", "改名")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("Mine"), for: document.schema.fields[0])
            return try document.serialized()
        }
        _ = try await repository.commit(stored.projectID, owner: TestSupport.owner,
                                        expectedRevision: stored.revision,
                                        changes: [GameFileChange.write(try GameRelativePath("data/manifest.json"),
                                                         TestSupport.jsonBytes(["map": "maps/home.floetilemap.json"]))])
        do {
            _ = try await session.save()
            Issue.record("Save should have failed with a conflict")
        } catch GameProjectError.conflict(let expected, let actual) {
            #expect(expected == stored.revision)
            #expect(!actual.isEmpty)
        }
        #expect(session.conflict != nil)
    }

    @Test("Rebase carries forward non-conflicting edits and isolates real conflicts")
    @MainActor
    func rebase() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "rebase")
        let projectRoot = try TestSupport.makeTemporaryDirectory("rebase-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        let characters = try GameRelativePath("data/characters.json")
        let manifest = try GameRelativePath("data/manifest.json")
        // Local edit on characters; external edit on manifest.
        try await session.editDocument(at: characters, summary: GameEditCopy("Rename", "改名")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("Mine"), for: document.schema.fields[0])
            return try document.serialized()
        }
        _ = try await repository.commit(stored.projectID, owner: TestSupport.owner,
                                        expectedRevision: stored.revision,
                                        changes: [GameFileChange.write(manifest, TestSupport.jsonBytes(["map": "maps/other.json"]))])
        do { _ = try await session.save(); Issue.record("Expected conflict") }
        catch GameProjectError.conflict {}
        try await session.reloadForRebase()
        #expect(session.conflict == nil)
        #expect(session.fileConflicts.isEmpty) // disjoint files: clean carry-forward
        #expect(session.isDirty) // local edit still pending
        let saved = try await session.save()
        #expect(saved.parent != nil)
        let bytes = try await repository.read(stored.projectID, owner: TestSupport.owner,
                                              revision: saved.revision, path: characters)
        #expect(String(data: bytes, encoding: .utf8)?.contains("Mine") == true)
        let manifestBytes = try await repository.read(stored.projectID, owner: TestSupport.owner,
                                                      revision: saved.revision, path: manifest)
        #expect(String(data: manifestBytes, encoding: .utf8)?.contains("other.json") == true)
    }

    @Test("Conflicting file requires explicit keepMine/keepTheirs resolution")
    @MainActor
    func perFileResolution() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "perfile")
        let projectRoot = try TestSupport.makeTemporaryDirectory("perfile-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let session = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        let characters = try GameRelativePath("data/characters.json")
        try await session.editDocument(at: characters, summary: GameEditCopy("Rename", "改名")) { bytes in
            var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
            try document.set(.string("Mine"), for: document.schema.fields[0])
            return try document.serialized()
        }
        _ = try await repository.commit(stored.projectID, owner: TestSupport.owner,
                                        expectedRevision: stored.revision,
                                        changes: [GameFileChange.write(characters,
                                                         TestSupport.jsonBytes(["characters": [["id": 1, "name": "Theirs"]]]))])
        do { _ = try await session.save(); Issue.record("Expected conflict") }
        catch GameProjectError.conflict {}
        try await session.reloadForRebase()
        #expect(session.fileConflicts.count == 1)
        do { _ = try await session.save(); Issue.record("Save must stay blocked") }
        catch let error as GameEditIssue {
            #expect(error.diagnostics.contains { $0.severity == .error })
        }
        try session.resolveConflict(at: characters, .keepMine)
        #expect(session.fileConflicts.isEmpty)
        let saved = try await session.save()
        let bytes = try await repository.read(stored.projectID, owner: TestSupport.owner,
                                              revision: saved.revision, path: characters)
        #expect(String(data: bytes, encoding: .utf8)?.contains("Mine") == true)
    }
}
