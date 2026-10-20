// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — run-bound projection pump foundations.
// The DURABLE side runs against the ORIGINAL SQLiteRunStore (real append-only
// per-run sequence, real 200-page limit); the LIVE side exercises the
// priority/delta semantics with real `HarnessEvent` values. No fabricated
// unsequenced event stream is asserted anywhere.
// AUTHORED ONLY: not compiled or executed by this source package.
import XCTest
import Foundation
import GRDB
import FloeModels
import FloeAgentRuntime
import FloePersistence
@testable import FloeAndroidCore

final class FacadeEventPumpTests: XCTestCase {

    private func migrated() async throws -> DatabaseManager {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        return manager
    }

    /// Seeds a real conversation + run + `count` durable events through the
    /// ORIGINAL store APIs (per-run monotonic sequence starts at 1).
    private func seedRun(database: DatabaseManager, store: SQLiteRunStore,
                         events count: Int,
                         payloadMaker: (Int) -> String) async throws -> (UUID, UUID) {
        let conversationStore = SQLiteConversationStore(database: database)
        let conversationID = UUID()
        let runID = UUID()
        let now = Date()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "pump probe", createdAt: now, updatedAt: now))
        try await store.saveRun(RunRecord(
            id: runID, conversationID: conversationID,
            state: "running", goal: "pump", startedAt: now))
        for index in 1...count {
            _ = try await store.appendEvent(runID: runID, kind: .assistantText,
                                            payloadJSON: payloadMaker(index))
        }
        return (conversationID, runID)
    }

    // MARK: Durable pages over the original store

    func testDurableWindowWalksRealPagesToCompletion() async throws {
        let database = try await migrated()
        let store = SQLiteRunStore(database: database)
        let (_, runID) = try await seedRun(database: database, store: store, events: 250) { index in
            "{\"index\":\(index)}"
        }
        let pump = FacadeEventPump()
        await pump.refreshDurableWindow(runID: runID, store: store)
        // First refresh delivers exactly the original 200-page limit.
        var page = pump.pollDurable(runID: runID, afterSequence: 0,
                                    budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        var collected = page["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(collected.count, min(200, FacadeEventPump.Limits.durablePageSize))
        XCTAssertEqual(collected.first?["sequence"] as? Int, 1)
        let firstNext = page["nextSequence"] as? Int ?? 0
        XCTAssertEqual(firstNext, 200)
        // The ATTACHED window was fully delivered (budget not binding); rows
        // beyond the window appear only after the next real refresh — the
        // projection never claims store rows it has not loaded.
        XCTAssertEqual(page["hasMore"] as? Bool, false)
        XCTAssertEqual(page["watermark"] as? Int, 200)
        // Second window refresh walks to 250.
        await pump.refreshDurableWindow(runID: runID, store: store)
        page = pump.pollDurable(runID: runID, afterSequence: firstNext,
                                budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        collected = page["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(collected.count, 50)
        XCTAssertEqual(collected.last?["sequence"] as? Int, 250)
        XCTAssertEqual(page["hasMore"] as? Bool, false)
        XCTAssertEqual(page["resyncRequired"] as? Bool, false)
    }

    func testBudgetStopsAtActualSerializedUTF8AndChainsCursor() async throws {
        let database = try await migrated()
        let store = SQLiteRunStore(database: database)
        // Wide payloads (CJK + quotes/backslashes force JSON escaping).
        let (_, runID) = try await seedRun(database: database, store: store, events: 40) { index in
            "{\"text\":\"第\(index)段：含 \\\"引号\\\" 与 \\\\ 反斜杠 🎉\",\"index\":\(index)}"
        }
        let pump = FacadeEventPump()
        await pump.refreshDurableWindow(runID: runID, store: store)
        let page = pump.pollDurable(runID: runID, afterSequence: 0,
                                    budgetBytes: 4_096)   // tiny budget for the walk
        let items = page["events"] as? [[String: Any]] ?? []
        XCTAssertGreaterThan(items.count, 0)
        XCTAssertLessThan(items.count, 40)
        XCTAssertEqual(page["hasMore"] as? Bool, true)
        // Byte-exact bound check: rebuild the page array and count actual bytes.
        let arrayBytes = FacadeFrameBudget.serializedBytes(["e": items])
        XCTAssertLessThanOrEqual(arrayBytes, 4_096 + 64)
        // Escape-aware counting is NOT Swift character count: assert the
        // helper itself measures serialized bytes for one escaped item.
        let probe: [String: Any] = ["s": "含 \"引\" \\ 号 🎉"]
        let measured = FacadeFrameBudget.serializedBytes(probe)
        let manual = (try? JSONSerialization.data(withJSONObject: probe))?.count ?? 0
        XCTAssertEqual(measured, manual)
        XCTAssertGreaterThan(measured, (probe["s"] as? String)?.count ?? 0)
    }

    func testLaggingCursorGetsExplicitResyncNotSilentGap() async throws {
        let database = try await migrated()
        let store = SQLiteRunStore(database: database)
        let (_, runID) = try await seedRun(database: database, store: store, events: 30) { "{\"i\":\($0)}" }
        let pump = FacadeEventPump()
        await pump.refreshDurableWindow(runID: runID, store: store)
        // Simulate a window that has moved (attach only the tail).
        let tail: [RuntimeDurableEvent]
        let records = try await store.events(runID: runID, afterSequence: 15, limit: 200)
        tail = records.map(RuntimeDurableEvent.init)
        pump.attachDurableWindow(runID: runID, events: tail, runExists: true)
        let page = pump.pollDurable(runID: runID, afterSequence: 5,
                                    budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        XCTAssertEqual(page["resyncRequired"] as? Bool, true)
        // Content still starts at the earliest retained item, never invented.
        let items = page["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.first?["sequence"] as? Int, 16)
    }

    func testGoneRunIsTypedNotFoundWithResyncNeverEmptySuccess() {
        let pump = FacadeEventPump()
        let runID = UUID()
        // Honest notAttached before any attach.
        let absent = pump.pollDurable(runID: runID, afterSequence: 0, budgetBytes: 4_096)
        XCTAssertEqual(absent["windowState"] as? String,
                       FacadeEventPump.DurableWindowStatus.notAttached.rawValue)
        // Attached but the durable owner is gone.
        pump.attachDurableWindow(runID: runID, events: [], runExists: false)
        let gone = pump.pollDurable(runID: runID, afterSequence: 0, budgetBytes: 4_096)
        XCTAssertEqual(gone["windowState"] as? String,
                       FacadeEventPump.DurableWindowStatus.runGone.rawValue)
        XCTAssertEqual(gone["resyncRequired"] as? Bool, true)
        let items = gone["events"] as? [[String: Any]] ?? []
        XCTAssertTrue(items.isEmpty)   // no fabricated events
    }

    // MARK: Live consumers

    func testDeltaSaturationDropsWithResyncAndNeverDetachesPriority() {
        let pump = FacadeEventPump()
        let runID = UUID()
        let token = pump.attachConsumer(runID: runID)
        for index in 0..<(FacadeEventPump.Limits.liveRingEvents + 100) {
            let outcome = pump.ingestLive(.answerDelta(TextDelta(text: "d\(index)")),
                                          token: token)
            switch outcome {
            case .enqueued, .droppedDeltas: break
            default: return XCTFail("delta ingest must stay attached: \(outcome)")
            }
        }
        let taken = pump.takeLive(token: token, budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        XCTAssertEqual(taken["liveState"] as? String, "resyncRequired")
        XCTAssertEqual(taken["resyncRequired"] as? Bool, true)
        // Priority frames survive the delta pressure and arrive.
        let priority = pump.ingestLive(.approvalResolved(callID: "call-1"), token: token)
        XCTAssertEqual(priority, .enqueued)
        let drained = pump.takeLive(token: token, budgetBytes: 4_096)
        let frames = drained["frames"] as? [[String: Any]] ?? []
        XCTAssertTrue(frames.contains { ($0["priority"] as? Bool) == true })
    }

    func testPrioritySaturationDetachesConsumerButRunContinues() {
        let pump = FacadeEventPump()
        let runID = UUID()
        let token = pump.attachConsumer(runID: runID)
        var detachedAt: Int?
        for index in 0..<(FacadeEventPump.Limits.priorityRingEvents + 8) {
            let outcome = pump.ingestLive(.stateChanged(.streaming), token: token)
            if outcome == .detached { detachedAt = index; break }
            if case .droppedDeltas = outcome {
                return XCTFail("priority ingest must never report delta drops")
            }
        }
        XCTAssertEqual(detachedAt, FacadeEventPump.Limits.priorityRingEvents)
        // After detach: further ingest cannot enqueue, and the projection is
        // explicitly resync-required. Nothing in this path cancels a run —
        // the run is owned by the separately bounded service lifecycle.
        let late = pump.ingestLive(.terminal(.completed), token: token)
        XCTAssertEqual(late, .detached)
        let taken = pump.takeLive(token: token, budgetBytes: 4_096)
        XCTAssertEqual(taken["liveState"] as? String, "detached")
        XCTAssertEqual(taken["resyncRequired"] as? Bool, true)
    }

    func testConsumerReattachFencesOldEpochLateCallbacks() {
        let pump = FacadeEventPump()
        let runID = UUID()
        let first = pump.attachConsumer(runID: runID)
        let second = pump.attachConsumer(runID: runID)   // re-attach = new epoch
        XCTAssertNotEqual(first.epoch, second.epoch)
        // Epoch fencing is reported BEFORE the detach classification (Main
        // decision 2026-10-20): a re-attached old-epoch token is
        // fencedByEpoch even though re-attach also marked its state detached.
        XCTAssertEqual(pump.ingestLive(.terminal(.completed), token: first), .fencedByEpoch)
        XCTAssertEqual(pump.ingestLive(.terminal(.completed), token: second), .enqueued)
        // The latest-epoch take (binder path) sees only the new consumer.
        let taken = pump.takeLatestLive(runID: runID, budgetBytes: 4_096)
        let frames = taken["frames"] as? [[String: Any]] ?? []
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(taken["liveState"] as? String, "attached")
    }

    func testNoConsumerIsHonestUntilRealTrackTaskAttaches() {
        let pump = FacadeEventPump()
        let taken = pump.takeLatestLive(runID: UUID(), budgetBytes: 4_096)
        XCTAssertEqual(taken["liveState"] as? String, "noConsumer")
        let frames = taken["frames"] as? [[String: Any]] ?? []
        XCTAssertTrue(frames.isEmpty)
    }

    func testHarnessEventFramesAreRealCodableContent() {
        let pump = FacadeEventPump()
        let runID = UUID()
        let token = pump.attachConsumer(runID: runID)
        let delta = HarnessEvent.answerDelta(TextDelta(text: "你好 🎉", blockID: "b1"))
        XCTAssertEqual(pump.ingestLive(delta, token: token), .enqueued)
        let taken = pump.takeLive(token: token, budgetBytes: 4_096)
        let frames = taken["frames"] as? [[String: Any]] ?? []
        XCTAssertEqual(frames.count, 1)
        // The frame payload round-trips the ORIGINAL Codable encoding.
        let payload = frames.first?["payload"] as? String ?? ""
        XCTAssertTrue(payload.contains("你好"))
        XCTAssertTrue(payload.contains("answerDelta") || payload.contains("blockID"))
    }

    // MARK: Window bounds

    func testWindowIsBoundedAndSlidingWithoutRenumbering() async throws {
        let database = try await migrated()
        let store = SQLiteRunStore(database: database)
        let pump = FacadeEventPump()
        let (conversationID, _) = try await seedRun(database: database, store: store, events: 1) { "{\"i\":\($0)}" }
        let runID = UUID()
        let now = Date()
        try await store.saveRun(RunRecord(id: runID, conversationID: conversationID,
                                          state: "running", goal: "slide", startedAt: now))
        for index in 1...(FacadeEventPump.Limits.durablePageSize * 3) {
            _ = try await store.appendEvent(runID: runID, kind: .status,
                                            payloadJSON: "{\"i\":\(index)}")
        }
        await pump.refreshDurableWindow(runID: runID, store: store)
        await pump.refreshDurableWindow(runID: runID, store: store)
        await pump.refreshDurableWindow(runID: runID, store: store)
        let page = pump.pollDurable(runID: runID, afterSequence: 0,
                                    budgetBytes: 1_024)
        let items = page["events"] as? [[String: Any]] ?? []
        XCTAssertFalse(items.isEmpty)
        // The bounded window may have dropped the head: the response must say
        // so instead of pretending contiguity.
        let watermark = page["watermark"] as? Int ?? 0
        if items.first?["sequence"] as? Int ?? 0 > 1 {
            XCTAssertEqual(page["resyncRequired"] as? Bool, true)
        }
        XCTAssertLessThanOrEqual(watermark, 600)
        XCTAssertGreaterThan(watermark, 0)
    }
}
