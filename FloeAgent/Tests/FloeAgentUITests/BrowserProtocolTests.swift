// FloeAppTests — visible WebKit CDP-style protocol contracts.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import Testing
import WebKit
import SwiftUI
import UIKit
import FloeExecution
import FloeTools
import FloeCore
@testable import FloeApp

// Each case owns real WebKit processes. Simultaneous cold process launches
// caused a load timeout before this suite could exercise its protocol checks.
// Keep the same timeouts and assertions, but bound concurrent browser hosts.
@Suite("FloeApp.FloeBrowserProtocol", .serialized)
struct BrowserProtocolTests {
    @Test("Service previews are scoped to the owning task and revoked on shutdown")
    func servicePreviewOwnership() throws {
        let service = UUID(), owner = UUID(), other = UUID()
        let url = URL(string: "http://127.0.0.1:53271/")!
        BrowserURLPolicy.authorizeService(url, owner: service, conversationID: owner)
        defer { BrowserURLPolicy.revokeService(owner: service) }
        #expect(try BrowserURLPolicy.validate(url.absoluteString, conversationID: owner) == url)
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString, conversationID: other) }
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString) }
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate("http://127.0.0.1:53272/", conversationID: owner) }
        BrowserURLPolicy.revokeService(owner: service)
        #expect(throws: BrowserPolicyError.self) { try BrowserURLPolicy.validate(url.absoluteString, conversationID: owner) }
    }

    @Test("Browser panels open only through an explicit human-interaction request")
    @MainActor
    func explicitPanelHandoff() async throws {
        let center = BrowserSessionCenter()
        let owner = UUID()
        center.bind(to: owner)
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)
        let panel = try #require(registry.runner(named: "browser.panel"))
        let tab = try #require(registry.runner(named: "browser.tab"))
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: owner)
        _ = try await tab.execute(argumentsJSON: Data(#"{"action":"create"}"#.utf8), context: context)
        #expect(center.presentationRequest == nil)
        await #expect(throws: (any Error).self) {
            _ = try await panel.execute(argumentsJSON: Data(#"{"action":"requestUser"}"#.utf8), context: context)
        }
        #expect(center.presentationRequest == nil)
        let result = try await panel.execute(argumentsJSON: Data(#"{"action":"requestUser","reason":"请完成网页登录，然后交还控制权。"}"#.utf8), context: context)
        #expect(!result.requiresUserAction)
        #expect(center.presentationRequest?.show == true)
        #expect(center.presentationRequest?.conversationID == owner)
        #expect(center.isUserControlling)
        await #expect(throws: (any Error).self) {
            _ = try await panel.execute(argumentsJSON: Data(#"{"action":"hide"}"#.utf8), context: context)
        }
        center.deliverHandoff = { _, _ in false }
        await center.returnToAgent()
        _ = try await panel.execute(argumentsJSON: Data(#"{"action":"hide"}"#.utf8), context: context)
        #expect(center.presentationRequest?.show == false)
        let request = center.presentationRequest
        let wrongTask = ToolContext(runID: UUID(), cancellation: CancellationToken(), conversationID: UUID())
        await #expect(throws: (any Error).self) {
            _ = try await panel.execute(argumentsJSON: Data(#"{"action":"requestUser","reason":"Wrong task"}"#.utf8), context: wrongTask)
        }
        #expect(center.presentationRequest == request)
    }

    @Test("Handoff retries retain identity, original task and stale document invalidation")
    @MainActor
    func durableHandoffRetry() async throws {
        let center = BrowserSessionCenter()
        let owner = UUID(), run = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        center.takeControl(runID: run)
        let event = try #require(center.handoff)
        let before = center.tabs.first?.documentID
        var attempts = 0
        center.deliverHandoff = { delivered, _ in
            #expect(delivered.id == event.id)
            #expect(delivered.conversationID == owner)
            #expect(delivered.runID == run)
            attempts += 1
            if attempts == 1 { throw FloeError.validationFailed("synthetic delivery failure") }
            return false
        }
        await center.returnToAgent()
        #expect(center.handoffError != nil)
        #expect(center.isUserControlling)
        await center.returnToAgent()
        #expect(center.handoffNotified)
        #expect(!center.isUserControlling)
        #expect(center.tabs.first?.documentID != before)
        center.bind(to: UUID())
        center.bind(to: owner)
        #expect(!center.isUserControlling)
        let preview = BrowserSessionCenter(durableHandoffs: false)
        preview.bind(to: owner)
        preview.discard(conversationID: owner)
        let recovered = BrowserSessionCenter()
        recovered.bind(to: owner)
        #expect(recovered.handoff?.id == event.id)
        #expect(recovered.handoff?.returning == true)
    }

    @Test("Ended task handoff offers continuation and never requests it implicitly")
    @MainActor
    func endedHandoff() async throws {
        let center = BrowserSessionCenter(), owner = UUID()
        center.bind(to: owner)
        defer { center.discard(conversationID: owner) }
        center.takeControl(runID: UUID())
        center.deliverHandoff = { _, explicitlyContinue in
            #expect(!explicitlyContinue)
            return true
        }
        await center.returnToAgent()
        #expect(center.handoffNeedsContinue)
        #expect(!center.isUserControlling)
    }

    @Test("Static preview navigation remains in the background")
    @MainActor
    func previewDoesNotOpenPanel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html><body>Preview</body></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let browser = BrowserSessionCenter()
        browser.bind(to: UUID())
        let preview = LocalPreviewCoordinator(browser: browser)
        defer { _ = preview.stop() }
        _ = try await preview.start(root: root, relativeRoot: nil, entry: nil)
        #expect(browser.presentationRequest == nil)
        _ = try await preview.reload()
        #expect(browser.presentationRequest == nil)
    }

    @Test("Tab management is callable through the same registry advertised to models")
    @MainActor
    func registeredTabLifecycle() async throws {
        let center = BrowserSessionCenter()
        let runID = UUID()
        center.bind(to: runID)
        let initial = try #require(center.activeTabID)
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)
        let tabs = try #require(registry.runner(named: "browser.tabs"))
        let tab = try #require(registry.runner(named: "browser.tab"))
        let context = ToolContext(runID: runID, cancellation: CancellationToken(), conversationID: runID)
        _ = try await tab.execute(argumentsJSON: Data(#"{"action":"create"}"#.utf8), context: context)
        let created = try #require(center.activeTabID)
        #expect(created != initial)
        let listing = try await tabs.execute(argumentsJSON: Data("{}".utf8), context: context)
        #expect((try? JSONSerialization.jsonObject(with: Data(listing.summary.utf8))) != nil)
        #expect(listing.fullOutputSHA256.count == 64)
        #expect(listing.summary.contains(created.uuidString))
        _ = try await tab.execute(argumentsJSON: Data("{\"action\":\"activate\",\"tabID\":\"\(initial)\"}".utf8), context: context)
        #expect(center.activeTabID == initial)
        _ = try await tab.execute(argumentsJSON: Data("{\"action\":\"close\",\"tabID\":\"\(created)\"}".utf8), context: context)
        let final = try await tabs.execute(argumentsJSON: Data("{}".utf8), context: context)
        #expect(!final.summary.contains(created.uuidString))
    }

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
              <div id="counter">Clicked: 0</div>
              <canvas id="surface" width="300" height="180" style="display:block"></canvas>
              <script>
                const canvas = document.getElementById('surface');
                const context = canvas.getContext('2d');
                context.beginPath(); context.arc(150, 90, 45, 0, Math.PI * 2); context.fill();
                canvas.addEventListener('click', event => {
                  const rect = canvas.getBoundingClientRect();
                  const x = event.clientX - rect.left;
                  const y = event.clientY - rect.top;
                  window.canvasClick = [event.clientX, event.clientY];
                  if ((x - 150) ** 2 + (y - 90) ** 2 <= 45 ** 2) {
                    document.getElementById('counter').textContent = 'Clicked: 1';
                  }
                });
              </script>
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

        // Simulator WebKit intermittently reports "An unknown error occurred"
        // (code=webkit) for the first capture after a load; retry a bounded
        // number of times so a transient capture failure does not fail the
        // entire accepted-SDK regression suite (observed 1.6.2/1.6.4/1.6.5/1.6.6).
        var screenshot = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            action: .screenshot
        ))
        for attempt in 1...3 where screenshot.status == .failed && screenshot.error?.code == "webkit" {
            try await Task.sleep(for: .seconds(Double(attempt)))
            screenshot = await center.execute(BrowserCommand(
                sessionID: center.sessionID,
                tabID: tabID,
                action: .screenshot
            ))
        }
        let page = try #require(screenshot.page)
        let artifact = try #require(page.screenshotArtifact)
        let button = try #require(page.nodes.first(where: { $0.role == "button" }))
        func screenshotPoint(cssX: Double, cssY: Double, artifact: BrowserArtifactReference) -> (Double, Double) {
            (
                cssX / page.viewportWidth * Double(artifact.pixelWidth),
                cssY / page.viewportHeight * Double(artifact.pixelHeight)
            )
        }
        let buttonPoint = screenshotPoint(
            cssX: button.bounds.x + button.bounds.width / 2,
            cssY: button.bounds.y + button.bounds.height / 2,
            artifact: artifact
        )

        let structuredPoint = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualEvidenceSHA256: artifact.sha256,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(
                x: buttonPoint.0,
                y: buttonPoint.1
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

        let canvasPoint = screenshotPoint(cssX: 150, cssY: 188, artifact: artifact)
        let canvasFallback = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualEvidenceSHA256: artifact.sha256,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(x: canvasPoint.0, y: canvasPoint.1))
        ))
        #expect(canvasFallback.status == .ok)
        let clickCoordinates = try #require(
            try await webView.evaluateJavaScript("window.canvasClick") as? [NSNumber]
        )
        #expect(clickCoordinates.count == 2)
        if clickCoordinates.count == 2 {
            #expect(abs(clickCoordinates[0].doubleValue - 150) < 1)
            #expect(abs(clickCoordinates[1].doubleValue - 188) < 1)
        }
        let counter = try await webView.evaluateJavaScript("document.getElementById('counter').textContent") as? String
        #expect(counter == "Clicked: 1")

        let postArtifact = try #require(canvasFallback.page?.screenshotArtifact)
        let missPoint = screenshotPoint(cssX: 10, cssY: 108, artifact: postArtifact)
        let unconfirmed = await center.execute(BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: page.documentID,
            visualEvidenceSHA256: postArtifact.sha256,
            visualFallbackReason: "noStructuredTarget",
            action: .click(.point(x: missPoint.0, y: missPoint.1))
        ))
        #expect(unconfirmed.status == .failed)
        #expect(unconfirmed.error?.code == "no-observable-effect")
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
@Suite("FloeApp.PortManagement", .serialized)
struct PortManagementTests {
    @MainActor @Test("Concurrent edits converge and stopped rules stay saved without listeners")
    func portRuleConvergence() async throws {
        let suite = "floe-port-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let applier = QualificationPortApplier()
        let center = LinuxPortForwardCenter(applier: applier, defaults: defaults, deviceAddressProvider: { "192.0.2.10" })
        async let first: Void = center.addRule(environmentID: "A", guestPort: 8080, requestedHostPort: nil, label: "one", bindAddress: "127.0.0.1")
        async let second: Void = center.addRule(environmentID: "A", guestPort: 9090, requestedHostPort: nil, label: "two", bindAddress: "127.0.0.1")
        _ = try await (first, second)
        #expect(center.rules(environmentID: "A").count == 2)
        #expect(center.previews(environmentID: "A").allSatisfy { $0.isApplied })
        #expect(await applier.count("A") == 2)
        #expect(center.rules(environmentID: "B").isEmpty)
        let rule = try #require(center.rules(environmentID: "A").first)
        try await center.updateRule(environmentID: "A", ruleID: rule.id, guestPort: 8081,
            requestedHostPort: nil, label: "edited", bindAddress: "127.0.0.1")
        #expect(center.rule(environmentID: "A", id: rule.id)?.guestPort == 8081)
        try await center.setEnabled(environmentID: "A", ruleID: rule.id, isEnabled: false)
        #expect(await applier.count("A") == 1)
        await applier.stop()
        center.guestStopped(environmentID: "A")
        await center.applyRules(environmentID: "A")
        #expect(center.rules(environmentID: "A").count == 2)
        #expect(center.previews(environmentID: "A").allSatisfy { !$0.isApplied })
    }
}

private actor QualificationPortApplier: LinuxPortForwardApplying {
    private var running = true
    private var forwards: [String: Set<LinuxGuestServiceForward>] = [:]
    func guestIsRunning(environmentID: String) async -> Bool { running }
    func apply(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        try await Task.sleep(for: .milliseconds(2))
        forwards[environmentID, default: []].insert(forward)
    }
    func remove(environmentID: String, forward: LinuxGuestServiceForward) async {
        forwards[environmentID]?.remove(forward)
    }
    func count(_ environmentID: String) -> Int { forwards[environmentID]?.count ?? 0 }
    func stop() { running = false; forwards.removeAll() }
}

@Suite("FloeApp.TerminalRendering", .serialized)
struct TerminalRenderingTests {
    @MainActor @Test("UTF8 and ANSI continue across chunks and buffer rollover without resetting the renderer")
    func orderedByteRendering() async throws {
        let state = TerminalPresentation(), generation = UUID()
        func surface(_ data: Data, end: Int) -> SSHEmulatorView {
            SSHEmulatorView(output: data, byteEnd: end, generation: generation, presentation: state,
                isInteractive: false, onSend: { _ in }, onResize: { _, _ in })
        }
        let host = UIHostingController(rootView: surface(Data([0xe4, 0xbd]), end: 2))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // The retained window starts in the middle of a UTF8 scalar. Byte
        // positions let the parser consume only the not-yet-rendered suffix.
        let tail = Data([0xbd, 0xa0, 0x1b, 0x5b])
        host.rootView = surface(tail, end: 5)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.rootView = surface(Data("31m好\r\nDONE".utf8), end: 5 + Data("31m好\r\nDONE".utf8).count)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // SwiftTerm exports a NUL continuation cell after each double-width
        // glyph; exclude those cell markers, as the clipboard export does.
        let text = String(decoding: state.view.getTerminal().getBufferAsData(), as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: "")
        #expect(text.contains("你好"))
        #expect(text.contains("DONE"))
        #expect(!text.contains("�"))
        #expect(state.renderedEnd == 5 + Data("31m好\r\nDONE".utf8).count)
        let scrollback = Data(String(repeating: "line 中文\r\n", count: 200).utf8)
        state.consume(scrollback, byteEnd: (state.renderedEnd ?? 0) + scrollback.count, generation: generation)
        try await Task.sleep(for: .milliseconds(100))
        state.view.setContentOffset(.zero, animated: false)
        let more = Data("tail\r\n".utf8)
        state.consume(more, byteEnd: (state.renderedEnd ?? 0) + more.count, generation: generation)
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.view.contentOffset.y < 1) // output must not steal scrollback position
        state.clear()
        #expect(state.renderedEnd != nil) // screen clear does not reset the byte cursor
    }
}
#endif
