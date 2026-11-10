#if canImport(UIKit) && canImport(WebKit) && DEBUG
import Foundation
import Testing
import WebKit
@testable import FloeApp

@Suite("User browser ownership", .serialized)
@MainActor
struct NextRoundBrowserModeTests {
    @Test("A user browser never creates or delivers a task handoff and leaves task control alone")
    func standaloneBrowserDoesNotTakeOverATask() async throws {
        let taskCenter = BrowserSessionCenter(durableHandoffs: false)
        let taskOwner = UUID()
        taskCenter.bind(to: taskOwner)
        taskCenter.takeControl(runID: UUID())
        let taskSession = try #require(taskCenter.visibleSession)
        let taskReceipt = try #require(taskCenter.handoff)
        defer { taskCenter.discard(conversationID: taskOwner) }

        let browser = BrowserSessionCenter(durableHandoffs: false, taskHandoffsEnabled: false)
        let browserOwner = UUID()
        browser.bind(to: browserOwner)
        let session = try #require(browser.visibleSession)
        defer { browser.discard(conversationID: browserOwner) }
        var delivered = false
        browser.deliverHandoff = { _, _ in delivered = true; return false }
        // Both native UI takeover and a WKWebView interaction must stay local.
        browser.takeControl()
        browser.browserSessionRequestedUserControl(session, reason: "User navigation")
        await browser.returnToAgent(continueTask: true)
        #expect(!browser.taskHandoffsEnabled)
        #expect(!session.isUserControlling && browser.handoff == nil)
        #expect(!delivered && browser.pendingPanelRequests.isEmpty)
        #expect(throws: (any Error).self) {
            try browser.requestUserInteraction(reason: "No assistant owns this browser", tabID: nil)
        }
        #expect(taskCenter.visibleSession === taskSession)
        #expect(taskSession.isUserControlling && taskCenter.handoff == taskReceipt)
        browser.bind(to: nil)
        browser.bind(to: browserOwner)
        #expect(browser.visibleSession === session)
        #expect(browser.handoff == nil)
    }

}
#endif
