// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — bounded operation-effect pump (`floe.effect-cursor/3`).
// AUTHORED ONLY: not compiled or executed by this source package.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class FacadeEffectPumpTests: XCTestCase {

    override func setUp() {
        super.setUp()
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
    }

    override func tearDown() {
        RuntimeRetiredEffectRegistry.shared.removeAllForTesting()
        super.tearDown()
    }

    private func canonicalReceipt() -> String {
        "op:v1:" + String(repeating: "0a", count: 16)
    }

    // MARK: Receipt identity

    func testCanonicalReceiptShapeStrict() {
        XCTAssertTrue(RuntimeOperationReceipt.isValid(canonicalReceipt()))
        XCTAssertFalse(RuntimeOperationReceipt.isValid("int:v1:" + String(repeating: "0a", count: 16)))
        XCTAssertFalse(RuntimeOperationReceipt.isValid("op:v1:" + String(repeating: "0A", count: 16)))
        XCTAssertFalse(RuntimeOperationReceipt.isValid("op:v1:" + String(repeating: "0a", count: 15)))
        XCTAssertFalse(RuntimeOperationReceipt.isValid("op:v1:" + String(repeating: "0a", count: 17)))
        XCTAssertFalse(RuntimeOperationReceipt.isValid(""))
    }

    func testMintedReceiptsAreCanonicalAndUnique() {
        let pump = FacadeEffectPump(generation: 1)
        var seen = Set<String>()
        for index in 0..<64 {
            let receipt = pump.register(correlationID: "corr-\(index)")
            XCTAssertNotNil(receipt)
            guard let receipt else { continue }
            XCTAssertTrue(RuntimeOperationReceipt.isValid(receipt))
            XCTAssertTrue(seen.insert(receipt).inserted)
        }
    }

    // MARK: Unknown / expired honesty

    func testUnknownReceiptIsNotFoundAndNothingIsFabricated() {
        let pump = FacadeEffectPump(generation: 1)
        if case .notFound = pump.poll(receipt: canonicalReceipt(), afterSequence: 0) {
            // pass
        } else {
            XCTFail("unknown receipt must resolve notFound")
        }
        // Appending to an unknown receipt does NOT resurrect a stream.
        XCTAssertFalse(pump.append(receipt: canonicalReceipt(), kind: .accepted))
        if case .notFound = pump.poll(receipt: canonicalReceipt(), afterSequence: 0) {} else {
            XCTFail("append must not fabricate streams")
        }
    }

    func testRetiredAndNewGenerationReceiptExpiryAreHonest() {
        let first = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(first.register(correlationID: "old"))
        XCTAssertTrue(first.append(receipt: receipt, kind: .accepted))
        first.retire()
        if case .expired = first.poll(receipt: receipt, afterSequence: 0) {} else {
            XCTFail("retired unobserved receipt must be typed-expired")
        }
        let second = FacadeEffectPump(generation: 2)
        if case .notFound = second.poll(receipt: receipt, afterSequence: 0) {} else {
            XCTFail("new App instance never knows old receipts")
        }
    }

    // MARK: Bounded replay

    func testPageReplayWalksSequenceWithoutRenumbering() {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "walk"))
        for index in 1...5 {
            XCTAssertTrue(pump.append(receipt: receipt, kind: .prepared,
                                      code: nil,
                                      detail: ["marker": "m\(index)"]))
        }
        if case .page(let items, let next, let hasMore, let resync) =
            pump.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(items.count, 5)
            XCTAssertEqual(items.map { $0.sequence }, [1, 2, 3, 4, 5])
            XCTAssertEqual(next, 5)
            XCTAssertFalse(hasMore)
            XCTAssertFalse(resync)
        } else { XCTFail("page expected") }
        // Reading again from the watermark returns an empty page, not a
        // re-emit (bounded replay, not a snapshot re-broadcast).
        if case .page(let again, _, _, _) = pump.poll(receipt: receipt, afterSequence: 5) {
            XCTAssertTrue(again.isEmpty)
        } else { XCTFail("page expected") }
    }

    func testRingHeadDropSurfacesResyncExactlyOnce() {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "ring"))
        let cap = FacadeEffectPump.Limits.maximumEffectsPerReceipt
        for index in 1...(cap + 10) {
            XCTAssertTrue(pump.append(receipt: receipt, kind: .prepared,
                                      detail: ["marker": "m\(index)"]))
        }
        if case .page(let items, let next, let hasMore, let resync) =
            pump.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertTrue(resync)                       // explicit, never silent
            XCTAssertEqual(items.first?.kind, .resyncRequired)
            XCTAssertEqual(items.first?.code, .resyncRequired)
            // The retained head starts at the FIRST NON-DROPPED sequence.
            XCTAssertEqual(items.dropFirst().first?.sequence, 11)
            XCTAssertEqual(next, cap + 10)
            XCTAssertFalse(hasMore)                     // everything retained was read
        } else { XCTFail("page expected") }
        // The synthetic marker is not replayed and resync clears after read.
        if case .page(let later, _, _, let resyncLater) =
            pump.poll(receipt: receipt, afterSequence: cap + 10) {
            XCTAssertFalse(resyncLater)
            XCTAssertTrue(later.isEmpty)
        }
    }

    // MARK: Exact-once terminal

    func testPreparedAndStartedRemainLiveUntilCommittedTerminal() throws {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = try XCTUnwrap(pump.register(correlationID: "progress-to-terminal"))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .prepared))
        XCTAssertFalse(pump.isTerminal(receipt: receipt))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .started))
        XCTAssertFalse(pump.isTerminal(receipt: receipt))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .accepted))
        XCTAssertTrue(pump.isTerminal(receipt: receipt))
        XCTAssertFalse(pump.append(receipt: receipt, kind: .started))
        guard case .page(let items, let next, let hasMore, let resync) =
            pump.poll(receipt: receipt, afterSequence: 0) else {
            return XCTFail("expected the complete owned progress/terminal sequence")
        }
        XCTAssertEqual(items.map(\.kind), [.prepared, .started, .accepted])
        XCTAssertEqual(items.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(items.map(\.isTerminal), [false, false, true])
        XCTAssertEqual(next, 3)
        XCTAssertFalse(hasMore)
        XCTAssertFalse(resync)
    }


    func testTerminalSettlesOnceAndLaterAppendsRefused() {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "once"))
        XCTAssertTrue(pump.append(receipt: receipt, kind: .failed, code: .migrationFailed))
        XCTAssertTrue(pump.isTerminal(receipt: receipt))
        XCTAssertFalse(pump.append(receipt: receipt, kind: .accepted))
        if case .page(let items, _, _, _) = pump.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.kind, .failed)
            XCTAssertEqual(items.first?.code, .migrationFailed)
        } else { XCTFail("page expected") }
    }

    // MARK: Registry bounds

    func testRegistryEvictsOnlyTerminalStreamsThenRefuses() {
        let pump = FacadeEffectPump(generation: 1)
        var liveReceipts: [String] = []
        // Fill with LIVE (non-terminal) streams: they must never be evicted.
        for index in 0..<FacadeEffectPump.Limits.maximumLiveReceipts {
            let receipt = pump.register(correlationID: "live-\(index)")
            XCTAssertNotNil(receipt)
            if let receipt { liveReceipts.append(receipt) }
        }
        // One more live receipt with nothing terminal to evict: refused.
        let extra = pump.register(correlationID: "extra")
        XCTAssertNil(extra)
        // Terminalise one, then registration succeeds again.
        let doomed = XCTUnwrapNotNilLocal(liveReceipts.first)
        XCTAssertTrue(pump.append(receipt: doomed, kind: .accepted))
        let replacement = pump.register(correlationID: "replacement")
        XCTAssertNotNil(replacement)
    }

    // MARK: Effect JSON shape

    func testEffectItemJsonIsTypedOnly() throws {
        let item = RuntimeEffectItem(sequence: 3, kind: .failed, code: .recoveryFailed,
                                     detail: ["ownedStoreReady": "false"])
        let data = try JSONSerialization.data(withJSONObject: item.jsonObject,
                                              options: [.sortedKeys])
        let string = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(string.contains("\"kind\":\"failed\""))
        XCTAssertTrue(string.contains("\"code\":\"recoveryFailed\""))
        XCTAssertTrue(string.contains("\"sequence\":3"))
        // detail is an ordered key/value list (deterministic under sortedKeys)
        XCTAssertTrue(string.contains("\"detail\""))
    }

    // MARK: RB1-R1 — retired-generation routing (terminal-only, bounded)

    func testStagedPumpCoversTheSettlementWindowWithoutNotFound() {
        let pump = FacadeEffectPump(generation: 7)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "anchor"))
        RuntimeRetiredEffectRegistry.shared.stagePending(generation: 7, effects: pump)
        // Before the terminal settles the receipt is KNOWN (empty page), not
        // a transient notFound that would trick a client into giving up.
        if let result = RuntimeRetiredEffectRegistry.shared.pollPending(
            receipt: receipt, afterSequence: 0) {
            if case .page(let items, _, _, _) = result {
                XCTAssertTrue(items.isEmpty)
            } else { XCTFail("known staged receipt must page empty") }
        } else { XCTFail("staged pump must know the receipt") }
        XCTAssertTrue(pump.append(receipt: receipt, kind: .accepted))
        if let result = RuntimeRetiredEffectRegistry.shared.pollPending(
            receipt: receipt, afterSequence: 0) {
            if case .page(let items, _, _, _) = result {
                XCTAssertEqual(items.last?.kind, .accepted)
            } else { XCTFail("staged terminal page") }
        } else { XCTFail("staged terminal must be visible") }
        RuntimeRetiredEffectRegistry.shared.retire(
            generation: 7, streams: pump.exportTerminalStreams())
        RuntimeRetiredEffectRegistry.shared.completePending(generation: 7)
        if case .page(let items, _, _, _) =
            RuntimeRetiredEffectRegistry.shared.poll(receipt: receipt,
                                                     afterSequence: 0) {
            XCTAssertEqual(items.last?.kind, .accepted)
        } else { XCTFail("retained snapshot must survive pending completion") }
    }

    private func terminalStream(generation: UInt64, correlation: String,
                                kind: RuntimeEffectItem.Kind = .accepted,
                                code: RuntimeFacadeCode? = nil)
        -> (FacadeEffectPump, String, RuntimeRetiredEffectStream) {
        let pump = FacadeEffectPump(generation: generation)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: correlation))
        _ = pump.append(receipt: receipt, kind: kind, code: code)
        let stream = XCTUnwrapNotNilLocal(pump.exportTerminalStreams().first)
        return (pump, receipt, stream)
    }

    func testRetiredRegistryPreservesTerminalSequenceAndRejectsNonTerminal() {
        let (_, receipt, stream) = terminalStream(generation: 1, correlation: "old",
                                                   kind: .failed,
                                                   code: .migrationFailed)
        RuntimeRetiredEffectRegistry.shared.retire(generation: 1, streams: [stream])
        if case .page(let items, let next, let hasMore, let resync) =
            RuntimeRetiredEffectRegistry.shared.poll(receipt: receipt,
                                                     afterSequence: 0) {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.sequence, 1)
            XCTAssertEqual(items.first?.kind, .failed)
            XCTAssertEqual(items.first?.code, .migrationFailed)
            XCTAssertEqual(next, 1)
            XCTAssertFalse(hasMore)
            XCTAssertFalse(resync)
        } else { XCTFail("retired terminal must page") }
        // A non-terminal stream is never exported/retired.
        let livePump = FacadeEffectPump(generation: 2)
        let liveReceipt = XCTUnwrapNotNilLocal(livePump.register(correlationID: "live"))
        XCTAssertTrue(livePump.exportTerminalStreams().isEmpty)
        RuntimeRetiredEffectRegistry.shared.retire(
            generation: 2, streams: livePump.exportTerminalStreams())
        if case .notFound = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: liveReceipt, afterSequence: 0) {
            // expected: only terminal streams are routable
        } else { XCTFail("non-terminal must not be retained") }
    }

    func testRetiredRegistryTwoGenerationWindowAndTypedExpiry() {
        var receipts: [String] = []
        for generation in 1...3 {
            let (_, receipt, stream) = terminalStream(generation: UInt64(generation),
                                                      correlation: "g\(generation)")
            receipts.append(receipt)
            RuntimeRetiredEffectRegistry.shared.retire(generation: UInt64(generation),
                                                       streams: [stream])
        }
        XCTAssertEqual(RuntimeRetiredEffectRegistry.shared.retainedGenerationCount, 2)
        if case .expired = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: receipts[0], afterSequence: 0) {
            // expected: the oldest generation left the two-generation window
        } else { XCTFail("evicted generation must be typed expired") }
        if case .page(let items, _, _, _) = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: receipts[1], afterSequence: 0) {
            XCTAssertEqual(items.last?.kind, .accepted)
        } else { XCTFail("retained generation must still page") }
        if case .page = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: receipts[2], afterSequence: 0) {
            // expected
        } else { XCTFail("newest generation must still page") }
    }

    func testRetiredRegistryUnknownIsNotFoundAndEvictedIsExpired() {
        var firstReceipt = ""
        for generation in 1...3 {
            let (_, receipt, stream) = terminalStream(generation: UInt64(generation),
                                                      correlation: "win-\(generation)")
            if generation == 1 { firstReceipt = receipt }
            RuntimeRetiredEffectRegistry.shared.retire(generation: UInt64(generation),
                                                       streams: [stream])
        }
        if case .expired = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: firstReceipt, afterSequence: 0) {
            // expected: evicted generation is recognisable but expired
        } else { XCTFail("evicted receipt must be typed expired") }
        if case .notFound = RuntimeRetiredEffectRegistry.shared.poll(
            receipt: canonicalReceipt(), afterSequence: 0) {
            // expected
        } else { XCTFail("never-seen receipt must be notFound") }
    }

    func testRetiredRegistryReplacementKeepsCursorTail() {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "replace"))
        _ = pump.append(receipt: receipt, kind: .closed)
        let first = XCTUnwrapNotNilLocal(pump.exportTerminalStreams().first)
        RuntimeRetiredEffectRegistry.shared.retire(generation: 1, streams: [first])
        // Re-retiring the same generation with the same terminal is
        // idempotent (the anchor observer may fire twice).
        RuntimeRetiredEffectRegistry.shared.retire(generation: 1, streams: [first])
        if case .page(let items, let next, _, _) =
            RuntimeRetiredEffectRegistry.shared.poll(receipt: receipt,
                                                     afterSequence: 1) {
            XCTAssertTrue(items.isEmpty)
            XCTAssertEqual(next, 1)
        } else { XCTFail("tail page") }
    }

    func testRetiredRegistryStreamBoundDoesNotFabricateSuccess() {
        var streams: [RuntimeRetiredEffectStream] = []
        var receipts: [String] = []
        let pump = FacadeEffectPump(generation: 1)
        for index in 0..<(RuntimeRetiredEffectRegistry.Limits.maximumStreams + 8) {
            guard let receipt = pump.register(correlationID: "bulk-\(index)") else {
                break
            }
            _ = pump.append(receipt: receipt, kind: .accepted)
            receipts.append(receipt)
        }
        streams = pump.exportTerminalStreams()
        XCTAssertGreaterThan(streams.count, RuntimeRetiredEffectRegistry.Limits.maximumStreams)
        RuntimeRetiredEffectRegistry.shared.retire(generation: 1, streams: streams)
        // Over-bound receipts are expired (recognisable), never accepted and
        // never silently notFound.
        var expiredCount = 0
        for receipt in receipts {
            switch RuntimeRetiredEffectRegistry.shared.poll(receipt: receipt,
                                                             afterSequence: 0) {
            case .expired: expiredCount += 1
            case .page: break
            case .notFound: XCTFail("retired-but-evicted receipt must be expired")
            }
        }
        XCTAssertGreaterThan(expiredCount, 0)
        XCTAssertLessThanOrEqual(
            RuntimeRetiredEffectRegistry.shared.retainedGenerationCount, 2)
    }

    func testCorrelationEchoAvailableForScopedVisibility() {
        let pump = FacadeEffectPump(generation: 1)
        let receipt = XCTUnwrapNotNilLocal(pump.register(correlationID: "corr-a"))
        XCTAssertEqual(pump.correlationID(for: receipt), "corr-a")
    }
}

private func XCTUnwrapNotNilLocal<T>(_ value: T?) -> T {
    guard let value else { fatalError("required value missing") }
    return value
}
