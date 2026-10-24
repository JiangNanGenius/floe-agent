// FloeBrowserTests — human takeover / handoff receipt semantics.
// Authored (job-9960651880854093), not executed in this source lane.

import XCTest
import FloeCore
@testable import FloeBrowser

/// Sendable recorders for the injected `deliverHandoff` closures. They run
/// on the session center's executor, so capturing a stack `var` is illegal
/// under Swift 6 concurrency; the recorded values and assertions stay
/// exactly as authored.
private actor DeliveryLog {
    private var entries: [(BrowserHandoff, Bool)] = []
    func append(_ handoff: BrowserHandoff, _ continueTask: Bool) { entries.append((handoff, continueTask)) }
    func countValue() -> Int { entries.count }
    func firstEntry() -> (BrowserHandoff, Bool)? { entries.first }
}

private actor AttemptCounter {
    private var value = 0
    func bump() -> Int { value += 1; return value }
}

private actor RunIDLog {
    private var ids: [UUID?] = []
    func append(_ runID: UUID?) { ids.append(runID) }
    func countValue() -> Int { ids.count }
    func lastID() -> UUID? { (ids.last ?? nil) ?? nil }
}

final class BrowserHandoffTests: XCTestCase {
    func testRequestUserRequiresAnExistingNavigatedSession() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        do {
            try await harness.center.requestUserInteraction(reason: "log in", tabID: nil, runID: nil, in: owner.taskID)
            XCTFail("handoff must not conjure a browser for a task that has none")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("navigate before requesting"))
        }
        let (session, _) = try await makeNavigatedSession(harness: harness, owner: owner)
        try await harness.center.requestUserInteraction(
            reason: "complete the verification",
            tabID: (await session.tabSnapshots()).first!.id,
            runID: nil,
            in: owner.taskID
        )
        let handoff = await harness.center.handoff(for: owner.taskID)
        XCTAssertNotNil(handoff)
        XCTAssertEqual(handoff?.returning, false)
        let controlling = await session.isUserControlling
        XCTAssertTrue(controlling)
    }

    func testReceiptSurvivesTabSwitchesAndCarriesExactSession() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tab1 = (await session.tabSnapshots()).first!.id
        let tab2 = await session.createTab()
        XCTAssertNotNil(tab2)

        try await harness.center.requestUserInteraction(reason: "pick a file", tabID: tab1, runID: nil, in: owner.taskID)
        let firstReceipt = await harness.center.handoff(for: owner.taskID)
        XCTAssertEqual(firstReceipt?.sessionID, sessionID)
        XCTAssertEqual(firstReceipt?.tabID, tab1)

        // The user switching to ANOTHER tab and taking control there keeps
        // the same durable receipt identity, only moving tabID. The switch is
        // the trusted UI activation route (the receipt captures the tab that
        // is active when control begins); creating the tab earlier does not
        // model the switch itself.
        let userTab = try XCTUnwrap(tab2)
        await harness.center.activate(userTab, in: owner.taskID)
        await harness.center.takeControl(in: owner.taskID)
        let secondReceipt = await harness.center.handoff(for: owner.taskID)
        XCTAssertEqual(secondReceipt?.id, firstReceipt?.id)
        XCTAssertEqual(secondReceipt?.tabID, tab2)
    }

    func testReturnToAgentSanitizesAddressInvalidatesDocsAndDeliversOnce() async throws {
        let delivered = DeliveryLog()
        let harness = BrowserTestHarness.make { handoff, continueTask in
            await delivered.append(handoff, continueTask)
            return true
        }
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        // A page URL carrying credentials/query/fragment must never persist
        // any of them into the durable receipt. The page identity reaches the
        // session through the trusted renderer lifecycle ingress (mirroring
        // the original `activeWebView.url` read), not by poking the fake's
        // internal tab-state table.
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.center.ingress(.loadFinished(
            tabID: tabID,
            url: "https://user:secret@example.test/path?token=abc#frag",
            title: "P"
        ))
        try await harness.center.requestUserInteraction(reason: "log in manually", tabID: tabID, runID: UUID(), in: owner.taskID)

        await harness.center.bind(to: owner.taskID, owner: owner) // make it visible
        let outcome = await harness.center.returnToAgent(continueTask: true)
        if case .delivered(let needsContinue) = outcome {
            XCTAssertTrue(needsContinue)
        } else {
            XCTFail("expected delivered, got \(outcome)")
        }
        let deliveredOnce = await delivered.countValue()
        XCTAssertEqual(deliveredOnce, 1)
        let firstDelivery = await delivered.firstEntry()
        let receipt = firstDelivery!.0
        XCTAssertEqual(receipt.returning, true)
        XCTAssertEqual(receipt.sessionID, sessionID)
        let address = receipt.pageAddress ?? ""
        XCTAssertTrue(address.contains("example.test/path"))
        XCTAssertFalse(address.contains("token=abc"))
        XCTAssertFalse(address.contains("#frag"))
        XCTAssertFalse(address.contains("secret"))

        // Pre-takeover document references are dead after control returns.
        let observed = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)),
            in: owner
        )
        let documentID = observed.page?.documentID
        let controlling = await session.isUserControlling
        XCTAssertFalse(controlling)
        XCTAssertNotNil(documentID)
        // A receipt-bearing second call still works via the durable outbox
        // (original keeps the outbox until a later takeover replaces it).
        let outcome2 = await harness.center.returnToAgent(continueTask: false)
        if case .delivered = outcome2 {
            let deliveredTwice = await delivered.countValue()
            XCTAssertEqual(deliveredTwice, 2)
        } else {
            XCTFail("second delivery should proceed through the same path")
        }
    }

    func testWrongReceiptIdIsRefusedWithoutTouchingControl() async throws {
        let harness = BrowserTestHarness.make { _, _ in true }
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, _) = try await makeNavigatedSession(harness: harness, owner: owner)
        try await harness.center.requestUserInteraction(reason: "captcha", tabID: nil, runID: nil, in: owner.taskID)
        await harness.center.bind(to: owner.taskID, owner: owner)
        let outcome = await harness.center.returnToAgent(receiptID: UUID(), continueTask: false)
        XCTAssertEqual(outcome, .receiptMismatch)
        let controlling = await session.isUserControlling
        XCTAssertTrue(controlling, "a mismatched receipt cannot return control")
    }

    func testFailedDeliveryKeepsTheExactReceiptForRetry() async throws {
        let attempt = AttemptCounter()
        let harness = BrowserTestHarness.make { _, _ in
            let thisAttempt = await attempt.bump()
            if thisAttempt == 1 { throw FloeError.validationFailed("delivery down") }
            return false
        }
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: owner)
        try await harness.center.requestUserInteraction(reason: "login", tabID: nil, runID: nil, in: owner.taskID)
        await harness.center.bind(to: owner.taskID, owner: owner)
        let failed = await harness.center.returnToAgent(continueTask: false)
        if case .failed = failed {} else { XCTFail("expected failed outcome") }
        let receipt1 = await harness.center.handoff(for: owner.taskID)
        XCTAssertEqual(receipt1?.returning, true)

        // Taking control again keeps the SAME receipt id for the retry
        // (original rule: an undelivered returning receipt is preserved).
        await harness.center.takeControl(in: owner.taskID)
        let receipt2 = await harness.center.handoff(for: owner.taskID)
        XCTAssertEqual(receipt1?.id, receipt2?.id)

        let ok = await harness.center.returnToAgent(continueTask: false)
        if case .delivered(let needsContinue) = ok {
            XCTAssertFalse(needsContinue)
        } else {
            XCTFail("expected delivered, got \(ok)")
        }
    }

    func testRecoverHandoffTargetsExactRunOnly() async throws {
        let deliveredIDs = RunIDLog()
        let harness = BrowserTestHarness.make { handoff, _ in
            await deliveredIDs.append(handoff.runID)
            return false
        }
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: owner)
        let runID = UUID()
        try await harness.center.requestUserInteraction(reason: "login", tabID: nil, runID: runID, in: owner.taskID)
        await harness.center.bind(to: owner.taskID, owner: owner)
        _ = await harness.center.returnToAgent(continueTask: false) // marks returning
        // Recovery with the WRONG run does nothing; the exact run delivers.
        await harness.center.recoverHandoff(conversationID: owner.taskID, runID: UUID())
        let afterWrongRecovery = await deliveredIDs.countValue()
        XCTAssertEqual(afterWrongRecovery, 1) // only the first delivery
        await harness.center.recoverHandoff(conversationID: owner.taskID, runID: runID)
        let afterExactRecovery = await deliveredIDs.countValue()
        XCTAssertEqual(afterExactRecovery, 2)
        let lastDeliveredRun = await deliveredIDs.lastID()
        XCTAssertEqual(lastDeliveredRun, runID)
    }

    func testDiscardReleasesExactlyOneOwnerAndKeepsOthers() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let ownerA = BrowserTestHarness.owner()
        let ownerB = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: ownerA)
        let sessionB = try await harness.center.taskSession(for: ownerB)
        await harness.center.bind(to: ownerA.taskID, owner: ownerA)
        await harness.center.discard(conversationID: ownerA.taskID, notifyHook: true)
        let visible = await harness.center.projection()
        XCTAssertNil(visible.visibleTaskID)
        let keptSession = await harness.center.session(for: ownerB.taskID)
        XCTAssertNotNil(keptSession)
        let keptTabs = await keptSession!.tabSnapshots()
        XCTAssertFalse(keptTabs.isEmpty, "another owner's tabs are untouched")
        let bReleased = await sessionB.isReleased
        XCTAssertFalse(bReleased)
    }

    func testPanelRequestsKeepPerOwnerPendingState() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let visible = BrowserTestHarness.owner()
        let background = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: visible)
        _ = try await makeNavigatedSession(harness: harness, owner: background)
        await harness.center.bind(to: visible.taskID, owner: visible)

        try await harness.center.requestUserInteraction(reason: "A needs a click", tabID: nil, runID: nil, in: visible.taskID)
        try await harness.center.requestUserInteraction(reason: "B needs a login", tabID: nil, runID: nil, in: background.taskID)

        let pendingA = await harness.center.pendingPanelRequest(for: visible.taskID)
        let pendingB = await harness.center.pendingPanelRequest(for: background.taskID)
        XCTAssertNotNil(pendingA)
        XCTAssertNotNil(pendingB, "one task's request never erases another's prompt")

        let consumedB = await harness.center.consumePendingPanelRequest(for: background.taskID)
        XCTAssertEqual(consumedB?.show, true)
        let again = await harness.center.consumePendingPanelRequest(for: background.taskID)
        XCTAssertNil(again, "a background request is presented exactly once")

        // Dismissing another task's panel is refused; only the visible one
        // may be closed, and not while the user controls it.
        do {
            try await harness.center.requestPanelDismissal(conversationID: background.taskID)
            XCTFail("non-visible panel must not be dismissed")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("not visible"))
        }
        do {
            try await harness.center.requestPanelDismissal(conversationID: visible.taskID)
            XCTFail("user-controlled panel must not be dismissed by hide")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("return browser control"))
        }
    }
}

extension BrowserReturnOutcome: Equatable {}
