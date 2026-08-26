// FloeApp — owns visible WKWebView sessions independently of SwiftUI views.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Foundation
import SwiftUI
import WebKit
import CryptoKit

@MainActor
final class BrowserSessionCenter: NSObject, ObservableObject {
    enum SurfaceState: Equatable {
        case unbound
        case ready
        case loading
        case failed(String)
        case needsUser(String)
    }
    struct VisualFallbackEvidence {
        var documentID: String
        var sha256: String
        var capturedAt: Date
    }
    struct Tab: Identifiable {
        let id: UUID
        let webView: WKWebView
        var documentID: String
        var revision: Int
        var nextEventSequence: Int
        var events: [BrowserProtocolEvent]
        var visualFallbackEvidence: VisualFallbackEvidence?
    }

    @Published private(set) var sessionID = UUID()
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var isUserControlling = false
    @Published var addressText = ""
    @Published private(set) var presentationRequestID = UUID()
    @Published private(set) var surfaceState: SurfaceState = .unbound

    private struct TaskSession {
        var sessionID: UUID
        var tabs: [Tab]
        var activeTabID: UUID?
        var isUserControlling: Bool
        var addressText: String
    }
    private var taskSessions: [UUID: TaskSession] = [:]
    private(set) var conversationID: UUID?

    private let maxTabs = 6
    private let maxEventsPerTab = 256
    private let protocolVersion = "FloeBrowser/1.0"
    private let contentWorld = WKContentWorld.world(name: "org.floeagent.browser.agent")
    private let artifactDirectory: URL

    override init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        artifactDirectory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("BrowserArtifacts", isDirectory: true)
        super.init()
        cleanupArtifacts()
    }

    /// Binds the visible WebKit surface to one durable task. Tabs and page
    /// state are kept independently in memory, so switching tasks never
    /// leaks one task's browser into another.
    func bind(to newConversationID: UUID?) {
        guard newConversationID != conversationID else { return }
        if let conversationID {
            taskSessions[conversationID] = TaskSession(
                sessionID: sessionID,
                tabs: tabs,
                activeTabID: activeTabID,
                isUserControlling: isUserControlling,
                addressText: addressText
            )
        }
        conversationID = newConversationID
        if let newConversationID, let saved = taskSessions[newConversationID] {
            sessionID = saved.sessionID
            tabs = saved.tabs
            activeTabID = saved.activeTabID
            isUserControlling = saved.isUserControlling
            addressText = saved.addressText
            surfaceState = saved.isUserControlling
                ? .needsUser("User takeover is active") : .ready
        } else {
            sessionID = UUID()
            tabs.forEach { $0.webView.stopLoading() }
            tabs = []
            activeTabID = nil
            isUserControlling = false
            addressText = ""
            if newConversationID != nil {
                _ = createTab()
                surfaceState = .ready
            } else {
                surfaceState = .unbound
            }
        }
    }

    func discard(conversationID: UUID) {
        if self.conversationID == conversationID { bind(to: nil) }
        taskSessions.removeValue(forKey: conversationID)?.tabs.forEach {
            $0.webView.stopLoading()
        }
    }

    var activeWebView: WKWebView? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })?.webView
    }

    @discardableResult
    func createTab() -> UUID? {
        guard tabs.count < maxTabs else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.protocolProbeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: contentWorld
        ))
        // Give off-screen/task-owned tabs a real viewport before SwiftUI
        // presents them. A zero-sized WKWebView makes every DOM node appear
        // invisible and breaks semantic observation during background work.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1_024, height: 768),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let id = UUID()
        tabs.append(Tab(
            id: id,
            webView: webView,
            documentID: UUID().uuidString,
            revision: 0,
            nextEventSequence: 1,
            events: [],
            visualFallbackEvidence: nil
        ))
        activeTabID = id
        appendEvent(tabID: id, method: "Target.targetCreated")
        return id
    }

    func activate(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshVisibleAddress()
        appendEvent(tabID: id, method: "Target.targetActivated")
    }

    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].webView.stopLoading()
        tabs.remove(at: index)
        if activeTabID == id { activeTabID = tabs[min(index, tabs.count - 1)].id }
    }

    func navigateFromAddressBar() {
        if let currentURL = activeWebView?.url,
           Self.isLocalPreview(currentURL),
           addressText == Self.visibleAddress(for: activeWebView) {
            activeWebView?.reload()
            return
        }
        let candidate = addressText.contains("://") ? addressText : "https://\(addressText)"
        guard let url = try? BrowserURLPolicy.validate(candidate), let activeWebView else { return }
        activeWebView.load(URLRequest(url: url))
    }

    /// The address bar deliberately presents a human label for app-owned
    /// loopback previews. The real URL remains on WKWebView for navigation,
    /// browser tools, diagnostics, and an explicit copy action.
    var technicalAddress: String? { activeWebView?.url?.absoluteString }

    var isDisplayingLocalPreview: Bool {
        activeWebView?.url.map(Self.isLocalPreview) ?? false
    }

    func refreshVisibleAddress() {
        addressText = Self.visibleAddress(for: activeWebView)
    }

    private static func visibleAddress(for webView: WKWebView?) -> String {
        guard let webView, let url = webView.url else { return "" }
        guard isLocalPreview(url) else { return url.absoluteString }
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty,
           title.caseInsensitiveCompare("localhost") != .orderedSame {
            return title
        }
        let decodedName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let baseName = (decodedName as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? String(localized: "本地网页预览") : baseName
    }

    private static func isLocalPreview(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return url.host == "127.0.0.1" || url.host?.lowercased() == "localhost"
    }

    func takeControl() {
        isUserControlling = true
        surfaceState = .needsUser("Complete login, QR scan, verification, or file selection, then return control to the Agent.")
    }
    func returnToAgent() {
        isUserControlling = false
        surfaceState = .ready
    }
    func requestPresentation() { presentationRequestID = UUID() }

    func execute(_ command: BrowserCommand) async -> BrowserResult {
        guard command.version == 1 else {
            return failure(command, status: .failed, code: "version", "Unsupported browser protocol version")
        }
        guard command.sessionID == sessionID else {
            return failure(command, status: .stale, code: "session", "Browser session is no longer active")
        }
        if isUserControlling {
            switch command.action {
            case .protocolInfo, .observe, .listTabs, .events:
                break
            default:
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
        }

        switch command.action {
        case .protocolInfo:
            return BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
        case .create:
            guard let id = createTab() else {
                return failure(command, status: .blocked, code: "tab-limit", "The six-tab limit was reached")
            }
            return await observeResult(command, tabID: id, cursor: nil)
        case .listTabs:
            return await observeResult(command, tabID: command.tabID ?? activeTabID, cursor: nil)
        case .activateTab(let id):
            activate(id)
            return await observeResult(command, tabID: id, cursor: nil)
        case .closeTab(let id):
            close(id)
            return await observeResult(command, tabID: activeTabID, cursor: nil)
        case .takeover:
            takeControl()
            return failure(command, status: .needsUser, code: "takeover", "Browser control was handed to the user")
        default:
            break
        }

        guard let tabID = command.tabID ?? activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let tab = tabs[index]
        if let expected = command.expectedDocumentID, expected != tab.documentID {
            return failure(command, status: .stale, code: "document", "The page changed; observe it again")
        }

        do {
            switch command.action {
            case .navigate(let value):
                let url = try BrowserURLPolicy.validate(value)
                tab.webView.load(URLRequest(url: url))
            case .back:
                tab.webView.goBack()
            case .forward:
                tab.webView.goForward()
            case .reload:
                tab.webView.reload()
            case .observe(let cursor):
                return await observeResult(command, tabID: tabID, cursor: cursor)
            case .screenshot:
                let artifact = try await saveSnapshot(of: tab.webView)
                var result = await observeResult(command, tabID: tabID, cursor: nil)
                result.page?.screenshotArtifact = artifact
                if let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                    tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                        documentID: tabs[currentIndex].documentID,
                        sha256: artifact.sha256.lowercased(),
                        capturedAt: Date()
                    )
                }
                return result
            case .click(let target):
                if case .point = target {
                    try validateVisualFallback(command, in: tab)
                }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "click",
                    text: nil,
                    submit: false,
                    visualFallbackReason: command.visualFallbackReason
                )
            case .type(let target, let text, let submit):
                guard text.utf8.count <= 16 * 1024 else {
                    throw BrowserPolicyError.blocked("Browser input exceeds 16 KiB")
                }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "type",
                    text: text,
                    submit: submit,
                    visualFallbackReason: nil
                )
            case .scroll(let x, let y):
                _ = try await tab.webView.callAsyncJavaScript(
                    "window.scrollBy(dx, dy); return true;",
                    arguments: ["dx": x, "dy": y],
                    in: nil,
                    contentWorld: contentWorld
                )
                appendEvent(tabID: tabID, method: "Input.dispatchMouseEvent", detail: "scroll")
            case .wait(let condition):
                return await waitResult(command, tabID: tabID, condition: condition)
            case .events(let afterSequence, let limit):
                return await eventsResult(
                    command,
                    tabID: tabID,
                    afterSequence: afterSequence,
                    limit: limit
                )
            case .protocolInfo, .create, .listTabs, .activateTab, .closeTab, .takeover:
                break
            }
            return await observeResult(command, tabID: tabID, cursor: nil)
        } catch BrowserInteractionError.needsUser(let message) {
            isUserControlling = true
            surfaceState = .needsUser(message)
            return failure(command, status: .needsUser, code: "takeover", message)
        } catch BrowserInteractionError.stale(let message) {
            return failure(command, status: .stale, code: "document", message)
        } catch let error as BrowserPolicyError {
            return failure(command, status: .blocked, code: "policy", error.localizedDescription)
        } catch {
            return failure(command, status: .failed, code: "webkit", error.localizedDescription)
        }
    }

    /// CDP-shaped, allowlisted dispatch surface for integrations that prefer
    /// method/params requests over Floe's typed BrowserAction enum.
    func executeProtocol(_ request: FloeBrowserProtocolCommand) async -> FloeBrowserProtocolResponse {
        let action: BrowserAction
        let documentID = request.documentID
        switch request.method {
        case .getVersion:
            action = .protocolInfo
        case .getTargets, .getDocument:
            action = request.method == .getTargets ? .listTabs : .observe(cursor: nil)
        case .createTarget:
            action = .create
        case .activateTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.activateTarget requires targetID")
            }
            action = .activateTab(targetID)
        case .closeTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.closeTarget requires targetID")
            }
            action = .closeTab(targetID)
        case .navigate:
            guard let url = request.url, !url.isEmpty else {
                return protocolFailure(request, "Page.navigate requires url")
            }
            action = .navigate(url: url)
        case .reload:
            action = .reload
        case .captureScreenshot:
            action = .screenshot
        case .waitForLoad:
            action = .wait(.load)
        case .waitForDOM:
            action = .wait(.domContentLoaded)
        case .waitForIdle:
            action = .wait(.idle(milliseconds: min(5_000, max(100, request.timeoutMilliseconds ?? 500))))
        case .dispatchMouseEvent:
            if let ref = request.ref, let documentID {
                action = .click(.element(ref: ref, documentID: documentID))
            } else if let x = request.x, let y = request.y,
                      x.isFinite, y.isFinite, x >= 0, y >= 0,
                      request.screenshotSHA256?.isEmpty == false,
                      request.fallbackReason?.isEmpty == false {
                action = .click(.point(x: x, y: y))
            } else {
                return protocolFailure(request, "Coordinate Input.dispatchMouseEvent requires documentID, a fresh screenshotSHA256, and fallbackReason")
            }
        case .insertText:
            guard let ref = request.ref, !ref.isEmpty,
                  let documentID, !documentID.isEmpty,
                  let text = request.text, text.utf8.count <= 16 * 1024 else {
                return protocolFailure(request, "Input.insertText requires ref, documentID, and bounded text")
            }
            action = .type(
                .element(ref: ref, documentID: documentID),
                text: text,
                submit: request.submit ?? false
            )
        case .getEvents:
            action = .events(
                afterSequence: request.afterSequence,
                limit: min(100, max(1, request.limit ?? 50))
            )
        }
        let command = BrowserCommand(
            requestID: UUID(),
            sessionID: request.sessionID,
            tabID: request.targetID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: min(30_000, max(250, request.timeoutMilliseconds ?? 15_000)),
            visualEvidenceSHA256: request.screenshotSHA256,
            visualFallbackReason: request.fallbackReason,
            action: action
        )
        return FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: await execute(command)
        )
    }

    private func protocolFailure(
        _ request: FloeBrowserProtocolCommand,
        _ message: String
    ) -> FloeBrowserProtocolResponse {
        FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: BrowserResult(
                requestID: UUID(),
                status: .failed,
                message: message,
                error: BrowserFailure(code: "invalid-params", message: message),
                protocolVersion: protocolVersion
            )
        )
    }

    private func perform(
        target: BrowserTarget,
        in tab: Tab,
        operation: String,
        text: String?,
        submit: Bool,
        visualFallbackReason: String?
    ) async throws {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {status:'stale'};
        return protocol.perform(operation, target, documentID, text, submit, visualFallbackReason);
        """
        let targetObject: [String: Any]
        switch target {
        case .element(let ref, let documentID):
            targetObject = ["kind": "element", "ref": ref, "documentID": documentID]
        case .point(let x, let y):
            targetObject = ["kind": "point", "x": x, "y": y]
        }
        let value = try await tab.webView.callAsyncJavaScript(
            script,
            arguments: [
                "operation": operation,
                "target": targetObject,
                "documentID": tab.documentID,
                "text": text ?? "",
                "submit": submit,
                "visualFallbackReason": visualFallbackReason ?? ""
            ],
            in: nil,
            contentWorld: contentWorld
        )
        let status = (value as? [String: Any])?["status"] as? String
        if status == "needsUser" { throw BrowserInteractionError.needsUser("Sensitive input requires user takeover") }
        if status == "stale" { throw BrowserInteractionError.stale("The target is stale; observe the page again") }
        if status == "structured" {
            let ref = (value as? [String: Any])?["ref"] as? String ?? "unknown"
            throw BrowserPolicyError.blocked(
                "A structured target (\(ref)) is available at these coordinates; use browser.click"
            )
        }
        if status != "ok" { throw BrowserPolicyError.blocked("The target cannot accept this action") }
        appendEvent(
            tabID: tab.id,
            method: operation == "click" ? "Input.dispatchMouseEvent" : "Input.insertText"
        )
    }

    private func validateVisualFallback(_ command: BrowserCommand, in tab: Tab) throws {
        guard let reason = command.visualFallbackReason,
              ["noStructuredTarget", "insufficientStructuredInformation"].contains(reason) else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a reason that structured information is absent or insufficient"
            )
        }
        guard let expectedDigest = command.visualEvidenceSHA256?.lowercased(),
              expectedDigest.count == 64,
              expectedDigest.allSatisfy(\.isHexDigit),
              let evidence = tab.visualFallbackEvidence,
              evidence.documentID == tab.documentID,
              evidence.sha256 == expectedDigest,
              Date().timeIntervalSince(evidence.capturedAt) <= 120 else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a fresh screenshot from the current page"
            )
        }
    }

    private func observeResult(_ command: BrowserCommand, tabID: UUID?, cursor: Int?) async -> BrowserResult {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        do {
            await collectProbeEvents(tabID: tabID)
            let start = max(0, cursor ?? 0)
            let pageSize = 40
            let probe = try await semanticSnapshot(
                in: tab.webView,
                documentID: tab.documentID,
                cursor: start,
                limit: pageSize
            )
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].revision = max(tabs[index].revision, probe.revision)
            }
            let snapshot = PageSnapshot(
                documentID: tab.documentID,
                revision: max(tab.revision, probe.revision),
                url: tab.webView.url?.absoluteString ?? "",
                title: tab.webView.title ?? "",
                isLoading: tab.webView.isLoading,
                viewportWidth: tab.webView.bounds.width,
                viewportHeight: tab.webView.bounds.height,
                scrollX: Double(tab.webView.scrollView.contentOffset.x),
                scrollY: Double(tab.webView.scrollView.contentOffset.y),
                tabs: tabSnapshots(),
                nodes: probe.nodes,
                nextCursor: probe.nextCursor,
                screenshotArtifact: nil
            )
            return BrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func semanticSnapshot(
        in webView: WKWebView,
        documentID: String,
        cursor: Int,
        limit: Int
    ) async throws -> ProbeSnapshot {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {revision:0, nodes:[], nextCursor:null};
        return protocol.snapshot(documentID, cursor, limit);
        """
        let value = try await webView.callAsyncJavaScript(
            script,
            arguments: ["documentID": documentID, "cursor": cursor, "limit": limit],
            in: nil,
            contentWorld: contentWorld
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            return ProbeSnapshot(revision: 0, nodes: [], nextCursor: nil)
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }

    private func eventsResult(
        _ command: BrowserCommand,
        tabID: UUID,
        afterSequence: Int?,
        limit: Int
    ) async -> BrowserResult {
        await collectProbeEvents(tabID: tabID)
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let floor = max(0, afterSequence ?? 0)
        let available = tab.events.filter { $0.sequence > floor }
        let boundedLimit = min(100, max(1, limit))
        let selected = Array(available.prefix(boundedLimit))
        return BrowserResult(
            requestID: command.requestID,
            status: .ok,
            events: selected,
            nextEventSequence: selected.last?.sequence ?? afterSequence,
            protocolVersion: protocolVersion
        )
    }

    private func waitResult(
        _ command: BrowserCommand,
        tabID: UUID,
        condition: BrowserWaitCondition
    ) async -> BrowserResult {
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        repeat {
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            await collectProbeEvents(tabID: tabID)
            if case .documentChanged(let oldDocumentID) = condition,
               tab.documentID != oldDocumentID {
                appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                return await observeResult(command, tabID: tabID, cursor: nil)
            }
            do {
                let state = try await probeState(
                    in: tab.webView,
                    documentID: tab.documentID,
                    condition: condition
                )
                let satisfied: Bool
                switch condition {
                case .load:
                    // `readyState` is the page-world lifecycle signal that
                    // corresponds to CDP's load event. WKWebView.isLoading
                    // may lag for loadHTMLString and late subresources.
                    satisfied = state.readyState == "complete"
                case .domContentLoaded:
                    satisfied = state.readyState == "interactive" || state.readyState == "complete"
                case .selector:
                    satisfied = state.selectorFound
                case .text:
                    satisfied = state.textFound
                case .documentChanged:
                    satisfied = false
                case .idle(let milliseconds):
                    satisfied = !tab.webView.isLoading
                        && state.idleMilliseconds >= Double(min(5_000, max(100, milliseconds)))
                }
                if satisfied {
                    appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                    return await observeResult(command, tabID: tabID, cursor: nil)
                }
            } catch {
                // Document-start script injection and the isolated content
                // world can briefly race navigation commit. Treat that as a
                // not-yet-satisfied wait and retry until the bounded deadline.
                if Date() >= deadline {
                    return failure(command, status: .failed, code: "probe", error.localizedDescription)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline && !Task.isCancelled
        if Task.isCancelled {
            return failure(command, status: .failed, code: "cancelled", "Browser wait was cancelled")
        }
        return failure(command, status: .timeout, code: "timeout", "Browser wait condition timed out")
    }

    private func probeState(
        in webView: WKWebView,
        documentID: String,
        condition: BrowserWaitCondition
    ) async throws -> ProbeState {
        var selector = ""
        var text = ""
        switch condition {
        case .selector(let value): selector = String(value.prefix(512))
        case .text(let value): text = String(value.prefix(512))
        default: break
        }
        let value = try await webView.callAsyncJavaScript(
            """
            const protocol = globalThis.__floeProtocol;
            if (!protocol) return {readyState:'loading', selectorFound:false, textFound:false, idleMilliseconds:0, revision:0};
            return protocol.status(documentID, selector, text);
            """,
            arguments: ["documentID": documentID, "selector": selector, "text": text],
            in: nil,
            contentWorld: contentWorld
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            throw BrowserPolicyError.blocked("The browser probe returned an invalid status")
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeState.self, from: data)
    }

    private func collectProbeEvents(tabID: UUID) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        do {
            let value = try await tab.webView.callAsyncJavaScript(
                "return globalThis.__floeProtocol ? globalThis.__floeProtocol.drainEvents(documentID) : [];",
                arguments: ["documentID": tab.documentID],
                in: nil,
                contentWorld: contentWorld
            )
            guard JSONSerialization.isValidJSONObject(value as Any) else { return }
            let data = try JSONSerialization.data(withJSONObject: value as Any)
            let events = try JSONDecoder().decode([ProbeEvent].self, from: data)
            for event in events {
                appendEvent(
                    tabID: tabID,
                    method: event.method,
                    detail: event.detail,
                    revision: event.revision
                )
            }
        } catch {
            // A navigation may replace the JS world between lookup and call.
            // Native lifecycle events still describe that transition.
        }
    }

    private func appendEvent(
        tabID: UUID,
        method: String,
        detail: String? = nil,
        revision: Int? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sequence = tabs[index].nextEventSequence
        tabs[index].nextEventSequence += 1
        tabs[index].events.append(BrowserProtocolEvent(
            sequence: sequence,
            timestamp: Date(),
            tabID: tabID,
            documentID: tabs[index].documentID,
            method: method,
            detail: detail.map { String($0.prefix(512)) },
            revision: revision
        ))
        if tabs[index].events.count > maxEventsPerTab {
            tabs[index].events.removeFirst(tabs[index].events.count - maxEventsPerTab)
        }
        if let revision {
            tabs[index].revision = max(tabs[index].revision, revision)
        }
    }

    /// Runs in a named isolated content world at document start. It maintains
    /// stable per-document node references and a small lifecycle/DOM queue,
    /// but deliberately exposes no arbitrary JavaScript evaluation endpoint.
    private static let protocolProbeSource = #"""
    (() => {
      if (globalThis.__floeProtocol) return;
      let documentID = '';
      let revision = 0;
      let nextRef = 1;
      let lastMutation = performance.now();
      const references = new WeakMap();
      const nodesByRef = new Map();
      const events = [];
      const selector = 'a,button,input,textarea,select,[role],[contenteditable="true"],[onclick],summary,label,h1,h2,h3,p';

      const push = (method, detail = null) => {
        events.push({method, detail, revision});
        if (events.length > 128) events.splice(0, events.length - 128);
      };
      const setDocument = id => {
        if (id && documentID !== id) documentID = id;
      };
      const roots = () => {
        const result = [document];
        const visit = root => {
          let all = [];
          try { all = Array.from(root.querySelectorAll('*')); } catch (_) {}
          for (const el of all) {
            if (el.shadowRoot) { result.push(el.shadowRoot); visit(el.shadowRoot); }
            if ((el.tagName || '').toLowerCase() === 'iframe') {
              try { if (el.contentDocument) { result.push(el.contentDocument); visit(el.contentDocument); } } catch (_) {}
            }
          }
        };
        visit(document);
        return result;
      };
      const visible = el => {
        try {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
        } catch (_) { return false; }
      };
      const ensureRef = el => {
        let ref = references.get(el);
        if (!ref) {
          if (nodesByRef.size >= 2048) {
            for (const [key, node] of nodesByRef) if (!node?.isConnected) nodesByRef.delete(key);
            while (nodesByRef.size >= 2048) nodesByRef.delete(nodesByRef.keys().next().value);
          }
          ref = `n${nextRef++}`;
          references.set(el, ref);
          nodesByRef.set(ref, el);
        }
        return ref;
      };
      const findByRef = ref => {
        const found = nodesByRef.get(ref);
        return found?.isConnected ? found : null;
      };
      const allNodes = () => {
        const seen = new Set();
        const output = [];
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll(selector)); } catch (_) {}
          for (const el of candidates) {
            if (seen.has(el) || !visible(el)) continue;
            seen.add(el);
            output.push(el);
            if (output.length >= 400) return output;
          }
        }
        return output;
      };
      const serialize = el => {
        const rect = el.getBoundingClientRect();
        const type = (el.type || '').toLowerCase();
        const role = el.getAttribute('role') || (el.tagName || '').toLowerCase();
        const password = type === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password';
        return {
          ref: ensureRef(el), role,
          name: String(el.getAttribute('aria-label') || el.title || '').slice(0, 300),
          text: password ? '' : String(el.innerText || el.textContent || '').trim().slice(0, 500),
          value: password ? null : (el.value == null ? null : String(el.value).slice(0, 500)),
          state: {disabled: !!el.disabled, checked: !!el.checked, selected: !!el.selected},
          bounds: {x:rect.x, y:rect.y, width:rect.width, height:rect.height}
        };
      };
      const snapshot = (id, cursor, limit) => {
        setDocument(id);
        const nodes = allNodes();
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(50, Math.max(1, Number(limit) || 40));
        const end = Math.min(nodes.length, start + count);
        return {
          revision,
          nodes: nodes.slice(start, end).map(serialize),
          nextCursor: end < nodes.length ? end : null
        };
      };
      const perform = (operation, target, expectedDocumentID, text, submit, visualFallbackReason) => {
        setDocument(expectedDocumentID);
        if (target.kind === 'element' && target.documentID !== documentID) return {status:'stale'};
        const el = target.kind === 'element'
          ? findByRef(target.ref)
          : document.elementFromPoint(Number(target.x), Number(target.y));
        if (!el || !el.isConnected) return {status:'stale'};
        if (operation === 'click') {
          if (target.kind === 'point' && visualFallbackReason === 'noStructuredTarget') {
            let structured = null;
            try { structured = el.closest(selector); } catch (_) {}
            const structuredTag = String((structured && structured.tagName) || '').toLowerCase();
            // A canvas can be observable as one structured DOM node while
            // containing many visual-only controls. browser.click on the
            // canvas ref cannot address those internal targets, so preserve
            // coordinate fallback for this exact boundary.
            if (structured && visible(structured) && structuredTag !== 'canvas') {
              return {status:'structured', ref:ensureRef(structured)};
            }
          }
          // A fresh screenshot point is already viewport-relative. Scrolling
          // its hit element before dispatch changes the coordinate and was
          // the main source of intermittent misses on long pages.
          if (target.kind === 'element') {
            el.scrollIntoView({block:'center', inline:'center'});
          }
          const rect = el.getBoundingClientRect();
          const x = target.kind === 'point' ? Number(target.x) : rect.x + rect.width / 2;
          const y = target.kind === 'point' ? Number(target.y) : rect.y + rect.height / 2;
          for (const type of ['pointerover','pointerenter','pointerdown','pointerup']) {
            try { el.dispatchEvent(new PointerEvent(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'mouse', isPrimary:true})); } catch (_) {}
          }
          if (target.kind === 'point') {
            // HTMLElement.click() manufactures a click at (0,0), which is
            // unusable for canvas hit-testing. Preserve the evidence-backed
            // viewport coordinates on the actual click event.
            el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));
          } else {
            el.click();
          }
          return {status:'ok'};
        }
        const tag = (el.tagName || '').toLowerCase();
        const inputType = (el.type || '').toLowerCase();
        if (inputType === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password') return {status:'needsUser'};
        if (!(tag === 'input' || tag === 'textarea' || el.isContentEditable)) return {status:'blocked'};
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(el, text); else el.value = text;
        }
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, inputType:'insertText', data:text})); } catch (_) {}
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        if (submit) {
          el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', bubbles:true}));
          if (el.form?.requestSubmit) el.form.requestSubmit();
          el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', bubbles:true}));
        }
        return {status:'ok'};
      };
      const status = (id, query, expectedText) => {
        setDocument(id);
        let selectorFound = false;
        if (query) {
          for (const root of roots()) {
            try { if (root.querySelector(query)) { selectorFound = true; break; } } catch (_) {}
          }
        }
        const bodyText = expectedText ? String(document.body?.innerText || '') : '';
        return {
          readyState: document.readyState,
          selectorFound,
          textFound: !!expectedText && bodyText.includes(expectedText),
          idleMilliseconds: Math.max(0, performance.now() - lastMutation),
          revision
        };
      };
      const drainEvents = id => { setDocument(id); return events.splice(0, events.length); };

      new MutationObserver(records => {
        if (!records.length) return;
        revision += 1;
        lastMutation = performance.now();
        push('DOM.documentUpdated');
      }).observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
      document.addEventListener('DOMContentLoaded', () => push('Page.domContentEventFired'), {once:true});
      addEventListener('load', () => push('Page.loadEventFired'), {once:true});
      addEventListener('hashchange', () => push('Page.navigatedWithinDocument'));
      addEventListener('popstate', () => push('Page.navigatedWithinDocument'));
      globalThis.__floeProtocol = {snapshot, perform, status, drainEvents};
      push('Runtime.executionContextCreated');
    })();
    """#

    private func saveSnapshot(of webView: WKWebView) async throws -> BrowserArtifactReference {
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let data = image.jpegData(compressionQuality: 0.78) else {
            throw BrowserPolicyError.blocked("The viewport could not be encoded")
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw BrowserPolicyError.blocked("The viewport snapshot exceeds 8 MiB")
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let name = "\(id.uuidString).jpg"
        try data.write(to: artifactDirectory.appendingPathComponent(name), options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BrowserArtifactReference(id: id, relativePath: "BrowserArtifacts/\(name)", mimeType: "image/jpeg", byteCount: data.count, sha256: digest)
    }

    /// Screenshot evidence is ephemeral. Keep a bounded recent set and
    /// remove stale Floe-owned artifacts without touching user files.
    private func cleanupArtifacts(now: Date = Date()) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: artifactDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        let files = urls.compactMap { url -> (URL, Date)? in
            guard url.pathExtension.lowercased() == "jpg",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, file) in files.enumerated() where index >= 128 || file.1 < cutoff {
            try? manager.removeItem(at: file.0)
        }
    }

    private func tabSnapshots() -> [BrowserTabSnapshot] {
        tabs.map {
            BrowserTabSnapshot(
                id: $0.id,
                url: $0.webView.url?.absoluteString ?? "",
                title: $0.webView.title ?? "",
                isActive: $0.id == activeTabID
            )
        }
    }

    private func failure(
        _ command: BrowserCommand,
        status: BrowserResult.Status,
        code: String,
        _ message: String
    ) -> BrowserResult {
        BrowserResult(
            requestID: command.requestID,
            status: status,
            message: message,
            error: BrowserFailure(code: code, message: message)
        )
    }
}

private struct ProbeSnapshot: Decodable {
    var revision: Int
    var nodes: [BrowserNode]
    var nextCursor: Int?
}

private struct ProbeState: Decodable {
    var readyState: String
    var selectorFound: Bool
    var textFound: Bool
    var idleMilliseconds: Double
    var revision: Int
}

private struct ProbeEvent: Decodable {
    var method: String
    var detail: String?
    var revision: Int?
}

private enum BrowserInteractionError: Error {
    case needsUser(String)
    case stale(String)
}

extension BrowserSessionCenter: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else {
            return .cancel
        }
        // WebKit uses its own blank document while `loadHTMLString` commits.
        // It is not a tool-addressable URL and must remain available for
        // local fixtures/previews; all external navigations still pass the
        // normal http/https/private-network policy below.
        if url.absoluteString == "about:blank" { return .allow }
        guard (try? BrowserURLPolicy.validate(url.absoluteString)) != nil else {
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
        surfaceState = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        tabs[index].documentID = UUID().uuidString
        tabs[index].revision = 0
        tabs[index].visualFallbackEvidence = nil
        appendEvent(
            tabID: tabs[index].id,
            method: "Page.frameNavigated"
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
        if tabs[index].id == activeTabID { refreshVisibleAddress() }
        surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
        objectWillChange.send()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))")
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let id = createTab(),
              let created = tabs.first(where: { $0.id == id })?.webView else { return nil }
        if let url = navigationAction.request.url,
           (try? BrowserURLPolicy.validate(url.absoluteString)) != nil {
            created.load(URLRequest(url: url))
        }
        return created
    }
}
#endif
