// FloeAppTests — durable conversation pinning as the conversation surfaces
// consume it: old rows default unpinned, metadata paths the center reuses
// (rename, archive/restore, workspace move, reconstructed saves) never
// erase or fake the pin, and the published ordering places pinned rows FIRST
// WITHIN their existing group with the newest pin first, falling back to the
// plain updatedAt recency after unpin. Migration-level and store-eligibility
// failures are covered by FloePersistenceTests.ConversationPinningStoreTests.

#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.ConversationPinning")
struct ConversationPinningTests {

    private func freshStore() async throws -> (DatabaseManager, SQLiteConversationStore) {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return (manager, SQLiteConversationStore(database: manager))
    }

    private func record(
        _ title: String,
        updated: Double,
        pinned: Double? = nil,
        purpose: ConversationPurpose = .ordinary
    ) -> ConversationRecord {
        ConversationRecord(
            id: UUID(),
            title: title,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updated),
            purpose: purpose,
            pinnedAt: pinned.map { Date(timeIntervalSince1970: $0) }
        )
    }

    // MARK: - Old-row compatibility

    @Test("Pre-pin call sites construct records exactly as before (pinnedAt defaults nil)")
    func legacyInitDefaultsUnpinned() {
        let legacy = ConversationRecord(
            id: UUID(), title: "old",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        #expect(legacy.pinnedAt == nil)
        #expect(!legacy.isPinned)
        let pinnedCopy = ConversationRecord(
            id: legacy.id, title: legacy.title,
            createdAt: legacy.createdAt, updatedAt: legacy.updatedAt,
            pinnedAt: Date(timeIntervalSince1970: 5)
        )
        #expect(pinnedCopy.isPinned)
        #expect(pinnedCopy != legacy)
    }

    @Test("A decoded pre-v55 row (NULL pinned_at) round-trips as unpinned, untouched otherwise")
    func storedOldRowsDecodeUnpinned() async throws {
        let (manager, store) = try await freshStore()
        let legacyID = UUID()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations(id,title,created_at,updated_at,purpose,visibility)
                VALUES (?, 'Legacy', '2025-01-01T00:00:00Z', '2025-01-02T00:00:00Z', 'ordinary', 'normal')
                """, arguments: [legacyID.uuidString])
        }
        let rows = try await store.conversations()
        #expect(rows.count == 1)
        #expect(rows[0].id == legacyID)
        #expect(rows[0].title == "Legacy")
        #expect(rows[0].pinnedAt == nil)
        #expect(!rows[0].isPinned)
    }

    // MARK: - Metadata paths preserve the pin

    @Test("Rename keeps the pin and does not fake recency from the pin itself")
    func renameKeepsPin() async throws {
        let (_, store) = try await freshStore()
        let conversation = record("chat", updated: 100)
        try await store.saveConversation(conversation)
        try await store.setPinned(id: conversation.id, pinnedAt: Date(timeIntervalSince1970: 500))
        try await store.renameConversation(id: conversation.id, title: "renamed")
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.title == "renamed")
        #expect(after?.pinnedAt == Date(timeIntervalSince1970: 500))
    }

    @Test("Archive and restore keep the pin; unpin restores the plain recency order")
    func archiveRestoreKeepsPinAndUnpinRestoresOrder() async throws {
        let (_, store) = try await freshStore()
        // Archive/restore legitimately touches updatedAt (existing
        // semantics). Pin restoration after UNPIN must therefore be judged
        // against the archived row's own NEW recency: the fresh row stays
        // newest by construction, and the unpin result equals the plain
        // updatedAt ordering the center already published.
        // Integer-second timestamps only: the codec persists fractional
        // seconds, so exact equality round-trips.
        let pinned = record("pinned chat", updated: 10, pinned: 400)
        let fresher = record("fresher chat",
                             updated: (Date().timeIntervalSince1970 + 10_000).rounded(.down))
        try await store.saveConversation(pinned)
        try await store.saveConversation(fresher)
        #expect(ConversationListOrdering.sorted(try await store.conversations())
            .map(\.id) == [pinned.id, fresher.id])

        try await store.setArchived(id: pinned.id, archived: true)
        try await store.setArchived(id: pinned.id, archived: false)
        guard let restored = try await store.conversation(id: pinned.id) else {
            Issue.record("the archived row did not come back")
            return
        }
        #expect(restored.pinnedAt == Date(timeIntervalSince1970: 400))
        #expect(ConversationListOrdering.sorted(try await store.conversations())
            .first?.id == pinned.id) // still pinned first despite fresh activity elsewhere

        // Cancel pin: ordering falls back to EXACTLY the plain updatedAt rule.
        try await store.setPinned(id: pinned.id, pinnedAt: nil)
        let order = ConversationListOrdering.sorted(try await store.conversations())
        #expect(order.map(\.id) == [fresher.id, pinned.id])
        #expect(order[0].updatedAt == fresher.updatedAt)
        #expect(order[1].updatedAt == restored.updatedAt)
    }

    @Test("A workspace move keeps the pin (ownership tables never touch the row)")
    func moveKeepsPin() async throws {
        let (manager, store) = try await freshStore()
        let conversation = record("chat", updated: 100, pinned: 300)
        try await store.saveConversation(conversation)
        let projectID = UUID()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO workspaces(id,name,root_bookmark,last_opened_at,
                    active_target_kind,active_target_host_id,inspector_state_json,
                    instructions_rel_path,created_at,updated_at,kind,internal_relative_path)
                VALUES (?,?,X'',NULL,'local',NULL,'{}',NULL,'2025-01-01T00:00:00Z',
                    '2025-01-01T00:00:00Z','project',?)
                """, arguments: [projectID.uuidString, "Project", "Project/\(projectID.uuidString)"])
        }
        try await SQLiteWorkspaceStore(database: manager)
            .assignConversation(workspaceID: projectID, conversationID: conversation.id)
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.pinnedAt == Date(timeIntervalSince1970: 300))
        // Reopening a moved conversation still projects the pin first.
        #expect(ConversationListOrdering.sorted(try await store.conversations())
            .first?.id == conversation.id)
    }

    @Test("A reconstructed record save (Keep/promotion style) can never erase the durable pin")
    func reconstructedSaveKeepsExistingPin() async throws {
        let (_, store) = try await freshStore()
        let conversation = record("chat", updated: 100)
        try await store.saveConversation(conversation)
        try await store.setPinned(id: conversation.id, pinnedAt: Date(timeIntervalSince1970: 600))
        var stale = conversation
        stale.pinnedAt = nil // older call sites never learned the field
        stale.updatedAt = Date(timeIntervalSince1970: 120)
        try await store.saveConversation(stale)
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.pinnedAt == Date(timeIntervalSince1970: 600))
        #expect(after?.updatedAt == stale.updatedAt) // the touched fields DO apply
    }

    @Test("Pinning never rewrites updated_at, so recency after unpin is the original truth")
    func pinDoesNotTouchRecency() async throws {
        let (_, store) = try await freshStore()
        let conversation = record("chat", updated: 100)
        try await store.saveConversation(conversation)
        try await store.setPinned(id: conversation.id, pinnedAt: Date(timeIntervalSince1970: 700))
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.updatedAt == Date(timeIntervalSince1970: 100))
    }

    // MARK: - Group projection (what the sidebar sections show)

    @Test("Pinned first WITHIN each existing group; newest pin first; rest by updatedAt")
    func pinnedFirstWithinExistingGroups() async throws {
        let (_, store) = try await freshStore()
        let chatOld = record("chat old", updated: 10)
        let chatPinned = record("chat pinned", updated: 20, pinned: 300)
        let chatFresher = record("chat fresher", updated: 40)
        let projectLatePin = record("project pinned later", updated: 5, pinned: 500)
        let projectPlain = record("project plain", updated: 30)
        for conversation in [chatOld, chatPinned, chatFresher, projectLatePin, projectPlain] {
            try await store.saveConversation(conversation)
        }
        let published = ConversationListOrdering.sorted(try await store.conversations())
        // The center publishes ONE ordered array; sidebar groups are
        // order-preserving filters over it, so each group keeps its pinned
        // rows first with the newest pin above.
        let chatGroup = published.filter {
            [chatOld.id, chatPinned.id, chatFresher.id].contains($0.id)
        }
        let projectGroup = published.filter {
            [projectLatePin.id, projectPlain.id].contains($0.id)
        }
        #expect(chatGroup.map(\.id) == [chatPinned.id, chatFresher.id, chatOld.id])
        #expect(projectGroup.map(\.id) == [projectLatePin.id, projectPlain.id])
        // Across the pinned set itself, the most recent pin leads the whole
        // list (host-level order), then recency takes over.
        #expect(published.first?.id == projectLatePin.id)
        #expect(published.map(\.id).prefix(2).elementsEqual([projectLatePin.id, chatPinned.id]))
    }
}
#endif
