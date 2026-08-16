// FloeAppTests — visible WebKit CDP-style protocol contracts.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import WebKit
@testable import FloeApp

@Suite("FloeApp.FloeBrowserProtocol")
struct BrowserProtocolTests {
    @Test("DOM snapshots keep stable refs and emit mutation/input events")
    @MainActor
    func stableSnapshotAndEvents() async throws {
        let center = BrowserSessionCenter()
        let tabID = try #require(center.activeTabID)
        let webView = try #require(center.activeWebView)
        webView.loadHTMLString(
            """
            <!doctype html><html><body>
              <button id="go" onclick="document.getElementById('status').textContent='clicked'">Go</button>
              <p id="status">ready</p>
            </body></html>
            """,
            baseURL: URL(string: "https://example.com")!
        )

        let waited = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            timeoutMilliseconds: 5_000,
            action: .wait(.load)
        ))
        #expect(
            waited.status == .ok,
            Comment(rawValue: waited.message ?? "browser load wait failed")
        )

        let first = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            action: .observe(cursor: nil)
        ))
        let firstPage = try #require(first.page)
        let button = try #require(firstPage.nodes.first(where: { $0.role == "button" }))

        let second = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            action: .observe(cursor: nil)
        ))
        #expect(second.page?.nodes.first(where: { $0.role == "button" })?.ref == button.ref)

        let clicked = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: firstPage.documentID,
            action: .click(.element(ref: button.ref, documentID: firstPage.documentID))
        ))
        #expect(clicked.status == .ok)

        let status = try await webView.callAsyncJavaScript(
            "return document.getElementById('status').textContent;",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(status == "clicked")

        let events = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            action: .events(afterSequence: nil, limit: 50)
        ))
        #expect(events.events.contains(where: { $0.method == "Input.dispatchMouseEvent" }))
        #expect(events.events.contains(where: { $0.method == "DOM.documentUpdated" }))
    }

    @Test("CDP-shaped dispatch is allowlisted and reports protocol version")
    @MainActor
    func protocolDispatch() async throws {
        let center = BrowserSessionCenter()
        let response = await center.executeProtocol(FloeBrowserProtocolCommand(
            id: 7,
            sessionID: center.sessionID,
            method: .getVersion
        ))
        #expect(response.id == 7)
        #expect(response.protocolVersion == "FloeBrowser/1.0")
        #expect(response.result.status == .ok)
        #expect(response.result.protocolVersion == "FloeBrowser/1.0")

        let invalid = await center.executeProtocol(FloeBrowserProtocolCommand(
            id: 8,
            sessionID: center.sessionID,
            method: .activateTarget
        ))
        #expect(invalid.result.status == .failed)
        #expect(invalid.result.error?.code == "invalid-params")
    }
}
#endif
