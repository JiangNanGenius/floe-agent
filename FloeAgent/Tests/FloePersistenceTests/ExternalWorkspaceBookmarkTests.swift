// FloePersistenceTests — durable external-workspace access for template
// environments.
//
// Picking a folder for a template environment only grants a security-scoped
// access window while the fileImporter callback runs, and the environment
// registry stores a plain path. The app therefore persists the picked folder
// as a WorkspaceRecord carrying a bookmark (through the existing
// WorkspaceCenter.ensureWorkspaceRecord path). This suite pins the storage
// half of that contract against the real store: after the database is
// reopened — a relaunch — the record still resolves to the same folder and
// the folder remains readable through the resolved URL. The app-side helper
// itself is covered by FloeAppTests/ExternalWorkspaceTemplateAccessTests.

import Foundation
import Testing
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.ExternalWorkspaceBookmark")
struct ExternalWorkspaceBookmarkTests {

    @Test("A template-environment workspace bookmark resolves and reads after a store relaunch")
    func bookmarkSurvivesRelaunch() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-external-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let folder = sandbox.appendingPathComponent("External Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("workspace-kept".utf8).write(to: folder.appendingPathComponent("README.md"))

        // The creation flow persists what the picker granted, while its
        // security scope is still active.
        let database = try DatabaseManager(path: sandbox.appendingPathComponent("floe.sqlite"))
        try await database.migrate()
        let bookmark = try folder.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        try await SQLiteWorkspaceStore(database: database).saveWorkspace(WorkspaceRecord(
            name: folder.lastPathComponent, rootBookmark: bookmark
        ))

        // Relaunch: reopen the same database file and resolve the persisted
        // record without the picker.
        let reopened = try DatabaseManager(path: sandbox.appendingPathComponent("floe.sqlite"))
        try await reopened.migrate()
        let store = SQLiteWorkspaceStore(database: reopened)
        let records = try await store.workspaces()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.kind == .project)
        #expect(record.rootBookmark == bookmark)

        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [], relativeTo: nil, bookmarkDataIsStale: &isStale
        )
        #expect(isStale == false)
        #expect(
            resolved.resolvingSymlinksInPath().standardizedFileURL.path
                == folder.resolvingSymlinksInPath().standardizedFileURL.path
        )
        let marker = resolved.appendingPathComponent("README.md")
        #expect(String(decoding: try Data(contentsOf: marker), as: UTF8.self) == "workspace-kept")
    }
}
