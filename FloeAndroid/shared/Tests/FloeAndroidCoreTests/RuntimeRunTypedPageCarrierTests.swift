// SPDX-License-Identifier: MPL-2.0
//
// F7 — completed run pages travel the ACTUAL command mailbox carrier.
//
// Main's ordinary-run review found that `RunDomainReply.commandResult()`
// settled a completed page as `accepted` with identifier detail ONLY and
// dropped the measured typed page, so `run.snapshot` / `child.list` /
// `child.entries` reached the App as `value=null` / no page. The repair
// attaches the canonical OBJECT page through the existing
// `RuntimeCommandResult.page` typed carrier without changing the frozen
// budgets, cursors, vocabulary or types.
//
// These tests exercise the REAL FacadeCommandMailbox + FacadeEffectPump with
// the REAL FacadeRunDomain (scripted model stream only):
//  * a real `run.snapshot` reply settles with its OBJECT page in the effect;
//  * a real `child.list` page does the same;
//  * a genuinely oversized page still settles the typed carrier refusal
//    (never a silent drop, never a truncated page).
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeRunTypedPageCarrierTests: XCTestCase {
    private var fixture: RunDomainFixture!
    private var mailboxes: [FacadeCommandMailbox] = []

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        for mailbox in mailboxes { mailbox.close(reason: .closed) }
        mailboxes.removeAll()
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Harness

    private func makeMailbox(
        command: String,
        processor: @escaping @Sendable (RunCommandEnvelope, RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult
    ) -> (FacadeCommandMailbox, FacadeEffectPump) {
        let effects = FacadeEffectPump(generation: 1)
        let registry = RuntimeDomainRegistry()
        let key = BridgeV3.handlerKey(scope: .taskExecution, command: command)
        registry.register(handlerKey: key, processor: RuntimeAsyncProcessor { job in
            guard let object = (try? JSONSerialization.jsonObject(with: job.envelope))
                    as? [String: Any] else {
                return RuntimeCommandResult(kind: .rejected, code: .domainNotBound)
            }
            return await processor(RunCommandEnvelope(object: object), job)
        })
        let mailbox = FacadeCommandMailbox(effects: effects, registry: registry)
        mailbox.startDrain()
        mailboxes.append(mailbox)
        return (mailbox, effects)
    }

    private func envelopeBytes(command: String, conversationID: UUID, runID: UUID,
                               correlation: String) -> Data {
        let object: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": command,
            "stateful": false,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString, "runID": runID.uuidString],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func job(command: String, conversationID: UUID, runID: UUID,
                     correlation: String, receipt: String) -> RuntimeCommandEnvelopeJob {
        RuntimeCommandEnvelopeJob(
            correlationID: correlation,
            handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: command),
            command: command, scope: .taskExecution, configurationScope: nil,
            receipt: receipt,
            envelope: envelopeBytes(command: command, conversationID: conversationID,
                                    runID: runID, correlation: correlation))
    }

    private func pollTerminal(_ effects: FacadeEffectPump, receipt: String,
                              timeout: TimeInterval = 10) -> RuntimeEffectItem? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .page(let items, _, _, _) = effects.poll(receipt: receipt, afterSequence: 0),
               let terminal = items.last(where: { $0.kind.isTerminal || $0.kind == .failed }) {
                return terminal
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func launchRun(_ domain: FacadeRunDomain,
                           conversationID: UUID) async throws -> UUID {
        let revision = (try? await fixture.revision(conversationID: conversationID)) ?? ""
        let reply = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: "page carrier"),
            revisionVersion: revision, correlation: "corr-page-start"), receipt:
                "op:v1:" + String(repeating: "3", count: 31) + "7",
            correlation: "corr-page-start")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1)
        }
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        return runID
    }

    private func makeRunningRun(_ domain: FacadeRunDomain) async throws -> (UUID, UUID) {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "bounded answer")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let runID = try await launchRun(domain, conversationID: conversationID)
        return (conversationID, runID)
    }

    // MARK: - Snapshot page

    func testRunSnapshotPageTravelsTheActualMailboxCarrier() async throws {
        let domain = fixture.makeDomain()
        let (conversationID, runID) = try await makeRunningRun(domain)
        let (mailbox, effects) = makeMailbox(command: "run.snapshot") { envelope, _ in
            await domain.snapshot(envelope: envelope).commandResult()
        }
        let receipt = try XCTUnwrap(effects.register(correlationID: "corr-page-snap"))
        let submission = mailbox.submit(job(command: "run.snapshot",
                                            conversationID: conversationID, runID: runID,
                                            correlation: "corr-page-snap", receipt: receipt))
        guard case .queued = submission else {
            return XCTFail("mailbox refused the snapshot job: \(submission)")
        }
        guard let terminal = pollTerminal(effects, receipt: receipt) else {
            return XCTFail("snapshot terminal did not settle")
        }
        XCTAssertEqual(terminal.kind, .accepted, "\(terminal)")
        let page = try XCTUnwrap(terminal.page, "F7: the measured typed page must ride the carrier")
        guard case .object(let fields) = page else {
            return XCTFail("page must be the canonical OBJECT document")
        }
        XCTAssertEqual(fields["runID"], .string(runID.uuidString))
        XCTAssertEqual(fields["conversationID"], .string(conversationID.uuidString))
        XCTAssertNotNil(fields["durableState"])
        let detail = terminal.detail ?? [:]
        XCTAssertEqual(detail["result"], "page")
        // The detail carries the DOMAIN's measured page size; the carrier
        // declares its own canonical re-encoded size. Both are real and
        // within the frozen budgets (they may differ by wrapper bytes).
        XCTAssertNotNil(Int(detail["pageBytes"] ?? ""))
        let carried = try XCTUnwrap(terminal.pageBytes)
        XCTAssertLessThanOrEqual(carried, FacadeEffectPump.Limits.maximumItemEncodedBytes)
        XCTAssertNil(detail["carrier"], "the page must fit the carrier budget")
    }

    // MARK: - Child page

    func testChildListPageTravelsTheActualMailboxCarrier() async throws {
        let domain = fixture.makeDomain()
        let (conversationID, runID) = try await makeRunningRun(domain)
        let (mailbox, effects) = makeMailbox(command: "child.list") { envelope, _ in
            await domain.childList(envelope: envelope).commandResult()
        }
        let receipt = try XCTUnwrap(effects.register(correlationID: "corr-page-children"))
        let submission = mailbox.submit(job(command: "child.list",
                                            conversationID: conversationID, runID: runID,
                                            correlation: "corr-page-children", receipt: receipt))
        guard case .queued = submission else {
            return XCTFail("mailbox refused the child.list job: \(submission)")
        }
        guard let terminal = pollTerminal(effects, receipt: receipt) else {
            return XCTFail("child.list terminal did not settle")
        }
        XCTAssertEqual(terminal.kind, .accepted, "\(terminal)")
        let page = try XCTUnwrap(terminal.page, "F7: the child page must ride the carrier")
        guard case .object(let fields) = page else {
            return XCTFail("child page must be the canonical OBJECT document")
        }
        XCTAssertEqual(fields["parentRunID"], .string(runID.uuidString))
        guard case .array(let children)? = fields["children"] else {
            return XCTFail("children array expected: \(fields)")
        }
        XCTAssertLessThanOrEqual(children.count, RunDomainLimits.maximumChildItems)
        XCTAssertNotNil(fields["childrenTruncated"])
    }

    // MARK: - True oversize

    func testOversizedPageSettlesTypedCarrierRefusalInsteadOfSilentDrop() throws {
        // A page that passes the domain's own 48 KiB guard but cannot fit the
        // ACTUAL effect item budget (47,616 encoded bytes) must settle the
        // typed carrier refusal. Synthetic size here: the domain normally
        // shrinks to its budget, so the true-over-budget shape is exercised
        // directly through the same commandResult() projection.
        var fields: [String: SettingsDomainV1.JSONValue] = [
            "runID": .string(UUID().uuidString),
            "conversationID": .string(UUID().uuidString),
        ]
        fields["answerText"] = .string(String(repeating: "x", count: 48_000))
        let oversized = RunTypedPage(object: .object(fields), pageBytes: 48_000)
        let reply = RunDomainReply(.completedPage(page: oversized, nextCursor: nil))
        let (mailbox, effects) = makeMailbox(command: "child.entries") { _, _ in
            reply.commandResult()
        }
        let receipt = try XCTUnwrap(effects.register(correlationID: "corr-page-oversize"))
        let conversationID = UUID()
        let submission = mailbox.submit(job(command: "child.entries",
                                            conversationID: conversationID,
                                            runID: UUID(),
                                            correlation: "corr-page-oversize",
                                            receipt: receipt))
        guard case .queued = submission else {
            return XCTFail("mailbox refused the job: \(submission)")
        }
        guard let terminal = pollTerminal(effects, receipt: receipt) else {
            return XCTFail("oversize terminal did not settle")
        }
        XCTAssertEqual(terminal.kind, .failed, "\(terminal)")
        XCTAssertEqual(terminal.code, .frameBudgetExceeded)
        let detail = terminal.detail ?? [:]
        XCTAssertEqual(detail["carrier"], "payloadTooLarge")
        XCTAssertNil(terminal.page, "an oversized page is never partially carried")
    }
}
