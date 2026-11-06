// SPDX-License-Identifier: MPL-2.0
import XCTest
import WebKit
#if os(macOS)
import AppKit
#endif
import FloeInteractiveContentCore
@testable import FloeInteractiveContentWebKit

@MainActor
final class WebKitTests: XCTestCase {
    private var probes: [ObjectIdentifier: FrameProbe] = [:]
    private func makeController(html: String) throws -> InteractiveWebController {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
        let owner = ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
        let document = try InteractiveDocument(owner: owner, kind: "runtime-probe", title: "Probe",
                                               html: html, fallbackText: "Unavailable")
        let session = try InteractiveSession(document: document, expectedOwner: owner, persistence: .temporary)
        let controller = InteractiveWebController(document: document, session: session)
        installProbe(controller.webView)
        return controller
    }

    private func waitUntil(_ condition: @escaping @MainActor () async throws -> Bool,
                           seconds: Double = 12, stage: String = "runtime",
                           controller: InteractiveWebController? = nil) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        if let controller {
            print("WEBKIT DIAGNOSTICS \(stage): bridge=\(controller.bridgeDiagnostic), navigation=\(controller.navigationDiagnostic), ready=\(controller.isReady), failed=\(controller.failed)")
            let diagnostic = try? await rawEvaluate("({host:!!window.__floeHost,handler:!!(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.floeInteractive),frames:frames.length,url:location.href})", webView: controller.webView)
            print("WEBKIT MAIN \(String(describing: diagnostic))")
        }
        XCTFail("Timed out waiting for actual WebKit/runtime state: \(stage)")
        throw InteractiveError.storageFailure
    }

    func testChildInteractionPersistsAndSurvivesRendererRecreation() async throws {
        let html = """
        <button id="increment">Increment</button><output id="count"></output>
        <script>floeInteractive.ready(function(s){
        let n=(s.privateContent||{}).count||0;
        document.getElementById('count').textContent=n;
        document.getElementById('increment').onclick=function(){n++;document.getElementById('count').textContent=n;floeInteractive.setState({privateContent:{count:n},modelContent:{count:n}})};
        });</script>
        """
        let controller = try makeController(html: html)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        await controller.resume()
        try await waitUntil({ controller.isReady }, stage: "initial ready", controller: controller)
        // Execute inside the opaque-origin subframe through WebKit, never by weakening sandbox.
        let frame = try await childFrame(controller)
        try await evaluate("document.getElementById('increment').click()", controller: controller, frame: frame)
        try await waitUntil({
            try await controller.session.snapshot().privateContent["count"] == .number(1)
        }, stage: "click saved", controller: controller)
        let firstRevision = try await controller.session.snapshot().revision
        await controller.suspend()
        await controller.resume()
        try await waitUntil({ controller.isReady }, stage: "resumed ready", controller: controller)
        let resumedFrame = try await childFrame(controller)
        let restored = try await evaluate("document.getElementById('count').textContent", controller: controller, frame: resumedFrame)
        XCTAssertEqual(restored, .string("1"))
        let restoredRevision = try await controller.session.snapshot().revision
        XCTAssertEqual(restoredRevision, firstRevision)
        await controller.suspend()
    }

    func testSandboxBlocksParentDOMDirectNativeBridgeAndNetwork() async throws {
        let controller = try makeController(html: """
        <script>floeInteractive.ready(async function(){
        let parentBlocked=false,nativeBlocked=false,networkBlocked=false,connectViolation=false;
        document.addEventListener('securitypolicyviolation',function(e){if(e.effectiveDirective==='connect-src')connectViolation=true});
        try{void parent.document.body}catch(e){parentBlocked=true}
        try{await window.webkit.messageHandlers.floeInteractive.postMessage('{"event":"state"}')}catch(e){nativeBlocked=true}
        try{await fetch('https://example.invalid/floe-forbidden')}catch(e){networkBlocked=true}
        await new Promise(function(resolve){setTimeout(resolve,50)});
        await floeInteractive.setState({modelContent:{parentBlocked:parentBlocked,nativeBlocked:nativeBlocked,networkBlocked:networkBlocked,connectViolation:connectViolation},privateContent:null});
        });</script>
        """)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        await controller.resume()
        try await waitUntil({
            try await controller.session.snapshot().modelContent["networkBlocked"] == .bool(true)
        }, stage: "sandbox result saved", controller: controller)
        let state = try await controller.session.snapshot()
        XCTAssertEqual(state.modelContent["parentBlocked"], .bool(true))
        XCTAssertEqual(state.modelContent["nativeBlocked"], .bool(true))
        // A DNS failure alone is not evidence of network isolation.
        XCTAssertEqual(state.modelContent["connectViolation"], .bool(true))
        XCTAssertEqual(state.revision, 1)
        await controller.suspend()
    }

    func testStandaloneExportActuallyRunsAndRestoresCapturedState() async throws {
        let owner = ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
        let document = try InteractiveExamples.document(.budget, owner: owner)
        let captured = InteractiveState(document: document,
            privateContent: .object(["people": .number(30), "price": .number(80), "fixed": .number(500)]))
        let html = String(decoding: try InteractiveHTML.export(document: document, state: captured), as: UTF8.self)
        let controller = try makeController(html: "<p>Unused</p>")
        // Standalone browser mode must work with NO registered native bridge.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        installProbe(browser)
        browser.loadHTMLString(html, baseURL: nil)
        try await waitUntil {
            (try? await self.rawEvaluate("!!window.__floeHost", webView: browser)) == .bool(true)
        }
        let frame = try await childFrame(browser)
        try await waitUntil {
            (try? await self.rawEvaluate("document.getElementById('total').textContent", webView: browser, frame: frame)) == .string("2900.00")
        }
        _ = try await rawEvaluate("document.getElementById('people').value=40;document.getElementById('people').dispatchEvent(new Event('input'))", webView: browser, frame: frame)
        try await waitUntil {
            (try? await self.rawEvaluate("window.__floeHost.state().privateContent.people", webView: browser)) == .number(40)
        }
        browser.loadHTMLString("", baseURL: nil)
        await controller.suspend()
    }

    func testRepresentativeContentCalculatesChangesAndStopsWhenUnloaded() async throws {
        for example in InteractiveExample.allCases {
            let owner = ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
            let document = try InteractiveExamples.document(example, owner: owner)
            let session = try InteractiveSession(document: document, expectedOwner: owner, persistence: .temporary)
            let controller = InteractiveWebController(document: document, session: session)
            installProbe(controller.webView)
            controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
            await controller.resume()
            try await waitUntil({ controller.isReady }, stage: example.rawValue, controller: controller)
            let frame = try await childFrame(controller)
            switch example {
            case .budget:
                try await evaluate("document.getElementById('people').value=30;document.getElementById('people').dispatchEvent(new Event('input'))", controller: controller, frame: frame)
                let total = try await evaluate("document.getElementById('total').textContent", controller: controller, frame: frame)
                XCTAssertEqual(total, .string("2900.00"))
            case .parameter:
                let previous = try await evaluate("document.getElementById('curve').getAttribute('d')", controller: controller, frame: frame)
                try await evaluate("document.getElementById('coefficient').value=2;document.getElementById('coefficient').dispatchEvent(new Event('input'))", controller: controller, frame: frame)
                let next = try await evaluate("document.getElementById('curve').getAttribute('d')", controller: controller, frame: frame)
                XCTAssertNotEqual(previous, next)
            case .process:
                try await evaluate("document.getElementById('next').click();document.getElementById('play').click()", controller: controller, frame: frame)
            case .preview:
                try await evaluate("document.getElementById('details').click();const n=document.getElementById('note');n.value='a';n.dispatchEvent(new Event('input'));n.value='ab';n.dispatchEvent(new Event('input'));n.value='最后输入';n.dispatchEvent(new Event('input'))", controller: controller, frame: frame)
            case .chart:
                try await evaluate("document.getElementById('showB').checked=false;document.getElementById('showB').dispatchEvent(new Event('change'))", controller: controller, frame: frame)
                let line = try await evaluate("document.getElementById('lineB').getAttribute('d')", controller: controller, frame: frame)
                XCTAssertEqual(line, .string(""))
            }
            // No wait-for-save here: immediate suspend must drain the child's last input.
            await controller.suspend()
            let state = try await session.snapshot()
            switch example {
            case .budget: XCTAssertEqual(state.modelContent["total"], .number(2_900))
            case .parameter: XCTAssertEqual(state.modelContent["coefficient"], .number(2))
            case .process:
                XCTAssertEqual(state.modelContent["values"], .array([2, 5, 4, 1, 3].map { .number(Double($0)) }))
                try await Task.sleep(for: .milliseconds(650))
                let afterPause = try await session.snapshot()
                XCTAssertEqual(afterPause.revision, state.revision)
            case .preview:
                XCTAssertEqual(state.privateContent["tab"], .string("details"))
                XCTAssertEqual(state.privateContent["note"], .string("最后输入"))
            case .chart: XCTAssertEqual(state.privateContent["showB"], .bool(false))
            }
            XCTAssertGreaterThan(state.revision, 0)
        }
    }

    func testEvenValidKnownLeaseEnvelopeCannotCallNativeFromChildFrame() async throws {
        let controller = try makeController(html: "<p>Frame provenance probe</p>")
        controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        await controller.resume()
        try await waitUntil({ controller.isReady }, stage: "provenance ready", controller: controller)
        // Only this trusted native test can read the parent document to obtain its nonce.
        let leaseValue = try await evaluate("""
        (function(){const s=document.scripts[0].textContent;const marker="const seed=JSON.parse(decode('";const b=s.split(marker)[1].split("'")[0];return JSON.parse(atob(b)).leaseID})()
        """, controller: controller)
        guard case .string(let lease) = leaseValue, let leaseID = UUID(uuidString: lease) else {
            XCTFail("Could not obtain test-only parent lease"); return
        }
        let message = RuntimeMessage(leaseID: leaseID, sequence: 10000, event: .state,
                                     expectedRevision: 0, modelContent: .object(["forged": .bool(true)]), privateContent: .null)
        let json = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        let frame = try await childFrame(controller)
        try await evaluate("window.__attempt='pending';window.webkit.messageHandlers.floeInteractive.postMessage(\(literal)).then(function(){window.__attempt='accepted'},function(){window.__attempt='rejected'});'scheduled'", controller: controller, frame: frame)
        try await waitUntil {
            (try? await self.evaluate("window.__attempt", controller: controller, frame: frame)) == .string("rejected")
        }
        let state = try await controller.session.snapshot()
        XCTAssertEqual(state.revision, 0)
        // A trusted host attempting external navigation is also blocked by the actual delegate.
        let before = controller.blockedNavigations
        controller.webView.load(URLRequest(url: URL(string: "https://example.invalid/forbidden")!))
        try await waitUntil { controller.blockedNavigations > before }
        await controller.suspend()
    }

    func testFailedSaveRetainsInputAcrossOffscreenAndCanRecover() async throws {
        let owner = ContentOwner(conversationID: UUID(), runID: UUID(), messageID: UUID())
        let document = try InteractiveExamples.document(.preview, owner: owner)
        let repository = FailingRepository()
        let session = try InteractiveSession(document: document, expectedOwner: owner,
                                            persistence: .durable, durableRepository: repository)
        let controller = InteractiveWebController(document: document, session: session)
        installProbe(controller.webView)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        await controller.resume()
        try await waitUntil({ controller.isReady }, stage: "failed-save ready", controller: controller)
        let frame = try await childFrame(controller)
        try await evaluate("const n=document.getElementById('note');n.value='未保存的输入';n.dispatchEvent(new Event('input'))", controller: controller, frame: frame)
        try await waitUntil { controller.hasUnsavedChanges }
        await controller.suspend()
        await controller.resume()
        let retained = try await evaluate("document.getElementById('note').value", controller: controller, frame: frame)
        XCTAssertEqual(retained, .string("未保存的输入"))
        let before = try await session.snapshot()
        XCTAssertEqual(before.revision, 0)
        await repository.allowWrites()
        try await evaluate("document.getElementById('note').dispatchEvent(new Event('input'))", controller: controller, frame: frame)
        try await waitUntil { !controller.hasUnsavedChanges }
        let saved = try await session.snapshot()
        XCTAssertEqual(saved.privateContent["note"], .string("未保存的输入"))
        try await controller.close()
        await XCTAssertClosed.check(session)
    }

    // frameInfo is returned by WebKit itself; no synthetic frame identities.
    private func childFrame(_ controller: InteractiveWebController) async throws -> WKFrameInfo {
        try await childFrame(controller.webView)
    }
    private func installProbe(_ webView: WKWebView) {
        let probe = FrameProbe()
        probes[ObjectIdentifier(webView)] = probe
        webView.configuration.userContentController.add(probe, name: "floeTestFrame")
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.floeTestFrame.postMessage('frame')",
            injectionTime: .atDocumentEnd, forMainFrameOnly: false
        ))
    }
    private func childFrame(_ webView: WKWebView) async throws -> WKFrameInfo {
        let probe = try XCTUnwrap(probes[ObjectIdentifier(webView)])
        try await waitUntil { probe.child != nil }
        return try XCTUnwrap(probe.child)
    }

    @discardableResult
    private func evaluate(_ script: String, controller: InteractiveWebController,
                          frame: WKFrameInfo? = nil) async throws -> JSONValue {
        try await rawEvaluate(script, webView: controller.webView, frame: frame)
    }

    private func rawEvaluate(_ script: String, webView: WKWebView, frame: WKFrameInfo? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: frame, in: .page) { result in
                switch result {
                case .success(let value):
                    do {
                        let mirror = Mirror(reflecting: value)
                        let unwrapped: Any = mirror.displayStyle == .optional ? (mirror.children.first?.value ?? NSNull()) : value
                        let data = try JSONSerialization.data(withJSONObject: unwrapped, options: .fragmentsAllowed)
                        continuation.resume(returning: try JSONDecoder().decode(JSONValue.self, from: data))
                    } catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor
private final class FrameProbe: NSObject, WKScriptMessageHandler {
    var child: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame { child = nil } else { child = message.frameInfo }
    }
}

private actor FailingRepository: InteractiveStateRepository {
    private let storage = MemoryInteractiveStateRepository()
    private var rejecting = true
    func allowWrites() { rejecting = false }
    func load(document: InteractiveDocument) async throws -> InteractiveState {
        try await storage.load(document: document)
    }
    func compareAndSwap(document: InteractiveDocument, expectedRevision: UInt64,
                        modelContent: JSONValue, privateContent: JSONValue) async throws -> InteractiveState {
        if rejecting { throw InteractiveError.storageFailure }
        return try await storage.compareAndSwap(document: document, expectedRevision: expectedRevision,
            modelContent: modelContent, privateContent: privateContent)
    }
    func remove(document: InteractiveDocument) async throws { await storage.remove(document: document) }
}

private enum XCTAssertClosed {
    static func check(_ session: InteractiveSession) async {
        do {
            _ = try await session.snapshot()
            XCTFail("Closed session accepted a new access")
        } catch { /* Expected explicit close fence. */ }
    }
}
