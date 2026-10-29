// SPDX-License-Identifier: MPL-2.0
// Authored focused suite for the owned-slot conflict admission rule
// (job-c4dd7334fa5341d2, Main rulings 2026-10-28).
//
// What is proven here, deterministically and without the Core composition:
//  * the pure admission rule reports a conflict ONLY for THIS conversation's
//    own live interactive terminal that the engine actually still holds a
//    lease for — never for a foreign conversation, a language/run session, a
//    released lease, a free slot or an unbound generation;
//  * the gate can never be widened by its caller: a tool that does not need
//    the engine slot is not gated even when a real conflict exists;
//  * the trusted-producer registry is epoch-fenced in BOTH directions (a
//    strictly-newer generation only; an exact-epoch retire that keeps the
//    monotonic high-water mark; a delayed stale registration refused even
//    AFTER a retirement) and NEVER invents a conflict when no producer is
//    registered, so the ordinary approval path is unchanged;
//  * a generation replaced while the probe was in flight cannot publish its
//    stale session identity into this run's approval;
//  * the exact-generation probe adapter answers nil for a store whose
//    generation moved on, and the store itself fails CLOSED (nil, no crash,
//    no invented conflict) when no live Root generation/composition exists;
//  * an isolated registry never publishes into the process-wide composition.
//
// Test isolation (Main review 2026-10-28): every registry assertion runs on a
// FRESH `LinuxEngineSlotRegistry()` instance exercising the SAME production
// implementation. Nothing here registers into, retires from, resets or reads
// mutable state of `LinuxEngineSlotRegistry.shared`, so no synthetic
// generation can poison a later real G02/mailbox bind and no sibling owner's
// live producer can be retired. There is no production reset or bypass, and
// the real Root epoch counter is untouched.
//
// Nothing here stops, kills, replays or grants anything: the suite observes
// the admission truth only.
import XCTest
import Foundation
// The admission vocabulary lives in FloeAgentRuntime (Main module-placement
// ruling 2026-10-28); this test target already imports that module elsewhere.
import FloeAgentRuntime
@testable import FloeAndroidCore

// MARK: - Fixtures

/// A probe that answers from fixed facts and counts how often it was asked.
/// All bookkeeping is synchronous: `NSLock.lock/unlock` are `noasync`, so an
/// async method must never take them directly (Swift 6).
private final class StubSlotProbe: LinuxEngineSlotConflictProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAnswer: LinuxEngineSlotConflict?
    private var storedCalls: [UUID] = []

    init(answer: LinuxEngineSlotConflict?) { storedAnswer = answer }

    private func record(_ conversationID: UUID) {
        lock.lock(); storedCalls.append(conversationID); lock.unlock()
    }

    private func snapshot() -> (answer: LinuxEngineSlotConflict?, calls: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        return (storedAnswer, storedCalls)
    }

    var calls: [UUID] { snapshot().calls }

    func interactiveTerminalHoldingEngineSlot(
        conversationID: UUID
    ) async -> LinuxEngineSlotConflict? {
        record(conversationID)
        return snapshot().answer
    }
}

/// A probe that parks until its gate opens, so a generation replacement can
/// land WHILE the read is in flight. Both signals are ONE-SHOT latches: a
/// release (or an entry) that happens before its waiter parks is remembered,
/// so the interleaving below cannot hang nondeterministically.
private final class GatedSlotProbe: LinuxEngineSlotConflictProbe, @unchecked Sendable {
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var entered = false

        /// Publishes that the read really is parked inside this probe, so the
        /// generation replacement in the test cannot race ahead of it (a test
        /// that replaced the generation before the probe was entered would
        /// prove nothing).
        func noteEntered() {
            entered = true
            let pending = enteredWaiters
            enteredWaiters.removeAll()
            pending.forEach { $0.resume() }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private let gate = Gate()
    let answer: LinuxEngineSlotConflict?

    init(answer: LinuxEngineSlotConflict?) { self.answer = answer }

    func interactiveTerminalHoldingEngineSlot(
        conversationID: UUID
    ) async -> LinuxEngineSlotConflict? {
        await gate.noteEntered()
        await gate.wait()
        return answer
    }

    func waitUntilEntered() async { await gate.waitUntilEntered() }
    func release() async { await gate.release() }
}

private struct NullTerminalSink: G04TerminalEventSink {
    func emitControl(_ object: [String: Any]) {}
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {}
}

// MARK: - Suite

final class LinuxEngineSlotConflictAdmissionTests: XCTestCase {

    // MARK: Pure rule

    func testRuleReportsConflictOnlyForOwnLiveEngineOwnedInteractiveTerminal() {
        let conversation = UUID()
        let token = "term-\(UUID().uuidString.lowercased())"
        let conflict = LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation,
            nativeEpoch: 3,
            liveInteractiveSessionTokens: [token],
            engineSlotBusy: true,
            ownedEngineSessionKeys: ["run:someone-else:abc", token]
        )
        XCTAssertEqual(conflict?.conversationID, conversation)
        XCTAssertEqual(conflict?.sessionToken, token, "the exact holder is named, never a sibling")
        XCTAssertEqual(conflict?.nativeEpoch, 3)
    }

    func testRuleIsNilForEveryNonConflictTruth() {
        let conversation = UUID()
        let token = "term-token"

        // A free slot is never a conflict, whatever the projection claims.
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 3,
            liveInteractiveSessionTokens: [token], engineSlotBusy: false,
            ownedEngineSessionKeys: [token]))

        // The engine already proved this lease released: no live holder.
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 3,
            liveInteractiveSessionTokens: [token], engineSlotBusy: true,
            ownedEngineSessionKeys: ["run:other:xyz"]))

        // No live interactive terminal of THIS conversation (a language/run
        // session is not a manual terminal, and is filtered by the caller).
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 3,
            liveInteractiveSessionTokens: [], engineSlotBusy: true,
            ownedEngineSessionKeys: [token]))

        // Unbound generation (0 is never an epoch).
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 0,
            liveInteractiveSessionTokens: [token], engineSlotBusy: true,
            ownedEngineSessionKeys: [token]))

        // No owned lease at all.
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 3,
            liveInteractiveSessionTokens: [token], engineSlotBusy: true,
            ownedEngineSessionKeys: []))

        // An empty token is never a holder.
        XCTAssertNil(LinuxEngineSlotConflictRule.conflict(
            conversationID: conversation, nativeEpoch: 3,
            liveInteractiveSessionTokens: [""], engineSlotBusy: true,
            ownedEngineSessionKeys: [""]))
    }

    // MARK: Tool scope

    func testOnlySlotAcquiringToolsAreGated() {
        // These must ACQUIRE the single engine slot before anything starts.
        XCTAssertTrue(LinuxEngineSlotTools.acquiresSlot("exec.shell"))
        XCTAssertTrue(LinuxEngineSlotTools.acquiresSlot("shell.open"))
        // These operate on an already-open session, or never touch the engine.
        for name in ["shell.exchange", "shell.close", "shell.signal",
                     "jobs.submit", "file.write", "web.fetch", "skill.create", ""] {
            XCTAssertFalse(LinuxEngineSlotTools.acquiresSlot(name), name)
        }
    }

    // MARK: Registry (a FRESH isolated instance per test)

    func testNoRegisteredProducerNeverInventsAConflict() async {
        let registry = LinuxEngineSlotRegistry()
        XCTAssertNil(registry.registeredEpoch)
        XCTAssertEqual(registry.reservedHighWaterEpoch, 0)
        let shellConflict = await registry.interactiveTerminalConflict(
            conversationID: UUID(), toolName: "exec.shell")
        let openConflict = await registry.interactiveTerminalConflict(
            conversationID: UUID(), toolName: "shell.open")
        XCTAssertNil(shellConflict, "with no trusted producer the ordinary approval path must stay unchanged")
        XCTAssertNil(openConflict)
    }

    func testCallerCanNeverWidenTheGateToANonSlotTool() async {
        let registry = LinuxEngineSlotRegistry()
        let conversation = UUID()
        let probe = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-1", nativeEpoch: 3))
        XCTAssertTrue(registry.register(probe, epoch: 3))

        // A real conflict exists, but a tool that does not need the slot is
        // not gated — and the producer is not even consulted for it.
        let exchangeConflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "shell.exchange")
        let fileConflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "file.write")
        XCTAssertNil(exchangeConflict)
        XCTAssertNil(fileConflict)
        XCTAssertEqual(probe.calls, [], "a non-slot tool must not reach the trusted producer")

        // The slot-acquiring tool does consult it.
        let conflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertEqual(conflict?.sessionToken, "term-1")
        XCTAssertEqual(conflict?.nativeEpoch, 3)
        XCTAssertEqual(probe.calls, [conversation])
    }

    func testAProducerAnsweringForAnotherConversationIsDiscarded() async {
        let registry = LinuxEngineSlotRegistry()
        let mine = UUID()
        let foreign = UUID()
        let probe = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: foreign, sessionToken: "term-foreign", nativeEpoch: 3))
        XCTAssertTrue(registry.register(probe, epoch: 3))
        let conflict = await registry.interactiveTerminalConflict(
            conversationID: mine, toolName: "exec.shell")
        XCTAssertNil(conflict,
            "a foreign conversation's terminal must never gate or be offered for this run")
        XCTAssertEqual(probe.calls, [mine], "the producer was asked, and its wrong-owner answer was dropped")
    }

    func testRegistrationIsStrictlyNewerEpochAndRetireIsExactEpoch() async {
        let registry = LinuxEngineSlotRegistry()
        let conversation = UUID()
        let older = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-older", nativeEpoch: 10))
        let newer = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-newer", nativeEpoch: 11))

        XCTAssertTrue(registry.register(newer, epoch: 11))
        // A same-or-older generation never replaces a newer producer.
        XCTAssertFalse(registry.register(older, epoch: 11))
        XCTAssertFalse(registry.register(older, epoch: 10))
        XCTAssertFalse(registry.register(older, epoch: 0))
        XCTAssertEqual(registry.registeredEpoch, 11)
        let beforeRetire = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertEqual(beforeRetire?.sessionToken, "term-newer")

        // A stale retire cannot clear the newer generation.
        XCTAssertFalse(registry.retire(epoch: 10))
        XCTAssertEqual(registry.registeredEpoch, 11)
        // The exact generation retires, and the conflict truth goes with it.
        XCTAssertTrue(registry.retire(epoch: 11))
        XCTAssertNil(registry.registeredEpoch)
        let afterRetire = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertNil(afterRetire)
        // Retirement clears the producer, NOT the accepted-generation history.
        XCTAssertEqual(registry.reservedHighWaterEpoch, 11)
        // A second retire of the same generation is not a second effect.
        XCTAssertFalse(registry.retire(epoch: 11))
    }

    /// Review finding 1 (Main, 2026-10-28): a retirement must not erase the
    /// monotonic high-water mark, or `register(10) → retire(10)` would let a
    /// DELAYED `register(9)` succeed and publish an ABA generation that can
    /// match an older probe still in flight.
    func testADelayedStaleRegistrationAfterRetirementIsStillRefused() async {
        let registry = LinuxEngineSlotRegistry()
        let conversation = UUID()
        let staleProbe = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-stale", nativeEpoch: 20))
        let newerProbe = StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-newer", nativeEpoch: 21))

        XCTAssertTrue(registry.register(newerProbe, epoch: 21))
        XCTAssertTrue(registry.retire(epoch: 21))
        XCTAssertNil(registry.registeredEpoch)

        // The delayed stale registration arrives AFTER the retirement.
        XCTAssertFalse(registry.register(staleProbe, epoch: 20),
            "a generation older than the accepted high-water mark must never resurrect")
        XCTAssertFalse(registry.register(staleProbe, epoch: 21),
            "the retired generation itself must never resurrect either")
        XCTAssertNil(registry.registeredEpoch)
        XCTAssertEqual(registry.reservedHighWaterEpoch, 21)
        let conflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertNil(conflict,
            "no producer means no conflict, so no approval is gated on a resurrected generation")
        XCTAssertEqual(staleProbe.calls, [])
    }

    func testAGenerationReplacedInFlightCannotPublishItsStaleIdentity() async {
        let registry = LinuxEngineSlotRegistry()
        let conversation = UUID()
        let gated = GatedSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-stale", nativeEpoch: 30))
        XCTAssertTrue(registry.register(gated, epoch: 30))

        let read = Task {
            await registry.interactiveTerminalConflict(
                conversationID: conversation, toolName: "exec.shell")
        }
        // Wait until the read is REALLY parked inside the stale producer, so
        // the replacement below provably lands mid-flight.
        await gated.waitUntilEntered()
        // The generation is replaced WHILE the read is parked in the probe.
        let newerProbe = StubSlotProbe(answer: nil)
        XCTAssertTrue(registry.register(newerProbe, epoch: 31))
        await gated.release()

        let conflict = await read.value
        XCTAssertNil(conflict, "a retired generation's session identity must never reach this run's approval")
        XCTAssertEqual(newerProbe.calls, [], "the stale answer must be discarded, not re-asked")
        XCTAssertEqual(registry.registeredEpoch, 31)
    }

    func testAnIsolatedRegistryNeverPublishesIntoTheProcessWideComposition() async {
        // The isolation property the suite depends on: a fresh registry is a
        // distinct instance, and a synthetic producer registered there is
        // invisible to the composition-root facade. Nothing in this file
        // mutates the shared registry, so no later real generation is poisoned.
        let isolated = LinuxEngineSlotRegistry()
        XCTAssertFalse(isolated === LinuxEngineSlotRegistry.shared)
        XCTAssertFalse(isolated === LinuxEngineSlotAuthority.shared)
        let conversation = UUID()
        XCTAssertTrue(isolated.register(StubSlotProbe(answer: LinuxEngineSlotConflict(
            conversationID: conversation, sessionToken: "term-isolated", nativeEpoch: 3)), epoch: 3))

        let isolatedConflict = await isolated.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertEqual(isolatedConflict?.sessionToken, "term-isolated")

        let facadeConflict = await LinuxEngineSlotAuthority.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertNil(facadeConflict,
            "an isolated test registry must never answer through the process-wide producer")
    }

    // MARK: Exact-generation adapter + fail-closed store

    func testProbeAdapterRefusesAStoreFromADifferentGeneration() async {
        let store = G04TerminalStore(epoch: 40, sink: NullTerminalSink())
        let mismatched = G04TerminalSlotConflictProbe(store: store, epoch: 41)
        let conflict = await mismatched.interactiveTerminalHoldingEngineSlot(conversationID: UUID())
        XCTAssertNil(conflict, "a retired generation must never report a terminal it no longer owns")
    }

    func testStoreFailsClosedWithoutALiveRootGeneration() async {
        // No live Root epoch and no installed composition exist on the host
        // test process: the store must answer nil (never invent a conflict,
        // never touch the engine) for any conversation.
        let store = G04TerminalStore(epoch: 41, sink: NullTerminalSink())
        let storeConflict = await store.interactiveTerminalHoldingEngineSlot(conversationID: UUID())
        XCTAssertNil(storeConflict)
        // Actor-isolated stored let: read it with await into a local before
        // constructing the adapter (Main ruling: await locals before asserts).
        let storeEpoch = await store.epoch
        let adapter = G04TerminalSlotConflictProbe(store: store, epoch: storeEpoch)
        let adapterConflict = await adapter.interactiveTerminalHoldingEngineSlot(conversationID: UUID())
        XCTAssertNil(adapterConflict)
    }

    // MARK: Vocabulary stability

    func testApprovalReasonTokenIsTheExactTypedConflictClass() {
        // The token rides the EXISTING escalation `reason` channel, so it is
        // matched exactly (never by substring) and is the only vocabulary the
        // trusted host maps to localized copy.
        XCTAssertEqual(LinuxEngineSlotConflict.approvalReasonToken,
                       "linuxEngineSlotHeldByOwnInteractiveTerminal")
        XCTAssertTrue(LinuxEngineSlotConflict.approvalReasonToken.allSatisfy {
            $0.isLetter || $0.isNumber
        }, "the token must stay a single opaque identifier with no prose or separators")
    }
}
