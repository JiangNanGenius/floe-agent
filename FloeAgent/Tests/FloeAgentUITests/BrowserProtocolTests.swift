// FloeAppTests — visible WebKit CDP-style protocol contracts.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import WebKit
@testable import FloeApp

@Suite("FloeApp.FloeBrowserProtocol")
struct BrowserProtocolTests {
    @Test("Static preview serves only its tokenized workspace files")
    func staticPreviewServerIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-preview-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>Floe preview</h1>".utf8).write(
            to: root.appendingPathComponent("index.html"),
            options: .atomic
        )

        let (server, session) = try await LocalPreviewServer.start(root: root, entry: nil)
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: session.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "<h1>Floe preview</h1>")

        let wrongToken = session.url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("wrong-token/index.html")
        let (_, deniedResponse) = try await URLSession.shared.data(from: wrongToken)
        #expect((deniedResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Only an explicitly authorized tokenized loopback preview is allowed")
    func localPreviewAuthorizationIsExact() throws {
        let allowed = try #require(URL(string: "http://127.0.0.1:54321/0123456789abcdef0123456789abcdef/index.html"))
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(allowed.absoluteString) }
        BrowserURLPolicy.authorizePreview(allowed)
        #expect(try BrowserURLPolicy.validate(allowed.absoluteString) == allowed)
        #expect(throws: BrowserPolicyError.self) {
            try BrowserURLPolicy.validate("http://127.0.0.1:54321/ffffffffffffffffffffffffffffffff/index.html")
        }
        BrowserURLPolicy.revokePreview(allowed)
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(allowed.absoluteString) }
    }

    @Test("DOM snapshots keep stable refs and emit mutation/input events")
    @MainActor
    func stableSnapshotAndEvents() async throws {
        let center = BrowserSessionCenter()
        center.bind(to: UUID())
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

    @Test("Coordinate fallback requires fresh visual evidence and yields to structured refs")
    @MainActor
    func coordinateFallbackIsEvidenceGated() async throws {
        let center = BrowserSessionCenter()
        center.bind(to: UUID())
        let tabID = try #require(center.activeTabID)
        let webView = try #require(center.activeWebView)
        webView.loadHTMLString(
            """
            <!doctype html><html><body style="margin:0">
              <button id="go" style="width:160px;height:80px">Go</button>
              <canvas id="surface" width="300" height="180" style="display:block"></canvas>
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
        #expect(waited.status == .ok)

        let screenshot = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            action: .screenshot
        ))
        let page = try #require(screenshot.page)
        let artifact = try #require(page.screenshotArtifact)
        let button = try #require(page.nodes.first(where: { $0.role == "button" }))

        let structuredPoint = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualEvidenceSHA256: artifact.sha256,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(
                x: button.bounds.x + button.bounds.width / 2,
                y: button.bounds.y + button.bounds.height / 2
            ))
        ))
        #expect(structuredPoint.status == .blocked)
        #expect(structuredPoint.message?.contains("use browser.click") == true)

        let missingEvidence = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(x: 20, y: 120))
        ))
        #expect(missingEvidence.status == .blocked)
        #expect(missingEvidence.message?.contains("fresh screenshot") == true)

        let canvasFallback = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualEvidenceSHA256: artifact.sha256,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(x: 20, y: 120))
        ))
        #expect(canvasFallback.status == .ok)
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
