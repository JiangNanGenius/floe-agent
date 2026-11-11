// FloePersistenceTests — durable conversation pinning (schema v55).
//
// Covers the migration (old rows decode unpinned with no backfill), the
// write discipline (pins live ONLY on the conversation row; the upsert
// never erases an existing pin while a FIRST insert round-trips its public
// pinnedAt), actionable failures (missing row / notes / hidden authoring /
// ephemeral temporary store all refuse instead of a silent zero-row
// success), pin writes never touching updated_at, workspace moves keeping
// the pin (they only rewrite ownership), and the canonical pinned-first
// ordering used by every list surface.

import Foundation
import GRDB
import FloeCore
import FloeModels
import Testing
@testable import FloePersistence

@Suite("v55 conversation pinning")
struct ConversationPinningStoreTests {
    private func migratedStore() async throws -> (DatabaseManager, SQLiteConversationStore) {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return (manager, SQLiteConversationStore(database: manager))
    }

    private func record(
        _ id: UUID = UUID(),
        title: String = "chat",
        created: Date = Date(timeIntervalSince1970: 100),
        updated: Date = Date(timeIntervalSince1970: 200),
        purpose: ConversationPurpose = .ordinary,
        visibility: ConversationVisibility = .normal,
        pinnedAt: Date? = nil
    ) -> ConversationRecord {
        ConversationRecord(
            id: id, title: title, createdAt: created, updatedAt: updated,
            purpose: purpose, visibility: visibility, pinnedAt: pinnedAt
        )
    }

    // MARK: - Migration + old-row compatibility

    @Test("v55 applies on fresh databases and joins the aligned user_version")
    func migrationApplies() async throws {
        let (manager, _) = try await migratedStore()
        let applied = try await manager.appliedMigrations()
        #expect(applied.contains("v55_conversation_pinning"))
        let version = try await manager.userVersion()
        #expect(version == DatabaseManager.currentSchemaVersion)
        #expect(DatabaseManager.currentSchemaVersion >= 55)
    }

    @Test("Pre-v55 rows (no pinned_at value) decode as unpinned, unchanged otherwise")
    func oldRowsDecodeUnpinned() async throws {
        let manager = try DatabaseManager.inMemory()
        // Insert through the RAW column list an app before v55 would have
        // written: no pinned_at. The migrated column defaults to NULL.
        try await manager.migrate()
        let legacyID = UUID()
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations(id,title,created_at,updated_at,purpose,visibility)
                VALUES (?, 'Old chat', '2025-01-01T00:00:00Z', '2025-01-02T00:00:00Z', 'ordinary', 'normal')
                """, arguments: [legacyID.uuidString])
        }
        let store = SQLiteConversationStore(database: manager)
        let listed = try await store.conversations()
        #expect(listed.count == 1)
        #expect(listed[0].id == legacyID)
        #expect(listed[0].title == "Old chat")
        #expect(listed[0].pinnedAt == nil)
        #expect(!listed[0].isPinned)
    }

    // MARK: - Persist, reopen, unpin

    @Test("setPinned persists across a new store instance (reopen) and unpin restores nil")
    func pinPersistsAcrossReopen() async throws {
        let (manager, store) = try await migratedStore()
        let conversation = record()
        try await store.saveConversation(conversation)
        let pinDate = Date(timeIntervalSince1970: 5_000)
        // Freeze "now" for the assertion by writing through the store with a
        // known value is impossible (setPinned takes Date now), so assert
        // presence + round-trip instead:
        try await store.setPinned(id: conversation.id, pinnedAt: pinDate)
        let first = try await store.conversation(id: conversation.id)
        #expect(first?.pinnedAt == pinDate)
        #expect(first?.updatedAt == conversation.updatedAt) // pin never touches recency

        let reopened = SQLiteConversationStore(database: manager)
        let second = try await reopened.conversation(id: conversation.id)
        #expect(second?.pinnedAt == pinDate)

        try await reopened.setPinned(id: conversation.id, pinnedAt: nil)
        let third = try await reopened.conversation(id: conversation.id)
        #expect(third?.pinnedAt == nil)
        #expect(third?.updatedAt == conversation.updatedAt)
    }

    // MARK: - Write discipline (reconstruction cannot erase a pin)

    @Test("The saveConversation upsert NEVER erases an existing pin")
    func staleReconstructionKeepsPin() async throws {
        let (manager, store) = try await migratedStore()
        let conversation = record()
        try await store.saveConversation(conversation)
        try await store.setPinned(id: conversation.id, pinnedAt: Date(timeIntervalSince1970: 700))
        // A reconstructed record with pinnedAt == nil (old call sites that
        // never learned the field) must not clear the durable pin.
        var stale = conversation
        stale.title = "renamed later"
        stale.pinnedAt = nil
        try await store.saveConversation(stale)
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.title == "renamed later")
        #expect(after?.pinnedAt == Date(timeIntervalSince1970: 700))
    }

    @Test("A FIRST insert honours the record's public pinnedAt (round-trip) — v55 review fix")
    func firstInsertPersistsSuppliedPin() async throws {
        let (_, store) = try await migratedStore()
        let pin = Date(timeIntervalSince1970: 9_000)
        try await store.saveConversation(record(pinnedAt: pin))
        let loaded = try await store.conversations()
        #expect(loaded.count == 1)
        #expect(loaded[0].pinnedAt == pin)
    }

    // MARK: - Actionable failures (review: no false success)

    @Test("setPinned on a missing row throws notFound, not a silent zero-row success")
    func pinMissingRowIsActionable() async throws {
        let (_, store) = try await migratedStore()
        let missing = UUID()
        do {
            try await store.setPinned(id: missing, pinnedAt: Date())
            Issue.record("a pin on a missing conversation must be actionable")
        } catch let error as FloeError {
            switch error {
            case .notFound(let reason):
                #expect(reason.contains(missing.uuidString))
            default:
                Issue.record("expected notFound, got \(error)")
            }
        }
    }

    @Test("setPinned refuses notes and hidden authoring rows; pins ordinary only")
    func pinRefusesNonOrdinary() async throws {
        let (manager, store) = try await migratedStore()
        let notes = record(title: "notes", purpose: .notes)
        try await store.saveConversation(notes)
        await #expect(throws: (any Error).self) {
            try await store.setPinned(id: notes.id, pinnedAt: Date())
        }
        // The notes row must not have been silently marked pinned.
        let rawNotesPin = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT pinned_at FROM conversations WHERE id = ?",
                                arguments: [notes.id.uuidString])
        }
        #expect(rawNotesPin == nil)

        let authoring = record(title: "hidden", visibility: .skillAuthoring)
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations(id,title,created_at,updated_at,purpose,visibility)
                VALUES (?, ?, '2025-01-01T00:00:00Z', '2025-01-02T00:00:00Z', 'ordinary', 'skillAuthoring')
                """, arguments: [authoring.id.uuidString, authoring.title])
        }
        await #expect(throws: (any Error).self) {
            try await store.setPinned(id: authoring.id, pinnedAt: Date())
        }
    }

    @Test("The ephemeral (temporary-chat) store refuses pinning through the protocol default")
    func ephemeralStoreRefusesPin() async throws {
        let ephemeral = EphemeralConversationStore(record: record(purpose: .temporary))
        await #expect(throws: (any Error).self) {
            try await ephemeral.setPinned(id: UUID(), pinnedAt: Date())
        }
    }

    // MARK: - Move keeps pin (ownership tables never touch the row)

    @Test("A workspace move keeps the durable pin on the conversation row")
    func moveKeepsPin() async throws {
        let (manager, store) = try await migratedStore()
        let conversation = record()
        try await store.saveConversation(conversation)
        try await store.setPinned(id: conversation.id, pinnedAt: Date(timeIntervalSince1970: 400))
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let project = WorkspaceRecord(
            name: "Project", rootBookmark: Data(), kind: .project,
            createdAt: Date(), updatedAt: Date()
        )
        try await workspaceStore.saveWorkspace(project)
        try await workspaceStore.assignConversation(workspaceID: project.id, conversationID: conversation.id)
        let after = try await store.conversation(id: conversation.id)
        #expect(after?.pinnedAt == Date(timeIntervalSince1970: 400))
    }

    // MARK: - Canonical ordering

    @Test("Pinned rows sort first within the list, most recent pin first; rest stay recency-ordered")
    func orderingIsPinnedFirstThenRecency() {
        func item(_ id: UUID, updated: Double, pinned: Double?) -> ConversationRecord {
            record(id, updated: Date(timeIntervalSince1970: updated), pinnedAt: pinned.map { Date(timeIntervalSince1970: $0) })
        }
        let a = item(UUID(), updated: 100, pinned: nil)
        let b = item(UUID(), updated: 300, pinned: nil)
        let p1 = item(UUID(), updated: 50, pinned: 600)   // pinned earlier
        let p2 = item(UUID(), updated: 20, pinned: 900)   // pinned later
        let ordered = ConversationListOrdering.sorted([a, b, p1, p2])
        #expect(ordered.map(\.id) == [p2.id, p1.id, b.id, a.id])
    }

    @Test("Unpin restores the plain recency order; equal keys stay deterministic by id")
    func unpinRestoresRecencyAndTiesAreStable() {
        let same = Date(timeIntervalSince1970: 100)
        let first = record(UUID(), updated: same)
        let second = record(UUID(), updated: same)
        let ordered = ConversationListOrdering.sorted([second, first])
        // No time difference: order is exactly the stable id comparison.
        #expect(ordered.map(\.id) == [ordered[0].id, ordered[1].id])
        let expected = [first, second]
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(\.id)
        #expect(ordered.map(\.id) == expected)
        // The comparison is antisymmetric for distinct ids.
        #expect(ConversationListOrdering.precedes(first, second)
                != ConversationListOrdering.precedes(second, first))
    }

    @Test("A pinned row with an older update still precedes freshly updated unpinned rows")
    func pinOutranksRecencyWithinGroup() {
        let pinnedOld = record(UUID(), updated: Date(timeIntervalSince1970: 10), pinnedAt: Date(timeIntervalSince1970: 20))
        let activeFresh = record(UUID(), updated: Date(timeIntervalSince1970: 900))
        let ordered = ConversationListOrdering.sorted([activeFresh, pinnedOld])
        #expect(ordered.first?.id == pinnedOld.id)
    }
}


@Suite("Editor assistant durable ownership")
struct EditorAssistantOwnershipTests {
    @Test("Owner and row commit atomically; archive, rename, workspace and cold reopen cannot expose an editor")
    func atomicOwnerSurvivesNormalMutationAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-editor-owner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite")
        let database = try DatabaseManager(path: url); try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let id = UUID(), file = UUID(), now = Date()
        let owned = ConversationRecord(id: id, title: "same title", createdAt: now, updatedAt: now,
            editorOwnership: .file(file))
        try await store.saveConversationWithCanonicalWorkspace(owned)
        #expect(try await store.conversations().isEmpty)
        #expect(try await store.conversation(id: id)?.editorOwnership == .file(file))
        #expect(try await SQLiteWorkspaceStore(database: database).workspaceID(conversationID: id) != nil)
        try await store.renameConversation(id: id, title: "ordinary title")
        try await store.setArchived(id: id, archived: true)
        try await store.setArchived(id: id, archived: false)
        try await store.saveConversation(.init(id: id, title: "save from an old caller", createdAt: now, updatedAt: now))
        #expect(try await store.conversation(id: id)?.editorOwnership == .file(file), "Old callers cannot erase durable ownership")
        #expect(try await store.conversations(includeArchived: true).isEmpty)
        let reopened = try DatabaseManager(path: url); try await reopened.migrate()
        let cold = SQLiteConversationStore(database: reopened)
        #expect(try await cold.conversation(id: id)?.editorOwnership == .file(file))
        #expect(try await cold.conversations(includeArchived: true).isEmpty)
        let rejectedID = UUID()
        await #expect(throws: (any Error).self) {
            try await store.saveConversationWithCanonicalWorkspace(.init(id: rejectedID, title: "wrong feature",
                createdAt: now, updatedAt: now, visibility: .skillAuthoring, editorOwnership: .file(file)))
        }
        #expect(try await store.conversation(id: rejectedID) == nil, "A failed ownership claim rolls the INSERT back")
    }

    @Test("Exact native claims retain old history while unrelated identically named chats stay ordinary")
    func exactClaimsNeverPromoteOrRetargetHistory() async throws {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let old = UUID(), next = UUID(), ordinary = UUID(), file = UUID(), now = Date()
        for id in [old, next, ordinary] {
            try await store.saveConversation(.init(id: id, title: "Work assistant · same", createdAt: now, updatedAt: now))
        }
        try await store.claimEditorOwnership(id: old, owner: .file(file))
        try await store.claimEditorOwnership(id: old, owner: .file(file))
        try await store.claimEditorOwnership(id: next, owner: .file(file))
        await #expect(throws: (any Error).self) { try await store.claimEditorOwnership(id: old, owner: .file(UUID())) }
        await #expect(throws: (any Error).self) { try await store.setPinned(id: old, pinnedAt: now) }
        #expect(try await store.conversations().map(\.id) == [ordinary])
        #expect(try await store.conversation(id: old)?.editorOwnership == .file(file))
        #expect(try await store.conversation(id: next)?.editorOwnership == .file(file))
        let blank = UUID()
        try await store.saveConversation(.init(id: blank, title: "", createdAt: now, updatedAt: now, editorOwnership: .file(file)))
        #expect(try await store.deleteConversationIfVerifiedEmpty(id: blank) == false)
    }

    @Test("The additive migration preserves table identity and rejects partial or unknown ownership")
    func migrationPreservesRowsAndRejectsPartialOwnership() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("legacy") { db in
            try db.execute(sql: "CREATE TABLE conversations(id TEXT PRIMARY KEY, purpose TEXT NOT NULL, visibility TEXT NOT NULL); INSERT INTO conversations VALUES ('kept','ordinary','normal'); CREATE TABLE messages(id TEXT PRIMARY KEY, conversation_id TEXT REFERENCES conversations(id), content TEXT); INSERT INTO messages VALUES ('message','kept','v60 history'); PRAGMA user_version=60")
        }
        try migrator.migrate(queue)
        let originalRoot = try queue.read { try Int.fetchOne($0, sql: "SELECT rootpage FROM sqlite_master WHERE name='conversations'") }
        V61EditorAssistantOwnership.register(into: &migrator)
        try migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT rootpage FROM sqlite_master WHERE name='conversations'") } == originalRoot)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM conversations WHERE editor_owner_kind IS NULL") } == 1)
        let uuid = UUID().uuidString
        for statement in [
            "UPDATE conversations SET editor_owner_kind='file'",
            "UPDATE conversations SET editor_document_id='\(uuid)'",
            "UPDATE conversations SET editor_owner_kind='unknown',editor_document_id='\(uuid)',editor_container_id='\(uuid)'"
        ] {
            #expect(throws: (any Error).self) { try queue.write { try $0.execute(sql: statement) } }
        }
        try queue.write { try $0.execute(sql: "UPDATE conversations SET editor_owner_kind='file',editor_document_id=?,editor_container_id=?", arguments: [uuid, uuid]) }
        #expect(throws: (any Error).self) { try queue.write { try $0.execute(sql: "UPDATE conversations SET purpose='notes'") } }
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 61)
        #expect(try queue.read { try String.fetchOne($0, sql: "SELECT content FROM messages WHERE id='message'") } == "v60 history")
    }
}
