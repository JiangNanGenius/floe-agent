// SPDX-License-Identifier: MPL-2.0

import AppKit
import Darwin
import FloeCore
import FloeMacToolbox
import FloeModels
import FloeTools
import Foundation

/// Hub for every task-owned Mac browser session and the compiled `browser.*`
/// tools that route to them. The hub is owned by
/// `MacBrowserWorkbenchController`, so the visible workbench browser and the
/// model tools share the exact same sessions: every session is keyed by the
/// trusted conversation identity (never by model input), the visible
/// `MacBrowserWorkbenchView` renders the active tab's WKWebView of the same
/// session a model run is driving, and no model action ever pulls a tab to
/// the front.
///
/// Per-run binding and teardown (HostAgentWorkspace owns the call sites):
/// - `makeToolBundle(conversationID:workspaceRoot:)` returns the
///   `[AnyAgentTool]` for one run binding, exactly like
///   `MacTaskVideoTools.make(service:conversationID:...)`;
/// - `finishRun(_:)` ends any lease a finished run still holds while keeping
///   the page, tabs and scroll positions for the user;
/// - `retireSession(for:)` releases the session on task deletion.
@MainActor
final class MacTaskBrowserTools: ObservableObject {
    /// Names of browser tools whose results carry verified image artifacts
    /// for the multimodal evidence chain. The workspace executor routes
    /// their summary caps through the vision-read envelope; keep in sync
    /// with the bundle below.
    nonisolated static let visionEvidenceToolNames: Set<String> = [MacBrowserScreenshotTool.name]

    /// URL-only page restore hooks backed by the workbench controller's
    /// `MacBrowserRestoreStore`; a record is only applied when the user
    /// materializes that task's browser and is dropped when the task goes
    /// away. Cookies/forms/POST data are never persisted.
    struct RestoreHooks {
        var record: (UUID) -> URL?
        var setRecord: (URL, UUID) -> Void
        var remove: (UUID) -> Void
    }

    private let store = MacTaskBrowserSessionStore()
    private let restore: RestoreHooks
    private var generations: [UUID: Int] = [:]
    /// Raises this task's browser in the Agent window and hands control to
    /// the user. Set by the workbench controller after its own initialization
    /// completes (a weak capture is not allowed in an escaping closure passed
    /// to a member initializer); never reads page data.
    var presentBrowser: (UUID) -> Void = { _ in }
    /// Per-owner download presentation state (active banner / saved row /
    /// error row in the workbench chrome). Weak: the controller owns this hub.
    weak var downloads: MacBrowserDownloadController?
    /// Remembered-site memory shared by every task session this hub creates.
    /// Injected by the owning workbench (construct-and-pass); nil keeps all
    /// sessions strictly ephemeral. Model tools can never set it. Setting it
    /// installs the jar-invalidation hook that detaches live tabs before a
    /// forgotten jar is wiped.
    var siteMemory: MacSiteMemoryRegistry? {
        didSet {
            siteMemory?.onJarsInvalidated = { [weak self] storeIDs in
                guard let self else { return }
                for session in self.store.sessionsByLeastRecentActivity() {
                    session.detachStores(storeIDs)
                }
            }
        }
    }

    init(restore: RestoreHooks) {
        self.restore = restore
    }

    var liveSessions: [MacTaskBrowserSession] {
        store.sessionsByLeastRecentActivity()
    }

    func session(for owner: UUID) -> MacTaskBrowserSession? {
        store.session(for: owner)
    }

    /// Materializes the session for a user-opened task browser and puts the
    /// last committed page back. Never called on startup by itself.
    @discardableResult
    func ensureSession(for owner: UUID) -> MacTaskBrowserSession {
        let session = makeSession(for: owner)
        if session.tabs.isEmpty {
            if let restored = restore.record(owner) { session.restorePage(restored) }
            else { session.createTab() }
        }
        return session
    }

    /// Session for model control; never restores a page by itself.
    private func modelSession(for owner: UUID) -> MacTaskBrowserSession {
        makeSession(for: owner)
    }

    private func makeSession(for owner: UUID) -> MacTaskBrowserSession {
        if let existing = store.session(for: owner) { return existing }
        let session = MacTaskBrowserSession(conversationID: owner, generation: generations[owner] ?? 0)
        session.siteMemory = siteMemory
        session.onFirstUserInput = { [weak self, weak session] reason in
            guard let self, let session, self.store.session(for: owner) === session else { return }
            self.presentBrowser(owner)
            session.beginUserTakeover(reason: reason)
        }
        session.onPageCommit = { [weak self, weak session] url in
            guard let self, let session, self.store.session(for: owner) === session else { return }
            guard let url else { self.restore.remove(owner); return }
            guard MacBrowserAddress.allows(url) else { return }
            self.restore.setRecord(url, owner)
        }
        if store.count >= store.maximumSessions,
           let oldest = store.sessionsByLeastRecentActivity().first(where: { !$0.hasModelControlHolder && !$0.isUserControlling }) {
            retireSession(for: oldest.conversationID, preservePage: true)
        }
        do {
            try store.insert(session)
        } catch {
            session.release()
        }
        objectWillChange.send()
        return session
    }

    // MARK: - Model control

    struct ModelControl {
        let session: MacTaskBrowserSession
        let lease: MacBrowserControlLease
        let acquiredNow: Bool
    }

    func beginModelControl(owner: UUID, runID: UUID) throws -> ModelControl {
        let session = modelSession(for: owner)
        switch try session.acquireModelControl(runID: runID) {
        case .acquired(let lease):
            return ModelControl(session: session, lease: lease, acquiredNow: true)
        case .heldByAnotherRun:
            throw MacBrowserControlError.heldByAnotherRun
        case .needsUser(let message):
            throw MacBrowserControlError.needsUser(message)
        }
    }

    func releaseModelControl(owner: UUID, runID: UUID, controlID: UUID) -> MacBrowserControlReleaseOutcome {
        guard let session = store.session(for: owner) else { return .alreadyReleased }
        return session.releaseModelControl(controlID: controlID, runID: runID)
    }

    func endModelControl(owner: UUID, runID: UUID) {
        store.session(for: owner)?.endModelControl(runID: runID)
    }

    func execute(_ command: MacBrowserCommand, in owner: UUID, control: MacBrowserControlLease?) async -> MacBrowserResult {
        guard let session = store.session(for: owner) else {
            return MacBrowserResult(
                requestID: command.requestID,
                status: .stale,
                message: "This task's browser session was released",
                error: MacBrowserFailure(code: "released", message: "This task's browser session was released")
            )
        }
        return await session.execute(command, control: control)
    }

    // MARK: - Run lifecycle

    /// Run terminal (completed, failed, cancelled or checkpointed): only the
    /// exact logical run loses the page; the user's tabs stay untouched.
    func finishRun(_ runID: UUID) {
        for session in store.sessionsByLeastRecentActivity() where session.currentModelRunID == runID {
            session.endModelControl(runID: runID)
        }
    }

    /// Task deletion / explicit owner discard: stops this task's WebViews,
    /// drops its restore record and cancels its transfers. No other task is
    /// touched.
    func retireSession(for owner: UUID, preservePage: Bool = false) {
        generations[owner, default: 0] += 1
        let session = store.release(owner)
        session?.release()
        if !preservePage { restore.remove(owner) }
        downloads?.discard(owner: owner)
        objectWillChange.send()
    }

    func retireAllSessions() {
        for session in store.sessionsByLeastRecentActivity() {
            retireSession(for: session.conversationID, preservePage: true)
        }
    }

    // MARK: - Tool bundle

    /// Per-run compiled tools bound to the durable conversation UUID that
    /// HostAgentWorkspace already chose for this binding. The workspace root
    /// authorizes `browser.download` destinations; every tool re-validates
    /// the runtime-issued ToolContext before touching the page.
    func makeToolBundle(conversationID: UUID, workspaceRoot: URL?) -> [AnyAgentTool] {
        [
            AnyAgentTool(MacBrowserTabsTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserTabTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserNavigateTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserObserveTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserScreenshotTool(environment: self, conversationID: conversationID,
                                                  workspaceRoot: workspaceRoot.map(MacAgentWorkspaceRoot.init))),
            AnyAgentTool(MacBrowserEventsTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserWaitTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserClickTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserClickVisualTextTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserClickPointTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserWorkspacePreviewTool(environment: self, conversationID: conversationID,
                                                        workspaceRoot: workspaceRoot.map(MacAgentWorkspaceRoot.init))),
            AnyAgentTool(MacBrowserExportFileTool(environment: self, conversationID: conversationID,
                                                  workspaceRoot: workspaceRoot.map(MacAgentWorkspaceRoot.init))),
            AnyAgentTool(MacBrowserTypeTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserScrollTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserDownloadTool(environment: self, conversationID: conversationID,
                                                workspaceRoot: workspaceRoot.map(MacAgentWorkspaceRoot.init))),
            AnyAgentTool(MacBrowserReleaseTool(environment: self, conversationID: conversationID)),
            AnyAgentTool(MacBrowserTakeoverTool(environment: self, conversationID: conversationID))
        ]
    }

    // MARK: - Tool environment

    /// Task ownership comes only from the runtime-issued ToolContext and must
    /// match the binding's durable UUID; a nil or foreign owner is rejected
    /// instead of falling back to whatever browser happens to be visible, and
    /// the temporary read-only ceiling stays unchanged.
    func owner(for context: ToolContext, binding: UUID) throws -> UUID {
        guard let owner = context.conversationID, owner == binding else {
            throw FloeError.validationFailed(
                "Browser tools require a task-owned run. Open a task and use its browser."
            )
        }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Temporary chat cannot open or control a durable browser session"
            )
        }
        return owner
    }

    /// The runtime-issued logical run: a delegated child acts for its
    /// original parent run; nested or foreign identities are refused.
    func logicalRun(for context: ToolContext, owner: UUID) throws -> UUID {
        guard let child = context.childExecution else { return context.runID }
        let identity = child.identity
        guard identity.depth == 1 else {
            throw FloeError.validationFailed(
                "A nested delegated child cannot use this task's browser control"
            )
        }
        guard identity.rootTaskID == owner else {
            throw FloeError.validationFailed(
                "The delegated child belongs to a different root task and cannot use this task's browser"
            )
        }
        return identity.parentRunID
    }

    /// One acquired holding period plus the exact session it covers. Every
    /// page read/action entry resolves this before touching the page; the
    /// lease is what later calls and `browser.release` present.
    func control(for context: ToolContext, binding: UUID) throws -> (owner: UUID, control: ModelControl) {
        let owner = try self.owner(for: context, binding: binding)
        try context.cancellation.throwIfCancelled()
        let runID = try logicalRun(for: context, owner: owner)
        do {
            let model = try beginModelControl(owner: owner, runID: runID)
            return (owner, model)
        } catch MacBrowserControlError.needsUser(let message) {
            // The user owns the page. Return an honest needsUser result with
            // no page, event or control token instead of reading anything,
            // and do not queue for a later attempt.
            throw MacBrowserControlError.needsUser(message)
        }
    }

    /// The lightweight marker attached to every control-acquiring result. It
    /// is only present while this exact holding period is still live, so a
    /// result produced after takeover/release carries no stale token.
    func controlMarker(for control: ModelControl) -> [String: String]? {
        guard control.session.isModelControlCurrent(control.lease) else { return nil }
        return ["id": control.lease.id.uuidString, "releaseTool": "browser.release"]
    }

    /// Honest needsUser tool result: no page, event or control token. The
    /// model can continue other work and must not retry in a loop.
    func needsUserOutput(_ message: String) -> ToolExecutionOutput {
        let result = MacBrowserResult(
            requestID: UUID(),
            status: .needsUser,
            message: message,
            error: MacBrowserFailure(code: "takeover", message: message)
        )
        let data = (try? JSONEncoder().encode(result)) ?? Data()
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            requiresUserAction: true,
            maximumSummaryCharacters: 16_384
        )
    }

    func clickVisual(
        context: ToolContext, binding: UUID, tabID: UUID?, documentID: String,
        target: MacTaskBrowserSession.VisualTarget, screenshotSHA256: String
    ) async throws -> ToolExecutionOutput {
        do {
            let (_, control) = try control(for: context, binding: binding)
            let changed = try await control.session.clickVisual(
                tabID: tabID, documentID: documentID, target: target, sha256: screenshotSHA256.lowercased(),
                control: control.lease, cancellation: context.cancellation
            )
            let summary = changed ? "Visual click verified by a page change."
                : "The visual input was sent. A page change could not be verified. Inspect the page before another action."
            return ToolExecutionOutput(summary: summary, fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)))
        } catch MacBrowserControlError.needsUser(let message) {
            return needsUserOutput(message)
        }
    }

    /// Shared execution path for the ordinary page commands.
    func run(
        context: ToolContext,
        binding: UUID,
        action: MacBrowserAction,
        tabID: UUID? = nil,
        documentID: String? = nil,
        timeoutMilliseconds: Int = 15_000
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner: UUID
        let control: ModelControl
        do {
            (owner, control) = try self.control(for: context, binding: binding)
        } catch MacBrowserControlError.needsUser(let message) {
            return needsUserOutput(message)
        }
        let command = MacBrowserCommand(
            sessionID: control.session.sessionID,
            tabID: tabID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: timeoutMilliseconds,
            action: action
        )
        // The owner and holding period are applied explicitly; visibility is
        // irrelevant and the command contents cannot choose a session.
        let result = await execute(command, in: owner, control: control.lease)
        try context.cancellation.throwIfCancelled()
        let encoded = try JSONEncoder().encode(result)
        var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        if let marker = controlMarker(for: control) { object["control"] = marker }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        guard result.status == .ok || result.status == .needsUser else {
            throw FloeError.validationFailed(result.message ?? "Browser action failed")
        }
        // The protocol bounds nodes, events and tabs well below this ceiling,
        // but the default summary budget would still cut the JSON mid-field.
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            requiresUserAction: result.status == .needsUser,
            maximumSummaryCharacters: 262_144
        )
    }
}

// MARK: - Tools

private struct MacBrowserTabsTool: AgentTool {
    struct Arguments: Decodable, Sendable {}

    static let name = "browser.tabs"
    static let toolDescription = "List tabs in this task's browser session with exact tab IDs and active state. Does not open, switch or close tabs."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {}

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context, binding: conversationID, action: .listTabs)
    }
}

private struct MacBrowserTabTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String
        var tabID: UUID?
    }

    static let name = "browser.tab"
    static let toolDescription = "Create, activate, or close a tab in this task's browser session. Create returns a new tab ID; use browser.navigate on that ID to open a URL. Activate/close require an exact tabID from browser.tabs. Does not manage other apps' tabs."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","activate","close"]},"tabID":{"type":"string","format":"uuid"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        switch args.action {
        case "create": break
        case "activate", "close":
            guard args.tabID != nil else {
                throw FloeError.validationFailed("\(args.action) requires an exact tabID from browser.tabs")
            }
        default:
            throw FloeError.validationFailed("action must be create, activate or close")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let action: MacBrowserAction
        switch args.action {
        case "create": action = .create
        case "activate": action = .activateTab(args.tabID!)
        case "close": action = .closeTab(args.tabID!)
        default: throw FloeError.validationFailed("action must be create, activate or close")
        }
        return try await environment.run(context: context, binding: conversationID, action: action)
    }
}

private struct MacBrowserNavigateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var url: String
        var tabID: UUID?
    }

    static let name = "browser.navigate"
    static let toolDescription = "Navigate this task's browser to an http or https URL without opening the user's panel. Use browser.takeover only for a required human interaction such as login or payment."
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","maxLength":8192},"tabID":{"type":"string","format":"uuid"}},"required":["url"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        guard MacBrowserAddress.url(from: args.url) != nil else {
            throw FloeError.validationFailed("url must be an http(s) URL without embedded credentials")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context, binding: conversationID,
                                  action: .navigate(url: args.url), tabID: args.tabID)
    }
}

private struct MacBrowserObserveTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var cursor: Int?
    }

    static let name = "browser.observe"
    static let toolDescription = "FIRST choice for reading a page: bounded semantic DOM with stable refs, text, state and bounds. Continue pagination with cursor before concluding information is absent. Navigation or scrolling invalidates refs; observe again after the page changes. No JavaScript is accepted."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"cursor":{"type":"integer","minimum":0}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        if let cursor = args.cursor, cursor < 0 {
            throw FloeError.validationFailed("cursor must be non-negative")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(context: context, binding: conversationID,
                                  action: .observe(cursor: args.cursor), tabID: args.tabID)
    }
}

private struct MacBrowserScreenshotTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
    }

    static let name = "browser.screenshot"
    static let toolDescription = "Capture this task's browser viewport as verified PNG visual evidence when browser.observe cannot read the content. Returns a quick OCR preview with screenshot-pixel bounds. Use image.ocr on the returned path for detailed text or for languages unavailable in fast mode. The viewport image stays in the task workspace. Verify page changes using browser.observe."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID
    let workspaceRoot: MacAgentWorkspaceRoot?

    func validate(_ args: Arguments) throws {}

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try environment.owner(for: context, binding: conversationID)
        let control: MacTaskBrowserTools.ModelControl
        do {
            (_, control) = try environment.control(for: context, binding: conversationID)
        } catch MacBrowserControlError.needsUser(let message) {
            return environment.needsUserOutput(message)
        }
        guard environment.session(for: owner) === control.session else {
            throw FloeError.validationFailed("The browser screenshot task changed while acquiring control")
        }
        // One exact viewport capture; the PNG bytes below feed both the
        // verifier and the bounded OCR — no second capture, no re-decode of
        // a different revision.
        let viewport = try await control.session.captureVisionViewport(tabID: args.tabID, control: control.lease)
        try context.cancellation.throwIfCancelled()
        // Bounded on-device OCR of the exact captured bytes: a text fallback
        // when DOM refs cannot describe the canvas/pixel state. Runs off the
        // MainActor through the shared bounded recognizer; the screenshot is
        // still attached when recognition is unavailable, busy or timed out.
        // The fast level keeps cold multilingual model loading out of the
        // screenshot path. Detailed recognition remains available in image.ocr.
        let bytes = viewport.bytes
        let capture = try await Task.detached(priority: .utility) {
            try MacWorkspaceImageEvidence.verifiedCapture(bytes, declaredMime: "image/png")
        }.value
        try control.session.assertModelControlCurrent(control.lease)
        let recognition = await BoundedVisualTextRecognizer.shared.recognize {
            try VisualTextRecognizer.recognize(
                imageData: capture.bytes,
                pixelWidth: capture.width,
                pixelHeight: capture.height,
                referencePrefix: "text",
                limit: 48,
                level: .fast
            )
        }
        try context.cancellation.throwIfCancelled()
        // The user may have taken the page back while OCR ran: never surface
        // an image, and (because publication happens after this check) never
        // leave an unused screenshot file behind.
        try control.session.assertModelControlCurrent(control.lease)
        guard let root = workspaceRoot else {
            throw FloeError.validationFailed("Browser screenshot requires this task's workspace")
        }
        let artifact = try MacWorkspaceImageEvidence.publish(
            root: root, context: context, capture: capture,
            basename: "Browser-" + UUID().uuidString)
        try control.session.rememberVisualEvidence(viewport, sha256: artifact.sha256,
            width: capture.width, height: capture.height, regions: recognition.elements, control: control.lease)
        var payload: [String: Any] = [
            "status": "ok",
            "path": artifact.relativePath,
            "mimeType": artifact.mimeType,
            "byteCount": artifact.byteCount,
            "sha256": artifact.sha256,
            "width": capture.width,
            "height": capture.height,
            "tabID": viewport.tabID.uuidString,
            "documentID": viewport.documentID,
            "visualEvidence": "attached",
            "ocrMode": "fast"
        ]
        switch recognition.status {
        case .available where !recognition.elements.isEmpty:
            let encoded = try JSONEncoder().encode(recognition.elements)
            payload["visualTextRegions"] = try JSONSerialization.jsonObject(with: encoded)
            payload["visualText"] = "When browser.observe cannot identify a canvas or SVG control, use browser.clickVisualText with a text-N reference and this screenshot's SHA-256. Capture again after any page change."
        case .available:
            payload["visualTextRegions"] = []
            payload["visualText"] = "No readable text found in the capture."
        default:
            payload["visualTextRegionsStatus"] = recognition.status.rawValue
            payload["visualText"] = "OCR \(recognition.status.rawValue); the PNG evidence is still attached."
        }
        if let marker = environment.controlMarker(for: control) { payload["control"] = marker }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            artifacts: [artifact],
            maximumSummaryCharacters: 16_384
        )
    }
}

private struct MacBrowserEventsTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var afterSequence: Int?
        var limit: Int?
    }

    static let name = "browser.events"
    static let toolDescription = "Read bounded CDP-style lifecycle and DOM events from this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"afterSequence":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":100}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        if let after = args.afterSequence, after < 0 {
            throw FloeError.validationFailed("afterSequence must be non-negative")
        }
        if let limit = args.limit, !(1...100).contains(limit) {
            throw FloeError.validationFailed("limit is out of bounds")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            context: context,
            binding: conversationID,
            action: .events(afterSequence: args.afterSequence, limit: args.limit ?? 50),
            tabID: args.tabID
        )
    }
}

private struct MacBrowserWaitTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var condition: String
        var value: String?
        var quietMilliseconds: Int?
        var timeoutMilliseconds: Int?
    }

    static let name = "browser.wait"
    static let toolDescription = "Wait for load, DOM readiness, selector, text, document change, or approximate idle in this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"condition":{"type":"string","enum":["load","dom","selector","text","documentChanged","idle"]},"value":{"type":"string","maxLength":512},"quietMilliseconds":{"type":"integer","minimum":100,"maximum":5000},"timeoutMilliseconds":{"type":"integer","minimum":250,"maximum":30000}},"required":["condition"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        switch args.condition {
        case "load", "dom", "documentChanged", "idle": break
        case "selector", "text":
            guard args.value?.isEmpty == false else {
                throw FloeError.validationFailed("\(args.condition) requires a value")
            }
        default:
            throw FloeError.validationFailed("condition must be load, dom, selector, text, documentChanged or idle")
        }
        if let quiet = args.quietMilliseconds, !(100...5_000).contains(quiet) {
            throw FloeError.validationFailed("quietMilliseconds is out of bounds")
        }
        if let timeout = args.timeoutMilliseconds, !(250...30_000).contains(timeout) {
            throw FloeError.validationFailed("timeoutMilliseconds is out of bounds")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let condition: MacBrowserWaitCondition
        switch args.condition {
        case "load": condition = .load
        case "dom": condition = .domContentLoaded
        case "selector": condition = .selector(args.value ?? "")
        case "text": condition = .text(args.value ?? "")
        case "documentChanged": condition = .documentChanged(from: args.value ?? "")
        case "idle": condition = .idle(milliseconds: args.quietMilliseconds ?? 500)
        default: throw FloeError.validationFailed("Unknown wait condition")
        }
        return try await environment.run(
            context: context,
            binding: conversationID,
            action: .wait(condition),
            tabID: args.tabID,
            timeoutMilliseconds: args.timeoutMilliseconds ?? 15_000
        )
    }
}

private struct MacBrowserClickTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var ref: String
        var documentID: String
    }

    static let name = "browser.click"
    static let toolDescription = "Click an element of this task's browser by the exact ref and documentID from browser.observe. Ordinary page interactions only; login, payment and other sensitive submissions require browser.takeover so the user performs them."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"ref":{"type":"string","maxLength":64},"documentID":{"type":"string","maxLength":64}},"required":["ref","documentID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else {
            throw FloeError.validationFailed("ref and documentID are required")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            context: context,
            binding: conversationID,
            action: .click(.element(ref: args.ref, documentID: args.documentID)),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

private struct MacBrowserTypeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var ref: String
        var documentID: String
        var text: String
        var submit: Bool?
    }

    static let name = "browser.type"
    static let toolDescription = "Type text into an element of this task's browser by the exact ref and documentID from browser.observe. Password and credential fields are refused and require browser.takeover so the user enters them. Use submit only for ordinary forms the task is authorized to send."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"ref":{"type":"string","maxLength":64},"documentID":{"type":"string","maxLength":64},"text":{"type":"string","maxLength":16384},"submit":{"type":"boolean"}},"required":["ref","documentID","text"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty, args.text.utf8.count <= 16 * 1024 else {
            throw FloeError.validationFailed("ref, documentID and bounded text are required")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            context: context,
            binding: conversationID,
            action: .type(.element(ref: args.ref, documentID: args.documentID),
                          text: args.text, submit: args.submit ?? false),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

private struct MacBrowserScrollTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var deltaX: Double?
        var deltaY: Double?
    }

    static let name = "browser.scroll"
    static let toolDescription = "Scroll this task's browser tab by a pixel delta. Observed refs stay valid; capture fresh evidence after scrolling before acting visually."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"deltaX":{"type":"number","minimum":-10000,"maximum":10000},"deltaY":{"type":"number","minimum":-10000,"maximum":10000}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        for value in [args.deltaX ?? 0, args.deltaY ?? 0] where !value.isFinite || abs(value) > 10_000 {
            throw FloeError.validationFailed("scroll delta is out of bounds")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            context: context,
            binding: conversationID,
            action: .scroll(deltaX: args.deltaX ?? 0, deltaY: args.deltaY ?? 0),
            tabID: args.tabID
        )
    }
}

private struct MacBrowserClickVisualTextTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let reference: String
        let screenshotSHA256: String
    }

    static let name = "browser.clickVisualText"
    static let toolDescription = "Click an OCR text reference on a canvas or SVG when browser.observe cannot identify that control. Use the latest browser.screenshot from the same document."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$","maxLength":12},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["documentID","reference","screenshotSHA256"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.documentID) != nil, args.reference.utf8.count <= 12,
              args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              StagedExportValidation.isSHA256Hex(args.screenshotSHA256.lowercased()) else {
            throw FloeError.validationFailed("Use the document ID, text reference and SHA-256 from browser.screenshot")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.clickVisual(context: context, binding: conversationID,
            tabID: args.tabID, documentID: args.documentID, target: .text(args.reference),
            screenshotSHA256: args.screenshotSHA256)
    }
}

private struct MacBrowserClickPointTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let x, y: Double
        let screenshotSHA256: String
        let fallbackReason: String
    }

    static let name = "browser.clickPoint"
    static let toolDescription = "Click a screenshot pixel on a canvas or SVG only when browser.observe and text references are insufficient. Ordinary controls use browser.click. Each attempt consumes the screenshot."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"x":{"type":"number","minimum":0,"maximum":4095},"y":{"type":"number","minimum":0,"maximum":4095},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"fallbackReason":{"type":"string","enum":["noStructuredTarget","insufficientStructuredInformation"]}},"required":["documentID","x","y","screenshotSHA256","fallbackReason"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.documentID) != nil, (0..<4096).contains(args.x), (0..<4096).contains(args.y),
              StagedExportValidation.isSHA256Hex(args.screenshotSHA256.lowercased()),
              ["noStructuredTarget", "insufficientStructuredInformation"].contains(args.fallbackReason) else {
            throw FloeError.validationFailed("Use a bounded point, document ID, SHA-256 and fallback reason from the current screenshot")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.clickVisual(context: context, binding: conversationID, tabID: args.tabID,
            documentID: args.documentID, target: .point(x: args.x, y: args.y), screenshotSHA256: args.screenshotSHA256)
    }
}

private struct MacBrowserWorkspacePreviewTool: AgentTool {
    struct Arguments: Decodable, Sendable { let path: String }

    static let name = "browser.previewWorkspace"
    static let toolDescription = "Open an HTML file from the current workspace in a task-owned browser tab. This local preview can use files beside the HTML and supports browser.exportFile for a staged PNG. Wait for the tab to load before observing or acting."
    static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","maxLength":1024,"description":"Workspace-relative .html or .htm file"}},"required":["path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID
    let workspaceRoot: MacAgentWorkspaceRoot?

    func validate(_ args: Arguments) throws {
        guard args.path.utf8.count <= 1024, !args.path.hasPrefix("/"), !args.path.hasPrefix("~"),
              ["html", "htm"].contains((args.path as NSString).pathExtension.lowercased()) else {
            throw FloeError.validationFailed("A workspace-relative HTML file is required")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = workspaceRoot else { throw FloeError.validationFailed("This task has no workspace") }
        let (physicalRoot, path) = try macWorkspacePinSetup(root: root, path: args.path)
        try context.authorizeWorkspacePath(path)
        do {
            let (_, control) = try environment.control(for: context, binding: conversationID)
            let tab = try await control.session.openWorkspacePreview(root: physicalRoot, path: path, context: context,
                                                                     control: control.lease)
            let summary = "Opened the workspace HTML in tab \(tab.uuidString). Use browser.wait for this tab."
            return ToolExecutionOutput(summary: summary, fullOutputSHA256: FloeDigest.sha256Hex(Data(summary.utf8)))
        } catch MacBrowserControlError.needsUser(let message) {
            return environment.needsUserOutput(message)
        }
    }
}

private struct MacBrowserExportFileTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let path: String
        let expectedWidth, expectedHeight: Int?
    }

    static let name = "browser.exportFile"
    static let toolDescription = "Save the original staged PNG from browser.previewWorkspace into a new workspace file. Stage the image using the page's export control first. The saved file is verified by size, dimensions and SHA-256."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"path":{"type":"string","maxLength":1024},"expectedWidth":{"type":"integer","minimum":1,"maximum":16384},"expectedHeight":{"type":"integer","minimum":1,"maximum":16384}},"required":["path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID
    let workspaceRoot: MacAgentWorkspaceRoot?

    func validate(_ args: Arguments) throws {
        let issues = StagedExportValidation.destinationRejections(args.path)
        guard issues.isEmpty else { throw FloeError.validationFailed(issues.joined(separator: ". ")) }
        for dimension in [args.expectedWidth, args.expectedHeight].compactMap({ $0 }) {
            guard (1...StagedExportContract.maxDimension).contains(dimension) else {
                throw FloeError.validationFailed("Expected image dimensions are out of range")
            }
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = workspaceRoot else { throw FloeError.validationFailed("This task has no workspace") }
        let (physicalRoot, path) = try macWorkspacePinSetup(root: root, path: args.path)
        try context.authorizeWorkspacePath(path)
        do {
            let (_, control) = try environment.control(for: context, binding: conversationID)
            let receipt = try await control.session.exportWorkspacePNG(tabID: args.tabID, root: root,
                physicalRoot: physicalRoot, path: path, expectedWidth: args.expectedWidth,
                expectedHeight: args.expectedHeight, context: context, control: control.lease)
            let source = URL(fileURLWithPath: physicalRoot, isDirectory: true).appendingPathComponent(path)
            let output = try? RunOutputSnapshotStore.publish(.init(producerTool: Self.name, slot: "image",
                commit: .init(sourceURL: source, sha256: receipt.sha256, byteCount: receipt.bytes,
                              displayName: source.lastPathComponent, mimeType: "image/png")), using: context)
            let data = try receipt.encodedJSON()
            return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self),
                fullOutputSHA256: FloeDigest.sha256Hex(data), outputFiles: output.map { [$0] } ?? [])
        } catch MacBrowserControlError.needsUser(let message) {
            return environment.needsUserOutput(message)
        }
    }
}

private struct MacBrowserDownloadTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var tabID: UUID?
        var url: String
        var path: String
        var maxBytes: Int?
        var overwrite: Bool?
    }

    static let name = "browser.download"
    static let toolDescription = "Download a PDF or image from this task's browser into this task's workspace using the page's existing login without exposing cookies. Use a workspace-relative file path whose parent folder already exists. Existing files are preserved unless overwrite is explicitly true. Reference the returned workspace-relative path."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string","format":"uuid"},"url":{"type":"string","maxLength":8192},"path":{"type":"string","maxLength":1024},"maxBytes":{"type":"integer","minimum":1,"maximum":67108864},"overwrite":{"type":"boolean"}},"required":["url","path"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID
    let workspaceRoot: MacAgentWorkspaceRoot?

    func validate(_ args: Arguments) throws {
        guard MacBrowserAddress.url(from: args.url) != nil else {
            throw FloeError.validationFailed("url must be an http(s) URL without embedded credentials")
        }
        let path = args.path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("path must be a workspace-relative file path")
        }
        if let maxBytes = args.maxBytes, !(1...64 * 1_024 * 1_024).contains(maxBytes) {
            throw FloeError.validationFailed("maxBytes is out of bounds")
        }
    }

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try environment.owner(for: context, binding: conversationID)
        let url = try Self.allowedURL(args.url)
        guard let root = workspaceRoot else {
            throw FloeError.validationFailed("Browser download requires this task's workspace")
        }
        let (physicalRoot, path) = try macWorkspacePinSetup(root: root, path: args.path)
        guard path != "." else { throw MacAgentWorkspaceToolsError.isDirectory(args.path) }
        try context.authorizeWorkspacePath(path)
        let destination = URL(fileURLWithPath: physicalRoot, isDirectory: true).appendingPathComponent(path)
        let overwrite = args.overwrite == true
        try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physicalRoot, relative: path, root: root) { pin in
            try Self.validateDownloadTarget(pin, path: path, overwrite: overwrite)
        }
        let cap = max(1, min(args.maxBytes ?? 32 * 1_024 * 1_024, 64 * 1_024 * 1_024))

        let control: MacTaskBrowserTools.ModelControl
        do {
            (_, control) = try environment.control(for: context, binding: conversationID)
        } catch MacBrowserControlError.needsUser(let message) {
            return environment.needsUserOutput(message)
        }
        guard environment.session(for: owner) === control.session else {
            throw FloeError.validationFailed("The browser download task changed while acquiring control")
        }
        let session = control.session
        let lease = control.lease
        let cancellation = context.cancellation
        let receipt = try await session.startDownload(
            tabID: args.tabID,
            url: url,
            destinationURL: destination,
            relativePath: path,
            maxBytes: cap,
            overwrite: overwrite,
            cancellation: cancellation
        ) { [weak session] staged in
            guard let session else { throw MacTaskBrowserError.validation("The task browser was closed") }
            try session.assertModelControlCurrent(lease)
            return try Self.commitDownload(staged, root: root, physicalRoot: physicalRoot,
                                           path: path, overwrite: overwrite, cap: cap, cancellation: cancellation)
        }
        let outputFiles = (try? Self.publishDownload(receipt, using: context)) ?? []
        var payload: [String: Any] = [
            "status": "ok",
            "saved": true,
            "preview": outputFiles.isEmpty ? "unavailable" : "ready",
            "path": receipt.relativePath,
            "mimeType": receipt.mimeType,
            "byteCount": receipt.byteCount,
            "sha256": receipt.sha256,
            "filename": receipt.suggestedFilename,
            "sourceHost": receipt.finalHost ?? ""
        ]
        if let marker = environment.controlMarker(for: control) { payload["control"] = marker }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            outputFiles: outputFiles,
            maximumSummaryCharacters: 16_384
        )
    }

    private static func validateDownloadTarget(
        _ pin: MacAgentWorkspacePinSupport.Pin, path: String, overwrite: Bool
    ) throws {
        let leaf = MacAgentWorkspacePinSupport.leafStatus(pin)
        if leaf.missing { return }
        guard leaf.exists, !leaf.symlink, leaf.info.st_mode & S_IFMT == S_IFREG,
              leaf.info.st_nlink == 1, leaf.info.st_mode & (S_ISUID | S_ISGID) == 0 else {
            throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(path)
        }
        guard overwrite else { throw MacAgentWorkspaceToolsError.targetAlreadyExists(path) }
    }

    private static func commitDownload(
        _ staged: URL, root: MacAgentWorkspaceRoot, physicalRoot: String, path: String,
        overwrite: Bool, cap: Int, cancellation: CancellationToken
    ) throws -> (byteCount: Int, sha256: String) {
        let input = try FileHandle(forReadingFrom: staged)
        defer { try? input.close() }
        let bytes = try input.read(upToCount: cap + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= cap else { throw MacAgentWorkspaceToolsError.tooLarge(limit: cap) }
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physicalRoot, relative: path, root: root) { pin in
            try validateDownloadTarget(pin, path: path, overwrite: overwrite)
            let leaf = MacAgentWorkspacePinSupport.leafStatus(pin)
            let receipt: MacAgentWorkspaceTextMutation.Receipt
            if leaf.missing {
                receipt = try MacAgentWorkspaceTextMutation.publishNewFile(
                    pin: pin, data: bytes, displayPath: path, cancellation: cancellation)
            } else {
                let fd = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physicalRoot, displayPath: path)
                defer { Darwin.close(fd) }
                let original = try MacAgentWorkspaceTextMutation.readBytes(fd, limit: cap)
                receipt = try MacAgentWorkspaceTextMutation.publishStagedReplacement(
                    pin: pin, originalFD: fd, originalIdentity: leaf.info, originalBytes: original,
                    updated: bytes, relative: path, limit: cap, cancellation: cancellation)
            }
            return (receipt.byteCount, receipt.sha256)
        }
    }

    private static func allowedURL(_ raw: String) throws -> URL {
        guard let url = MacBrowserAddress.url(from: raw) else {
            throw FloeError.validationFailed("url must be an http(s) URL without embedded credentials")
        }
        return url
    }

    private static func publishDownload(
        _ receipt: BrowserDownloadReceipt,
        using context: ToolContext
    ) throws -> [RunOutputFile] {
        guard !context.temporaryReadOnly,
              let callID = context.toolCallID, !callID.isEmpty,
              context.conversationID != nil else {
            return []
        }
        do {
            let output = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: "browser.download",
                    slot: "download",
                    commit: RunOutputCommit(
                        sourceURL: receipt.destinationURL,
                        sha256: receipt.sha256,
                        byteCount: receipt.byteCount,
                        displayName: receipt.destinationURL.lastPathComponent,
                        mimeType: normalizedContentType(receipt.mimeType)
                    )
                ),
                using: context
            )
            return [output]
        } catch let error as RunOutputSnapshotError {
            throw FloeError.validationFailed("browser download output publication failed: \(error.localizedDescription)")
        }
    }

    private static func normalizedContentType(_ raw: String) -> String {
        let base = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !base.isEmpty, base.utf8.count <= 128, base.contains("/"),
              !base.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return "application/octet-stream"
        }
        return base
    }
}

/// Explicit end of one model holding period. It releases only the caller's
/// own lease: the page, tabs and scroll position stay exactly where they
/// are, and the tool can never acquire page access. Repeating an
/// already-consumed token is a no-op, so a stale release can never unlock
/// the run's newer holding period.
private struct MacBrowserReleaseTool: AgentTool {
    struct Arguments: Decodable, Sendable { let controlID: UUID }

    static let name = "browser.release"
    static let toolDescription = "Release this run's control of this task's browser when you have finished browsing. Pass the control.id from your latest browser tool result. The page and tabs stay open for the user; another run may then take control. Repeating an old release has no effect. This tool never grants page access and requires no confirmation."
    static let parametersJSON = #"{"type":"object","properties":{"controlID":{"type":"string","format":"uuid"}},"required":["controlID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {}

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try environment.owner(for: context, binding: conversationID)
        let runID = try environment.logicalRun(for: context, owner: owner)
        // Never create a browser just to release one.
        guard let session = environment.session(for: owner), !session.isReleased else {
            return ToolExecutionOutput(digesting: "No task browser is open; nothing was released")
        }
        if session.isUserControlling {
            return ToolExecutionOutput(digesting: "The user controls this browser; nothing was released")
        }
        switch environment.releaseModelControl(owner: owner, runID: runID, controlID: args.controlID) {
        case .released:
            return ToolExecutionOutput(digesting: "Browser control released; the page stays open for the user")
        case .alreadyReleased:
            return ToolExecutionOutput(digesting: "That browser control was already released; nothing changed")
        case .heldByAnotherRun:
            throw FloeError.validationFailed(
                "This browser is controlled by another run; nothing was released"
            )
        }
    }
}

/// Hands this task's browser to the user. The workbench browser surface
/// opens for this task (never pulling unrelated windows forward), the model
/// lease is revoked synchronously, and browser mutations return needsUser
/// until the user returns control from the browser chrome. Use only for
/// interactions a human must perform: login, payment, verification or an
/// explicit user-input request.
private struct MacBrowserTakeoverTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var reason: String?
    }

    static let name = "browser.takeover"
    static let toolDescription = "Hand this task's browser to the user. The task's browser panel opens, the model loses browser control, and browser tools return needsUser until the user returns control. Use only for a required human interaction (login, payment, verification, file selection or explicit user input); never for ordinary navigation or reading. The task may continue other work meanwhile."
    static let parametersJSON = #"{"type":"object","properties":{"reason":{"type":"string","maxLength":500}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: MacTaskBrowserTools
    let conversationID: UUID

    func validate(_ args: Arguments) throws {}

    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let output = try await environment.run(
            context: context,
            binding: conversationID,
            action: .takeover
        )
        // The takeover action itself always answers needsUser; that result is
        // the tool's success signal (requiresUserAction is set by the run
        // helper only for acquisition refusals, so mark it here).
        return ToolExecutionOutput(
            summary: output.summary,
            fullOutputSHA256: output.fullOutputSHA256,
            requiresUserAction: true,
            maximumSummaryCharacters: 262_144
        )
    }
}
