import Foundation
import Testing
@testable import FloeCore

// FloeCoreTests — Durable design decision outbox.
// Durability contracts: ENOENT is the only fresh-start; corrupt/newer-schema
// and read failures make the outbox READ-ONLY with observable thrown errors
// and the original quarantined; pending intents are never pruned and survive
// reopen beyond the acknowledged-retention bound; the hard pending cap
// rejects new work.

@Suite("Design decision outbox")
struct DesignDecisionOutboxTests {
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignDecisions-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("outbox.json")
    }

    private func intent(_ index: Int = 0, decision: String = "adopted") -> DesignDecisionIntent {
        DesignDecisionIntent(
            canvasID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            nodeID: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            candidateID: UUID().uuidString.lowercased(),
            conversationID: "dddddddd-dddd-dddd-dddd-dddddddddddd",
            decision: decision,
            operationID: "op-\(index)"
        )
    }

    @Test func firstWritePersistsAndReopens() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        #expect(await outbox.unavailableReason == nil)
        try await outbox.prepare(intent())
        let reopened = DesignDecisionOutbox(fileURL: url)
        #expect(await reopened.pendingIntents().count == 1)
        let first = try #require(await reopened.pendingIntents().first)
        try await reopened.markDelivered(id: first.id)
        let final = DesignDecisionOutbox(fileURL: url)
        #expect(await final.pendingIntents().isEmpty)
    }

    @Test func corruptStateIsQuarantinedAndMutationsThrow() async throws {
        let url = makeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let outbox = DesignDecisionOutbox(fileURL: url)
        // Observable unavailable state, not a silent empty store.
        #expect(await outbox.unavailableReason != nil)
        do {
            try await outbox.prepare(intent())
            Issue.record("mutations must throw while state is unavailable")
        } catch DesignDecisionOutboxError.stateUnavailable { }
        #expect(await outbox.pendingIntents().isEmpty)
        // The original bytes are quarantined, not deleted or overwritten.
        let quarantined = try #require(
            FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                .first { $0.hasPrefix("outbox.json.quarantine.") }
        )
        _ = quarantined
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func newerSchemaIsQuarantinedAndCannotBeReplacedByOlderBuild() async throws {
        let url = makeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "intents": []}"#.utf8).write(to: url)
        let outbox = DesignDecisionOutbox(fileURL: url)
        let reason = try #require(await outbox.unavailableReason)
        #expect(reason.contains("newer schema"))
        do {
            try await outbox.prepare(intent())
            Issue.record("older build must not replace newer-schema state")
        } catch DesignDecisionOutboxError.stateUnavailable { }
    }

    @Test func unavailableSupportDirectoryFailsClosed() async throws {
        let outbox = DesignDecisionOutbox(fileURL: URL(fileURLWithPath: "/dev/null/design-decisions-unavailable"))
        #expect(await outbox.unavailableReason != nil)
        do {
            try await outbox.prepare(intent())
            Issue.record("prepare must fail closed when persistence is unavailable")
        } catch DesignDecisionOutboxError.stateUnavailable { }
    }

    @Test func pendingIntentsAreNeverPrunedAcrossReopen() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        // Exceed the acknowledged-retention bound with PENDING intents only.
        let count = DesignDecisionOutbox.acknowledgedRetention + 40
        for index in 0..<count {
            try await outbox.prepare(intent(index))
        }
        let reopened = DesignDecisionOutbox(fileURL: url)
        #expect(await reopened.pendingIntents().count == count)
    }

    @Test func settledRecordsCompactButPendingSurvive() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        for index in 0..<(DesignDecisionOutbox.acknowledgedRetention + 20) {
            let prepared = try await outbox.prepare(intent(index))
            try await outbox.markDelivered(id: prepared.id)
        }
        // 20 fresh pending on top of the settled tail.
        for index in 1000..<1020 {
            try await outbox.prepare(intent(index))
        }
        let reopened = DesignDecisionOutbox(fileURL: url)
        #expect(await reopened.pendingIntents().count == 20)
        // Settled tail is bounded.
        let envelope = try #require(await {
            () -> DesignDecisionOutbox.Envelope? in
            // Read the raw file to count settled records.
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(DesignDecisionOutbox.Envelope.self, from: data)
        }())
        let settled = envelope.intents.filter { $0.phase != .committing }.count
        #expect(settled <= DesignDecisionOutbox.acknowledgedRetention)
    }

    @Test func hardPendingCapRejectsNewWork() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        for index in 0..<DesignDecisionOutbox.pendingHardCap {
            try await outbox.prepare(intent(index))
        }
        do {
            try await outbox.prepare(intent(999_999))
            Issue.record("prepare must reject past the pending hard cap")
        } catch DesignDecisionOutboxError.pendingCapReached(let pending) {
            #expect(pending == DesignDecisionOutbox.pendingHardCap)
        }
        // Reopen: the cap did not prune anything.
        let reopened = DesignDecisionOutbox(fileURL: url)
        #expect(await reopened.pendingIntents().count == DesignDecisionOutbox.pendingHardCap)
    }

    @Test func reconcileCrashAfterCASDeliversOnce() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        try await outbox.prepare(intent(decision: "adopted"))
        let reopened = DesignDecisionOutbox(fileURL: url)
        let counter = Counter()
        await reopened.reconcile(
            terminalDecision: { intent in
                intent.decision == "adopted" ? .committed("adopted") : .notCommitted
            },
            deliver: { _, _ in await counter.increment() }
        )
        #expect(await counter.value == 1)
        let final = DesignDecisionOutbox(fileURL: url)
        let counter2 = Counter()
        await final.reconcile(
            terminalDecision: { _ in .committed("adopted") },
            deliver: { _, _ in await counter2.increment() }
        )
        #expect(await counter2.value == 0)
    }

    @Test func reconcileLookupUnavailableRetriesLater() async throws {
        let url = makeURL()
        let outbox = DesignDecisionOutbox(fileURL: url)
        try await outbox.prepare(intent())
        let reopened = DesignDecisionOutbox(fileURL: url)
        let counter = Counter()
        await reopened.reconcile(
            terminalDecision: { _ in .unavailable },
            deliver: { _, _ in await counter.increment() }
        )
        #expect(await counter.value == 0)
        #expect(await reopened.pendingIntents().count == 1)
    }
}
