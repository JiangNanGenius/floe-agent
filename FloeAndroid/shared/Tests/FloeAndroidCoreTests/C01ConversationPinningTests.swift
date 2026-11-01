// SPDX-License-Identifier: MPL-2.0
//
// C01 — durable conversation pinning (Android schema v50).
//
// Authored from the pinned iOS donor (Git object a59b4d40, V55ConversationPinning)
// against the REAL file-backed DatabaseManager/migrations and the REAL
// ConversationStore + FacadeConversationDomain. NOTHING here is a mock store:
// pins are asserted from the raw `conversations.pinned_at` column and from a
// reopened manager on the same file, and the facade tests go through the SAME
// frozen `conversation.archive` metadata envelope that the Android host uses.
//
// Coverage: migration/version alignment; pre-v50 rows decode unpinned; pin
// persistence across reopen; pin never touching `updated_at`; upsert never
// erasing a pin; actionable notFound/Notes refusals; pinned-first ordering,
// archive/unarchive preserving the pin while the normal view excludes it;
// facade CAS (success/stale/conflict/unknown payload) with zero effects on
// refusal; bounded keyset pagination over pinned rows; a pinned blank row is
// not "verified empty"; created conversations default to unpinned; search
// rows carry the durable pin state.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class C01ConversationPinningTests: XCTestCase {

    private func load(_ stores: RB3TestBed.Stores,
                      _ id: UUID) async throws -> ConversationRecord? {
        try await stores.conversations.conversation(id: id)
    }

    // MARK: - Migration

    func testMigrationV50IsRegisteredAndAligned() async throws {
        let stores = try await RB3TestBed.stores(name: #function)

        let version = try await stores.database.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(version, 50)

        let applied = try await stores.database.appliedMigrations()
        XCTAssertTrue(applied.contains("v49_user_questions"))
        XCTAssertTrue(applied.contains("v50_conversation_pinning"))

        let columns = try await stores.database.reader { db -> [String] in
            try Row.fetchAll(db, sql: "PRAGMA table_info(conversations)")
                .map { $0["name"] as String }
        }
        XCTAssertTrue(columns.contains("pinned_at"),
                      "v50 must add the durable pin column to conversations")
        try await stores.database.close()
    }

    func testPreV50RowDecodesUnpinnedWithMetadataUnchanged() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let legacyID = UUID()
        try await stores.database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations(id,title,created_at,updated_at,purpose)
                VALUES (?, 'Legacy chat', '2025-01-01T00:00:00.000Z',
                        '2025-01-02T00:00:00.000Z', 'ordinary')
                """, arguments: [legacyID.uuidString])
        }
        let maybeLegacy = try await load(stores, legacyID)
        let loaded = try XCTUnwrap(maybeLegacy)
        XCTAssertNil(loaded.pinnedAt)
        XCTAssertFalse(loaded.isPinned)
        XCTAssertEqual(loaded.title, "Legacy chat")
        XCTAssertEqual(loaded.purpose, .ordinary)
        try await stores.database.close()
    }

    // MARK: - Store write discipline

    func testPinPersistsAcrossReopenAndNeverMovesUpdatedAt() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let fixedUpdated = Date(timeIntervalSince1970: 1_760_100_000)
        let record = try await RB3TestBed.seedOrdinary(stores, title: "pin me",
                                                       updatedAt: fixedUpdated)
        let pin = Date(timeIntervalSince1970: 5_000)

        try await stores.conversations.setPinned(id: record.id, pinnedAt: pin)
        let firstMaybe = try await load(stores, record.id)
        let first = try XCTUnwrap(firstMaybe)
        XCTAssertEqual(first.pinnedAt, pin)
        XCTAssertEqual(first.updatedAt, fixedUpdated,
                       "a pin must not fake activity")

        let reopened = try await RB3TestBed.reopen(stores)
        let secondMaybe = try await reopened.conversations.conversation(id: record.id)
        let second = try XCTUnwrap(secondMaybe)
        XCTAssertEqual(second.pinnedAt, pin,
                       "the pin is on the durable row and survives a new manager")

        try await reopened.conversations.setPinned(id: record.id, pinnedAt: nil)
        let thirdMaybe = try await reopened.conversations.conversation(id: record.id)
        let third = try XCTUnwrap(thirdMaybe)
        XCTAssertNil(third.pinnedAt)
        XCTAssertEqual(third.updatedAt, fixedUpdated,
                       "unpin restores nothing but the pin value")
        try await reopened.database.close()
    }

    func testSaveConversationRoundTripsFirstInsertAndNeverErasesAPin() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let pin = Date(timeIntervalSince1970: 9_000)
        let record = ConversationRecord(
            id: UUID(), title: "first", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), pinnedAt: pin)
        try await stores.conversations.saveConversation(record)
        let insertedMaybe = try await load(stores, record.id)
        let inserted = try XCTUnwrap(insertedMaybe)
        XCTAssertEqual(inserted.pinnedAt, pin)

        var stale = record
        stale.title = "renamed later"
        stale.pinnedAt = nil
        try await stores.conversations.saveConversation(stale)
        let afterMaybe = try await load(stores, record.id)
        let after = try XCTUnwrap(afterMaybe)
        XCTAssertEqual(after.title, "renamed later")
        XCTAssertEqual(after.pinnedAt, pin,
                       "a reconstruction that did not load the pin cannot clear it")
        try await stores.database.close()
    }

    func testSetPinnedIsActionableForMissingAndNotesRows() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let missing = UUID()
        do {
            try await stores.conversations.setPinned(id: missing, pinnedAt: Date())
            XCTFail("a pin on a missing row must fail actionably")
        } catch FloeError.notFound(let reason) {
            XCTAssertTrue(reason.contains(missing.uuidString))
        }

        let notes = ConversationRecord(
            id: UUID(), title: "notes", createdAt: Date(), updatedAt: Date(),
            purpose: .notes)
        try await stores.conversations.saveConversation(notes)
        do {
            try await stores.conversations.setPinned(id: notes.id, pinnedAt: Date())
            XCTFail("Notes assistants must not be pinned")
        } catch is FloeError {
            // expected
        }
        let raw: String? = try await stores.database.reader { db in
            try String.fetchOne(db, sql: "SELECT pinned_at FROM conversations WHERE id = ?",
                                arguments: [notes.id.uuidString])
        }
        XCTAssertNil(raw, "the refused Notes pin wrote nothing")
        try await stores.database.close()
    }

    // MARK: - Ordering / archive

    func testPinnedFirstOrderingAndUnpinRestoresRecency() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let a = try await RB3TestBed.seedOrdinary(
            stores, title: "A", updatedAt: Date(timeIntervalSince1970: 100))
        let b = try await RB3TestBed.seedOrdinary(
            stores, title: "B", updatedAt: Date(timeIntervalSince1970: 300))
        let c = try await RB3TestBed.seedOrdinary(
            stores, title: "C", updatedAt: Date(timeIntervalSince1970: 200))

        var listed = try await stores.conversations.conversations()
        XCTAssertEqual(listed.map(\.id), [b.id, c.id, a.id],
                       "without pins the established recency order is unchanged")

        try await stores.conversations.setPinned(id: a.id,
                                                 pinnedAt: Date(timeIntervalSince1970: 400))
        listed = try await stores.conversations.conversations()
        XCTAssertEqual(listed.map(\.id), [a.id, b.id, c.id],
                       "an older pinned chat precedes fresher unpinned chats")

        try await stores.conversations.setPinned(id: c.id,
                                                 pinnedAt: Date(timeIntervalSince1970: 500))
        listed = try await stores.conversations.conversations()
        XCTAssertEqual(listed.map(\.id), [c.id, a.id, b.id],
                       "the most recently pinned row sorts first within the pinned group")

        try await stores.conversations.setPinned(id: c.id, pinnedAt: nil)
        listed = try await stores.conversations.conversations()
        XCTAssertEqual(listed.map(\.id), [a.id, b.id, c.id],
                       "unpin returns the row to the plain recency group")

        try await stores.conversations.setPinned(id: a.id, pinnedAt: nil)
        listed = try await stores.conversations.conversations()
        XCTAssertEqual(listed.map(\.id), [b.id, c.id, a.id])
        try await stores.database.close()
    }

    func testArchivePreservesPinAndExcludesRowFromTheNormalView() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let archived = try await RB3TestBed.seedOrdinary(
            stores, title: "Archived with pin", updatedAt: Date(timeIntervalSince1970: 100))
        let active = try await RB3TestBed.seedOrdinary(
            stores, title: "Active", updatedAt: Date(timeIntervalSince1970: 300))
        try await stores.conversations.setPinned(
            id: archived.id, pinnedAt: Date(timeIntervalSince1970: 200))

        try await stores.conversations.setArchived(id: archived.id, archived: true)
        let normal = try await stores.conversations.conversations()
        XCTAssertEqual(normal.map(\.id), [active.id],
                       "an archived row is excluded from the normal view")
        let withArchive = try await stores.conversations.conversations(includeArchived: true)
        let archivedRow = try XCTUnwrap(withArchive.first { $0.id == archived.id })
        XCTAssertNotNil(archivedRow.archivedAt)
        XCTAssertEqual(archivedRow.pinnedAt, Date(timeIntervalSince1970: 200),
                       "archive never clears the pin")

        try await stores.conversations.setArchived(id: archived.id, archived: false)
        let restoredMaybe = try await load(stores, archived.id)
        let restored = try XCTUnwrap(restoredMaybe)
        XCTAssertNil(restored.archivedAt)
        XCTAssertEqual(restored.pinnedAt, Date(timeIntervalSince1970: 200),
                       "unarchive preserves the pin")
        let afterRestore = try await stores.conversations.conversations()
        XCTAssertEqual(afterRestore.map(\.id), [archived.id, active.id],
                       "the restored pinned row leads the normal view again")
        try await stores.database.close()
    }

    func testPinnedBlankRowIsNotVerifiedEmptyForTemporaryConversion() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let blank = try await RB3TestBed.seedOrdinary(stores, title: "")
        try await stores.conversations.setPinned(id: blank.id,
                                                 pinnedAt: Date(timeIntervalSince1970: 10))
        let removedPinned = try await stores.conversations
            .deleteConversationIfVerifiedEmpty(id: blank.id)
        XCTAssertFalse(removedPinned, "a pinned row is explicit user metadata")
        let stillThere = try await load(stores, blank.id)
        XCTAssertNotNil(stillThere)

        try await stores.conversations.setPinned(id: blank.id, pinnedAt: nil)
        let removed = try await stores.conversations
            .deleteConversationIfVerifiedEmpty(id: blank.id)
        XCTAssertTrue(removed, "an unpinned blank ordinary row keeps the old contract")
        let gone = try await load(stores, blank.id)
        XCTAssertNil(gone)
        try await stores.database.close()
    }

    // MARK: - Facade metadata CAS through the existing archive envelope

    func testFacadePinCASThroughArchiveEnvelopeAndTypedRefusals() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let fixed = Date(timeIntervalSince1970: 700)
        let domain = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           clock: { fixed }).domain
        let record = try await RB3TestBed.seedOrdinary(
            stores, title: "CAS pin", updatedAt: Date(timeIntervalSince1970: 42))
        var revision = try await RB3TestBed.revision(stores.database, record.id)

        let pinned = try await domain.archive(
            conversationID: record.id, revision: revision,
            payload: .object(["pinned": .boolean(true)]))
        XCTAssertNotEqual(pinned.revision, revision.version)
        XCTAssertEqual(pinned.resourceID, revision.resourceID)
        revision = BaseRevision(resourceID: pinned.resourceID, version: pinned.revision)

        let raw = try await stores.database.reader { db -> (String?, String) in
            let row = try Row.fetchOne(
                db, sql: "SELECT pinned_at, updated_at FROM conversations WHERE id = ?",
                arguments: [record.id.uuidString])
            guard let row else { throw FloeError.notFound("row") }
            let pinnedRaw: String? = row["pinned_at"]
            let updatedRaw: String = row["updated_at"]
            return (pinnedRaw, updatedRaw)
        }
        XCTAssertEqual(raw.0, ConversationWireDate.encode(fixed))
        XCTAssertEqual(raw.1, ConversationWireDate.encode(Date(timeIntervalSince1970: 42)),
                       "pin writes ONLY pinned_at")

        // Stale CAS: zero effect.
        do {
            _ = try await domain.archive(
                conversationID: record.id,
                revision: BaseRevision(resourceID: revision.resourceID,
                                       version: "sha256:" + String(repeating: "0", count: 64)),
                payload: .object(["pinned": .boolean(false)]))
            XCTFail("a stale pin must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "staleRevision")
        }
        let stillPinnedMaybe = try await load(stores, record.id)
        let stillPinned = try XCTUnwrap(stillPinnedMaybe)
        XCTAssertNotNil(stillPinned.pinnedAt)
        XCTAssertEqual(stillPinned.title, "CAS pin")

        // Mixed/non-boolean payloads are refused before any read/write.
        do {
            _ = try await domain.archive(
                conversationID: record.id, revision: revision,
                payload: .object(["archived": .boolean(true), "pinned": .boolean(true)]))
            XCTFail("mixed metadata mutation must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }
        do {
            _ = try await domain.archive(
                conversationID: record.id, revision: revision,
                payload: .object(["pinned": .string("yes")]))
            XCTFail("non-boolean pin must be refused")
        } catch let error as ConversationDomainError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
        }

        // Unpin with the CURRENT revision.
        _ = try await domain.archive(
            conversationID: record.id, revision: revision,
            payload: .object(["pinned": .boolean(false)]))
        let clearedMaybe = try await load(stores, record.id)
        let cleared = try XCTUnwrap(clearedMaybe)
        XCTAssertNil(cleared.pinnedAt)
        XCTAssertEqual(cleared.updatedAt, Date(timeIntervalSince1970: 42))
        try await stores.database.close()
    }

    func testFacadeListPaginationWalksPinnedFirstWithoutDuplicates() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let domain = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           clock: { Date() }).domain
        var seeded: [UUID] = []
        for index in 0..<7 {
            let record = try await RB3TestBed.seedOrdinary(
                stores, title: "Task \(index)",
                updatedAt: Date(timeIntervalSince1970: 1_000 + Double(index)))
            seeded.append(record.id)
        }
        try await stores.conversations.setPinned(id: seeded[0],
                                                 pinnedAt: Date(timeIntervalSince1970: 200))
        try await stores.conversations.setPinned(id: seeded[3],
                                                 pinnedAt: Date(timeIntervalSince1970: 300))

        var collected: [UUID] = []
        var cursor: String? = nil
        var pages = 0
        while true {
            var payload: [String: SettingsDomainV1.JSONValue] = [
                "includeArchived": .boolean(false),
                "limit": .integer(2),
            ]
            if let cursor { payload["cursor"] = .string(cursor) }
            let reply = try await domain.list(payload: .object(payload))
            pages += 1
            XCTAssertLessThanOrEqual(reply.rows.count, 2)
            collected.append(contentsOf: reply.rows.map(\.conversationID))
            if !reply.hasMore {
                XCTAssertNil(reply.nextCursor)
                break
            }
            cursor = try XCTUnwrap(reply.nextCursor)
            XCTAssertLessThanOrEqual(pages, 8, "cursor must make progress")
        }
        XCTAssertEqual(pages, 4)
        XCTAssertEqual(Set(collected).count, collected.count, "no duplicate rows")
        XCTAssertEqual(Set(collected), Set(seeded))

        let storeRows = try await stores.conversations.conversations()
        let storeOrder = storeRows.map(\.id)
        XCTAssertEqual(collected, storeOrder,
                       "the bounded page walk preserves the pinned-first store order")
        XCTAssertEqual(Set(collected.prefix(2)), Set([seeded[3], seeded[0]]),
                       "pinned rows lead both the store and every page walk")
        try await stores.database.close()
    }

    func testFacadeCreateDefaultsUnpinnedAndSearchRowsCarryPin() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let domain = RB3TestBed.makeDomain(stores: stores, lifecycle: nil,
                                           clock: { Date() }).domain

        let created = try await domain.create(payload: nil)
        let createdMaybe = try await load(stores, created.conversationID)
        let createdRow = try XCTUnwrap(createdMaybe)
        XCTAssertNil(createdRow.pinnedAt, "a new ordinary chat starts unpinned")

        let record = try await RB3TestBed.seedOrdinary(
            stores, title: "Search me", updatedAt: Date(timeIntervalSince1970: 10))
        _ = try await RB3TestBed.seedMessage(stores, conversationID: record.id,
                                             content: "durable pinneedle body")
        try await stores.conversations.setPinned(id: record.id,
                                                 pinnedAt: Date(timeIntervalSince1970: 20))

        let reply = try await domain.search(
            payload: .object(["query": .string("pinneedle"), "limit": .integer(10)]))
        let pinnedHit = try XCTUnwrap(reply.rows.first { $0.conversationID == record.id })
        XCTAssertTrue(pinnedHit.pinned)

        try await stores.conversations.setPinned(id: record.id, pinnedAt: nil)
        let unpinnedReply = try await domain.search(
            payload: .object(["query": .string("pinneedle"), "limit": .integer(10)]))
        let unpinnedHit = try XCTUnwrap(
            unpinnedReply.rows.first { $0.conversationID == record.id })
        XCTAssertFalse(unpinnedHit.pinned)
        try await stores.database.close()
    }
}
