// SPDX-License-Identifier: MPL-2.0
//
// G02 temporary-session ACTUAL-boundary tests (this revision): the two
// mandatory Main repairs get REAL wired coverage —
//
//   * TMP-NAV-2 — the `temp.end` synchronous admission fence + the typed
//     `value.navigationFence` acknowledgement, exercised through the REAL
//     process binder ingress, the generation's REAL mailbox and the REAL
//     effect pump, including a mailbox blocked behind an in-flight Keep.
//   * TMP-COMMIT-1 — the commit-boundary fence against the ORIGINAL
//     `ConversationPromoter` (Android mirror) on the SAME owned schema-46
//     file-backed database: a discard landing between the transaction
//     guards refuses the COMMIT (zero rows); a discard landing after the
//     FINAL guard resolves by the REAL commit outcome; the attempt-resolved
//     -lost contract and idempotent repeats are proven.
//   * The deferred original composition intent — the REAL temp.start
//     accepted value carries the ACTUAL native root epoch (never 7, never
//     a UI counter), and the fence ack carries the identical epoch, equal
//     to the G02NativeRootEpoch readback.
//
// Fixtures are the same monotonic REAL bootstrap; teardown is the REAL
// shutdown control. No copied-code assertions.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeTemporaryNavigationFenceTests: XCTestCase {
    private var fixture: TemporaryDomainFixture!

    override func setUp() async throws {
        // WIRED: processors on the generation's REAL registry; every
        // submit travels the exact production path:
        // binder handler -> effects.register -> mailbox -> processor ->
        // terminal on the same receipt stream.
        fixture = try await TemporaryDomainFixture.make(wiredMailbox: true)
    }

    override func tearDown() async throws {
        await fixture.teardown()
    }

    // MARK: - Helpers

    private func binderHandler(for command: String) throws -> RuntimeCommandBinder.Handler {
        let scope: BridgeV3.Scope = command == "temp.start" ? .launch : .conversationLifecycle
        let key = BridgeV3.handlerKey(scope: scope, command: command)
        guard let handler = RuntimeCommandBinder.shared.handler(for: key) else {
            throw NSError(domain: "fence", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "\(command) binder key not installed"])
        }
        return handler
    }

    private func submit(_ command: String, _ envelope: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let response = try binderHandler(for: command)(data)
        guard let object = try JSONSerialization.jsonObject(with: response)
                as? [String: Any] else {
            throw NSError(domain: "fence", code: 2)
        }
        return object
    }

    private func receiptID(of response: [String: Any]) throws -> String {
        XCTAssertEqual(response["ok"] as? Bool, true)
        guard let receipt = response["operationReceiptID"] as? String else {
            throw NSError(domain: "fence", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(response)"])
        }
        return receipt
    }

    /// Bounded drain: poll the REAL pump until the receipt carries its
    /// single terminal (poll is non-advancing). Never an unbounded sleep.
    private func awaitTerminal(receipt: String,
                               timeoutMillis: Int = 5_000) async throws
        -> [RuntimeEffectItem] {
        var waited = 0
        while waited < timeoutMillis {
            if case .page(let items, _, _, _) =
                fixture.effects.poll(receipt: receipt, afterSequence: 0),
               items.contains(where: { $0.kind.isTerminal }) {
                return items
            }
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        throw NSError(domain: "fence", code: 9,
                      userInfo: [NSLocalizedDescriptionKey:
                                    "terminal did not settle for \(receipt)"])
    }

    private func items(of receipt: String) throws -> [RuntimeEffectItem] {
        if case .page(let items, _, _, _) =
            fixture.effects.poll(receipt: receipt, afterSequence: 0) {
            return items
        }
        return []
    }

    private func navigationFenceItem(_ items: [RuntimeEffectItem]) -> RuntimeEffectItem? {
        items.first { item in
            guard case .object(let pairs)? = item.value else { return false }
            return pairs["navigationFence"] != nil
        }
    }

    private func startViaBinder() async throws
        -> (conversationID: UUID, incarnation: UUID, receipt: String,
            correlation: String) {
        let correlation = TemporaryTestEnvelopes.correlation()
        let response = try submit("temp.start",
                                  TemporaryTestEnvelopes.tempStart(correlation: correlation))
        // The IMMEDIATE answer is correlation + receipt ONLY (settled rule).
        XCTAssertEqual(Set(response.keys),
                       ["ok", "schema", "correlationID", "queued",
                        "operationReceiptID"])
        XCTAssertNil(response["conversationID"])
        let receipt = try receiptID(of: response)
        let items = try await awaitTerminal(receipt: receipt)
        guard let terminal = items.first(where: { $0.kind.isTerminal }),
              terminal.kind == .accepted,
              case .object(let value)? = terminal.value,
              case .string(let rawID)? = value["conversationID"],
              let cid = UUID(uuidString: rawID),
              case .string(let rawInc)? = value["incarnation"],
              let inc = UUID(uuidString: rawInc) else {
            throw NSError(domain: "fence", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "\(items)"])
        }
        return (cid, inc, receipt, correlation)
    }

    // MARK: - TMP-NAV-2: synchronous admission fence + typed ack

    func testSynchronousEndAdmissionFencesAndAcknowledgesBeforeMailboxDrains() async throws {
        let (cid, inc, _, _) = try await startViaBinder()

        // Park the mailbox behind an in-flight Keep blocked right BEFORE
        // the promoter transaction (Main's scenario: the native session
        // fence must NOT wait for the processor, and queued/prepared
        // answers are not acks).
        let gate = TempGateBox()
        await fixture.domain.setTestHooksForTesting(afterFreezeBeforeCommit: {
            await gate.wait()
        })
        let keepCorr = TemporaryTestEnvelopes.correlation()
        let keepReceipt = try receiptID(of: try submit("temp.keep",
            TemporaryTestEnvelopes.tempKeep(conversationID: cid,
                                             incarnation: inc,
                                             correlation: keepCorr)))
        var parked = false
        for _ in 0..<1_000 {
            let status = await fixture.domain.status()
            if status.promotion == "inFlight" { parked = true; break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(parked, "the keep must be stalled before the commit dispatch")

        let endCorr = TemporaryTestEnvelopes.correlation()
        let endReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid,
                                           incarnation: inc,
                                           correlation: endCorr)))

        // ---- WHILE THE KEEP IS STILL BLOCKED: the fence already landed.
        XCTAssertTrue(fixture.gate.blocksOperations(conversationID: cid,
                                                   incarnation: inc),
                      "the synchronous admission must fence before the drain")
        // The typed acknowledgement is present on the end receipt stream
        // WITHOUT the processor having run…
        let endItems = try items(of: endReceipt)
        guard let ack = navigationFenceItem(endItems),
              case .object(let value)? = ack.value,
              case .object(let fence)? = value["navigationFence"] else {
            gate.release()
            return XCTFail("no typed navigationFence acknowledgement while the mailbox was blocked")
        }
        // The acknowledgement is APPENDED SYNCHRONOUSLY by the submit
        // handler, so on the SAME receipt stream it always precedes the
        // end's terminal (the async drain). Assert the exact ordering.
        if let terminalIndex = endItems.firstIndex(where: { $0.kind.isTerminal }) {
            XCTAssertLessThan(ack.sequence, endItems[terminalIndex].sequence,
                              "the ack must precede the end's terminal/drain")
        }
        // NOT queued, NOT a bare prepared: the exact closed admitted object.
        XCTAssertEqual(fence["admitted"], .bool(true))
        XCTAssertEqual(fence["conversationID"], .string(cid.uuidString))
        XCTAssertEqual(fence["incarnationID"], .string(inc.uuidString))
        XCTAssertEqual(fence["requestCorrelationID"], .string(endCorr))
        XCTAssertEqual(fence["epoch"], .integer(Int64(fixture.epoch)))
        XCTAssertEqual(fence["reason"], .string("fenced"))
        XCTAssertFalse(ack.kind.isTerminal,
                       "the acknowledgement rides the non-terminal prepared stage")

        // Release the Keep: it unwinds truthfully through the fence.
        gate.release()
        let keepItems = try await awaitTerminal(receipt: keepReceipt)
        let keepTerminal = keepItems.first { $0.kind.isTerminal }!
        XCTAssertEqual(keepTerminal.kind, .rejected)
        XCTAssertEqual(keepTerminal.detail?["reason"], "promotionRefusedByFence")
        let drained = try await awaitTerminal(receipt: endReceipt)
        let endTerminal = drained.first { $0.kind.isTerminal }!
        XCTAssertEqual(endTerminal.kind, .accepted)
        XCTAssertEqual(endTerminal.detail?["endState"], "fenced")
        // The fenced discard persisted NOTHING.
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        // Exactly one cleanup happened (the async drain, AFTER the ack).
        XCTAssertEqual(fixture.surface.discarded.count, 1)
        // A late save/launch for the fenced tuple is refused.
        let late = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "late", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0, stagedAttachmentHandles: 0)
        guard case .refused(let error) = late else { return XCTFail("late launch must refuse") }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.tombstonedDiscarded)
        // A NEW session still starts normally afterwards (fence is
        // per-tuple, not a permanent ban).
        _ = try await startViaBinder()
    }

    func testAlreadyAbsentEndCertifiesAuthoritativelyAndAdmits() async throws {
        // No session ever existed this generation: the SAME lock that
        // fences admissions certifies absence — an admitted alreadyAbsent
        // ack (never a bare refusal, never a queued pretend).
        let cid = UUID()
        let inc = UUID()
        let corr = TemporaryTestEnvelopes.correlation()
        let endReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid,
                                           incarnation: inc,
                                           correlation: corr)))
        let items = try await awaitTerminal(receipt: endReceipt)
        guard let ack = navigationFenceItem(items),
              case .object(let value)? = ack.value,
              case .object(let fence)? = value["navigationFence"] else {
            return XCTFail("alreadyAbsent must ride the exact admitted ack")
        }
        XCTAssertEqual(fence["admitted"], .bool(true))
        XCTAssertEqual(fence["reason"], .string("alreadyAbsent"))
        XCTAssertEqual(fence["conversationID"], .string(cid.uuidString))
        let terminal = items.first { $0.kind.isTerminal }!
        XCTAssertEqual(terminal.kind, .accepted)
        XCTAssertEqual(terminal.detail?["endState"], "alreadyAbsent")
    }

    func testStaleIncarnationEndNeverAdmitsAndNeverFences() async throws {
        let (cid, _, _, _) = try await startViaBinder()
        let corr = TemporaryTestEnvelopes.correlation()
        let endReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid,
                                           incarnation: UUID(),
                                           correlation: corr)))
        let items = try await awaitTerminal(receipt: endReceipt)
        // Refusal is NOT an acknowledgement: no navigationFence anywhere.
        XCTAssertNil(navigationFenceItem(items),
                     "a refused admission must never fabricate an ack")
        let terminal = items.first { $0.kind.isTerminal }!
        XCTAssertEqual(terminal.kind, .rejected)
        XCTAssertEqual(terminal.detail?["reason"], "incarnationMismatch")
        // The live session is UNTOUCHED.
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
    }

    func testDuplicateEndCleansExactlyOnceAndCertifiesRetired() async throws {
        let (cid, inc, _, _) = try await startViaBinder()
        let firstReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid, incarnation: inc,
                                           correlation: TemporaryTestEnvelopes.correlation())))
        _ = try await awaitTerminal(receipt: firstReceipt)
        let secondReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid, incarnation: inc,
                                           correlation: TemporaryTestEnvelopes.correlation())))
        let items = try await awaitTerminal(receipt: secondReceipt)
        guard let ack = navigationFenceItem(items),
              case .object(let value)? = ack.value,
              case .object(let fence)? = value["navigationFence"] else {
            return XCTFail("exact alreadyRetired certification must admit")
        }
        XCTAssertEqual(fence["admitted"], .bool(true))
        XCTAssertEqual(fence["reason"], .string("alreadyRetired"))
        let terminal = items.first { $0.kind.isTerminal }!
        XCTAssertEqual(terminal.kind, .accepted)
        XCTAssertEqual(terminal.detail?["endState"], "alreadyRetired")
        // Exactly one surface discard ever happened.
        XCTAssertEqual(fixture.surface.discarded.count, 1)
    }

    func testTicketFencingRefusesAQueuedStartCommitAfterNavigationLanded() throws {
        // The exact mailbox race: a start job whose ticket was issued
        // BEFORE an admitted end must be unable to publish its RAM session
        // AFTER that end. Deterministic at the gate (same lock, no sleeps).
        let gate = fixture.gate
        gate.issueStartTicket(correlation: "start-1")
        let decision = gate.admitEnd(conversationID: UUID(),
                                     incarnation: UUID(),
                                     correlation: "end-1")
        XCTAssertTrue(decision.isAdmitted,
                      "certified absence still fences queued starts")
        XCTAssertFalse(gate.publishSession(conversationID: UUID(),
                                           incarnation: UUID(),
                                           fence: TemporaryPromotionCommitFence(
                                            sessionConversationID: UUID(),
                                            sessionIncarnation: UUID()),
                                           ticketCorrelation: "start-1"),
                       "a fenced ticket can never publish after the navigation")
        // A NEW ticket (a later, legitimate start) publishes normally.
        gate.issueStartTicket(correlation: "start-2")
        let cid = UUID(); let inc = UUID()
        XCTAssertTrue(gate.publishSession(conversationID: cid, incarnation: inc,
                                          fence: TemporaryPromotionCommitFence(
                                            sessionConversationID: cid,
                                            sessionIncarnation: inc),
                                          ticketCorrelation: "start-2"))
        XCTAssertEqual(gate.liveIdentity()?.conversationID, cid)
    }

    func testAdmissionAckEpochMatchesNativeRootReadbackAndTerminalCarriesSame() async throws {
        // MAIN_TEMP_ACK_NATIVE_EPOCH_DECISION: the wire epoch is the ACTUAL
        // native Root generation epoch. Readback agrees, and so does the
        // real temp.start accepted value (the deferred composition intent).
        XCTAssertEqual(G02NativeRootEpoch.readback(), fixture.epoch)
        let (cid, inc, receipt, _) = try await startViaBinder()
        let items = try await awaitTerminal(receipt: receipt)
        let terminal = items.first { $0.kind.isTerminal }!
        guard case .object(let value)? = terminal.value,
              case .integer(let epochValue)? = value["rootEpoch"] else {
            return XCTFail("temp.start accepted must carry the native rootEpoch")
        }
        XCTAssertEqual(epochValue, Int64(fixture.epoch))
        XCTAssertNotEqual(epochValue, 7, "no fixed-epoch fabrication")
        let corr = TemporaryTestEnvelopes.correlation()
        let endReceipt = try receiptID(of: try submit("temp.end",
            TemporaryTestEnvelopes.tempEnd(conversationID: cid, incarnation: inc,
                                           correlation: corr)))
        let endItems = try await awaitTerminal(receipt: endReceipt)
        guard let ack = navigationFenceItem(endItems),
              case .object(let value)? = ack.value,
              case .object(let fence)? = value["navigationFence"],
              case .integer(let ackEpoch)? = fence["epoch"] else {
            return XCTFail("fence ack missing")
        }
        XCTAssertEqual(ackEpoch, Int64(fixture.epoch))
        XCTAssertEqual(ackEpoch, epochValue)
    }

    func testReplacedDomainNeverFencesOrAdmits() throws {
        // Synchronous ingress is fail-closed when the epoch's domain is
        // gone: no fence, no ack, no receipt pretending.
        TemporaryDomainFacade.clearForTesting()   // simulate a replaced domain
        let data = try JSONSerialization.data(
            withJSONObject: TemporaryTestEnvelopes.tempEnd(conversationID: UUID(),
                                                           incarnation: UUID()))
        let handler = try binderHandler(for: "temp.end")
        let response = (try JSONSerialization.jsonObject(with: handler(data)))
            as! [String: Any]
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable")
    }



    // MARK: - TMP-COMMIT-1: the ACTUAL commit boundary (real file DB)

    /// A probe fence that lands the discard at exact promoter-internal
    /// moments, recording EVERY consultation. The authoritative decision is
    /// made in `beginFinalCommit`, which the promoter's commit-boundary
    /// observer invokes from SQLite's real pre-COMMIT callback.
    final class LinearizingProbeFence: PromotionCommitFence, @unchecked Sendable {
        enum Mode {
            /// Flip lands during the real pre-COMMIT callback, BEFORE the
            /// allow/refuse decision is taken there (the mandatory losing
            /// boundary: after the writer body returned, before COMMIT).
            case refuseDuringBoundary
            /// The callback allows the commit, THEN the discard lands (the
            /// in-flight commit genuinely wins the real boundary).
            case allowThenFlip
            /// Flip on the very first advisory body consultation.
            case earlyFlip
        }
        private let lock = NSLock()
        private let mode: Mode
        private var fenced = false
        private var phase: Int = 0   // 0 open, 1 attemptStarted, 2 resolved
        private var refusedAtBoundary = false
        var allowsCalls = 0
        var beginCalls = 0
        var finishCalls: [Bool] = []
        var boundaryHookRuns = 0

        init(mode: Mode) { self.mode = mode }

        private func flipLocked() { fenced = true }

        func allowsCommit() -> Bool {
            lock.lock()
            allowsCalls += 1
            var value = (phase == 0 && !fenced)
            if mode == .earlyFlip, allowsCalls == 1 {
                flipLocked()
                value = false
            }
            lock.unlock()
            return value
        }

        func beginFinalCommit() -> Bool {
            lock.lock()
            beginCalls += 1
            guard phase == 0, !fenced else {
                refusedAtBoundary = true
                lock.unlock()
                return false
            }
            switch mode {
            case .allowThenFlip:
                phase = 1
                lock.unlock()
                lock.lock(); boundaryHookRuns += 1; flipLocked(); lock.unlock()
                return true
            case .refuseDuringBoundary:
                // The commit is in flight (phase 1) when the discard lands;
                // the callback then refuses — SQLite converts the COMMIT
                // into a rollback and ZERO rows survive.
                phase = 1
                boundaryHookRuns += 1
                flipLocked()
                refusedAtBoundary = true
                phase = 0
                lock.unlock()
                return false
            case .earlyFlip:
                phase = 1
                lock.unlock()
                return true
            }
        }

        func finishFinalCommit(committed: Bool) {
            lock.lock()
            if phase == 1 { phase = 2 }
            finishCalls.append(committed)
            lock.unlock()
        }

        var commitBoundaryRefused: Bool {
            lock.lock(); defer { lock.unlock() }
            return refusedAtBoundary
        }
    }

    /// Frozen watermark snapshot from the REAL ephemeral stores (the exact
    /// producer the Keep pipeline hands to the promoter).
    private func seededSnapshot() async throws
        -> (cid: UUID, inc: UUID, snapshot: ConversationPromoter.Snapshot,
            stores: TemporaryStoreBundle) {
        let (cid, inc, _, _, _) = try await fixture.startedSession(draft: "commit-boundary")
        _ = try await fixture.seedTurn(conversationID: cid, canary: "BOUNDARY")
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        var saved = ConversationRecord(id: cid, title: "boundary",
                                       createdAt: Date(), updatedAt: Date(),
                                       purpose: .ordinary)
        saved.title = "boundary"
        let conv = try await authority.stores.conversations.beginPromotion()
        let runs = try await authority.stores.runs.beginPromotion()
        let inputs = try await authority.stores.runningInputs.beginPromotion()
        let snapshot = ConversationPromoter.Snapshot(
            conversation: saved,
            messages: conv.messages,
            attachments: conv.attachments,
            runs: runs.runs,
            events: runs.runs.flatMap { runs.events[$0.id, default: []] },
            usage: runs.runs.flatMap { runs.usage[$0.id, default: []] },
            errors: runs.runs.flatMap { runs.errors[$0.id, default: []] },
            inputs: inputs)
        return (cid, inc, snapshot, authority.stores)
    }

    /// The MANDATORY boundary: the discard lands after the writer body has
    /// returned but BEFORE the real SQLite COMMIT completes. The commit
    /// callback refuses, the transaction rolls back, and ZERO durable rows
    /// survive in the reopened real file DB.
    func testDiscardBetweenBodyReturnAndRealCommitCallbackRollsBackZeroRows() async throws {
        let (cid, _, snapshot, stores) = try await seededSnapshot()
        let probe = LinearizingProbeFence(mode: .refuseDuringBoundary)
        let promoter = ConversationPromoter(database: fixture.census)
        do {
            try await promoter.promote(snapshot, commitFence: probe)
            XCTFail("the real pre-COMMIT callback must refuse the COMMIT")
        } catch is PromotionCommitRefused {
            // expected: zero durable rows.
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(probe.beginCalls, 1,
                       "the authoritative consultation happens at the commit callback")
        XCTAssertEqual(probe.boundaryHookRuns, 1)
        XCTAssertEqual(probe.finishCalls, [false],
                       "the writer threw: the attempt resolves as NOT committed")
        XCTAssertTrue(probe.commitBoundaryRefused)
        let counts = try await fixture.durableCounts()
        for table in ["conversations", "messages", "message_parts", "attachments",
                      "runs", "run_events", "run_usage", "run_errors",
                      "pending_user_inputs", "message_fts", "workspaces",
                      "conversation_workspace_ownership"] {
            XCTAssertEqual(counts[table], 0,
                           "the refused COMMIT must leave \(table) empty")
        }
        // Reopen through a FRESH store object on the real file DB.
        let reopened = try await SQLiteConversationStore(database: fixture.census)
            .conversation(id: cid)
        XCTAssertNil(reopened)
        await stores.closeAll()
    }

    /// A discard that lands before any write refuses cheaply at the
    /// advisory body consultation; no commit callback is ever reached and
    /// zero rows stand.
    func testDiscardBeforeAnyWriteRefusesEarlyWithZeroRows() async throws {
        let (_, _, snapshot, stores) = try await seededSnapshot()
        let probe = LinearizingProbeFence(mode: .earlyFlip)
        let promoter = ConversationPromoter(database: fixture.census)
        do {
            try await promoter.promote(snapshot, commitFence: probe)
            XCTFail("a flipped fence must refuse before any write")
        } catch is PromotionCommitRefused {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        XCTAssertEqual(probe.beginCalls, 0,
                       "the commit callback must never be reached")
        XCTAssertEqual(probe.finishCalls, [false])
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        await stores.closeAll()
    }

    /// The ONLY true commit-winner: the real pre-COMMIT callback allowed
    /// the commit and the discard landed after that decision. The durable
    /// rows are genuine truth and reopen consistent.
    func testAllowedCommitCallbackThenDiscardRetainsGenuinelyCommittedRows() async throws {
        let (cid, _, snapshot, stores) = try await seededSnapshot()
        let probe = LinearizingProbeFence(mode: .allowThenFlip)
        let promoter = ConversationPromoter(database: fixture.census)
        try await promoter.promote(snapshot, commitFence: probe)
        XCTAssertEqual(probe.beginCalls, 1)
        XCTAssertEqual(probe.finishCalls, [true])
        XCTAssertFalse(probe.commitBoundaryRefused)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 1)
        XCTAssertEqual(counts["messages"], 2)
        let reopened = try await SQLiteConversationStore(database: fixture.census)
            .conversation(id: cid)
        XCTAssertEqual(reopened?.purpose, .ordinary)
        await stores.closeAll()
    }

    /// A REAL same-connection commit failure AFTER the actual boundary
    /// allowed the commit (a scoped observer throws inside
    /// databaseWillCommit): the transaction rolls back with zero rows, the
    /// fence resolves as a truthful loss WITHOUT any discard, the RAM
    /// session stays live/retryable, and the SAME session's next Keep on
    /// the same unfenced fence commits (no new session, no fabricated
    /// commit). A navigation-flipped fence stays permanently refused.
    func testRealCommitFailureAfterBoundaryAllowedKeepsRAMRetryableAndNextKeepCommits() async throws {
        struct InjectedCommitFailure: Error {}
        PromotionCommitBoundaryTestHooks.afterBoundaryAllowForTesting = {
            throw InjectedCommitFailure()
        }
        defer { PromotionCommitBoundaryTestHooks.afterBoundaryAllowForTesting = nil }
        let (cid, inc, _, _, _) = try await fixture.startedSession(draft: "fault")
        _ = try await fixture.seedTurn(conversationID: cid, canary: "FAULT")
        let first = await fixture.domain.keep(conversationID: cid, incarnation: inc,
                                              idempotencyKey: UUID(), receipt: nil,
                                              correlation: "fault-1")
        guard case .rejected(let error) = first.outcome else {
            return XCTFail("the injected real commit failure must be reported: \(first.outcome)")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.persistenceUnavailable)
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.promoterCommitFailed)
        // REAL rollback: zero durable rows in the reopened file DB.
        var counts = try await fixture.durableCounts()
        for table in ["conversations", "messages", "runs", "run_events",
                      "run_usage", "run_errors", "pending_user_inputs",
                      "message_fts", "workspaces"] {
            XCTAssertEqual(counts[table], 0, "\(table) must stay empty after rollback")
        }
        let rolledBackConversation = try await SQLiteConversationStore(
            database: fixture.census).conversation(id: cid)
        XCTAssertNil(rolledBackConversation)
        // Same live session, unfenced, advertised retryable — RAM intact.
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.promotion, "idle")
        XCTAssertEqual(status.conversationID, cid)
        XCTAssertEqual(status.incarnation, inc)
        XCTAssertFalse(fixture.gate.blocksOperations(conversationID: cid,
                                                     incarnation: inc))
        // Remove the fault: the SAME session's next Keep must commit.
        PromotionCommitBoundaryTestHooks.afterBoundaryAllowForTesting = nil
        let retry = await fixture.domain.keep(conversationID: cid, incarnation: inc,
                                              idempotencyKey: UUID(), receipt: nil,
                                              correlation: "fault-2")
        guard case .mutationAccepted(let detail, _) = retry.outcome else {
            return XCTFail("the same unfenced session must retry successfully: \(retry.outcome)")
        }
        XCTAssertEqual(detail["keep"], "committed")
        XCTAssertEqual(detail["conversationID"], cid.uuidString)
        counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 1)
        XCTAssertEqual(counts["messages"], 2)
        // No new session was fabricated: the durable id is the SAME hosted id.
        let reopened = try await SQLiteConversationStore(database: fixture.census)
            .conversation(id: cid)
        XCTAssertEqual(reopened?.purpose, .ordinary)
        // A navigation-flipped fence stays permanently refused (no retry
        // can revive a discarded session).
        let (cid2, inc2, _, _, _) = try await fixture.startedSession(draft: "flip")
        _ = try await fixture.seedTurn(conversationID: cid2, canary: "FLIP")
        _ = await fixture.domain.end(conversationID: cid2, incarnation: inc2)
        let flippedRetry = await fixture.domain.keep(conversationID: cid2,
                                                     incarnation: inc2,
                                                     idempotencyKey: UUID(),
                                                     receipt: nil,
                                                     correlation: "flip-retry")
        guard case .rejected(let flipError) = flippedRetry.outcome else {
            return XCTFail("a discarded session must never resurrect")
        }
        XCTAssertEqual(flipError.code, TemporaryDomainError.Code.sessionDiscarded)
    }

    func testRepeatedFlipAndFinishAreIdempotentOnRealTemporaryFence() throws {
        let fence = TemporaryPromotionCommitFence(sessionConversationID: UUID(),
                                                  sessionIncarnation: UUID())
        XCTAssertTrue(fence.allowsCommit())
        XCTAssertTrue(fence.beginFinalCommit())
        XCTAssertEqual(fence.flip(), .commitInProgress,
                       "flip after the real callback allowed the commit = winner window")
        XCTAssertFalse(fence.beginFinalCommit(),
                       "no second attempt while one is in flight")
        XCTAssertTrue(fence.commitBoundaryRefused,
                      "the refused second consultation is recorded honestly")
        fence.finishFinalCommit(committed: true)
        XCTAssertEqual(fence.flip(), .commitWon)
        fence.finishFinalCommit(committed: false)  // late finish: no-op
        XCTAssertEqual(fence.commitPhase, .resolved(committed: true))
        // Post-commit resume semantics: the session is discarded by the
        // flip above (fenced), so any further attempt is refused.
        XCTAssertFalse(fence.allowsCommit())
    }

    // MARK: - Retirement through the wired surface

    func testRetirementThroughFacadeDiscardsAndUnbindsKeys() async throws {
        let (cid, inc, _, _) = try await startViaBinder()
        await TemporaryDomainFacade.beginGenerationRetirement(epoch: fixture.epoch)
        // Discard-only: no durable row, the three binder keys are GONE,
        // and a late end for the retired tuple cannot act.
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertNil(RuntimeCommandBinder.shared.handler(
            for: BridgeV3.handlerKey(scope: .launch, command: "temp.start")))
        let late = await fixture.domain.end(conversationID: cid, incarnation: inc)
        guard case .rejected = late.outcome else { return XCTFail("late end must refuse") }
    }
}
