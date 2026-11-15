// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("Draft recovery")
struct DraftRecoveryTests {
    @Test("Unsaved edits survive a session 'crash' and can be recovered")
    @MainActor
    func recoverDraft() async throws {
        let (root, repository) = try TestSupport.makeRepository(name: "draft")
        let projectRoot = try TestSupport.makeTemporaryDirectory("draft-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let path = try GameRelativePath("data/characters.json")
        let revisionBefore: String
        do {
            let session = try await GameEditingSession.open(
                repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
                adapter: GameUnknownEditingAdapter(engine: .godot))
            try await session.editDocument(at: path, summary: GameEditCopy("Rename", "改名")) { bytes in
                var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
                try document.set(.string("Recovered"), for: document.schema.fields[0])
                return try document.serialized()
            }
            revisionBefore = session.expectedRevision
            // "Crash": session deallocates without save.
        }
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        let draft = try #require(reopened.pendingDraft)
        #expect(draft.baseRevision == revisionBefore)
        #expect(draft.documentCount == 1)
        try await reopened.recoverDraft()
        let bytes = try await reopened.documentBytes(at: path)
        #expect(String(data: bytes, encoding: .utf8)?.contains("Recovered") == true)
        #expect(reopened.canUndo) // undo stack restored from the draft
        // Save now commits the recovered content.
        let saved = try await reopened.save()
        #expect(saved.parent == stored.revision)
        #expect(reopened.pendingDraft == nil)
        let again = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        #expect(again.pendingDraft == nil)
        let finalBytes = try await again.documentBytes(at: path)
        #expect(String(data: finalBytes, encoding: .utf8)?.contains("Recovered") == true)
        _ = root
    }

    @Test("Discard drops the draft and keeps the repository clean")
    @MainActor
    func discardDraft() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "discard")
        let projectRoot = try TestSupport.makeTemporaryDirectory("discard-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        do {
            let session = try await GameEditingSession.open(
                repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
                adapter: GameUnknownEditingAdapter(engine: .godot))
            try await session.editDocument(at: try GameRelativePath("data/characters.json"),
                summary: GameEditCopy("Rename", "改名")) { bytes in
                var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
                try document.set(.string("Dropped"), for: document.schema.fields[0])
                return try document.serialized()
            }
        }
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        try #require(reopened.pendingDraft)
        try reopened.discardDraft()
        let bytes = try await reopened.documentBytes(at: try GameRelativePath("data/characters.json"))
        #expect(String(data: bytes, encoding: .utf8)?.contains("Mira") == true)
        #expect(!reopened.isDirty)
    }

    @Test("A retained draft survives external changes and recovers as a reviewable conflict")
    @MainActor
    func staleDraft() async throws {
        let (_, repository) = try TestSupport.makeRepository(name: "stale")
        let projectRoot = try TestSupport.makeTemporaryDirectory("stale-source")
        try TestSupport.createSampleProject(at: projectRoot)
        let stored = try await repository.importProject(
            from: projectRoot, projectID: UUID(), owner: TestSupport.owner, title: "Sample")
        let path = try GameRelativePath("data/characters.json")
        let originalBytes = try await repository.read(stored.projectID, owner: TestSupport.owner, revision: stored.revision, path: path)
        do {
            let session = try await GameEditingSession.open(
                repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
                adapter: GameUnknownEditingAdapter(engine: .godot))
            try await session.editDocument(at: try GameRelativePath("data/characters.json"),
                summary: GameEditCopy("Rename", "改名")) { bytes in
                var document = try ParameterDocument(bytes: bytes, schema: TestSupport.sampleSchema())
                try document.set(.string("X"), for: document.schema.fields[0])
                return try document.serialized()
            }
        }
        // Legacy drafts stored the base only in immutable repository history.
        // Prove recovery still works when the new retained base blob is absent.
        let directory = await repository.directory
        let baseBlob = directory.appendingPathComponent("EditingDrafts/" + stored.projectID.uuidString.lowercased() + "/Files/" + GameDigest.sha256(originalBytes))
        if FileManager.default.fileExists(atPath: baseBlob.path) { try FileManager.default.removeItem(at: baseBlob) }
        // External commit moves HEAD while the draft still points at the old revision.
        let external: [GameFileChange] = [.write(try GameRelativePath("data/characters.json"),
            try TestSupport.jsonBytes(["characters": [["id": 1, "name": "Extern"]]]))]
        _ = try await repository.commit(stored.projectID, owner: TestSupport.owner,
                                        expectedRevision: stored.revision, changes: external)
        let reopened = try await GameEditingSession.open(
            repository: repository, projectID: stored.projectID, owner: TestSupport.owner,
            adapter: GameUnknownEditingAdapter(engine: .godot))
        #expect(reopened.pendingDraft != nil)
        #expect(reopened.diagnostics.contains { $0.message.en.contains("Recover") })
        try await reopened.recoverDraft()
        #expect(reopened.fileConflicts[path]?.baseBytes == originalBytes)
        #expect(String(data: reopened.fileConflicts[path]?.mineBytes ?? Data(), encoding: .utf8)?.contains("X") == true)
        #expect(String(data: reopened.fileConflicts[path]?.theirsBytes ?? Data(), encoding: .utf8)?.contains("Extern") == true)
        let stillRetained = try await GameEditingSession.open(repository: repository, projectID: stored.projectID,
            owner: TestSupport.owner, adapter: GameUnknownEditingAdapter(engine: .godot))
        #expect(stillRetained.pendingDraft != nil)
        try await stillRetained.recoverDraft()
        #expect(stillRetained.fileConflicts[path] != nil)
        let actual = try await repository.read(stored.projectID, owner: TestSupport.owner,
            revision: stillRetained.expectedRevision, path: path)
        #expect(String(data: actual, encoding: .utf8)?.contains("Extern") == true)
    }
}
