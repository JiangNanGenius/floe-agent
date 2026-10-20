// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P2 memory adapter (SOURCE ONLY — not
// executed by the authoring job; no assertion may be weakened to make a
// candidate pass; failures observed during later compilation/tests must be
// recorded honestly). Vectors follow behavioralTestDesign positives/negatives
// for memory.* (P2 checklist). Test doubles are synthetic ONLY.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadeMemoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var url: URL!
    private var intelligence: SQLiteIntelligenceStore!
    private var workspaces: SQLiteWorkspaceStore!
    private var conversations: SQLiteConversationStore!
    private var adapter: FacadeMemoryAdapter!

    override func setUp() async throws {
        let made = try await IntelligenceTestSupport.makeDatabase("mem-\(UUID().uuidString.prefix(8))")
        manager = made.0
        url = made.1
        intelligence = SQLiteIntelligenceStore(database: manager)
        workspaces = SQLiteWorkspaceStore(database: manager)
        conversations = SQLiteConversationStore(database: manager)
        adapter = FacadeMemoryAdapter(database: manager, intelligenceStore: intelligence,
                                      workspaceStore: workspaces,
                                      conversationStore: conversations)
    }

    override func tearDown() async throws {
        IntelligenceTestSupport.cleanup(url)
    }

    private func wireScopeUser() throws -> SettingsDomainV1.MemoryScope {
        try SettingsDomainV1.MemoryScope(kind: .user)
    }

    private func listRequest(scope: SettingsDomainV1.MemoryScope? = nil,
                             status: SettingsDomainV1.MemoryEntryStatus? = nil,
                             cursor: Int = 0, limit: Int = 50) throws
        -> MemoryListWireRequest
    {
        MemoryListWireRequest(scope: scope, status: status, cursor: cursor, limit: limit)
    }

    // MARK: - List/get equivalence + digests

    func testListEquivalenceAgainstOriginalProjection() async throws {
        // 120 seeded entries (bounded fixture), limit 50 → 3 pages, stable
        // ordering, nextCursor chain exhausts exactly once; every entry
        // carries the same-transaction 23-column digest.
        for index in 0..<120 {
            _ = try await IntelligenceTestSupport.seedMemory(
                manager, content: "fact number \(index)",
                importance: Double(index % 7) / 10.0,
                isPinned: index % 11 == 0,
                id: UUID())
        }
        let scope = try wireScopeUser()
        var cursor: Int? = 0
        var collected: [SettingsDomainV1.MemoryEntry] = []
        var pages = 0
        while let offset = cursor {
            let reply = try await adapter.list(try listRequest(scope: scope,
                                                               status: .active,
                                                               cursor: offset,
                                                               limit: 50))
            pages += 1
            for entry in reply.entries {
                let recomputed = try await XCTUnwrapAsync(
                    await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
                XCTAssertEqual(entry.revision, recomputed,
                               "digest must equal the in-transaction full-row digest")
            }
            collected.append(contentsOf: reply.entries)
            if let next = reply.nextCursor { cursor = Int(next) } else { cursor = nil }
            XCTAssertLessThanOrEqual(pages, 3, "SQL page + budget stop must not exceed 3 pages at limit 50")
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(Set(collected.map(\.id)).count, 120)
        // Ordering parity with the original listMemories page concatenation.
        let original = try await intelligence.listMemories(
            MemoryListRequest(scope: nil, status: MemoryEntryStatus.active,
                              cursor: nil, limit: 500))
        XCTAssertEqual(collected.map(\.id), original.entries.map(\.id),
                       "mirrored SQL/ordering must equal the original projection")
    }

    func testGetEquivalenceFullRowDigest() async throws {
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "  Mixed CASE fact  ", importance: 0.42)
        let dto = try await adapter.get(id: entry.id)
        XCTAssertEqual(dto.content, entry.content) // store value verbatim
        let recomputed = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        XCTAssertEqual(dto.revision, recomputed)
        XCTAssertEqual(dto.ownership.recallCount, 0)
        XCTAssertNil(dto.ownership.ownerDeletedAt)
    }

    func testDTOReflectsDetachedOwnershipColumns() async throws {
        // task-scoped rows carry the ORIGINAL FK to conversations(id): use a
        // real conversation row, then detach it exactly like the preserve path.
        let taskID = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, scope: .task(taskID), content: "task-bound fact")
        try await intelligence.preserveMemoriesBeforeConversationDeletion(
            conversationID: taskID, ownerLabel: "Old Chat")
        let dto = try await adapter.get(id: entry.id)
        XCTAssertNotNil(dto.ownership.ownerDeletedAt,
                        "V21 detach state must be surfaced honestly")
        XCTAssertNotNil(dto.ownership.retainedUntil)
        XCTAssertEqual(dto.ownership.originOwnerLabel, "Old Chat")
    }

    func testSyncRevisionColumnStaysZeroAndNeverWireWritable() async throws {
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "vestigial sync column")
        let digest = try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        let updated = try await adapter.update(expectedRevision: digest,
                                               request: MemoryUpdateRequest(id: entry.id,
                                                                            importance: 0.9))
        XCTAssertEqual(updated.entry.revision.count, 71)
        let rawValue = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT sync_revision FROM memory_entries WHERE id = ?",
                               arguments: [entry.id.uuidString])
        }
        XCTAssertEqual(rawValue, 0, "the adapter must never write the vestigial column")
    }

    // MARK: - Canonical digest vectors on memory domains

    func testDigestNullVsLiteralVsEmpty() async throws {
        // Four rows differing only in expires_at storage: SQL NULL, text
        // 'NULL', text '<null>', empty text — four distinct digests.
        var ids: [UUID] = []
        for content in ["alpha one", "alpha two", "alpha three", "alpha four"] {
            let seeded = try await IntelligenceTestSupport.seedMemory(
                manager, content: content)
            ids.append(seeded.id)
        }
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET expires_at = ? WHERE id = ?",
            ["NULL", ids[1].uuidString])
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET expires_at = ? WHERE id = ?",
            ["<null>", ids[2].uuidString])
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET expires_at = ? WHERE id = ?",
            ["", ids[3].uuidString])
        let digests = try await ids.mapAsync { try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: $0)) }
        XCTAssertEqual(Set(digests).count, 4,
                       "NULL vs 'NULL' vs '<null>' vs '' must not collide (digest.nullVsLiteral)")
        // The DTO timestamps pass the raw text through unchanged.
        let empty = try await adapter.get(id: ids[3])
        XCTAssertEqual(empty.expiresAt, "")
        let literal = try await adapter.get(id: ids[1])
        XCTAssertEqual(literal.expiresAt, "NULL")
    }

    func testDigestDelimiterBytesAndTypes() async throws {
        // 'a\u{1F}b' vs 'a|b' vs 'a:b' → distinct digests (length-prefixed
        // bytes; no delimiter collision).
        let separator = try await IntelligenceTestSupport.seedMemory(
            manager, content: "a\u{1F}b", sourceKind: .automaticTurnReview)
        let pipe = try await IntelligenceTestSupport.seedMemory(
            manager, content: "a|b", sourceKind: .automaticTurnReview)
        let colon = try await IntelligenceTestSupport.seedMemory(
            manager, content: "a:b", sourceKind: .automaticTurnReview)
        let digests = [
            try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: separator.id)),
            try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: pipe.id)),
            try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: colon.id)),
        ]
        XCTAssertEqual(Set(digests).count, 3)
        // Fixed-order sensitivity: identical fields in different column
        // order change the digest (unit vector against the P0 encoder).
        let one = SettingsDomainV1.CanonicalDigest.rowToken(
            domain: SettingsDomainV1.CanonicalDigest.domainMemoryEntry,
            fields: [.text("x"), .text("y")])
        let two = SettingsDomainV1.CanonicalDigest.rowToken(
            domain: SettingsDomainV1.CanonicalDigest.domainMemoryEntry,
            fields: [.text("y"), .text("x")])
        XCTAssertNotEqual(one, two)
        // INTEGER 1 vs REAL 1.0 vs TEXT '1' distinct; -0.0 vs +0.0 distinct.
        let i1 = SettingsDomainV1.CanonicalDigest.fieldBytes(.integer(1))
        let r1 = SettingsDomainV1.CanonicalDigest.fieldBytes(.real(1.0))
        let t1 = SettingsDomainV1.CanonicalDigest.fieldBytes(.text("1"))
        XCTAssertEqual(Set([i1, r1, t1].map { $0.base64EncodedString() }).count, 3)
        let negZero = SettingsDomainV1.CanonicalDigest.fieldBytes(.real(-0.0))
        let posZero = SettingsDomainV1.CanonicalDigest.fieldBytes(.real(0.0))
        XCTAssertNotEqual(negZero, posZero)
        // Int64 min/max encoded exactly.
        let minimum = SettingsDomainV1.CanonicalDigest.fieldBytes(.integer(Int64.min))
        XCTAssertEqual(minimum.count, 9)
    }

    func testDigestCJKEmojiAndEmbeddedNulByteExact() async throws {
        // Native store binding: GRDB binds Swift String with length -1, so an
        // embedded NUL terminates the stored TEXT at the ORIGINAL layer. The
        // adapter must not "fix" that (it would diverge from the native
        // digest); it must surface the stored truth and stay digest-stable.
        let nulEntry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "中文表情😀\u{0}嵌入", sourceKind: .automaticTurnReview)
        let first = try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: nulEntry.id))
        let again = try await XCTUnwrapAsync(await IntelligenceTestSupport.memoryDigest(manager, id: nulEntry.id))
        XCTAssertEqual(first, again)
        let nulDTO = try await adapter.get(id: nulEntry.id)
        XCTAssertEqual(nulDTO.content, "中文表情😀",
                       "stored truth: the original SQLite binding terminates at NUL")
        // A NON-NUL control scalar is preserved byte-exactly (CJK + emoji +
        // U+0001): no normalization happens in the adapter.
        let controlEntry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "中文表情😀\u{1}嵌入", sourceKind: .automaticTurnReview)
        let controlDTO = try await adapter.get(id: controlEntry.id)
        XCTAssertEqual(controlDTO.content, "中文表情😀\u{1}嵌入",
                       "content passes raw stored text, no normalization")
    }

    // MARK: - add

    func testAddStoresNativeConstants() async throws {
        let reply = try await adapter.add(MemoryAddRequest(
            content: "  Preferred Editor: VS Code  ",
            scope: try wireScopeUser()))
        XCTAssertEqual(reply.status, .added)
        let entry = try XCTUnwrap(reply.entry)
        XCTAssertEqual(entry.content, "  Preferred Editor: VS Code  ")
        XCTAssertEqual(entry.confidence, 1)
        XCTAssertEqual(entry.importance, 0.8)
        XCTAssertTrue(entry.isPinned)
        XCTAssertEqual(entry.status, .active)
        XCTAssertEqual(entry.sourceKind, .explicitUserRequest)
        // Manual created realID only after commit: the effect digest was
        // recomputed from the committed row.
        let recomputed = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        XCTAssertEqual(entry.revision, recomputed)
        // Second-precision ISO timestamps written like the original store.
        XCTAssertEqual(entry.updatedAt.count, 20)
    }

    func testAddDuplicateScanReturnsExisting() async throws {
        _ = try await adapter.add(MemoryAddRequest(content: "Stable fact",
                                                  scope: try wireScopeUser()))
        let reply = try await adapter.add(MemoryAddRequest(content: " stable FACT ",
                                                           scope: try wireScopeUser()))
        XCTAssertEqual(reply.status, .duplicate)
        XCTAssertNotNil(reply.existingID)
        XCTAssertNil(reply.entry)
    }

    func testAddUniqueConvergenceWithSupersededTwin() async throws {
        // Pre-seed a SUPERSEDED row with identical normalized content: the
        // active-only pre-check does not see it, but the V21 UNIQUE index
        // still covers it — the INSERT violates and the adapter converges
        // on the real existing id (contract: re-query scope+normalized).
        let twin = try await IntelligenceTestSupport.seedMemory(
            manager, status: .superseded, content: "Race Fact",
            sourceKind: .automaticTurnReview)
        let reply = try await adapter.add(MemoryAddRequest(content: "race fact",
                                                           scope: try wireScopeUser()))
        XCTAssertEqual(reply.status, .duplicate)
        XCTAssertEqual(reply.existingID, twin.id)
    }

    func testAddOversizeRejectedBeforeMutation() async throws {
        let big = String(repeating: "字", count: 4_097)
        do {
            _ = try await adapter.add(MemoryAddRequest(content: big,
                                                       scope: try wireScopeUser()))
            XCTFail("oversize add must fail typed")
        } catch let error as MemoryAdapterError {
            guard case .payloadTooLarge(let maxChars) = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertEqual(maxChars, 4_096)
        }
        let count = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries")
        }
        XCTAssertEqual(count, 0, "no silent prefix clamp; nothing stored")
    }

    func testAddSecretLikeRejected() async throws {
        do {
            _ = try await adapter.add(MemoryAddRequest(
                content: "config: api_key=sk-abcdefghijklmnop",
                scope: try wireScopeUser()))
            XCTFail("secret-like content must be rejected")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "memoryRejected:secretLike")
        }
        let count = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries")
        }
        XCTAssertEqual(count, 0)
    }

    func testAddMissingScopeNeverFallsBackToUserGlobal() async throws {
        let missingWorkspace = UUID()
        let scope = try SettingsDomainV1.MemoryScope(kind: .workspace,
                                                     workspaceID: missingWorkspace)
        do {
            _ = try await adapter.add(MemoryAddRequest(content: "orphan scope fact",
                                                       scope: scope))
            XCTFail("missing requested scope must fail")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "notFound")
            XCTAssertEqual(error.wireReason, "workspaceMissing")
        }
        let count = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries")
        }
        XCTAssertEqual(count, 0, "NEVER user-global or first-project fallback")
    }

    // MARK: - update CAS

    func testUpdateColumnSetPreservesNonWritableColumns() async throws {
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "durable before", importance: 0.3)
        let beforeFields = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryFields(manager, id: entry.id))
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        // The native write format is SECOND-precision ISO-8601
        // (IntelligenceStore :1585); wait past one second so the real
        // updated_at bump is observable rather than a same-second collision.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let updated = try await adapter.update(
            expectedRevision: digest,
            request: MemoryUpdateRequest(id: entry.id, importance: 0.75))
        XCTAssertEqual(updated.entry.importance, 0.75)
        let afterFields = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryFields(manager, id: entry.id))
        // Preserved by construction (contract preservedColumns): compare the
        // canonical DatabaseValue-derived fields per column index — exact
        // storage-class equality, not a text projection.
        let preservedIndices: [(String, Int)] = [
            ("scope", 0), ("workspace_id", 1), ("conversation_id", 13),
            ("origin_workspace_id", 14), ("origin_conversation_id", 15),
            ("origin_owner_label", 16), ("owner_deleted_at", 17),
            ("last_recalled_at", 18), ("retained_until", 19),
            ("recall_count", 20), ("source_kind", 8), ("created_at", 11),
            ("sync_revision", 10), ("status", 2), ("confidence", 5),
            ("normalized_content", 4),
        ]
        for (name, index) in preservedIndices {
            XCTAssertEqual(
                SettingsDomainV1.CanonicalDigest.fieldBytes(beforeFields[index]),
                SettingsDomainV1.CanonicalDigest.fieldBytes(afterFields[index]),
                "column \(name) must be byte-identical (never wire-writable here)")
        }
        XCTAssertEqual(
            SettingsDomainV1.CanonicalDigest.fieldBytes(afterFields[10]),
            SettingsDomainV1.CanonicalDigest.fieldBytes(.integer(0)),
            "the vestigial sync_revision stays 0")
        XCTAssertEqual(afterFields[3], .text("durable before"))
        XCTAssertNotEqual(beforeFields[12], afterFields[12],
                          "updated_at is the one bumped timestamp column")
    }

    func testUpdateStaleOnDetachWithoutUpdatedAtBump() async throws {
        let workspaceID = try await IntelligenceTestSupport.seedWorkspace(manager)
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, scope: .workspace(workspaceID), content: "owned fact")
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        let beforeUpdated = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryRawFields(manager, id: entry.id))["updated_at"]
        // ORIGINAL detach path — no updated_at bump.
        try await intelligence.preserveMemoriesBeforeWorkspaceDeletion(
            workspaceID: workspaceID, ownerLabel: "gone-workspace")
        let afterUpdated = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryRawFields(manager, id: entry.id))["updated_at"]
        XCTAssertEqual(beforeUpdated, afterUpdated,
                       "detach intentionally preserves the stored second")
        do {
            _ = try await adapter.update(
                expectedRevision: digest,
                request: MemoryUpdateRequest(id: entry.id, isPinned: true))
            XCTFail("detach must invalidate the digest")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(let stale, _) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(stale, [entry.id])
        }
    }

    func testUpdateStaleOnRecallReinforcement() async throws {
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "reinforce me badly", importance: 0.5)
        let digest = try await adapter.list(try listRequest(status: .active))
        let target = try XCTUnwrap(digest.entries.first)
        // The facade's OWN search reinforces (mutating read).
        _ = try await adapter.search(MemorySearchWireRequest(
            query: "reinforce badly", limit: 20))
        do {
            _ = try await adapter.update(
                expectedRevision: target.revision,
                request: MemoryUpdateRequest(id: target.id, isPinned: true))
            XCTFail("reinforce must invalidate the outstanding digest")
        } catch is MemoryAdapterError {
            // staleRevision — recall_count/importance/last_recalled_at all
            // inside the 23-column digest.
        }
    }

    func testUpdateSameValueSameSecondIsDigestStableNoOp() async throws {
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "noop parity", importance: 0.4)
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        let first = try await adapter.update(expectedRevision: digest,
                                             request: MemoryUpdateRequest(id: entry.id,
                                                                          importance: 0.4))
        let second = try await adapter.update(expectedRevision: digest,
                                              request: MemoryUpdateRequest(id: entry.id,
                                                                           importance: 0.4))
        // Two identical-value writes in the same stored second: the digest
        // does not change, so the old token still matches — the contract's
        // documented semantic no-op (no false-positive stale).
        XCTAssertEqual(first.entry.revision, second.entry.revision)
    }

    func testUpdateStatusSubsetClosed() async throws {
        // The wire enum MemoryUpdateStatus only admits active|superseded;
        // pending/rejected are not constructible (Q2 closed subset).
        XCTAssertNil(SettingsDomainV1.MemoryUpdateStatus(rawValue: "pending"))
        XCTAssertNotNil(SettingsDomainV1.MemoryUpdateStatus(rawValue: "superseded"))
    }

    func testUpdateUniqueCollisionTyped() async throws {
        _ = try await IntelligenceTestSupport.seedMemory(manager, content: "sibling fact")
        let other = try await IntelligenceTestSupport.seedMemory(
            manager, content: "to change", importance: 0.2)
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: other.id))
        do {
            _ = try await adapter.update(
                expectedRevision: digest,
                request: MemoryUpdateRequest(id: other.id, content: "SIBLING FACT"))
            XCTFail("content must collide with the sibling UNIQUE index")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "invalidEnvelope")
            XCTAssertEqual(error.wireReason, "memoryDuplicateContent")
        }
        // Nothing written.
        let unchanged = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: other.id))
        XCTAssertEqual(unchanged, digest)
    }

    func testUpdateMissingAndStaleTokenShapes() async throws {
        let missingID = UUID()
        do {
            _ = try await adapter.update(
                expectedRevision: "sha256:" + String(repeating: "0", count: 64),
                request: MemoryUpdateRequest(id: missingID, isPinned: true))
            XCTFail("missing id must be notFound memoryMissing")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "notFound")
            XCTAssertEqual(error.wireReason, "memoryMissing")
        }
    }

    // MARK: - delete + tombstone

    func testDeleteTombstoneOrderingAndCascade() async throws {
        let entry = try await IntelligenceTestSupport.seedMemory(
            manager, content: "expire away")
        // A real embedding row for the FK cascade assertion (store-internal
        // blob never crosses the wire).
        try await manager.writer { db in
            var values: [Float] = [1, 2, 3]
            let blob = values.withUnsafeMutableBytes { Data($0) }
            try db.execute(sql: """
                INSERT INTO memory_embeddings (memory_id, modality, model_identifier,
                    model_revision, dimensions, vector_blob, content_digest, created_at)
                VALUES (?, 'text', 'synthetic', 'rev0', 3, ?, 'digest', ?)
                """, arguments: [entry.id.uuidString, blob,
                                 FacadeStoreTime.second(Date())])
        }
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: entry.id))
        let reply = try await adapter.delete(expectedRevision: digest, id: entry.id)
        XCTAssertTrue(reply.deleted)
        XCTAssertTrue(reply.tombstoned)
        let remaining = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [entry.id.uuidString])
        }
        XCTAssertEqual(remaining, 0)
        let cascaded = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embeddings WHERE memory_id = ?",
                               arguments: [entry.id.uuidString])
        }
        XCTAssertEqual(cascaded, 0, "embeddings cascade via the original FK")
        let tombstoneRevision: Int64? = try await manager.reader { db -> Int64? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT deleted_at, sync_revision FROM memory_tombstones WHERE memory_id = ?
                """, arguments: [entry.id.uuidString]) else { return nil }
            let value: DatabaseValue = row["sync_revision"]
            if case .int64(let raw) = value.storage { return raw }
            return nil
        }
        XCTAssertNotNil(tombstoneRevision, "the delete wrote its tombstone row")
        let revision: Int64 = try XCTUnwrap(tombstoneRevision)
        let nowMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        XCTAssertLessThan(abs(nowMillis - revision), 5 * 60 * 1_000,
                          "tombstone ordering value is wall-clock ms (documented wire choice), never a precondition")
        // Late retry with the OLD digest → typed notFound (idempotent signal).
        do {
            _ = try await adapter.delete(expectedRevision: digest, id: entry.id)
            XCTFail("late retry must surface typed notFound")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "notFound")
            XCTAssertEqual(error.wireReason, "memoryMissing")
        }
    }

    // MARK: - bulk

    func testBulkIdempotentLedgerReplay() async throws {
        let first = try await IntelligenceTestSupport.seedMemory(manager, content: "bulk one")
        let second = try await IntelligenceTestSupport.seedMemory(manager, content: "bulk two")
        let batchID = UUID()
        let sync = Int64(Date().timeIntervalSince1970 * 1_000)
        let items = [
            MemoryBulkDeleteRequest.Item(id: first.id,
                                         expectedDigest: try await XCTUnwrapAsync(
                                            await IntelligenceTestSupport.memoryDigest(manager, id: first.id))),
            MemoryBulkDeleteRequest.Item(id: second.id,
                                         expectedDigest: try await XCTUnwrapAsync(
                                            await IntelligenceTestSupport.memoryDigest(manager, id: second.id))),
        ]
        let applied = try await adapter.deleteBulk(
            MemoryBulkDeleteRequest(batchID: batchID, items: items, syncRevision: sync))
        XCTAssertEqual(applied.result, .applied)
        XCTAssertEqual(applied.deletedCount, 2)
        let replay = try await adapter.deleteBulk(
            MemoryBulkDeleteRequest(batchID: batchID, items: items, syncRevision: sync))
        XCTAssertEqual(replay.result, .alreadyApplied)
        XCTAssertEqual(replay.deletedCount, 2, "stored ledger counts, zero re-application")
        XCTAssertEqual(replay.appliedCount, 2)
        let ledgerRows = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_maintenance_batches WHERE id = ?",
                               arguments: [batchID.uuidString])
        }
        XCTAssertEqual(ledgerRows, 1)
    }

    func testBulkAllOrNothingStaleIDs() async throws {
        let ok = try await IntelligenceTestSupport.seedMemory(manager, content: "fine")
        let stale = try await IntelligenceTestSupport.seedMemory(manager, content: "moving target")
        _ = try await adapter.update(
            expectedRevision: try await XCTUnwrapAsync(
                await IntelligenceTestSupport.memoryDigest(manager, id: stale.id)),
            request: MemoryUpdateRequest(id: stale.id, isPinned: true))
        let items = [
            MemoryBulkDeleteRequest.Item(id: ok.id,
                                         expectedDigest: try await XCTUnwrapAsync(
                                            await IntelligenceTestSupport.memoryDigest(manager, id: ok.id))),
            MemoryBulkDeleteRequest.Item(id: stale.id,
                                         expectedDigest: "sha256:" + String(repeating: "a", count: 64)),
        ]
        do {
            _ = try await adapter.deleteBulk(MemoryBulkDeleteRequest(
                batchID: UUID(), items: items, syncRevision: 1))
            XCTFail("stale digest must reject the whole batch")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(let staleIDs, _) = error else {
                return XCTFail("expected staleRevision with staleIDs, got \(error)")
            }
            XCTAssertEqual(staleIDs, [stale.id])
        }
        // ZERO deletions, no ledger row.
        let remaining = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries")
        }
        XCTAssertEqual(remaining, 2)
        let ledger = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_maintenance_batches")
        }
        XCTAssertEqual(ledger, 0)
    }

    func testBulkMissingIDsTyped() async throws {
        let ghost = UUID()
        let items = [MemoryBulkDeleteRequest.Item(
            id: ghost, expectedDigest: "sha256:" + String(repeating: "b", count: 64))]
        do {
            _ = try await adapter.deleteBulk(MemoryBulkDeleteRequest(
                batchID: UUID(), items: items, syncRevision: 1))
            XCTFail("missing id must be typed")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "notFound")
            XCTAssertEqual(error.wireReason, "memoryMissing")
            XCTAssertEqual(error.wireDetailArrays["missingIDs"], [ghost.uuidString])
        }
    }

    // MARK: - search (mutating read, bounded pages, honest effects)

    func testSearchRecallRunsOnceRankingStablePerDigests() async throws {
        for index in 0..<22 {
            _ = try await IntelligenceTestSupport.seedMemory(
                manager, content: "quantum widget calibration note \(index)",
                importance: 0.3)
        }
        let first = try await adapter.search(MemorySearchWireRequest(
            query: "quantum widget calibration", limit: 20))
        XCTAssertFalse(first.items.isEmpty)
        XCTAssertFalse(first.semantic)
        XCTAssertNil(first.sideEffects.reinforcedCount,
                     "original API returns no per-item count; never fabricated")
        XCTAssertTrue(first.sideEffects.lifecycleMaintained)
        XCTAssertTrue(first.sideEffects.reinforcementPathExecuted)
        let handle = try XCTUnwrap(first.searchHandle)
        // Snapshot recall_count NOW; continuation must not reinforce again.
        let countsAfterFirst = await recallCounts()
        let second = try await adapter.search(MemorySearchWireRequest(
            query: "quantum widget calibration", handle: handle,
            cursor: first.items.count))
        // Continuation reads the SAME ranked snapshot and NEVER re-ranks or
        // re-runs recall: it may be empty when the first page consumed the
        // bounded recall set, or contain only the remaining suffix ids.
        if !second.items.isEmpty {
            let firstIDs = Set(first.items.map(\.id))
            XCTAssertTrue(second.items.allSatisfy { !firstIDs.contains($0.id) },
                          "a continuation never repeats a ranked id")
        }
        XCTAssertFalse(second.semantic)
        let countsAfterSecond = await recallCounts()
        XCTAssertEqual(countsAfterFirst, countsAfterSecond,
                       "continuation pages NEVER re-run recall/reinforce")
        // Fresh digests: a content edit after the first page must show up
        // on the continuation page (current row projection), not the old
        // recall projection token.
        if let target = first.items.first, let current = target.current {
            try await IntelligenceTestSupport.rawMemoryUpdate(
                manager,
                "UPDATE memory_entries SET content = ?, normalized_content = ? WHERE id = ?",
                ["quantum widget calibration EDITED",
                 "quantum widget calibration edited", target.id.uuidString])
            let page = try await adapter.search(MemorySearchWireRequest(
                query: "quantum widget calibration", handle: handle, cursor: 0))
            let fresh = try XCTUnwrap(page.items.first?.current)
            XCTAssertNotEqual(fresh.revision, current.revision,
                              "edit/delete must render current + current digest")
        }
    }

    func testSearchDeletedBetweenRecallAndBatchedRead() async throws {
        let doomed = try await IntelligenceTestSupport.seedMemory(
            manager, content: "vanishing token search")
        // Directly run a recall over a snapshot we then mutate: emulate by
        // deleting before the FIRST page completes is impossible inside one
        // actor; instead assert the codec path: an id absent in the batched
        // read yields current=null/deleted=true and no edit offer.
        _ = doomed
        let raw = try await adapter.search(MemorySearchWireRequest(
            query: "vanishing token search", limit: 20))
        if let item = raw.items.first(where: { $0.id == doomed.id }) {
            XCTAssertFalse(item.deleted)
            XCTAssertNotNil(item.current)
        }
        // Remove the row and force a continuation page over the stored
        // ranking (handle exists even when exhausted).
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: doomed.id))
        _ = try await adapter.delete(expectedRevision: digest, id: doomed.id)
        let handle = try XCTUnwrap(raw.searchHandle)
        let after = try await adapter.search(MemorySearchWireRequest(
            query: "vanishing token search", handle: handle, cursor: 0))
        if let item = after.items.first(where: { $0.id == doomed.id }) {
            XCTAssertTrue(item.deleted)
            XCTAssertNil(item.current, "no fabricated projection for a vanished row")
        }
    }

    func testSearchHandleUnknownAndExpired() async throws {
        do {
            _ = try await adapter.search(MemorySearchWireRequest(
                query: "anything", handle: "msearch:v1:neverexisted", cursor: 5))
            XCTFail("unknown handle must be typed")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireCode, "notFound")
            XCTAssertEqual(error.wireReason, "searchHandleUnknown")
        }
    }

    func testSearchOversizeCJKPagesBudgetStopRowsAtomic() async throws {
        // 20 items × 4096 CJK chars exceed one 48KiB page: first page must
        // budget-stop with hasMore/nextCursor and no item may be truncated.
        for index in 0..<20 {
            // FTS5 unicode61 treats a CJK run as one token, so the shared
            // matchable token is an ASCII word; the payload is CJK-heavy.
            let body = "budget " + String(repeating: "测", count: 4_080)
                + " item\(index)"
            try await IntelligenceTestSupport.seedMemory(
                manager, content: body, importance: 0.9)
        }
        let page = try await adapter.search(MemorySearchWireRequest(
            query: "budget", limit: 20))
        XCTAssertLessThan(page.items.count, 20, "48KiB escape-aware budget must stop the page")
        XCTAssertTrue(page.hasMore)
        XCTAssertNotNil(page.nextCursor)
        for item in page.items {
            if let current = item.current {
                XCTAssertLessThanOrEqual(current.content.count, 4_096)
                XCTAssertFalse(current.content.isEmpty,
                               "atomic items are never truncated mid-entry")
            }
        }
        let rest = try await adapter.search(MemorySearchWireRequest(
            query: "测 item", handle: try XCTUnwrap(page.searchHandle),
            cursor: try XCTUnwrap(page.nextCursor.flatMap(Int.init))))
        XCTAssertFalse(rest.items.isEmpty)
    }

    private func recallCounts() async -> [String: Int64] {
        try! await manager.reader { db in
            var mapping: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, recall_count FROM memory_entries") {
                let id: String = row["id"]
                let count: Int64 = row["recall_count"]
                mapping[id] = count
            }
            return mapping
        }
    }

    // MARK: - candidates

    func testCandidatesPagedWithSweepDisclosure() async throws {
        // 130 candidates: 50 pending with expiry in the past (sweep
        // changes), others fresh pending; ordering = importance DESC,
        // created_at DESC.
        let past = Date().addingTimeInterval(-60)
        for index in 0..<10 {
            try await IntelligenceTestSupport.seedCandidate(
                manager, content: "expired candidate \(index)",
                importance: 0.1 + Double(index) / 100.0,
                expiresAt: past, id: UUID(),
                createdAt: Date().addingTimeInterval(Double(index)))
        }
        for index in 0..<120 {
            try await IntelligenceTestSupport.seedCandidate(
                manager, content: "pending candidate \(index)",
                importance: 0.5 + Double(index % 50) / 100.0,
                expiresAt: nil, id: UUID(),
                createdAt: Date().addingTimeInterval(100 + Double(index)))
        }
        let page = try await adapter.candidatesPage(
            MemoryCandidatesListRequest(status: .pending, cursor: 0, limit: 50))
        XCTAssertTrue(page.expiredSweepApplied,
                      "the sweep really changed 10 rows on the first call")
        XCTAssertEqual(page.candidates.count, 50)
        XCTAssertNotNil(page.nextCursor)
        for candidate in page.candidates {
            let recomputed = try await XCTUnwrapAsync(
                await IntelligenceTestSupport.candidateDigest(manager, id: candidate.id))
            XCTAssertEqual(candidate.revision, recomputed,
                           "floe.memory-candidate.v1 full-row digest (18 columns)")
        }
        let page2 = try await adapter.candidatesPage(
            MemoryCandidatesListRequest(status: .pending,
                                        cursor: try XCTUnwrap(page.nextCursor.flatMap(Int.init)),
                                        limit: 50))
        XCTAssertFalse(page2.expiredSweepApplied,
                      "the second call sweeps nothing: honest false")
        let second = try await adapter.candidatesPage(
            MemoryCandidatesListRequest(status: .pending, cursor: 100, limit: 50))
        XCTAssertNil(second.nextCursor)
    }

    func testCandidateResolveActivateSingleTransaction() async throws {
        // memory_evidence.message_id has the ORIGINAL FK to messages(id):
        // the producer reference must name a REAL persisted message.
        let conversation = try await IntelligenceTestSupport.seedOrdinaryConversation(manager)
        let message = try await IntelligenceTestSupport.seedUserMessage(
            manager, conversationID: conversation)
        let evidence = [MemoryEvidenceReference(
            messageID: message, excerpt: "raw conversation excerpt secret-free")]
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "adopt this candidate", confidence: 0.82,
            importance: 0.64, origin: .goalStepReview, evidence: evidence)
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        let reply = try await adapter.resolveCandidate(expectedRevision: digest,
                                                      id: candidate.id,
                                                      activate: true)
        XCTAssertEqual(reply.status, .activated)
        let entry = try XCTUnwrap(reply.entry)
        // Original construction parity: id==candidate.id, active, content,
        // confidence, importance, sourceKind=origin, createdAt from the row.
        XCTAssertEqual(entry.id, candidate.id)
        XCTAssertEqual(entry.status, .active)
        XCTAssertEqual(entry.content, "adopt this candidate")
        XCTAssertEqual(entry.sourceKind, .goalStepReview)
        XCTAssertNotNil(entry.createdAt)
        // Evidence double-digest: excerpt_digest == stableDigest(stored
        // redacted 'sha256:<hex>' excerpt) — byte-exact FNV reproduction.
        let evidenceDigests: [String] = try await manager.reader { db in
            try String.fetchAll(db, sql: """
                SELECT excerpt_digest FROM memory_evidence WHERE memory_id = ?
                """, arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(evidenceDigests.count, 1)
        let digestText: String = try XCTUnwrap(evidenceDigests.first)
        // The store-side excerpt was redacted at saveCandidate time to
        // "sha256:" + MemoryContentDigest.make(raw); the adapter hashes the
        // STORED string with the original stableDigest.
        let expectedRedacted = "sha256:" + MemoryContentDigest.make(
            "raw conversation excerpt secret-free")
        XCTAssertEqual(digestText, FacadeStableDigest.fnvRadix16(expectedRedacted),
                       "the original double-digest path byte-exactly")
        let status = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT status FROM memory_candidates WHERE id = ?",
                                arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(status, "activated")
        let reason = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT review_reason FROM memory_candidates WHERE id = ?",
                                arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(reason, "approved by user")
    }

    func testCandidateResolveRejectWritesNoEntry() async throws {
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "reject this candidate")
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        let reply = try await adapter.resolveCandidate(expectedRevision: digest,
                                                      id: candidate.id,
                                                      activate: false)
        XCTAssertEqual(reply.status, .rejected)
        XCTAssertNil(reply.entry)
        let memoryRows = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(memoryRows, 0)
    }

    func testCandidateAcceptVersusRejectRaceExactlyOneWins() async throws {
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "contended candidate")
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        // Capture ONLY Sendable values (the actor + immutable ids): never the
        // non-Sendable XCTestCase through an implicitly-unwrapped property.
        let racingAdapter = try XCTUnwrap(adapter)
        let candidateID = candidate.id
        let firstResult = await Task { () -> Result<String, Error> in
            do {
                let reply = try await racingAdapter.resolveCandidate(
                    expectedRevision: digest, id: candidateID, activate: true)
                return .success(reply.status.rawValue)
            } catch {
                return .failure(error)
            }
        }.value
        let secondResult = await Task { () -> Result<String, Error> in
            do {
                let reply = try await racingAdapter.resolveCandidate(
                    expectedRevision: digest, id: candidateID, activate: false)
                return .success(reply.status.rawValue)
            } catch {
                return .failure(error)
            }
        }.value
        let successes = [firstResult, secondResult].filter {
            if case .success = $0 { return true }
            return false
        }
        XCTAssertEqual(successes.count, 1, "one winner (GRDB writer serialization + status guard)")
        let error = try XCTUnwrap(
            [firstResult, secondResult].compactMap { result -> MemoryAdapterError? in
                if case .failure(let failure) = result,
                   let typed = failure as? MemoryAdapterError { return typed }
                return nil
            }.first)
        XCTAssertEqual(error.wireCode, "notFound")
        XCTAssertTrue((error.wireReason ?? "").hasPrefix("candidateNotPending:"),
                      "loser gets the truthful actualStatus guard, never a silent flip")
        // No mixed state ever observable: single status, matching entry.
        let status = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT status FROM memory_candidates WHERE id = ?",
                                arguments: [candidate.id.uuidString])
        }
        let entryCount = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(status == "activated", entryCount == 1)
    }

    func testCandidateSameSecondFieldChangeStale() async throws {
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "replayed candidate field", importance: 0.4)
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        // Producer replay changes importance within the SAME stored second.
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_candidates SET importance = ?, updated_at = ? WHERE id = ?",
            [0.9, await currentStoredCandidateUpdatedAt(candidate.id),
             candidate.id.uuidString])
        do {
            _ = try await adapter.resolveCandidate(expectedRevision: digest,
                                                   id: candidate.id, activate: true)
            XCTFail("timestamp-only CAS would have accepted this; the full-row digest must not")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(let stale, _) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(stale, [candidate.id])
        }
    }

    private func currentStoredCandidateUpdatedAt(_ id: UUID) async -> String {
        let fetched = try? await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT updated_at FROM memory_candidates WHERE id = ?",
                                arguments: [id.uuidString])
        }
        return fetched ?? ""
    }

    func testCandidateFailAfterMemoryWriteRollsBackWholeTransaction() async throws {
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "rollback vector")
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        struct Injected: Error {}
        let racing = FacadeMemoryAdapter(
            database: manager, intelligenceStore: intelligence,
            workspaceStore: workspaces, conversationStore: conversations,
            faultInjection: { stage in
                if stage == "candidate.afterEntryWriteBeforeStatus" {
                    throw Injected()
                }
            })
        do {
            _ = try await racing.resolveCandidate(expectedRevision: digest,
                                                  id: candidate.id, activate: true)
            XCTFail("injected failure must surface")
        } catch {
            // WHOLE transaction rolled back: no entry, still pending.
            let entryCount = try await manager.reader { db in
                try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                                   arguments: [candidate.id.uuidString])
            }
            XCTAssertEqual(entryCount, 0)
            let status = try await manager.reader { db in
                try String.fetchOne(db, sql: "SELECT status FROM memory_candidates WHERE id = ?",
                                    arguments: [candidate.id.uuidString])
            }
            XCTAssertEqual(status, "pending")
        }
        // Retry converges on the healthy adapter.
        _ = try await adapter.resolveCandidate(expectedRevision: digest,
                                               id: candidate.id, activate: true)
        let status = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT status FROM memory_candidates WHERE id = ?",
                                arguments: [candidate.id.uuidString])
        }
        XCTAssertEqual(status, "activated")
    }

    func testExpiryDuringQueuedResolveImpossible() async throws {
        // Candidate expires while a resolve is queued: the in-transaction
        // sweep rejects it FIRST → status guard → candidateNotPending:rejected.
        let candidate = try await IntelligenceTestSupport.seedCandidate(
            manager, content: "expiring mid queue",
            expiresAt: Date().addingTimeInterval(-1))
        let candidateDigest = try await IntelligenceTestSupport.candidateDigest(
            manager, id: candidate.id)
        let digest = try XCTUnwrap(candidateDigest)
        do {
            _ = try await adapter.resolveCandidate(expectedRevision: digest,
                                                   id: candidate.id, activate: true)
            XCTFail("activation after expiry must be impossible")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireReason, "candidateNotPending:rejected")
        }
    }
}

private extension FacadeMemoryAdapter {}
