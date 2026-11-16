import XCTest
import FloeCore
import FloeTools
@testable import FloeBrowser

/// Models WebView's asynchronous loadUrl/commit ordering rather than assuming
/// the renderer's navigation acknowledgement already means the new page exists.
final class BrowserNavigationIdentityTests: XCTestCase {
    private let oldURL = "https://example.test/feed"
    private let requestedURL = "https://example.test/target"
    private let redirectedURL = "https://redirect.example.test/final"
    private let oldSnapshot = #"{"revision":2,"viewportWidth":1280,"viewportHeight":800,"nodes":[{"ref":"n1","role":"p","name":"","text":"OLD PAGE","value":null,"state":{},"bounds":{"x":0,"y":0,"width":10,"height":10}}],"nextCursor":null}"#
    private let newSnapshot = #"{"revision":1,"viewportWidth":1280,"viewportHeight":800,"nodes":[{"ref":"n1","role":"p","name":"","text":"NEW PAGE","value":null,"state":{},"bounds":{"x":0,"y":0,"width":10,"height":10}}],"nextCursor":null}"#

    private func tokenSnapshot(_ token: String, url: String) -> String {
        #"{"probeAvailable":true,"documentToken":"\#(token)","documentURL":"\#(url)","revision":1,"viewportWidth":1280,"viewportHeight":800,"nodes":[],"nextCursor":null}"#
    }

    private func tokenIdentity(_ token: String, url: String, revision: Int = 1) -> String {
        #"{"probeAvailable":true,"documentToken":"\#(token)","documentURL":"\#(url)","revision":\#(revision),"scrollX":0,"scrollY":0,"viewportWidth":1280,"viewportHeight":800}"#
    }

    private func waitForNavigation(_ renderer: FakeRenderer, count: Int) async throws {
        guard await renderer.waitForNavigationCount(count) else {
            throw FakeRendererWaitFailure.navigationNotDispatched
        }
    }

    private func finish(
        _ harness: BrowserTestHarness, tabID: UUID, url: String
    ) async {
        await harness.center.ingress(.loadStarted(tabID: tabID))
        await harness.renderer.commitNewDocument(tabID)
        await harness.renderer.setTabState(tabID, url: url, title: "New page", loading: false)
        await harness.renderer.setSnapshot(newSnapshot)
        await harness.center.ingress(.loadCommitted(tabID: tabID))
        await harness.center.ingress(.loadFinished(tabID: tabID, url: url, title: "New page"))
    }

    private func bindOldToken(
        _ harness: BrowserTestHarness, session: BrowserTaskSession, sessionID: UUID, tabID: UUID
    ) async -> String? {
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: oldURL))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: oldURL))
        await harness.renderer.setDocumentStamp(tokenIdentity("token-A", url: oldURL))
        let first = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(first.status, .ok)
        return first.page?.documentID
    }

    func testPendingNavigationDoesNotReturnOldDocumentAsNewPage() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let before = (await session.tabs).first!.documentID
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        let during = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 500, action: .observe(cursor: nil)))
        XCTAssertNotEqual(during.status, .ok, "a still-current old page is not the requested navigation")
        await finish(harness, tabID: tabID, url: requestedURL)
        _ = await navigation.value
        let after = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(after.status, .ok)
        XCTAssertEqual(after.page?.url, requestedURL)
        XCTAssertEqual(after.page?.nodes.first?.text, "NEW PAGE")
        XCTAssertNotEqual(after.page?.documentID, before)
    }

    func testCommitDuringSnapshotCannotAttachOldDOMToNewDocument() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let oldDocument = (await session.tabs).first!.documentID
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.holdNextSnapshotReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForSnapshotReplyToBeHeld() else {
            observation.cancel()
            XCTFail("snapshot did not reach the renderer")
            return
        }
        await finish(harness, tabID: tabID, url: requestedURL)
        await harness.renderer.releaseHeldSnapshotReply()
        let result = await observation.value
        if result.status == .ok {
            XCTAssertEqual(result.page?.url, requestedURL)
            XCTAssertNotEqual(result.page?.documentID, oldDocument)
            XCTAssertNotEqual(result.page?.nodes.first?.text, "OLD PAGE")
        }
    }

    func testMissingProbeIsNotReportedAsSuccessfulEmptyDOM() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        await harness.renderer.setSnapshot(#"{"probeAvailable":false}"#)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)))
        XCTAssertNotEqual(result.status, .ok)
    }

    func testGenuinelyEmptyDOMIsStillValid() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        await harness.renderer.setSnapshot(#"{"revision":1,"viewportWidth":1280,"viewportHeight":800,"nodes":[],"nextCursor":null}"#)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.page?.nodes.count, 0)
    }

    func testRedirectReportsTheActualCommittedURL() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        await finish(harness, tabID: tabID, url: redirectedURL)
        _ = await navigation.value
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.page?.url, redirectedURL)
    }

    func testWaitForLoadDoesNotAcceptOldPageCompleteBeforeCommit() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setPreserveStateOnNavigate(true)
        // The old document's probe says complete throughout the pending load.
        await harness.renderer.setProbeStatus(#"{"readyState":"complete","selectorFound":false,"textFound":false,"idleMilliseconds":900,"revision":1}"#)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 300, action: .wait(.load)))
        XCTAssertNotEqual(result.status, .ok)
        await finish(harness, tabID: tabID, url: destination)
        _ = await navigation.value
    }

    func testPriorPageFinishCannotCompletePendingNavigation() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        await harness.center.ingress(.loadStarted(tabID: tabID))
        // The previous page sends a late completion without a new commit.
        await harness.center.ingress(.loadFinished(tabID: tabID, url: oldURL, title: "Old page"))
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 500, action: .observe(cursor: nil)))
        XCTAssertNotEqual(result.status, .ok)
        await finish(harness, tabID: tabID, url: destination)
        _ = await navigation.value
    }

    func testSameURLReloadStillRequiresNewDocumentCommit() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let oldDocument = (await session.tabs).first!.documentID
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = oldURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        let during = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 500, action: .observe(cursor: nil)))
        XCTAssertNotEqual(during.status, .ok)
        await finish(harness, tabID: tabID, url: oldURL)
        _ = await navigation.value
        let after = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(after.status, .ok)
        XCTAssertNotEqual(after.page?.documentID, oldDocument)
    }

    func testFragmentNavigationKeepsSameCommittedDocumentWithoutCommitEvent() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: oldURL))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: oldURL))
        await harness.renderer.setDocumentStamp(tokenIdentity("token-A", url: oldURL))
        let initial = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(initial.status, .ok)
        let originalDocument = initial.page?.documentID

        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = oldURL + "#section"
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 1_000, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        // Fragment navigation updates location in the same document; Android
        // may deliver no main-frame commit callback for this operation.
        await harness.renderer.setTabState(tabID, url: destination, title: "Page", loading: false)
        await harness.renderer.setDocumentStamp(tokenIdentity("token-A", url: destination))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: destination))
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: destination))
        let result = await navigation.value
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.page?.url, destination)
        XCTAssertEqual(result.page?.documentID, originalDocument)
    }

    func testSameURLCommitRejectsPreviousRealDocumentTokenUntilItChanges() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: oldURL))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: oldURL))
        let first = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(first.status, .ok)
        let firstDocument = first.page?.documentID

        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = oldURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 1_000, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        await harness.center.ingress(.loadStarted(tabID: tabID))
        await harness.center.ingress(.loadCommitted(tabID: tabID))
        await harness.center.ingress(.loadFinished(tabID: tabID, url: oldURL, title: "Page"))
        _ = await navigation.value

        // Same URL alone is insufficient: WebView may still answer from A.
        let old = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertNotEqual(old.status, .ok)
        await harness.renderer.setSnapshot(tokenSnapshot("token-B", url: oldURL))
        await harness.renderer.setIdentity(tokenIdentity("token-B", url: oldURL))
        let fresh = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(fresh.status, .ok)
        XCTAssertEqual(fresh.page?.url, oldURL)
        XCTAssertNotEqual(fresh.page?.documentID, firstDocument)
    }

    func testChangingRealTokenBetweenSnapshotAndIdentityIsStale() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: oldURL))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: oldURL))
        let first = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(first.status, .ok)

        await harness.renderer.holdNextIdentityReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForIdentityReplyToBeHeld() else {
            observation.cancel()
            XCTFail("identity check did not reach the renderer")
            return
        }
        await harness.renderer.setIdentity(tokenIdentity("token-B", url: oldURL))
        await harness.renderer.releaseHeldIdentityReply()
        let result = await observation.value
        XCTAssertEqual(result.status, .stale)
    }

    func testClosingTabWhileSnapshotIsPendingCannotReturnItsOldPage() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let secondTab = await session.createTab()
        XCTAssertNotNil(secondTab, "the session retains at least one tab when another is closed")
        await session.activate(tabID)
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.holdNextSnapshotReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForSnapshotReplyToBeHeld() else {
            observation.cancel()
            XCTFail("snapshot did not reach the renderer")
            return
        }
        await session.close(tabID)
        await harness.renderer.releaseHeldSnapshotReply()
        let result = await observation.value
        XCTAssertNotEqual(result.status, .ok)
    }

    func testSwitchingActiveTabDoesNotRetargetAnInFlightObservation() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let firstTab = (await session.tabSnapshots()).first!.id
        let originalDocument = (await session.tabs).first!.documentID
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.holdNextSnapshotReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: firstTab,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForSnapshotReplyToBeHeld() else {
            observation.cancel()
            XCTFail("snapshot did not reach the renderer")
            return
        }
        let newTab = await session.createTab()
        XCTAssertNotNil(newTab)
        await harness.renderer.releaseHeldSnapshotReply()
        let result = await observation.value
        if result.status == .ok {
            XCTAssertEqual(result.page?.documentID, originalDocument)
            XCTAssertEqual(result.page?.url, oldURL)
            XCTAssertEqual(result.page?.nodes.first?.text, "OLD PAGE")
        }
    }

    func testFailureDuringPendingNavigationIsNotSuccess() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 500, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        await harness.center.ingress(.loadStarted(tabID: tabID))
        await harness.center.ingress(.loadFailed(tabID: tabID, errorDomain: "webview",
                                                 errorCode: -2, errorDescription: "Host lookup failed"))
        _ = await navigation.value
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 500, action: .observe(cursor: nil)))
        XCTAssertNotEqual(result.status, .ok)
    }

    func testCancellationOfHeldSnapshotDoesNotDeliverItsLateResult() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.holdNextSnapshotReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForSnapshotReplyToBeHeld() else {
            observation.cancel()
            XCTFail("snapshot did not reach the renderer")
            return
        }
        observation.cancel()
        await harness.renderer.releaseHeldSnapshotReply()
        let result = await observation.value
        XCTAssertNotEqual(result.status, .ok)
    }

    func testReleasedOwnerCannotDeliverAnInFlightSnapshot() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setSnapshot(oldSnapshot)
        await harness.renderer.holdNextSnapshotReply()
        let observation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .observe(cursor: nil)))
        }
        guard await harness.renderer.waitForSnapshotReplyToBeHeld() else {
            observation.cancel()
            XCTFail("snapshot did not reach the renderer")
            return
        }
        await harness.center.discard(conversationID: owner.taskID)
        await harness.renderer.releaseHeldSnapshotReply()
        let result = await observation.value
        XCTAssertNotEqual(result.status, .ok)
    }

    func testNoHistoryBackOrForwardDoesNotPoisonCurrentDocument() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let original = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.setTabState(tabID, url: oldURL, canGoBack: false, canGoForward: false)
        for action in [BrowserAction.back, .forward] {
            let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 300, action: action))
            XCTAssertNotEqual(result.status, .ok)
            let observation = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
            XCTAssertEqual(observation.status, .ok)
            XCTAssertEqual(observation.page?.documentID, original)
            XCTAssertEqual(observation.page?.url, oldURL)
        }
        let dispatched = await harness.renderer.backForwards
        XCTAssertTrue(dispatched.isEmpty, "a nonexistent history entry must not be dispatched")
    }

    private func assertSameDocumentHistory(_ action: BrowserAction, destination: String) async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let original = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.setTabState(tabID, url: oldURL, canGoBack: true, canGoForward: true)
        let history = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 1_000, action: action))
        }
        guard await harness.renderer.waitForHistoryCount(1) else {
            history.cancel()
            XCTFail("history action did not reach the renderer")
            return
        }
        // pushState/fragment history may change location without a new
        // document or a WebView commit callback.
        await harness.renderer.setTabState(tabID, url: destination, canGoBack: true, canGoForward: true)
        await harness.renderer.setDocumentStamp(tokenIdentity("token-A", url: destination))
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: destination))
        await harness.renderer.setSnapshot(tokenSnapshot("token-A", url: destination))
        let result = await history.value
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.page?.documentID, original)
        XCTAssertEqual(result.page?.url, destination)
    }

    func testBackHistoryFragmentKeepsTheRealDocument() async throws {
        try await assertSameDocumentHistory(.back, destination: oldURL + "#section")
    }

    func testForwardHistoryPushStateKeepsTheRealDocument() async throws {
        try await assertSameDocumentHistory(.forward, destination: "https://example.test/another-route?view=1")
    }

    func testTimedOutNavigationRequiresExplicitRecovery() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: BrowserTestHarness.owner())
        let tabID = (await session.tabSnapshots()).first!.id
        _ = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.setPreserveStateOnNavigate(true)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 300, action: .navigate(url: requestedURL)))
        XCTAssertEqual(result.status, .timeout)
        let observation = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(observation.error?.code, "navigation-uncertain")
        let destination = requestedURL
        let retry = Task { await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 1_000, action: .navigate(url: destination))) }
        try await waitForNavigation(harness.renderer, count: 3)
        await finish(harness, tabID: tabID, url: destination)
        let recovered = await retry.value
        XCTAssertEqual(recovered.status, .ok)
        XCTAssertEqual(recovered.page?.url, destination)
    }

    func testTimeoutWithUnprovenDocumentDoesNotRestoreOldPage() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        _ = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 300, action: .navigate(url: destination)))
        }
        try await waitForNavigation(harness.renderer, count: 2)
        await harness.renderer.setTabState(tabID, url: destination)
        await harness.renderer.setDocumentStamp(tokenIdentity("token-B", url: destination))
        await harness.renderer.setIdentity(tokenIdentity("token-B", url: destination))
        await harness.renderer.setSnapshot(tokenSnapshot("token-B", url: destination))
        let result = await navigation.value
        XCTAssertEqual(result.status, .timeout)
        let observation = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertNotEqual(observation.status, .ok)
    }

    func testCancelledNavigationFencesUnconfirmedDocument() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: BrowserTestHarness.owner())
        let tabID = (await session.tabSnapshots()).first!.id
        _ = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.setPreserveStateOnNavigate(true)
        let destination = requestedURL
        let navigation = Task { await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 2_000, action: .navigate(url: destination))) }
        try await waitForNavigation(harness.renderer, count: 2)
        navigation.cancel()
        let result = await navigation.value
        XCTAssertNotEqual(result.status, .ok)
        let observation = await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)))
        XCTAssertEqual(observation.error?.code, "navigation-uncertain")
    }

    func testMissingProbeScreenshotReturnsActualJPEGArtifact() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP//Z")!
        await harness.renderer.setScreenshot(jpeg, width: 1, height: 1)
        await harness.renderer.setRawSnapshot(#"{"probeAvailable":false}"#)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, action: .screenshot))
        XCTAssertEqual(result.status, .ok)
        let artifact = try XCTUnwrap(result.page?.screenshotArtifact)
        XCTAssertEqual(artifact.mimeType, "image/jpeg")
        XCTAssertEqual(artifact.pixelWidth, 1)
        XCTAssertEqual(artifact.pixelHeight, 1)
        let store = BrowserArtifactStore(directory: harness.directory.appendingPathComponent("Artifacts", isDirectory: true))
        XCTAssertEqual(store.read(artifact), jpeg, "the artifact must contain the actual renderer JPEG")
    }

    func testScreenshotSpanningACommitCannotReturnOldImageForNewDocument() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        _ = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.holdNextScreenshotReply()
        let screenshot = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
                timeoutMilliseconds: 2_000, action: .screenshot))
        }
        guard await harness.renderer.waitForScreenshotReplyToBeHeld() else {
            screenshot.cancel()
            XCTFail("screenshot did not reach the renderer")
            return
        }
        await finish(harness, tabID: tabID, url: requestedURL)
        await harness.renderer.releaseHeldScreenshotReply()
        let result = await screenshot.value
        XCTAssertNotEqual(result.status, .ok)
        XCTAssertNil(result.page?.screenshotArtifact)
    }

    func testScreenshotRejectsDOMRevisionChangedDuringCapture() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: BrowserTestHarness.owner())
        let tabID = (await session.tabSnapshots()).first!.id
        _ = await bindOldToken(harness, session: session, sessionID: sessionID, tabID: tabID)
        await harness.renderer.holdNextScreenshotReply()
        let screenshot = Task { await session.execute(BrowserCommand(sessionID: sessionID, tabID: tabID,
            timeoutMilliseconds: 2_000, action: .screenshot)) }
        guard await harness.renderer.waitForScreenshotReplyToBeHeld() else {
            screenshot.cancel()
            XCTFail("screenshot did not reach the renderer")
            return
        }
        await harness.renderer.setIdentity(tokenIdentity("token-A", url: oldURL, revision: 2))
        await harness.renderer.releaseHeldScreenshotReply()
        let result = await screenshot.value
        XCTAssertNotEqual(result.status, .ok)
        XCTAssertNil(result.page?.screenshotArtifact)
    }

    func testCreateBlankTabDoesNotDependOnProbeOrDuplicateTheTab() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let before = (await session.tabSnapshots()).count
        await harness.renderer.setRawSnapshot(#"{"probeAvailable":false}"#)
        let result = await session.execute(BrowserCommand(sessionID: sessionID, action: .create))
        XCTAssertEqual(result.status, .ok)
        let after = await session.tabSnapshots()
        XCTAssertEqual(after.count, before + 1)
        let created = await harness.renderer.createdTabs
        XCTAssertEqual(created.count, after.count)
    }

    func testProbeWithMissingTokenOrURLCannotPretendToBeAvailable() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        for raw in [
            #"{"probeAvailable":true,"documentURL":"https://example.test/feed","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
            #"{"probeAvailable":true,"documentToken":"token-A","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
            #"{"documentToken":"token-A","documentURL":"https://example.test/feed","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
            #"{"probeAvailable":true,"documentToken":"","documentURL":"https://example.test/feed","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
            #"{"probeAvailable":true,"documentToken":"token-A","documentURL":"","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
            #"{"probeAvailable":true,"documentToken":"\#(String(repeating: "x", count: 129))","documentURL":"https://example.test/feed","revision":1,"viewportWidth":1,"viewportHeight":1,"nodes":[],"nextCursor":null}"#,
        ] {
            await harness.renderer.setRawSnapshot(raw)
            let observation = await session.execute(BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)))
            XCTAssertNotEqual(observation.status, .ok)
        }
    }
}
