// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameEditingCore

@Suite("External import refresh")
struct ImportRefreshTests {
    @Test("Imported files appear without reopening; unsaved work cannot be discarded by refresh")
    @MainActor func importRefreshAndDirtyProtection() async throws {
        let (repositoryRoot, repository) = try TestSupport.makeRepository(name: "refresh-import")
        let source = try TestSupport.makeTemporaryDirectory("refresh-import-source")
        defer { try? FileManager.default.removeItem(at: repositoryRoot); try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let path = try GameRelativePath("nested/unknown.dat")
        try Data([1, 2, 3]).write(to: source.appendingPathComponent(path.value))
        let id = UUID(), owner = TestSupport.owner
        let empty = try await repository.createProject(projectID: id, owner: owner, title: "Imported game")
        let session = try await GameEditingSession.open(repository: repository, projectID: id, owner: owner, adapter: GameUnknownEditingAdapter(engine: .godot))
        #expect(session.existingPaths().isEmpty)
        let imported = try await repository.importContents(from: source, into: id, owner: owner, expectedRevision: empty.revision)
        try await session.refreshAfterProjectImport()
        #expect(session.existingPaths() == [path])
        #expect(session.expectedRevision == imported.revision)
        #expect(try await session.documentBytes(at: path) == Data([1, 2, 3]))
        try await session.editDocument(at: path, summary: GameEditCopy("Edit", "编辑")) { _ in Data([9]) }
        _ = try await repository.commit(id, owner: owner, expectedRevision: imported.revision, changes: [.write(try GameRelativePath("other.txt"), Data([4]))])
        do { try await session.refreshAfterProjectImport(); Issue.record("Refresh discarded unsaved changes") }
        catch { #expect(session.isDirty) }
        #expect(try await session.documentBytes(at: path) == Data([9]))
        #expect(session.expectedRevision == imported.revision)
    }
}
