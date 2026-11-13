import XCTest
@testable import FloeBrowser

final class BrowserNavigationFailureTests: XCTestCase {
    func testErrorPageFinishDoesNotTurnFailedNavigationIntoSuccess() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.center.ingress(.loadStarted(tabID: tabID))
        await harness.center.ingress(.loadFailed(tabID: tabID, errorDomain: "webview",
                                               errorCode: -2, errorDescription: "Host lookup failed"))
        await harness.center.ingress(.loadFinished(tabID: tabID,
                                                  url: "https://example.test/unreachable", title: "Error page"))
        let result = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)), in: owner)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.error?.code, "navigation-load-failed")
        XCTAssertTrue(result.error?.message.contains("webview:-2") == true)
        XCTAssertNotNil(result.page, "The real error page remains inspectable")
        let state = await session.surfaceState
        guard case .failed = state else { return XCTFail("Error-page finish erased the platform failure") }
        let events = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .events(afterSequence: 0, limit: 50)), in: owner)
        XCTAssertEqual(events.events.last?.method, "Page.frameStoppedLoading")
    }

    func testNewSuccessfulLoadClearsThePriorNavigationFailure() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.center.ingress(.loadFailed(tabID: tabID, errorDomain: "http",
                                               errorCode: 503, errorDescription: "Unavailable"))
        let failed = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)), in: owner)
        XCTAssertEqual(failed.status, .failed)
        await harness.center.ingress(.loadStarted(tabID: tabID))
        await harness.center.ingress(.loadCommitted(tabID: tabID))
        await harness.center.ingress(.loadFinished(tabID: tabID, url: "https://example.test/feed", title: "Feed"))
        let recovered = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)), in: owner)
        XCTAssertEqual(recovered.status, .ok)
        XCTAssertNil(recovered.error)
    }

    func testEmptyPageAndErrorLookingTitleAreNotFailureEvidence() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.renderer.setTabState(tabID, url: "https://example.test/feed", title: "网页无法打开")
        await harness.center.ingress(.loadFinished(tabID: tabID, url: "https://example.test/feed", title: "网页无法打开"))
        let result = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)), in: owner)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.page?.nodes.count, 0)
        XCTAssertNil(result.error)
    }
}
