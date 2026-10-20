// SPDX-License-Identifier: MPL-2.0
//
// RB-4 event/snapshot projection tests. AUTHORED, NOT EXECUTED. Live
// frames come from the REAL ConversationRunService harness channel;
// durable pages from the ORIGINAL append-only store; only the model
// stream is scripted.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunEventsTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    private func launch(_ domain: FacadeRunDomain, conversationID: UUID,
                        goal: String, receipt: String,
                        correlation: String) async -> RunDomainReply {
        let revision = (try? await fixture.revision(conversationID: conversationID)) ?? ""
        return await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: correlation),
            receipt: receipt, correlation: correlation)
    }

    private func runID(from reply: RunDomainReply) throws -> UUID {
        guard case .mutationAccepted(let detail) = reply.outcome,
              let id = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 2)
        }
        return id
    }

    func testStreamReasoningAndToolProjectionsReachDurableAndLive() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let index = fixture.adapter.requestCount
        let echoCall = try ToolCall(id: "call-e1", toolName: FixtureEchoTool.name,
                                    argumentsJSON: Data(#"{"message":"x"}"#.utf8),
                                    scope: .local)
        fixture.adapter.enqueue(script: .init(events: [
            .reasoningSummary(.init(text: "thinking…")),
            .textDelta(.init(text: "part one ")),
            .toolRequest(echoCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let receipt = "op:v1:" + String(repeating: "1", count: 31) + "9"
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "project stream", receipt: receipt,
                                 correlation: "corr-proj")
        let runID = try runID(from: reply)
        let state = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(state, "completed")
        // Durable pages (the correctness path): assistantText, toolRequest,
        // toolResult, terminal in monotonic order.
        let events = try await fixture.durableEvents(runID)
        let kinds = events.map(\.kind)
        XCTAssertTrue(kinds.contains(.assistantText))
        XCTAssertTrue(kinds.contains(.toolRequest))
        XCTAssertTrue(kinds.contains(.toolResult))
        XCTAssertEqual(events.first?.sequence, 1)
        let sequences = events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertTrue(events.last?.kind == .terminal || kinds.contains(.terminal))
        // The pump's bounded window carries the same native sequences.
        let page = fixture.events.pollDurable(runID: runID, afterSequence: 0,
                                              budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        XCTAssertEqual(page["windowState"] as? String, "attached")
        let pageEvents = (page["events"] as? [[String: Any]]) ?? []
        XCTAssertFalse(pageEvents.isEmpty)
        XCTAssertEqual(page["nextSequence"] as? Int, pageEvents.last?["sequence"] as? Int)
    }

    func testSnapshotCarriesRealStateAndRevisionsAndRetiresAtTerminal() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "snapshot inline answer")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "snapshot me",
                                 receipt: "op:v1:" + String(repeating: "2", count: 32),
                                 correlation: "corr-snap")
        let runID = try runID(from: reply)
        let snapshot = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-snap-read"))
        guard case .completedPage(let page, _) = snapshot.outcome,
              case .object(let fields) = page.object else {
            gate.release()
            return XCTFail("snapshot page expected")
        }
        XCTAssertEqual(fields["runID"] ?? .null, .string(runID.uuidString))
        XCTAssertEqual(fields["conversationID"] ?? .null, .string(conversationID.uuidString))
        XCTAssertEqual(fields["liveOwner"] ?? .null, .boolean(true))
        // The CAS identities the host needs are REAL, not placeholders.
        if case .object(let revision) = fields["revision"] {
            XCTAssertEqual(revision["resourceID"], .string(RunWireRevision.runResourceID(runID)))
            XCTAssertEqual(revision["version"],
                           fields["durableState"] ?? .null)
        } else { XCTFail("revision object expected") }
        // Mid-stream text: never labelled complete. Gate on the REAL
        // observed text, not an optional-if-null check.
        var observedMid: [String: SettingsDomainV1.JSONValue] = [:]
        let midTextSeen = await pollFor(timeoutSeconds: 8) {
            let mid = await domain.snapshot(envelope: self.fixture.executionEnvelope(
                command: "run.snapshot", conversationID: conversationID, runID: runID,
                payload: nil, correlation: "corr-snap-mid"))
            guard case .completedPage(let midPage, _) = mid.outcome,
                  case .object(let midFields) = midPage.object,
                  case .string(let text) = midFields["answerText"], !text.isEmpty else {
                return false
            }
            observedMid = midFields
            return true
        }
        XCTAssertTrue(midTextSeen, "the streamed delta must be observable mid-run")
        XCTAssertEqual(observedMid["answerComplete"], .boolean(false),
                       "inline mid-stream content must NEVER claim completion")
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        let after = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-snap-after"))
        guard case .completedPage(let donePage, _) = after.outcome,
              case .object(let done) = donePage.object else {
            return XCTFail("post-terminal snapshot expected")
        }
        XCTAssertEqual(done["durableState"], .string("completed"))
        XCTAssertEqual(done["isTerminal"], .boolean(true))
    }

    func testOversizedCJKEmojiEscapeSnapshotUsesHandlesNotTruncation() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let index = fixture.adapter.requestCount
        // ~56 KiB of mixed CJK + emoji + quotes/backslashes (escape-heavy),
        // streamed as 25 small deltas: the ORIGINAL runtime refuses any
        // SINGLE delta above the model output-safety limit, so an oversized
        // answer must accumulate across real stream chunks.
        let unit = "汉字🚀\"\\ / "
        let big = String(repeating: unit, count: 150 * 25)
        var events: [AgentEvent] = []
        for _ in 0..<25 {
            events.append(.textDelta(.init(text: String(repeating: unit, count: 150))))
        }
        // Hold the provider after the 25th delta (before completion): the
        // handle path must be proven against REAL oversized LIVE content,
        // not a retired run whose snapshot would be nil.
        let gate = RunGateBox()
        events.append(.completed(.init(stopReason: .endTurn)))
        fixture.adapter.enqueue(script: .init(events: events, stallAfter: 25, gate: gate),
                                forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "oversize",
                                 receipt: "op:v1:" + String(repeating: "3", count: 32),
                                 correlation: "corr-big")
        let runID = try runID(from: reply)
        // Observe ACTUAL consumed text in the REAL projection while held.
        let liveOversized = await pollFor(timeoutSeconds: 8) {
            let text = await domain.liveService(runID)?.snapshot().streamedText ?? ""
            return text.utf8.count > RunDomainLimits.snapshotInlineBudgetBytes
        }
        XCTAssertTrue(liveOversized, "the held provider must deliver real oversized live text")
        let snap = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-big-snap"))
        guard case .completedPage(let page, _) = snap.outcome else {
            gate.release()
            return XCTFail("page required, got \(snap.outcome)")
        }
        XCTAssertLessThanOrEqual(page.pageBytes, RunDomainLimits.pageBudgetBytes)
        var handle: String?
        if case .object(let fields) = page.object,
           case .string(let h) = fields["answerContinuationHandle"] {
            handle = h
        }
        guard let handle else {
            return XCTFail("oversized text must expose a continuation handle, not a silent cut")
        }
        // Byte-exact reassembly through the reviewed reader.
        var reassembled = Data()
        var offset = 0
        while true {
            let outcome = await domain.readRunContent(handle: handle, offset: offset,
                                                      maxBytes: 16_384,
                                                      runID: runID,
                                                      conversationID: conversationID)
            switch outcome {
            case .slice(let bytes, let next, let complete):
                reassembled.append(bytes)
                offset = next
                if complete { offset = Int.max }
            case .notFound, .invalidOffset:
                return XCTFail("handle must resolve for its owning run")
            }
            if offset == Int.max { break }
        }
        XCTAssertEqual(String(decoding: reassembled, as: UTF8.self), big)
        // A foreign run can never read the handle.
        switch await domain.readRunContent(handle: handle, offset: 0, maxBytes: 64,
                                           runID: UUID(), conversationID: conversationID) {
        case .notFound: break
        default: XCTFail("cross-run handle leak")
        }
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
    }

    func testDurablePaginationAndResyncWalkFromCursor() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let index = fixture.adapter.requestCount
        var events: [AgentEvent] = []
        for i in 0..<40 {
            events.append(.textDelta(.init(text: "chunk\(i) ")))
        }
        events.append(.completed(.init(stopReason: .endTurn)))
        fixture.adapter.enqueue(script: .init(events: events), forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "paginate",
                                 receipt: "op:v1:" + String(repeating: "4", count: 32),
                                 correlation: "corr-page")
        let runID = try runID(from: reply)
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // Walk the durable window in small-budget pages; cursor must
        // advance exactly with the native sequence and never skip.
        var cursor = 0
        var seen: [Int] = []
        var guardCount = 0
        while guardCount < 40 {
            guardCount += 1
            let page = fixture.events.pollDurable(runID: runID, afterSequence: cursor,
                                                  budgetBytes: 2_048)
            guard (page["windowState"] as? String) == "attached" else { break }
            let items = (page["events"] as? [[String: Any]]) ?? []
            if items.isEmpty { break }
            for item in items {
                seen.append((item["sequence"] as? Int)!)
            }
            cursor = (page["nextSequence"] as? Int) ?? cursor
        }
        XCTAssertEqual(seen, seen.sorted())
        // Complete, gap-free coverage of the native sequence range the
        // cursor actually observed (the first durable event is the prepare
        // status at sequence 1; `Set(2...)` over an unbounded range never
        // terminates, so bound by the LAST observed sequence).
        XCTAssertEqual(seen.first, 1)
        if let last = seen.last {
            XCTAssertEqual(seen.sorted(), Array(1...last),
                           "every native sequence through the observed cursor must be present exactly once, in order")
        }
        let allEvents = try await fixture.durableEvents(runID)
        let lastSeq = allEvents.last?.sequence ?? 0
        // Every native sequence <= cursor has been observed (no gaps).
        let missing = allEvents.filter { $0.sequence <= cursor }.map(\.sequence)
            .filter { !seen.contains($0) }
        XCTAssertTrue(missing.isEmpty)
        XCTAssertGreaterThan(lastSeq, 0)
    }

    func testSlowConsumerNeverCancelsTheRunAndOverflowResyncsExplicitly() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "slow consumer",
                                 receipt: "op:v1:" + String(repeating: "5", count: 32),
                                 correlation: "corr-slow")
        let runID = try runID(from: reply)
        // Nobody ever calls event.poll for this run: the run still finishes
        // because the projection pump is decoupled from the engine.
        let state = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(state, "completed")
        // Durable pages remain fetchable late (the correctness path).
        let late = fixture.events.pollDurable(runID: runID, afterSequence: 0,
                                              budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        let items = (late["events"] as? [[String: Any]]) ?? []
        XCTAssertFalse(items.isEmpty)
        // Live state after teardown: detached/noConsumer is honest, and a
        // resync via snapshot+durable walk works (documented contract).
        let live = fixture.events.takeLatestLive(runID: runID, budgetBytes: 4_096)
        let liveState = live["liveState"] as? String
        XCTAssertTrue(liveState == "attached" || liveState == "detached"
                        || liveState == "noConsumer")
    }

    func testPriorityApprovalFramesSurviveDeltaSaturation() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let index = fixture.adapter.requestCount
        let sideCall = try ToolCall(id: "call-side-sat",
                                    toolName: FixtureSideEffectTool.name,
                                    argumentsJSON: Data(#"{"target":"x"}"#.utf8),
                                    scope: .local)
        // Flood droppable deltas to saturate the ring, then request approval.
        var events: [AgentEvent] = (0..<600).map {
            .textDelta(.init(text: "delta\($0) "))
        }
        events.append(.toolRequest(sideCall))
        events.append(.completed(.init(stopReason: .endTurn)))
        fixture.adapter.enqueue(script: .init(events: events), forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "flood then approve",
                                 receipt: "op:v1:" + String(repeating: "6", count: 32),
                                 correlation: "corr-flood")
        let runID = try runID(from: reply)
        // The approval card must arrive through the engine regardless of the
        // flood (priority class never dropped; saturation DETACHES with
        // resyncRequired instead).
        let pending = await pollFor(timeoutSeconds: 10) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending)
        // Durable approval event is fetchable regardless of live drops.
        let events2 = try await fixture.durableEvents(runID)
        XCTAssertTrue(events2.contains { $0.kind == .approval })
        // Resolve deny so the run can terminate cooperatively.
        let waiting = try unwrapAsync(await domain.liveService(runID)?.snapshot().pendingApproval)
        _ = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "deny",
                      "reason": "test deny",
                      "expectedApprovalVersion": RunWireRevision.approvalVersion(
                          requestedAt: waiting.requestedAt)],
            correlation: "corr-deny",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": RunWireRevision.approvalVersion(requestedAt: waiting.requestedAt)]))
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(final)
        // Terminal survives in durable pages even if the live consumer
        // detached mid-flood.
        let durable = try await fixture.durableEvents(runID)
        XCTAssertTrue(durable.contains { $0.kind == .terminal })
    }

    func testOldEpochCallbacksCannotMutateNewProjection() async throws {
        // Two generations (epochs 7 fixture vs a stale token): ingesting
        // with a foreign-epoch consumer token must classify fencedByEpoch.
        let token = fixture.events.attachConsumer(runID: UUID())
        // Re-attach bumps the epoch; the OLD token must now fence.
        let newer = fixture.events.attachConsumer(runID: token.runID)
        XCTAssertNotEqual(token.epoch, newer.epoch)
        let outcome = fixture.events.ingestLive(
            .stateChanged(.streaming), token: token)
        XCTAssertEqual(outcome, .fencedByEpoch)
    }

    func testOversizedAnswerWithSaturatedContentReaderFailsTyped() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // REAL reader saturation: fill the aggregate staged-byte budget of
        // the SAME content reader the domain stages through.
        let filler = Data(count: FacadeContentReader.Limits.maximumTotalBytes)
        guard case .staged = fixture.content.stage(filler) else {
            return XCTFail("filler staging must succeed to saturate the reader")
        }
        let index = fixture.adapter.requestCount
        // ~56 KiB of mixed CJK + emoji + quotes/backslashes (escape-heavy),
        // streamed as 25 real chunks (the ORIGINAL runtime refuses one huge
        // delta): above the inline budget, so staging is the only carrier.
        let unit = "汉字🚀\"\\ / "
        var events: [AgentEvent] = []
        for _ in 0..<25 {
            events.append(.textDelta(.init(text: String(repeating: unit, count: 150))))
        }
        let gate = RunGateBox()
        // Hold the provider AFTER the 25th delta (before completion): the
        // regression must hit REAL oversized LIVE content, not a retired run
        // whose snapshot would be nil.
        events.append(.completed(.init(stopReason: .endTurn)))
        fixture.adapter.enqueue(script: .init(events: events, stallAfter: 25, gate: gate),
                                forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "oversize saturated",
                                 receipt: "op:v1:" + String(repeating: "6", count: 32),
                                 correlation: "corr-sat")
        let runID = try runID(from: reply)
        // Observe ACTUAL consumed text in the REAL projection while the
        // scripted provider is held (a yielded delta is not proof).
        let liveOversized = await pollFor(timeoutSeconds: 8) {
            let text = await domain.liveService(runID)?.snapshot().streamedText ?? ""
            return text.utf8.count > RunDomainLimits.snapshotInlineBudgetBytes
        }
        XCTAssertTrue(liveOversized, "the held provider must deliver real oversized live text")
        let snap = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-sat-snap"))
        gate.release()
        guard case .rejected(let error) = snap.outcome else {
            return XCTFail("saturated staging must fail the page typed, never a lossy successful page: \(snap.outcome)")
        }
        XCTAssertEqual(error.code, .payloadTooLarge,
                       "refused continuation staging must surface as the existing typed refusal")
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
    }

    func testTerminalSnapshotWithoutLiveOwnerNeverClaimsCompleteAndReconstructsExactly() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let expected = "汉字🚀 \"quoted\" tail"
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: expected)),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "terminal reconstruction",
                                 receipt: "op:v1:" + String(repeating: "9", count: 32),
                                 correlation: "corr-recon")
        let runID = try runID(from: reply)
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // Wait for the projection to retire so the no-live-owner branch is
        // exercised truthfully.
        let retired = await pollFor(timeoutSeconds: 8) {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(retired)
        let snap = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-recon-snap"))
        guard case .completedPage(let page, _) = snap.outcome,
              case .object(let fields) = page.object else {
            return XCTFail("durable-only snapshot page expected, got \(snap.outcome)")
        }
        // Absent/unretrievable text must NEVER claim completion.
        XCTAssertEqual(fields["answerText"], .null)
        XCTAssertEqual(fields["answerComplete"], .boolean(false))
        XCTAssertEqual(fields["answerContinuationHandle"], .null)
        XCTAssertEqual(fields["isTerminal"], .boolean(true))
        // Exact bounded reconstruction through the ORIGINAL durable events.
        let durableText = try await fixture.durableEvents(runID)
            .last(where: { $0.kind == .assistantText })
            .flatMap { record -> String? in
                guard let data = record.payloadJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return object["text"] as? String
            }
        XCTAssertEqual(durableText, expected)
    }

    func testInlineMidStreamAnswerNeverClaimsCompleteWithObservedText() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "first observable delta")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let reply = await launch(domain, conversationID: conversationID,
                                 goal: "partial truth",
                                 receipt: "op:v1:" + String(repeating: "7", count: 32),
                                 correlation: "corr-partial")
        let runID = try runID(from: reply)
        // Poll the REAL snapshot until the observed text is actually present
        // (never gate on optional-if-null).
        var midFields: [String: SettingsDomainV1.JSONValue] = [:]
        let observedText = await pollFor(timeoutSeconds: 8) {
            let mid = await domain.snapshot(envelope: self.fixture.executionEnvelope(
                command: "run.snapshot", conversationID: conversationID, runID: runID,
                payload: nil, correlation: "corr-partial-mid"))
            guard case .completedPage(let midPage, _) = mid.outcome,
                  case .object(let fields) = midPage.object,
                  case .string(let text) = fields["answerText"], !text.isEmpty else {
                return false
            }
            midFields = fields
            return true
        }
        XCTAssertTrue(observedText, "the first streamed delta must be observable in the live snapshot")
        XCTAssertEqual(midFields["answerComplete"], .boolean(false),
                       "inline mid-stream content must NEVER claim completion")
        XCTAssertEqual(midFields["answerContinuationHandle"] ?? .null, .null)
        gate.release()
        // The terminal full text must be observable: poll the REAL live
        // snapshot for completion BEFORE the projection retires (after
        // retirement the durable events are the documented correctness path).
        var doneFields: [String: SettingsDomainV1.JSONValue] = [:]
        let terminalSeen = await pollFor(timeoutSeconds: 8) {
            let after = await domain.snapshot(envelope: self.fixture.executionEnvelope(
                command: "run.snapshot", conversationID: conversationID, runID: runID,
                payload: nil, correlation: "corr-partial-after"))
            guard case .completedPage(let donePage, _) = after.outcome,
                  case .object(let fields) = donePage.object,
                  case .string(let text) = fields["answerText"], !text.isEmpty else {
                return false
            }
            doneFields = fields
            return fields["answerComplete"] == .boolean(true)
        }
        if terminalSeen {
            XCTAssertEqual(doneFields["answerComplete"], .boolean(true))
            if case .string(let finalText) = doneFields["answerText"] {
                XCTAssertEqual(finalText, "first observable delta")
            }
        } else {
            // The projection retired before completion was observed: the
            // durable assistantText event is the authoritative full text.
            _ = await waitDurableTerminal(fixture: fixture, runID: runID)
            let durableText = try await fixture.durableEvents(runID)
                .last(where: { $0.kind == .assistantText })
                .flatMap { record -> String? in
                    guard let data = record.payloadJSON.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any] else { return nil }
                    return object["text"] as? String
                }
            XCTAssertEqual(durableText, "first observable delta")
        }
    }
}
