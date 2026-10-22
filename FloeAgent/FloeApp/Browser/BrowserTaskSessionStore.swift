// FloeApp — task-scoped WKWebView execution contexts.
//
// One BrowserTaskSession owns exactly one task's WebKit tabs, document
// identities, visual evidence, event buffers and user-control state. The
// session is selected from a trusted ToolContext identity, never from model
// input, and it outlives any SwiftUI view that happens to show it. The visible
// browser is a projection of one session; other tasks keep executing in their
// own sessions while it is on screen.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Combine
import Foundation
import WebKit
import FloeCore

/// Immutable engine settings shared by every task session. Values are copied
/// at session creation so a session never reaches back into the visible
/// center for protocol or buffer configuration.
struct BrowserTaskSessionConfiguration {
    let protocolVersion: String
    let contentWorld: WKContentWorld
    let artifactDirectory: URL
    let maximumTabs: Int
    let maximumEventsPerTab: Int
}

/// Narrow callback surface from an execution context back to the service that
/// owns durable handoff receipts. Ordinary browser state is published by the
/// session itself; this host callback exists only for identity-bearing user
/// control transitions that must be persisted and routed.
@MainActor
protocol BrowserTaskSessionHost: AnyObject {
    func browserSessionRequestedUserControl(_ session: BrowserTaskSession, reason: String)
}

/// A callback may never arrive after a WebKit process/navigation failure.
/// Resolve a single Sendable JSON receipt on callback, deadline, cancellation,
/// or owner release; a late callback cannot resume it twice. No task group
/// waits for an uncooperative native callback before returning the failure.
enum BrowserProbeError: Error, Sendable, Equatable {
    case timedOut
    case released
}

@MainActor
final class BrowserProbeRequest {
    typealias Completion = @MainActor @Sendable (Result<Any, Error>) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadlineTask: Task<Void, Never>?
    private var started = false

    func run(
        deadline: ContinuousClock.Instant,
        invoke: (@escaping Completion) -> Void
    ) async throws -> Data {
        precondition(!started)
        started = true
        try Task.checkCancellation()
        let bytes = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                guard ContinuousClock.now < deadline else {
                    finish(.failure(BrowserProbeError.timedOut))
                    return
                }
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(.failure(BrowserProbeError.timedOut))
                }
                invoke { [weak self] result in
                    guard let self, self.continuation != nil else { return }
                    do {
                        // SDK Any stays on MainActor. Only JSON Data crosses
                        // the continuation; no unchecked Sendable wrapper.
                        let value = try result.get()
                        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                        self.finish(.success(data))
                    } catch {
                        self.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return bytes
    }

    func invalidate() { finish(.failure(BrowserProbeError.released)) }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(with: result)
    }
}

/// A single task's independent browser. All WebKit/UI work is MainActor.
///
/// `generation` is the owner lifecycle generation this session was created
/// under. The owning center bumps it on every release and every explicit
/// trusted reactivation, so a completion fenced to an older session can never
/// authorize work after the owner moved on to a newer generation. The
/// authoritative fences remain `isReleased` and the exact `sessionID`; the
/// generation makes the owner-level continuity explicit and testable.
@MainActor
final class BrowserTaskSession: NSObject, ObservableObject {
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
        var pixelWidth: Int
        var pixelHeight: Int
        var viewportWidth: Double
        var viewportHeight: Double
        var revision: Int
        var visualTextRegions: [VisualTextRegion]
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

    let conversationID: UUID
    /// Owner lifecycle generation stamped at creation by the owning center.
    let generation: Int
    @Published private(set) var sessionID = UUID()
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var isUserControlling = false
    @Published var addressText = ""
    @Published var surfaceState: SurfaceState = .unbound
    var isEditingAddress = false
    private(set) var isReleased = false
    private(set) var activeExecutionCount = 0
    private var pendingProbes: [UUID: BrowserProbeRequest] = [:]
    private(set) var lastActivityAt = Date()

    private weak var host: BrowserTaskSessionHost?
    private let protocolVersion: String
    private let contentWorld: WKContentWorld
    private let artifactDirectory: URL
    private let maximumTabs: Int
    private let maximumEventsPerTab: Int

    init(
        conversationID: UUID,
        generation: Int,
        configuration: BrowserTaskSessionConfiguration,
        host: BrowserTaskSessionHost
    ) {
        self.conversationID = conversationID
        self.generation = generation
        self.host = host
        self.protocolVersion = configuration.protocolVersion
        self.contentWorld = configuration.contentWorld
        self.artifactDirectory = configuration.artifactDirectory
        self.maximumTabs = configuration.maximumTabs
        self.maximumEventsPerTab = configuration.maximumEventsPerTab
        super.init()
    }

    // MARK: - Tabs

    var activeWebView: WKWebView? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })?.webView
    }

    @discardableResult
    func createTab() -> UUID? {
        guard !isReleased, tabs.count < maximumTabs else { return nil }
        lastActivityAt = Date()
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
        guard !isReleased, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        refreshVisibleAddress()
        appendEvent(tabID: id, method: "Target.targetActivated")
    }

    func close(_ id: UUID) {
        guard !isReleased, tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].webView.stopLoading()
        tabs.remove(at: index)
        if activeTabID == id { activeTabID = tabs[min(index, tabs.count - 1)].id }
    }

    func navigateFromAddressBar() {
        guard !isReleased else { return }
        if let currentURL = activeWebView?.url,
           Self.isLocalPreview(currentURL),
           addressText == Self.visibleAddress(for: activeWebView) {
            activeWebView?.reload()
            return
        }
        let candidate = addressText.contains("://") ? addressText : "https://\(addressText)"
        guard let url = try? BrowserURLPolicy.validate(candidate, conversationID: conversationID),
              let activeWebView else { return }
        activeWebView.load(URLRequest(url: url))
    }

    /// The title never replaces the navigable address, including loopback pages.
    var technicalAddress: String? { activeWebView?.url?.absoluteString }

    var isDisplayingLocalPreview: Bool {
        activeWebView?.url.map(Self.isLocalPreview) ?? false
    }

    func refreshVisibleAddress() {
        guard !isReleased, !isEditingAddress else { return }
        addressText = Self.visibleAddress(for: activeWebView)
    }

    private static func visibleAddress(for webView: WKWebView?) -> String {
        webView?.url?.absoluteString ?? ""
    }

    private static func isLocalPreview(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return url.host == "127.0.0.1" || url.host?.lowercased() == "localhost"
    }

    // MARK: - Ownership lifecycle

    func setUserControlling(_ value: Bool) {
        isUserControlling = value
        if value {
            surfaceState = .needsUser("User takeover is active")
        } else if case .needsUser = surfaceState {
            surfaceState = .ready
        }
    }

    /// Invalidate every element/document reference before the user or a new
    /// run takes the page. Only this task's evidence is affected.
    func invalidateDocumentsForHandoff() {
        guard !isReleased else { return }
        for index in tabs.indices {
            tabs[index].documentID = UUID().uuidString
            tabs[index].visualFallbackEvidence = nil
        }
    }

    /// Service-owned release. Stops only this task's WebViews and fences its
    /// delegate/probe callbacks; no other task session is touched.
    func release() {
        guard !isReleased else { return }
        isReleased = true
        let probes = Array(pendingProbes.values)
        pendingProbes.removeAll()
        probes.forEach { $0.invalidate() }
        isUserControlling = false
        surfaceState = .unbound
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.navigationDelegate = nil
            tab.webView.uiDelegate = nil
            tab.webView.removeFromSuperview()
        }
        tabs.removeAll()
        activeTabID = nil
        addressText = ""
    }

    // MARK: - Command execution

    func execute(_ command: BrowserCommand) async -> BrowserResult {
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        lastActivityAt = Date()
        activeExecutionCount += 1
        defer { activeExecutionCount -= 1 }

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
            host?.browserSessionRequestedUserControl(self, reason: "Browser control was handed to the user")
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
                let url = try BrowserURLPolicy.validate(value, conversationID: conversationID)
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
                let visualTextRegions = try recognizeVisualText(in: artifact)
                var result = await observeResult(command, tabID: tabID, cursor: nil)
                result.page?.screenshotArtifact = artifact
                result.page?.visualTextRegions = visualTextRegions
                if let page = result.page,
                   let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                    tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                        documentID: tabs[currentIndex].documentID,
                        sha256: artifact.sha256.lowercased(),
                        capturedAt: Date(),
                        pixelWidth: artifact.pixelWidth,
                        pixelHeight: artifact.pixelHeight,
                        viewportWidth: page.viewportWidth,
                        viewportHeight: page.viewportHeight,
                        revision: page.revision,
                        visualTextRegions: visualTextRegions
                    )
                }
                return result
            case .click(let requestedTarget):
                let target: BrowserTarget
                if case .visualText(let reference) = requestedTarget {
                    let evidence = try validateVisualFallback(command, in: tab)
                    guard let region = evidence.visualTextRegions.first(where: { $0.reference == reference }) else {
                        throw BrowserPolicyError.blocked(
                            "The visual text reference is absent or stale; capture a new browser screenshot"
                        )
                    }
                    target = .point(x: Double(region.centerX), y: Double(region.centerY))
                } else {
                    target = requestedTarget
                }
                if case .point(let x, let y) = target {
                    let evidence = try validateVisualFallback(command, in: tab)
                    guard x >= 0, y >= 0,
                          x < Double(evidence.pixelWidth),
                          y < Double(evidence.pixelHeight) else {
                        throw BrowserPolicyError.blocked(
                            "Visual click coordinates are outside the referenced screenshot"
                        )
                    }
                    let cssTarget = BrowserTarget.point(
                        x: x / Double(evidence.pixelWidth) * evidence.viewportWidth,
                        y: y / Double(evidence.pixelHeight) * evidence.viewportHeight
                    )
                    try await perform(
                        target: cssTarget,
                        in: tab,
                        operation: "click",
                        text: nil,
                        submit: false,
                        visualFallbackReason: command.visualFallbackReason
                    )
                    // Synthetic WebKit pointer dispatch is not proof that the
                    // intended visual target accepted the action. Capture the
                    // viewport again and require an observable state change.
                    try? await Task.sleep(for: .milliseconds(250))
                    let postArtifact = try await saveSnapshot(of: tab.webView)
                    let postVisualTextRegions = try recognizeVisualText(in: postArtifact)
                    var result = await observeResult(command, tabID: tabID, cursor: nil)
                    result.page?.screenshotArtifact = postArtifact
                    result.page?.visualTextRegions = postVisualTextRegions
                    let changed = result.page.map {
                        $0.documentID != evidence.documentID
                            || $0.revision > evidence.revision
                            || postArtifact.sha256.lowercased() != evidence.sha256
                    } ?? false
                    if let page = result.page,
                       let currentIndex = tabs.firstIndex(where: { $0.id == tabID }) {
                        tabs[currentIndex].visualFallbackEvidence = VisualFallbackEvidence(
                            documentID: page.documentID,
                            sha256: postArtifact.sha256.lowercased(),
                            capturedAt: Date(),
                            pixelWidth: postArtifact.pixelWidth,
                            pixelHeight: postArtifact.pixelHeight,
                            viewportWidth: page.viewportWidth,
                            viewportHeight: page.viewportHeight,
                            revision: page.revision,
                            visualTextRegions: postVisualTextRegions
                        )
                    }
                    if changed {
                        result.message = "Visual click produced an observable page change; the returned screenshot is post-click evidence."
                    } else {
                        let message = "Visual click produced no observable page change; the target was not confirmed. Use the returned post-click screenshot to choose a different point or hand control to the user."
                        result.status = .failed
                        result.message = message
                        result.error = BrowserFailure(code: "no-observable-effect", message: message)
                    }
                    return result
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
            host?.browserSessionRequestedUserControl(self, reason: message)
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
        case .visualText:
            throw BrowserPolicyError.blocked(
                "Visual text references must be resolved from fresh screenshot evidence"
            )
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

    private func validateVisualFallback(
        _ command: BrowserCommand,
        in tab: Tab
    ) throws -> VisualFallbackEvidence {
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
              evidence.pixelWidth > 0,
              evidence.pixelHeight > 0,
              evidence.viewportWidth > 0,
              evidence.viewportHeight > 0,
              Date().timeIntervalSince(evidence.capturedAt) <= 120 else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a fresh screenshot from the current page"
            )
        }
        return evidence
    }

    private func observeResult(_ command: BrowserCommand, tabID: UUID?, cursor: Int?) async -> BrowserResult {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(min(30_000, max(250, command.timeoutMilliseconds))))
        let trace = command.requestID.uuidString
        do {
            try Task.checkCancellation()
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=drainEvents.begin")
            await collectProbeEvents(tabID: tabID, deadline: deadline)
            try Task.checkCancellation()
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=drainEvents.end")
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=snapshot.begin")
            let start = max(0, cursor ?? 0)
            let pageSize = 40
            let probe = try await semanticSnapshot(
                in: tab.webView,
                documentID: tab.documentID,
                cursor: start,
                limit: pageSize,
                deadline: deadline
            )
            try Task.checkCancellation()
            guard !isReleased else { throw BrowserProbeError.released }
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=snapshot.end")
            if let index = tabs.firstIndex(where: { $0.id == tabID }) {
                tabs[index].revision = max(tabs[index].revision, probe.revision)
            }
            let snapshot = PageSnapshot(
                documentID: tab.documentID,
                revision: max(tab.revision, probe.revision),
                url: tab.webView.url?.absoluteString ?? "",
                title: tab.webView.title ?? "",
                isLoading: tab.webView.isLoading,
                viewportWidth: probe.viewportWidth,
                viewportHeight: probe.viewportHeight,
                scrollX: Double(tab.webView.scrollView.contentOffset.x),
                scrollY: Double(tab.webView.scrollView.contentOffset.y),
                tabs: tabSnapshots(),
                nodes: probe.nodes,
                nextCursor: probe.nextCursor,
                screenshotArtifact: nil
            )
            return BrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch BrowserProbeError.timedOut {
            FloeLogger(category: .tools).info("Browser observe request=\(trace) outcome=timeout")
            return failure(command, status: .timeout, code: "timeout", "Browser page observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        } catch {
            let native = error as NSError
            FloeLogger(category: .tools).info("Browser observe request=\(trace) errorDomain=\(native.domain) code=\(native.code)")
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func probeValue(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView,
        deadline: ContinuousClock.Instant
    ) async throws -> Any? {
        guard !isReleased else { throw BrowserProbeError.released }
        let id = UUID()
        let request = BrowserProbeRequest()
        pendingProbes[id] = request
        defer { pendingProbes.removeValue(forKey: id) }
        let data = try await request.run(deadline: deadline) { completion in
            webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil, in: self.contentWorld,
                completionHandler: completion
            )
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func semanticSnapshot(
        in webView: WKWebView,
        documentID: String,
        cursor: Int,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> ProbeSnapshot {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {
          revision:0,
          viewportWidth:Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight:Math.max(1, Number(window.innerHeight) || 1),
          nodes:[],
          nextCursor:null
        };
        return protocol.snapshot(documentID, cursor, limit);
        """
        let value = try await probeValue(
            script,
            arguments: ["documentID": documentID, "cursor": cursor, "limit": limit],
            in: webView,
            deadline: deadline
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            return ProbeSnapshot(
                revision: 0,
                viewportWidth: max(1, webView.bounds.width),
                viewportHeight: max(1, webView.bounds.height),
                nodes: [],
                nextCursor: nil
            )
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
            guard !isReleased else {
                return failure(command, status: .stale, code: "released", "This task's browser session was released")
            }
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

    private func collectProbeEvents(tabID: UUID, deadline: ContinuousClock.Instant? = nil) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        do {
            let value = try await probeValue(
                "return globalThis.__floeProtocol ? globalThis.__floeProtocol.drainEvents(documentID) : [];",
                arguments: ["documentID": tab.documentID],
                in: tab.webView,
                deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(15))
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
            let native = error as NSError
            FloeLogger(category: .tools).info("Browser probe phase=drainEvents.error errorDomain=\(native.domain) code=\(native.code)")
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
        if tabs[index].events.count > maximumEventsPerTab {
            tabs[index].events.removeFirst(tabs[index].events.count - maximumEventsPerTab)
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
          viewportWidth: Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight: Math.max(1, Number(window.innerHeight) || 1),
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
        let digest = FloeDigest.sha256Hex(data)
        return BrowserArtifactReference(
            id: id,
            relativePath: "BrowserArtifacts/\(name)",
            mimeType: "image/jpeg",
            byteCount: data.count,
            sha256: digest,
            pixelWidth: image.cgImage?.width ?? Int(image.size.width * image.scale),
            pixelHeight: image.cgImage?.height ?? Int(image.size.height * image.scale)
        )
    }

    private func recognizeVisualText(in artifact: BrowserArtifactReference) throws -> [VisualTextRegion] {
        let filename = (artifact.relativePath as NSString).lastPathComponent
        return try VisualTextRecognizer.recognize(
            imageData: Data(contentsOf: artifactDirectory.appendingPathComponent(filename)),
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight
        )
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

extension BrowserTaskSession: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard !isReleased, let url = navigationAction.request.url else {
            return .cancel
        }
        // WebKit uses its own blank document while `loadHTMLString` commits.
        // It is not a tool-addressable URL and must remain available for
        // local fixtures/previews; all external navigations still pass the
        // normal http/https/private-network policy below.
        if url.absoluteString == "about:blank" { return .allow }
        // The owner is this session's trusted task, never the visible task.
        guard (try? BrowserURLPolicy.validate(url.absoluteString, conversationID: conversationID)) != nil else {
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
        surfaceState = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        tabs[index].documentID = UUID().uuidString
        tabs[index].revision = 0
        tabs[index].visualFallbackEvidence = nil
        appendEvent(
            tabID: tabs[index].id,
            method: "Page.frameNavigated"
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
        if tabs[index].id == activeTabID { refreshVisibleAddress() }
        surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
        // Title/back-forward availability are WebKit getters, not @Published
        // fields; notify the visible projection explicitly.
        objectWillChange.send()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))")
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
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
        guard !isReleased,
              let id = createTab(),
              let created = tabs.first(where: { $0.id == id })?.webView else { return nil }
        if let url = navigationAction.request.url,
           (try? BrowserURLPolicy.validate(url.absoluteString, conversationID: conversationID)) != nil {
            created.load(URLRequest(url: url))
        }
        return created
    }
}

/// Registry of live task sessions. It never swaps one task's tabs into
/// another: entries are keyed by trusted conversation identity and released
/// only by their own task deletion or explicit release.
@MainActor
final class BrowserTaskSessionStore {
    private var sessions: [UUID: BrowserTaskSession] = [:]
    let maximumSessions: Int

    init(maximumSessions: Int) {
        self.maximumSessions = maximumSessions
    }

    var count: Int { sessions.count }

    func session(for conversationID: UUID) -> BrowserTaskSession? {
        sessions[conversationID]
    }

    func insert(_ session: BrowserTaskSession) throws {
        if let existing = sessions[session.conversationID] {
            guard existing === session else {
                throw FloeError.validationFailed("Another browser session already owns this task")
            }
            return
        }
        guard sessions.count < maximumSessions else {
            throw FloeError.validationFailed(
                "Too many task browsers are open; close a browser or delete a task you no longer use"
            )
        }
        sessions[session.conversationID] = session
    }

    @discardableResult
    func release(_ conversationID: UUID) -> BrowserTaskSession? {
        sessions.removeValue(forKey: conversationID)
    }

    /// Least-recently-used first, so a caller under capacity pressure can
    /// decide with explicit ownership guards. Never used to evict implicitly.
    func sessionsByLeastRecentActivity() -> [BrowserTaskSession] {
        sessions.values.sorted { $0.lastActivityAt < $1.lastActivityAt }
    }
}

private struct ProbeSnapshot: Decodable {
    var revision: Int
    var viewportWidth: Double
    var viewportHeight: Double
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
#endif
