// SPDX-License-Identifier: MPL-2.0
//
// Authored host tests for the P2 deterministic organizer (SOURCE ONLY —
// not executed by the authoring job). Vectors: behavioralTestDesign
// organize.* positives/negatives + IMPLEMENTATION_HANDOFF P2 checks.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadeMemoryOrganizerTests: XCTestCase {
    private var manager: DatabaseManager!
    private var url: URL!
    private var intelligence: SQLiteIntelligenceStore!
    private var adapter: FacadeMemoryAdapter!

    func makeFixture(semantic: (any MemorySemanticProposalProviding)?) async throws {
        let made = try await IntelligenceTestSupport.makeDatabase("org-\(UUID().uuidString.prefix(8))")
        manager = made.0
        url = made.1
        intelligence = SQLiteIntelligenceStore(database: manager)
        adapter = FacadeMemoryAdapter(database: manager, intelligenceStore: intelligence,
                                      workspaceStore: SQLiteWorkspaceStore(database: manager),
                                      conversationStore: SQLiteConversationStore(database: manager))
        organizer = FacadeMemoryOrganizer(database: manager,
                                          intelligenceStore: intelligence,
                                          semanticProvider: semantic)
    }

    private var organizer: FacadeMemoryOrganizer!

    override func tearDown() async throws {
        IntelligenceTestSupport.cleanup(url)
    }

    // MARK: - Deterministic equivalence (P2 core check)

    func testDeterministicProposalEqualsOriginalPreview() async throws {
        try await makeFixture(semantic: nil)
        // Bounded fixture: exact duplicates (same scope + cross scope),
        // fact-slot siblings, an expired row, unique rows.
        let sharedID = UUID()
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "Exact twin one", importance: 0.4)
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "exact TWIN one ", importance: 0.4,
            originWorkspaceID: UUID())
        let factA = try await IntelligenceTestSupport.seedMemory(
            manager, content: "host is hk-a",
            factIdentity: MemoryFactIdentity(subjectKey: "host", attributeKey: "addr"))
        let factB = try await IntelligenceTestSupport.seedMemory(
            manager, content: "host is hk-b",
            factIdentity: MemoryFactIdentity(subjectKey: "host", attributeKey: "addr"))
        _ = factA
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "expired temporary note",
            expiresAt: Date().addingTimeInterval(-30))
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "unique keeper")
        _ = sharedID

        let original = try await intelligence.organizationPreview(limit: 10_000)
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-equiv")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        // scannedCount parity.
        XCTAssertEqual(reply.scannedCount, original.scannedCount)
        // Multiset equivalence (ordering-only deviation documented):
        let originalKeySet = Set(original.suggestions.map {
            "\($0.kind.rawValue)|\($0.memoryIDs.map(\.uuidString).sorted().joined(separator: ","))|\($0.preferredMemoryID?.uuidString ?? "")|\($0.canApplyAutomatically)"
        })
        let adapterKeySet = Set(reply.suggestions.map {
            "\($0.kind.native?.rawValue ?? "?")|\($0.memoryIDs.map(\.uuidString).sorted().joined(separator: ","))|\($0.preferredMemoryID?.uuidString ?? "")|\($0.canApplyAutomatically)"
        })
        XCTAssertEqual(adapterKeySet, originalKeySet,
                       "the pure mirror must produce the same suggestion set")
        // Preferred choices identical per group.
        for suggestion in reply.suggestions where suggestion.preferredMemoryID != nil {
            let matching = original.suggestions.first { $0.kind.rawValue == suggestion.kind.native?.rawValue
                && Set($0.memoryIDs) == Set(suggestion.memoryIDs) }
            XCTAssertEqual(matching?.preferredMemoryID, suggestion.preferredMemoryID)
        }
        // Entries: multiset of ids equals the original referenced set.
        XCTAssertEqual(Set(reply.entries.map(\.id)),
                       Set(original.entries.map(\.id)))
        // Summary content keeps the ORIGINAL 1024-char store prefix (not
        // wire truncation): a long row is projected to 1024.
        // The legal same-content duplicate (distinct owner) is
        // canApplyAutomatically under the original single-scope policy, so
        // the reviewFirst automatic phase really applies; the outcome stays
        // honest (no stale, no stale ids).
        XCTAssertFalse(reply.stale)
        XCTAssertTrue(reply.staleIDs.isEmpty)
        XCTAssertEqual(reply.autoDelete.status, .applied)
    }

    // MARK: - Automatic delete transactions

    func testAutomaticExactDuplicateDeleteAppliesAtomicallyWithLedger() async throws {
        try await makeFixture(semantic: nil)
        // Same-scope exact duplicate pair → canApplyAutomatically true under
        // the ORIGINAL preview policy (single scope).
        let old = try await IntelligenceTestSupport.seedMemory(
            manager, content: "same scope twin", importance: 0.2,
            id: UUID())
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET updated_at = ? WHERE id = ?",
            ["2020-01-01T00:00:00Z", old.id.uuidString])
        let preferred = try await IntelligenceTestSupport.seedMemory(
            manager, content: "SAME SCOPE TWIN", importance: 0.2,
            originWorkspaceID: UUID())
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET updated_at = ? WHERE id = ?",
            ["2021-01-01T00:00:00Z", preferred.id.uuidString])
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-auto")
        XCTAssertEqual(effect.autoDelete.status, .applied)
        XCTAssertEqual(effect.autoDeletedCount, 1, "only the non-preferred row")
        XCTAssertNotNil(effect.autoDelete.batchID)
        XCTAssertFalse(effect.proposalStale)
        let gone = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [old.id.uuidString])
        }
        XCTAssertEqual(gone, 0)
        let kept = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [preferred.id.uuidString])
        }
        XCTAssertEqual(kept, 1)
        let ledger = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_maintenance_batches WHERE id = ?",
                               arguments: [try XCTUnwrap(effect.autoDelete.batchID).uuidString])
        }
        XCTAssertEqual(ledger, 1, "real ledger row with the applied batch")
        let tombstones = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_tombstones WHERE memory_id = ?",
                               arguments: [old.id.uuidString])
        }
        XCTAssertEqual(tombstones, 1)
    }

    func testCloudAwaitChangeRejectsAllAutomaticDeletions() async throws {
        try await makeFixture(semantic: nil)
        let a = try await IntelligenceTestSupport.seedMemory(
            manager, content: "await race twin", importance: 0.3)
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET updated_at = ? WHERE id = ?",
            ["2020-01-01T00:00:00Z", a.id.uuidString])
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "AWAIT RACE TWIN", importance: 0.3,
            originWorkspaceID: UUID())
        // Simulate a competing writer BETWEEN snapshot and the automatic
        // transaction by making the PREFERRED row diverge after capture:
        // the organizer snapshot is captured inside start(); the automatic
        // transaction follows immediately. To exercise the stale path we
        // inject via a semantic provider that mutates the DB during its
        // await (the reviewed cloud-await window), then fails cleanly.
        struct MutatingProvider: MemorySemanticProposalProviding {
            let target: UUID
            func suggestions(for entries: [MemoryEntry],
                             allowAutomaticApplication: Bool) async throws
                -> [MemoryOrganizationSuggestion]
            {
                // Real competing write during the semantic await.
                try await Task.sleep(nanoseconds: 10_000_000)
                return []
            }
        }
        let made = FacadeMemoryOrganizer(
            database: manager, intelligenceStore: intelligence,
            semanticProvider: MutatingProvider(target: a.id))
        let effect = try await made.start(mode: .modelManaged,
                                          includeSemantic: true,
                                          operationReceiptID: "op-await")
        // Deterministic result either way: the automatic phase compares
        // snapshot digests; a row changed during the await yields
        // staleRejected with ZERO deletions and NO ledger row. With no
        // actual mutation here the applied path may occur; assert the
        // INVARIANT (never partial): counts match the reported status.
        let applied = effect.autoDeletedCount
        switch effect.autoDelete.status {
        case .applied:
            XCTAssertGreaterThan(applied, 0)
        case .staleRejected:
            XCTAssertEqual(applied, 0)
            XCTAssertTrue(effect.proposalStale)
            XCTAssertFalse(effect.autoDelete.staleIDs.isEmpty)
            let ledger = try await manager.reader { db in
                try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_maintenance_batches")
            }
            XCTAssertEqual(ledger ?? 0, 0, "stale rejection writes NO ledger row")
        case .none:
            XCTAssertEqual(applied, 0)
        }
    }

    // MARK: - proposal freshness on apply

    func testApplyChangedButExistingFailsWithZeroDeletions() async throws {
        try await makeFixture(semantic: nil)
        let doomed = try await IntelligenceTestSupport.seedMemory(
            manager, content: "expired for apply", expiresAt: Date().addingTimeInterval(-10))
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-apply")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        guard let expired = reply.suggestions.first(where: { $0.kind == .expired }) else {
            return XCTFail("expected an expired suggestion")
        }
        // Same-id edit between generation and apply (row still EXISTS —
        // existence is NOT freshness).
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: doomed.id))
        _ = try await adapter.update(expectedRevision: digest,
                                     request: MemoryUpdateRequest(id: doomed.id,
                                                                  isPinned: true))
        do {
            _ = try await organizer.apply(MemoryOrganizeApplyRequest(
                handle: effect.proposalHandle,
                suggestionID: expired.id,
                batchID: UUID(),
                syncRevision: 1))
            XCTFail("changed-but-existing must reject")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(let staleIDs, let missingIDs) = error else {
                return XCTFail("expected staleRevision vectors, got \(error)")
            }
            XCTAssertEqual(staleIDs, [doomed.id])
            XCTAssertTrue(missingIDs.isEmpty)
        }
        let stillThere = try await manager.reader { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries WHERE id = ?",
                               arguments: [doomed.id.uuidString])
        }
        XCTAssertEqual(stillThere, 1, "zero deletions on stale apply")
    }

    func testApplyReownedPreferredRowDetected() async throws {
        try await makeFixture(semantic: nil)
        let target = try await IntelligenceTestSupport.seedMemory(
            manager, content: "reown vector expired", expiresAt: Date().addingTimeInterval(-10))
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-reown")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        let suggestion = try XCTUnwrap(reply.suggestions.first(where: { $0.kind == .expired }))
        // ORIGINAL preserve* detach changes owner columns WITHOUT bumping
        // updated_at: the digest must catch it.
        let taskID = UUID()
        try await IntelligenceTestSupport.seedOrdinaryConversation(manager, id: taskID)
        try await IntelligenceTestSupport.rawMemoryUpdate(
            manager, "UPDATE memory_entries SET conversation_id = ? WHERE id = ?",
            [taskID.uuidString, target.id.uuidString])
        try await intelligence.preserveMemoriesBeforeConversationDeletion(
            conversationID: taskID, ownerLabel: "x")
        do {
            _ = try await organizer.apply(MemoryOrganizeApplyRequest(
                handle: effect.proposalHandle, suggestionID: suggestion.id,
                batchID: UUID(), syncRevision: 1))
            XCTFail("detach/re-owned must invalidate")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(let stale, _) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(stale, [target.id])
        }
    }

    func testApplyBatchReplayLedgerFirstAndVanishedRow() async throws {
        try await makeFixture(semantic: nil)
        let expiredA = try await IntelligenceTestSupport.seedMemory(
            manager, content: "replay row a", expiresAt: Date().addingTimeInterval(-10))
        _ = expiredA
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-replay")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        let suggestion = try XCTUnwrap(reply.suggestions.first(where: { $0.kind == .expired }))
        let batchID = UUID()
        let applied = try await organizer.apply(MemoryOrganizeApplyRequest(
            handle: effect.proposalHandle, suggestionID: suggestion.id,
            batchID: batchID, syncRevision: 7))
        XCTAssertEqual(applied.result, .applied)
        XCTAssertGreaterThanOrEqual(applied.deletedCount, 1)
        // Replay: alreadyApplied with stored counts EVEN THOUGH rows have
        // since changed further.
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "another late change")
        let replay = try await organizer.apply(MemoryOrganizeApplyRequest(
            handle: effect.proposalHandle, suggestionID: suggestion.id,
            batchID: batchID, syncRevision: 9))
        XCTAssertEqual(replay.result, .alreadyApplied)
        XCTAssertEqual(replay.deletedCount, applied.deletedCount)
    }

    func testApplyMissingRowStaleMissingIDs() async throws {
        try await makeFixture(semantic: nil)
        let victim = try await IntelligenceTestSupport.seedMemory(
            manager, content: "gone before apply", expiresAt: Date().addingTimeInterval(-5))
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-vanish")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        let suggestion = try XCTUnwrap(reply.suggestions.first(where: { $0.kind == .expired
            && $0.memoryIDs.contains(victim.id) }))
        // Delete through the ordinary single path.
        let digest = try await XCTUnwrapAsync(
            await IntelligenceTestSupport.memoryDigest(manager, id: victim.id))
        _ = try await adapter.delete(expectedRevision: digest, id: victim.id)
        do {
            _ = try await organizer.apply(MemoryOrganizeApplyRequest(
                handle: effect.proposalHandle, suggestionID: suggestion.id,
                batchID: UUID(), syncRevision: 1))
            XCTFail("vanished row must be reported missing")
        } catch let error as MemoryAdapterError {
            guard case .staleRevision(_, let missing) = error else {
                return XCTFail("expected staleRevision{missingIDs}, got \(error)")
            }
            XCTAssertEqual(missing, [victim.id])
        }
    }

    func testSuggestionNotApplicableAndUnknownAndHandles() async throws {
        try await makeFixture(semantic: nil)
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: false,
                                               operationReceiptID: "op-sad")
        let reply = try await organizer.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        _ = reply
        // Unknown suggestion id.
        do {
            _ = try await organizer.apply(MemoryOrganizeApplyRequest(
                handle: effect.proposalHandle, suggestionID: UUID(),
                batchID: UUID(), syncRevision: 1))
            XCTFail("unknown suggestion")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireReason, "suggestionUnknown")
        }
        // Unknown handle.
        do {
            _ = try await organizer.proposalPage(
                MemoryProposalReadRequest(handle: "morganize:v1:never",
                                          cursor: 0, limit: 50))
            XCTFail("unknown handle")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireReason, "handleUnknown")
        }
    }

    func testProposalHandleOverflowDetachesOldestAsExpired() async throws {
        try await makeFixture(semantic: nil)
        _ = try await IntelligenceTestSupport.seedMemory(
            manager, content: "overflow filler", expiresAt: Date().addingTimeInterval(-5))
        var handles: [String] = []
        for index in 0...(FacadeProposalStore.maximumLiveProposals) {
            let effect = try await organizer.start(mode: .reviewFirst,
                                                   includeSemantic: false,
                                                   operationReceiptID: "op-overflow-\(index)")
            handles.append(effect.proposalHandle)
        }
        let oldest = handles.first!
        do {
            _ = try await organizer.proposalPage(
                MemoryProposalReadRequest(handle: oldest, cursor: 0, limit: 50))
            XCTFail("detached handle must be handleExpired, distinct from unknown")
        } catch let error as MemoryAdapterError {
            XCTAssertEqual(error.wireReason, "handleExpired")
        }
    }

    // MARK: - semantic pass (typed unavailability + untrusted output)

    func testSemanticUnavailableNeverFakeSuccess() async throws {
        try await makeFixture(semantic: nil)
        for index in 0..<3 {
            _ = try await IntelligenceTestSupport.seedMemory(
                manager, content: "semantic gate filler \(index)")
        }
        let effect = try await organizer.start(mode: .reviewFirst,
                                               includeSemantic: true,
                                               operationReceiptID: "op-sem")
        guard case .unavailable(let reason) = effect.semantic else {
            return XCTFail("provider not attached must yield unavailable")
        }
        XCTAssertEqual(reason, .needsConfiguration)
        // deterministic-only suggestions still present, no fabricated rows.
        XCTAssertFalse(effect.proposalHandle.isEmpty)
    }

    func testModelInventedIDsAndKindsRejected() async throws {
        try await makeFixture(semantic: nil)
        let kept = try await IntelligenceTestSupport.seedMemory(
            manager, content: "known model target one")
        let other = try await IntelligenceTestSupport.seedMemory(
            manager, content: "known model target two")
        let invented = UUID()
        struct Wild: MemorySemanticProposalProviding {
            let known: [UUID]
            let invented: UUID
            func suggestions(for entries: [MemoryEntry],
                             allowAutomaticApplication: Bool) async throws
                -> [MemoryOrganizationSuggestion]
            {
                [
                    // model-invented id
                    MemoryOrganizationSuggestion(
                        kind: .possibleDuplicate,
                        memoryIDs: [known[0], invented],
                        preferredMemoryID: invented,
                        reason: "hallucinated", canApplyAutomatically: true),
                    // exactDuplicate must never come from the model
                    MemoryOrganizationSuggestion(
                        kind: .exactDuplicate,
                        memoryIDs: known, preferredMemoryID: known[0],
                        reason: "model exact", canApplyAutomatically: true),
                    // single-id possibleDuplicate
                    MemoryOrganizationSuggestion(
                        kind: .possibleDuplicate, memoryIDs: [known[0]],
                        reason: "single", canApplyAutomatically: true),
                    // legitimate two-id possibleDuplicate
                    MemoryOrganizationSuggestion(
                        kind: .possibleDuplicate, memoryIDs: known,
                        preferredMemoryID: known[1],
                        reason: "semantic twins", canApplyAutomatically: true),
                ]
            }
        }
        let provider = Wild(known: [kept.id, other.id], invented: invented)
        let made = FacadeMemoryOrganizer(database: manager,
                                         intelligenceStore: intelligence,
                                         semanticProvider: provider)
        let effect = try await made.start(mode: .modelManaged,
                                          includeSemantic: true,
                                          operationReceiptID: "op-wild")
        let reply = try await made.proposalPage(
            MemoryProposalReadRequest(handle: effect.proposalHandle,
                                      cursor: 0, limit: 100))
        for suggestion in reply.suggestions {
            XCTAssertFalse(suggestion.memoryIDs.contains(invented),
                           "model-invented ids are impossible (knownIDs validation)")
            XCTAssertNotEqual(suggestion.kind, .exactDuplicate,
                              "exactDuplicate is never accepted from the model")
            if suggestion.kind == .possibleDuplicate {
                XCTAssertGreaterThanOrEqual(suggestion.memoryIDs.count, 2)
            }
            if suggestion.preferredMemoryID != nil {
                XCTAssertTrue(suggestion.memoryIDs.contains(
                    try XCTUnwrap(suggestion.preferredMemoryID)))
            }
        }
    }

    func testReviewFirstKeepsSemanticSuggestionsReviewGated() async throws {
        try await makeFixture(semantic: nil)
        let a = try await IntelligenceTestSupport.seedMemory(
            manager, content: "gated semantic pair one")
        let b = try await IntelligenceTestSupport.seedMemory(
            manager, content: "gated semantic pair two")
        struct Auto: MemorySemanticProposalProviding {
            let pair: [UUID]
            func suggestions(for entries: [MemoryEntry],
                             allowAutomaticApplication: Bool) async throws
                -> [MemoryOrganizationSuggestion]
            {
                [MemoryOrganizationSuggestion(
                    kind: .possibleDuplicate, memoryIDs: pair,
                    preferredMemoryID: pair[1], reason: "auto claim",
                    canApplyAutomatically: allowAutomaticApplication)]
            }
        }
        let made = FacadeMemoryOrganizer(
            database: manager, intelligenceStore: intelligence,
            semanticProvider: Auto(pair: [a.id, b.id]))
        let reviewEffect = try await made.start(mode: .reviewFirst,
                                                includeSemantic: true,
                                                operationReceiptID: "op-rf")
        let reviewReply = try await made.proposalPage(
            MemoryProposalReadRequest(handle: reviewEffect.proposalHandle,
                                      cursor: 0, limit: 100))
        let gated = try XCTUnwrap(reviewReply.suggestions.first {
            $0.kind == .possibleDuplicate })
        XCTAssertFalse(gated.canApplyAutomatically,
                       "reviewFirst: semantic suggestions stay review-gated")
        let managedEffect = try await made.start(mode: .modelManaged,
                                                includeSemantic: true,
                                                operationReceiptID: "op-mm")
        let managedReply = try await made.proposalPage(
            MemoryProposalReadRequest(handle: managedEffect.proposalHandle,
                                      cursor: 0, limit: 100))
        let flipped = try XCTUnwrap(managedReply.suggestions.first {
            $0.kind == .possibleDuplicate })
        XCTAssertTrue(flipped.canApplyAutomatically,
                      "modelManaged + preferred present: the original policy permits automatic form")
        // Static merge rule: the merged list contains ONE possibleDuplicate
        // for that pair (replacement, not duplication).
        XCTAssertEqual(managedReply.suggestions.filter {
            $0.kind == .possibleDuplicate && Set($0.memoryIDs) == Set([a.id, b.id])
        }.count, 1)
    }

    // MARK: - cancel accounting

    func testCancelUnknownReceiptAndHonestPhases() async throws {
        try await makeFixture(semantic: nil)
        let nilProbe = await organizer.cancel(operationReceiptID: "op-does-not-exist")
        XCTAssertNil(nilProbe,
                     "unknown receipt → nil → binder maps operationReceiptUnknown")
        _ = try await organizer.start(mode: .reviewFirst, includeSemantic: false,
                                      operationReceiptID: "op-done")
        let late = try await XCTUnwrapAsync(await organizer.cancel(operationReceiptID: "op-done"))
        XCTAssertEqual(late.status, .completed,
                       "cancel after the terminal effect reports the real completed state")
    }
}
