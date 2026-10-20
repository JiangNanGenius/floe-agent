// FloeAppTests — durable Shortcuts draft inbox: FIFO, lossless
// claim/ack, stable migration identity, stale-token rejection.

import Foundation
import Testing
import FloePersistence
import FloeModels

@Suite("FloePersistence.ShortcutInboxStore")
struct ShortcutInboxStoreTests {

    private func makeStore() async throws -> SQLiteShortcutDraftInboxStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return SQLiteShortcutDraftInboxStore(database: database)
    }

    @Test("Consecutive enqueues keep unique ids and FIFO order across reopen")
    func fifoSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-inbox-\(UUID().uuidString).sqlite")
        var ids: [UUID] = []
        let database = try DatabaseManager(path: url)
        try await database.migrate()
        let store = SQLiteShortcutDraftInboxStore(database: database)
        for text in ["first", "second", "first"] {
            ids.append(try await store.enqueue(text: text, source: .intentCreate, migrationKey: nil).id)
        }
        try await database.close()
        // Reopen proves the rows are durable, still pending, and FIFO.
        let again = try DatabaseManager(path: url)
        let againStore = SQLiteShortcutDraftInboxStore(database: again)
        let reopened = try await againStore.pendingEntries(limit: 10)
        try await again.close()
        try? FileManager.default.removeItem(at: url)

        #expect(Set(ids).count == 3)
        #expect(reopened.map(\.id) == ids)
        #expect(reopened.map(\.text) == ["first", "second", "first"])
        #expect(reopened.allSatisfy { $0.state == .pending })
    }

    @Test("Empty drafts are rejected instead of occupying the queue")
    func emptyRejected() async throws {
        let store = try await makeStore()
        await #expect(throws: (any Error).self) {
            _ = try await store.enqueue(text: "   \n ", source: .intentSend, migrationKey: nil)
        }
        let text = "Summarize this text\n\nReal payload"
        let entry = try await store.enqueue(text: text, source: .intentSend, migrationKey: nil)
        #expect(entry.text == text)
        #expect(try await store.pendingCount() == 1)
    }

    @Test("Legacy migration re-enqueue dedupes on the stable identity")
    func migrationIdempotent() async throws {
        let store = try await makeStore()
        let first = try await store.enqueue(
            text: "old single-slot draft", source: .legacyMigration, migrationKey: "pendingDraft"
        )
        #expect(first.id == ShortcutDraftInboxEntry.stableID(migrationKey: "pendingDraft"))
        // Crash-after-enqueue retry: same id, one row, content preserved.
        let retry = try await store.enqueue(
            text: "old single-slot draft", source: .legacyMigration, migrationKey: "pendingDraft"
        )
        #expect(retry.id == first.id)
        let countAfterRetry = try await store.pendingCount()
        #expect(countAfterRetry == 1)
        // Normal enqueues never dedupe, even with identical text.
        _ = try await store.enqueue(text: "old single-slot draft", source: .intentCreate, migrationKey: nil)
        _ = try await store.enqueue(text: "old single-slot draft", source: .intentCreate, migrationKey: nil)
        let finalCount = try await store.pendingCount()
        #expect(finalCount == 3)
    }

    @Test("Concurrent claims elect exactly one owner")
    func concurrentClaimSingleOwner() async throws {
        let store = try await makeStore()
        _ = try await store.enqueue(text: "only one", source: .intentCreate, migrationKey: nil)
        let winners = await withTaskGroup(of: ShortcutDraftInboxEntry?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await store.claimNext(destinationID: "home", at: Date()) }
            }
            var won: [ShortcutDraftInboxEntry] = []
            for await entry in group {
                if let entry { won.append(entry) }
            }
            return won
        }
        #expect(winners.count == 1)
        // A second claim now finds the queue empty (claimed, not pending).
        let again = try await store.claimNext(destinationID: "home", at: Date())
        #expect(again == nil)
    }

    @Test("Ack requires the exact claim token; stale tokens are rejected")
    func ackTokenGated() async throws {
        let store = try await makeStore()
        let entry = try await store.enqueue(text: "tokened", source: .intentCreate, migrationKey: nil)
        let claim = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(claim.id == entry.id)
        let token = try #require(claim.claimToken)

        let staleAck = try await store.ack(id: entry.id, claimToken: "stale-token")
        #expect(staleAck == false)
        // A stale ack must not disturb the live handoff.
        let current = try #require(try await store.entry(id: entry.id))
        #expect(current.state == .claimed)

        let realAck = try await store.ack(id: entry.id, claimToken: token)
        #expect(realAck == true)
        let gone = try await store.entry(id: entry.id)
        #expect(gone == nil)
        // Re-ack (retry of an already-settled delivery) is a harmless false.
        let reAck = try await store.ack(id: entry.id, claimToken: token)
        #expect(reAck == false)
    }

    @Test("Release restores pending and rotates the claim token")
    func releaseRotatesToken() async throws {
        let store = try await makeStore()
        let entry = try await store.enqueue(text: "releasable", source: .intentCreate, migrationKey: nil)
        let first = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        let firstToken = try #require(first.claimToken)

        let wrongRelease = try await store.release(id: entry.id, claimToken: "not-the-token")
        #expect(wrongRelease == false)
        let released = try await store.release(id: entry.id, claimToken: firstToken)
        #expect(released == true)
        let revived = try #require(try await store.entry(id: entry.id))
        #expect(revived.state == .pending)
        #expect(revived.claimToken == nil && revived.claimEpoch == nil)

        let second = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(second.claimToken != firstToken)
        // The dead claimant's stale ack cannot settle the newer handoff…
        let staleAck = try await store.ack(id: entry.id, claimToken: firstToken)
        #expect(staleAck == false)
        // …and its stale release cannot steal it either.
        let staleRelease = try await store.release(id: entry.id, claimToken: firstToken)
        #expect(staleRelease == false)
        let secondToken = try #require(second.claimToken)
        let settled = try await store.ack(id: entry.id, claimToken: secondToken)
        #expect(settled == true)
        let finalCount = try await store.pendingCount()
        #expect(finalCount == 0)
    }

    @Test("A claimed FIFO head blocks a later pending row until it settles")
    func claimedHeadBlocksOvertaking() async throws {
        let store = try await makeStore()
        let first = try await store.enqueue(text: "first", source: .intentCreate, migrationKey: nil)
        let second = try await store.enqueue(text: "second", source: .intentCreate, migrationKey: nil)
        let head = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(head.id == first.id)
        // The claimant's release fails (e.g. a transient store error): the
        // head stays claimed with its token.
        #expect(try await store.release(id: first.id, claimToken: "stale") == false)
        // The younger pending row must NOT be handed out while the older
        // entry is still unsettled.
        let overtake = try await store.claimNext(destinationID: "home", at: Date())
        #expect(overtake == nil)
        let younger = try #require(try await store.entry(id: second.id))
        #expect(younger.state == .pending)
        // A token-matched release unblocks the true head; FIFO then advances.
        let token = try #require(head.claimToken)
        #expect(try await store.release(id: first.id, claimToken: token) == true)
        let reclaimed = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(reclaimed.id == first.id)
        #expect(try await store.ack(
            id: reclaimed.id, claimToken: try #require(reclaimed.claimToken)
        ) == true)
        let next = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(next.id == second.id)
        #expect(next.text == "second")
    }

    @Test("Concurrent claims never skip the oldest row")
    func concurrentClaimsKeepFIFOHead() async throws {
        let store = try await makeStore()
        let first = try await store.enqueue(text: "oldest", source: .intentSend, migrationKey: nil)
        let second = try await store.enqueue(text: "younger", source: .intentCreate, migrationKey: nil)
        let winners = await withTaskGroup(of: ShortcutDraftInboxEntry?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await store.claimNext(destinationID: "home", at: Date()) }
            }
            var won: [ShortcutDraftInboxEntry] = []
            for await entry in group {
                if let entry { won.append(entry) }
            }
            return won
        }
        #expect(winners.count == 1)
        #expect(winners.first?.id == first.id)
        let younger = try #require(try await store.entry(id: second.id))
        #expect(younger.state == .pending)
    }

    @Test("Claims are scoped by destination and process epoch for crash recovery")
    func epochScoping() async throws {
        let store = try await makeStore()
        _ = try await store.enqueue(text: "dead window", source: .intentCreate, migrationKey: nil)
        _ = try await store.enqueue(text: "live window", source: .intentCreate, migrationKey: nil)
        let dead = try #require(try await store.claimNext(
            destinationID: "home", at: Date(), epoch: "epoch-dead-process"
        ))
        #expect(dead.claimEpoch == "epoch-dead-process")
        // The dead claim still owns the FIFO head: a live caller cannot skip
        // it for the younger pending row.
        let blocked = try await store.claimNext(destinationID: "home", at: Date())
        #expect(blocked == nil)

        let abandoned = try await store.abandonedClaims()
        #expect(abandoned.map(\.id) == [dead.id])
        // Recovery releases the dead claim by its stored token; the head is
        // then claimable by the live process and resumes under its epoch.
        let deadToken = try #require(dead.claimToken)
        #expect(try await store.release(id: dead.id, claimToken: deadToken) == true)
        let live = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(live.id == dead.id)
        #expect(live.claimEpoch == ShortcutInboxProcessEpoch.value)
        let resumable = try await store.claims(destinationID: "home")
        #expect(resumable.map(\.id) == [dead.id])
        // A different destination sees neither.
        let other = try await store.claims(destinationID: "other")
        #expect(other.isEmpty)
        // The live claim settles with its own token, then FIFO advances.
        #expect(try await store.ack(
            id: live.id, claimToken: try #require(live.claimToken)
        ) == true)
        let next = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(next.text == "live window")
        #expect(try await store.ack(
            id: next.id, claimToken: try #require(next.claimToken)
        ) == true)
        let remaining = try await store.abandonedClaims()
        #expect(remaining.isEmpty)
    }

    @Test("A migrated entry tombstones instead of redelivering after ack")
    func deliveredTombstone() async throws {
        let store = try await makeStore()
        let entry = try await store.enqueue(
            text: "legacy", source: .legacyMigration, migrationKey: "pendingDraft"
        )
        let claim = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        let token = try #require(claim.claimToken)
        let acked = try await store.ack(id: claim.id, claimToken: token)
        #expect(acked == true)
        let settled = try #require(try await store.entry(id: entry.id))
        #expect(settled.state == .delivered)
        // A late retry of the same stable identity sees the tombstone: no
        // pending row, nothing claimable, no redelivery.
        let retry = try await store.enqueue(
            text: "legacy", source: .legacyMigration, migrationKey: "pendingDraft"
        )
        #expect(retry.id == entry.id)
        #expect(retry.state == .delivered)
        let count = try await store.pendingCount()
        #expect(count == 0)
        let next = try await store.claimNext(destinationID: "home", at: Date())
        #expect(next == nil)
        // Ordinary entries have no migration key and are removed normally.
        _ = try await store.enqueue(text: "ordinary", source: .intentCreate, migrationKey: nil)
        let ordinary = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        let ordinaryAcked = try await store.ack(
            id: ordinary.id, claimToken: try #require(ordinary.claimToken)
        )
        #expect(ordinaryAcked == true)
        let gone = try await store.entry(id: ordinary.id)
        #expect(gone == nil)
    }

    @Test("Peeking never claims")
    func peekReadOnly() async throws {
        let store = try await makeStore()
        let first = try await store.enqueue(text: "one", source: .intentSend, migrationKey: nil)
        _ = try await store.enqueue(text: "two", source: .intentCreate, migrationKey: nil)
        let peeked = try await store.pendingEntries(limit: 5)
        #expect(peeked.count == 2)
        #expect(peeked.map(\.text) == ["one", "two"])
        let count = try await store.pendingCount()
        #expect(count == 2)
        let claimed = try #require(try await store.claimNext(destinationID: "home", at: Date()))
        #expect(claimed.id == first.id)
    }
}
