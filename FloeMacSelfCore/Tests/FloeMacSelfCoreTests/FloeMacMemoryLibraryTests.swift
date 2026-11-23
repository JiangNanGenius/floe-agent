// SPDX-License-Identifier: MPL-2.0

import FloeAgentRuntime
import FloePersistence
import FloeTools
import Foundation
import Testing
@testable import FloeMacSelfCore

@Test func nativeMemoryLibraryReviewsEditsAndForgetsTheSharedStore() async throws {
    let database = try DatabaseManager.inMemory()
    try await database.migrate()
    let store = SQLiteIntelligenceStore(database: database)
    let documents = SQLitePersonalizationStore(database: database)
    let library = FloeMacMemoryLibrary(entries: store, runs: SQLiteRunStore(database: database), documents: documents)

    try await library.save(content: "Prefer concise checklist items", scope: .userProfile, pinned: false, forReview: true)
    #expect(try await library.list(scope: .userProfile, cursor: nil).entries.isEmpty)
    let queued = try #require(try await library.pendingReview().candidates.first)
    try await library.resolveReview(id: queued.id, keep: true)
    let original = try #require(try await library.list(scope: .userProfile, cursor: nil).entries.first)
    #expect(original.id == queued.id)
    try await library.edit(original, content: "Prefer numbered checklist items", pinned: true)
    await #expect(throws: (any Error).self) {
        try await library.edit(original, content: "An old editor", pinned: false)
    }
    #expect(try await store.memory(id: original.id)?.content == "Prefer numbered checklist items")
    #expect(try await store.memory(id: original.id)?.isPinned == true)
    try await library.forget(id: original.id)
    #expect(try await store.memory(id: original.id) == nil)
    await #expect(throws: (any Error).self) {
        try await library.save(content: "password=synthetic-fixture-value", scope: .userProfile,
                               pinned: false, forReview: true)
    }
    #expect(try await library.pendingReview().candidates.isEmpty)
}

@Test func nativePersonalizationUsesActiveSharedRevisionsAndScopedMemoryTools() async throws {
    let database = try DatabaseManager.inMemory()
    try await database.migrate()
    let store = SQLiteIntelligenceStore(database: database)
    let documents = SQLitePersonalizationStore(database: database)
    let library = FloeMacMemoryLibrary(entries: store, runs: SQLiteRunStore(database: database), documents: documents)
    try await library.saveProfile(kind: .soul, workspaceID: nil, content: "Use plain language", expectedRevision: 0)
    let first = try #require(try await library.profile(kind: .soul, workspaceID: nil).current)
    try await library.saveProfile(kind: .soul, workspaceID: nil, content: "Use short paragraphs", expectedRevision: first.revision)
    #expect(try await documents.liveSnapshot(workspaceID: nil).soul == "Use short paragraphs")
    try await library.restoreProfile(kind: .soul, workspaceID: nil)
    #expect(try await documents.liveSnapshot(workspaceID: nil).soul == "Use plain language")
    let tools = library.tools(conversationID: UUID(), workspaceID: nil, allowWrites: false)
    #expect(Set(tools.map(\.descriptor.name)) == [MemoryRecallTool.name, MemorySearchTool.name])
    #expect(!tools.contains { $0.descriptor.isSideEffecting })
}
