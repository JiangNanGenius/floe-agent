// FloeAndroid shared/Sources/FloeBrowser — the frozen browser/preview tool
// surface routed to the calling task's own session.
//
// Android mirror of the iOS `BrowserToolEnvironment` + the 13 `browser.*`
// tools (BrowserTools.swift @ 3fd597b…, sha256 a832ea4c…) and the 3
// `preview.*` tools (LocalPreviewServer.swift, sha256 8bec3f01…). Owner
// resolution, ceilings, handoff-run attribution, validation bounds and the
// result envelope are preserved rule-for-rule. Main registers thin AgentTool
// adapters that call `BrowserToolSurface.invoke`; the tool catalog, risk
// labels and routing stay in the existing FloeAgentRuntime/ToolDiscovery
// composition (no parallel task/policy DB here).
//
// The tool JSON never carries a task identity: `caller` is assembled by the
// trusted runtime from the actual ToolContext before this surface is entered.

import Foundation
import FloeCore
import FloeModels
import FloeTools

/// Trusted facts of the calling run, mirrored from ToolContext fields the
/// Android FloeTools overlay already compiles.
public struct BrowserToolCaller: Sendable, Codable, Hashable {
    public struct Child: Sendable, Codable, Hashable {
        public var rootTaskID: UUID
        public var parentRunID: UUID
        public var depth: Int
        public init(rootTaskID: UUID, parentRunID: UUID, depth: Int) {
            self.rootTaskID = rootTaskID
            self.parentRunID = parentRunID
            self.depth = depth
        }
    }
    public var conversationID: UUID?
    public var runID: UUID?
    public var temporaryReadOnly: Bool
    public var publicWebOnly: Bool
    public var childExecution: Child?
    /// Exact native ownership triple resolved by the runtime for this call.
    public var owner: BrowserOwnerID?

    public init(
        conversationID: UUID?,
        runID: UUID? = nil,
        temporaryReadOnly: Bool = false,
        publicWebOnly: Bool = false,
        childExecution: Child? = nil,
        owner: BrowserOwnerID? = nil
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.temporaryReadOnly = temporaryReadOnly
        self.publicWebOnly = publicWebOnly
        self.childExecution = childExecution
        self.owner = owner
    }
}

/// Typed argument union for the frozen family. JSON decoding (model-facing)
/// happens in Main's tool adapters; this surface only receives already
/// validated typed payloads. The bounds below still re-enforce every limit so
/// a buggy adapter cannot pass an unbounded value through.
public enum BrowserToolArguments: Sendable, Codable, Hashable {
    case panel(action: String, reason: String?, tabID: UUID?)
    case tabs
    case tab(action: String, tabID: UUID?)
    case events(tabID: UUID?, afterSequence: Int?, limit: Int?)
    case wait(tabID: UUID?, condition: String, value: String?, quietMilliseconds: Int?, timeoutMilliseconds: Int?)
    case navigate(url: String, tabID: UUID?)
    case observe(tabID: UUID?, cursor: Int?)
    case screenshot(tabID: UUID?)
    case clickVisualText(tabID: UUID?, documentID: String, reference: String, screenshotSHA256: String)
    case click(tabID: UUID?, ref: String, documentID: String)
    case clickPoint(tabID: UUID?, documentID: String, x: Double, y: Double, screenshotSHA256: String, fallbackReason: String)
    case type(tabID: UUID?, ref: String, documentID: String, text: String, submit: Bool?)
    case scroll(tabID: UUID?, deltaX: Double?, deltaY: Double)
    case previewStart(root: String?, entry: String?)
    case previewReload
    case previewStop
}

public enum BrowserToolError: Error, LocalizedError, Sendable, Equatable {
    case validation(String)
    case notFound(String)
    case configuration(String)

    public var errorDescription: String? {
        switch self {
        case .validation(let message): return message
        case .notFound(let message): return message
        case .configuration(let message): return message
        }
    }
}

public actor BrowserToolSurface {
    public static let frozenToolNames: [String] = [
        "browser.panel", "browser.tabs", "browser.tab", "browser.events", "browser.wait",
        "browser.navigate", "browser.observe", "browser.screenshot", "browser.clickVisualText",
        "browser.click", "browser.clickPoint", "browser.type", "browser.scroll",
        "preview.start", "preview.reload", "preview.stop",
    ]

    public static let summaryCeilingCharacters = 262_144

    private let center: BrowserSessionCenter
    private let preview: LocalPreviewCoordinator?
    private let policy: BrowserURLPolicy

    public init(center: BrowserSessionCenter, policy: BrowserURLPolicy, preview: LocalPreviewCoordinator? = nil) {
        self.center = center
        self.preview = preview
        self.policy = policy
    }

    // MARK: - Owner resolution (original BrowserToolEnvironment semantics)

    /// Task ownership comes only from the runtime-issued facts. A nil owner is
    /// rejected instead of falling back to whatever browser happens to be
    /// visible, and the temporary chat ceiling stays unchanged.
    public static func resolveOwner(for caller: BrowserToolCaller) throws -> BrowserOwnerID {
        guard let conversationID = caller.conversationID else {
            throw BrowserToolError.validation(
                "Browser tools require a task-owned run. Open a task and use its browser."
            )
        }
        guard !caller.temporaryReadOnly, !caller.publicWebOnly else {
            throw BrowserToolError.validation(
                "Temporary chat cannot open or control a durable browser session"
            )
        }
        guard let owner = caller.owner, owner.taskID == conversationID else {
            throw BrowserToolError.validation(
                "The runtime did not resolve an exact workspace ownership binding for this task"
            )
        }
        return owner
    }

    /// Resolves the exact run that owns a durable browser handoff for this
    /// call. Main-run calls use their actual `runID`. A delegated child uses
    /// the runtime-issued identity: the original parent run that delegated
    /// it, validated against the actual conversation (`rootTaskID`) and
    /// against canonical depth (nested delegation is never minted and is
    /// refused). The newest run of a conversation is never chosen as a
    /// substitute for a known original.
    static func handoffRun(for caller: BrowserToolCaller, owner: UUID) throws -> UUID? {
        guard let child = caller.childExecution else { return caller.runID }
        guard child.depth == 1 else {
            throw BrowserToolError.validation(
                "A nested delegated child cannot request a browser handoff"
            )
        }
        guard child.rootTaskID == owner else {
            throw BrowserToolError.validation(
                "The delegated child belongs to a different root task and cannot use this task's browser"
            )
        }
        return child.parentRunID
    }

    // MARK: - Dispatch

    public func invoke(
        name: String,
        caller: BrowserToolCaller,
        arguments: BrowserToolArguments,
        cancellation: CancellationToken? = nil
    ) async throws -> ToolExecutionOutput {
        try cancellation?.throwIfCancelled()
        guard Self.frozenToolNames.contains(name) else {
            throw BrowserToolError.validation("Unknown browser tool '\(name)'")
        }
        let owner = try Self.resolveOwner(for: caller)
        switch (name, arguments) {
        case ("browser.panel", .panel(let action, let reason, let tabID)):
            return try await panel(owner: owner, caller: caller, action: action, reason: reason, tabID: tabID, cancellation: cancellation)
        case ("browser.tabs", .tabs):
            return try await run(owner: owner, action: .listTabs, cancellation: cancellation)
        case ("browser.tab", .tab(let action, let tabID)):
            let command: BrowserAction
            switch action {
            case "create": guard tabID == nil else { throw BrowserToolError.validation("Create must omit tabID; activate/close require tabID"); }; command = .create
            case "activate": guard let tabID else { throw BrowserToolError.validation("Create must omit tabID; activate/close require tabID"); }; command = .activateTab(tabID)
            case "close": guard let tabID else { throw BrowserToolError.validation("Create must omit tabID; activate/close require tabID"); }; command = .closeTab(tabID)
            default: throw BrowserToolError.validation("Unknown tab action")
            }
            return try await run(owner: owner, action: command, cancellation: cancellation)
        case ("browser.events", .events(let tabID, let afterSequence, let limit)):
            if let sequence = afterSequence, sequence < 0 {
                throw BrowserToolError.validation("afterSequence must be non-negative")
            }
            if let limit, !(1...50).contains(limit) {
                throw BrowserToolError.validation("limit must be between 1 and 50")
            }
            return try await run(
                owner: owner,
                action: .events(afterSequence: afterSequence, limit: limit ?? 20),
                tabID: tabID,
                cancellation: cancellation
            )
        case ("browser.wait", .wait(let tabID, let condition, let value, let quiet, let timeout)):
            guard ["load", "dom", "selector", "text", "documentChanged", "idle"].contains(condition) else {
                throw BrowserToolError.validation("Unknown browser wait condition")
            }
            if ["selector", "text", "documentChanged"].contains(condition), value?.isEmpty != false {
                throw BrowserToolError.validation("This wait condition requires value")
            }
            if let value, value.utf8.count > 512 {
                throw BrowserToolError.validation("Browser wait value exceeds 512 bytes")
            }
            if let quiet, !(100...5_000).contains(quiet) {
                throw BrowserToolError.validation("quietMilliseconds must be between 100 and 5000")
            }
            if let timeout, !(250...30_000).contains(timeout) {
                throw BrowserToolError.validation("timeoutMilliseconds must be between 250 and 30000")
            }
            let wait: BrowserWaitCondition
            switch condition {
            case "load": wait = .load
            case "dom": wait = .domContentLoaded
            case "selector": wait = .selector(value ?? "")
            case "text": wait = .text(value ?? "")
            case "documentChanged": wait = .documentChanged(from: value ?? "")
            default: wait = .idle(milliseconds: quiet ?? 500)
            }
            return try await run(
                owner: owner,
                action: .wait(wait),
                tabID: tabID,
                timeoutMilliseconds: timeout ?? 15_000,
                cancellation: cancellation
            )
        case ("browser.navigate", .navigate(let url, let tabID)):
            // Validation happens BEFORE any session work, in the tool error
            // envelope (the original BrowserNavigateTool.validate semantics).
            do {
                _ = try policy.validate(url, allowRegisteredServices: true)
            } catch let error as BrowserPolicyError {
                throw BrowserToolError.validation(error.errorDescription ?? "Only http and https URLs are allowed")
            }
            return try await run(owner: owner, action: .navigate(url: url), tabID: tabID, cancellation: cancellation)
        case ("browser.observe", .observe(let tabID, let cursor)):
            if let cursor, cursor < 0 {
                throw BrowserToolError.validation("cursor must be non-negative")
            }
            return try await run(owner: owner, action: .observe(cursor: cursor), tabID: tabID, cancellation: cancellation)
        case ("browser.screenshot", .screenshot(let tabID)):
            return try await run(owner: owner, action: .screenshot, tabID: tabID, cancellation: cancellation)
        case ("browser.clickVisualText", .clickVisualText(let tabID, let documentID, let reference, let screenshotSHA256)):
            guard !documentID.isEmpty,
                  reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
                  screenshotSHA256.count == 64,
                  screenshotSHA256.allSatisfy(\.isHexDigit) else {
                throw BrowserToolError.validation(
                    "documentID, a text-N reference, and its fresh screenshot sha256 are required"
                )
            }
            return try await run(
                owner: owner,
                action: .click(.visualText(reference: reference)),
                tabID: tabID,
                documentID: documentID,
                visualEvidenceSHA256: screenshotSHA256,
                visualFallbackReason: "insufficientStructuredInformation",
                cancellation: cancellation
            )
        case ("browser.click", .click(let tabID, let ref, let documentID)):
            guard !ref.isEmpty, !documentID.isEmpty else {
                throw BrowserToolError.validation("ref and documentID are required")
            }
            return try await run(
                owner: owner,
                action: .click(.element(ref: ref, documentID: documentID)),
                tabID: tabID,
                documentID: documentID,
                cancellation: cancellation
            )
        case ("browser.clickPoint", .clickPoint(let tabID, let documentID, let x, let y, let screenshotSHA256, let fallbackReason)):
            guard !documentID.isEmpty, x.isFinite, y.isFinite,
                  (0...10_000).contains(x), (0...10_000).contains(y) else {
                throw BrowserToolError.validation("documentID and bounded screenshot pixel coordinates are required")
            }
            guard screenshotSHA256.count == 64, screenshotSHA256.allSatisfy(\.isHexDigit) else {
                throw BrowserToolError.validation("a fresh browser screenshot sha256 is required")
            }
            guard ["noStructuredTarget", "insufficientStructuredInformation"].contains(fallbackReason) else {
                throw BrowserToolError.validation("fallbackReason must explain why structured access is insufficient")
            }
            return try await run(
                owner: owner,
                action: .click(.point(x: x, y: y)),
                tabID: tabID,
                documentID: documentID,
                visualEvidenceSHA256: screenshotSHA256,
                visualFallbackReason: fallbackReason,
                cancellation: cancellation
            )
        case ("browser.type", .type(let tabID, let ref, let documentID, let text, let submit)):
            guard !ref.isEmpty, !documentID.isEmpty else {
                throw BrowserToolError.validation("ref and documentID are required")
            }
            guard text.utf8.count <= 16 * 1024 else {
                throw BrowserToolError.validation("text exceeds 16 KiB")
            }
            return try await run(
                owner: owner,
                action: .type(.element(ref: ref, documentID: documentID), text: text, submit: submit ?? false),
                tabID: tabID,
                documentID: documentID,
                cancellation: cancellation
            )
        case ("browser.scroll", .scroll(let tabID, let deltaX, let deltaY)):
            guard deltaY.isFinite, deltaX?.isFinite != false,
                  abs(deltaY) <= 20_000, abs(deltaX ?? 0) <= 20_000 else {
                throw BrowserToolError.validation("scroll delta is invalid")
            }
            return try await run(
                owner: owner,
                action: .scroll(deltaX: deltaX ?? 0, deltaY: deltaY),
                tabID: tabID,
                cancellation: cancellation
            )
        case ("preview.start", .previewStart(let root, let entry)):
            return try await previewStart(owner: owner, caller: caller, root: root,
                                          entry: entry, cancellation: cancellation)
        case ("preview.reload", .previewReload):
            return try await previewReload(owner: owner, cancellation: cancellation)
        case ("preview.stop", .previewStop):
            guard let preview else { throw BrowserToolError.configuration("Preview service is unavailable") }
            return await preview.stop(owner: owner.taskID)
        default:
            throw BrowserToolError.validation("Tool '\(name)' does not accept these arguments")
        }
    }

    // MARK: - panel

    private func panel(
        owner: BrowserOwnerID,
        caller: BrowserToolCaller,
        action: String,
        reason: String?,
        tabID: UUID?,
        cancellation: CancellationToken?
    ) async throws -> ToolExecutionOutput {
        guard ["requestUser", "hide"].contains(action) else {
            throw BrowserToolError.validation("Unknown browser panel action")
        }
        if action == "requestUser" {
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty, reason.count <= 500 else {
                throw BrowserToolError.validation("Explain the required human interaction in 1–500 characters")
            }
            let handoffRunID = try Self.handoffRun(for: caller, owner: owner.taskID)
            try await center.requestUserInteraction(
                reason: reason,
                tabID: tabID,
                runID: handoffRunID,
                in: owner.taskID
            )
            return ToolExecutionOutput(
                summary: "The user controls this task's browser; continue other authorized work. A return notification will arrive in this task. Requested interaction: " + reason,
                fullOutputSHA256: FloeDigest.sha256Hex(Data(reason.utf8)),
                requiresUserAction: false
            )
        }
        guard tabID == nil, reason == nil else {
            throw BrowserToolError.validation("hide does not accept a tab or interaction reason")
        }
        try await center.requestPanelDismissal(conversationID: owner.taskID)
        return ToolExecutionOutput(digesting: "Browser panel closed; sidebar preference retained")
    }

    // MARK: - preview trio (original previewOwner ceilings)

    private func previewStart(
        owner: BrowserOwnerID,
        caller: BrowserToolCaller,
        root: String?,
        entry: String?,
        cancellation: CancellationToken?
    ) async throws -> ToolExecutionOutput {
        guard let preview else { throw BrowserToolError.configuration("Preview service is unavailable") }
        guard caller.temporaryReadOnly == false, caller.publicWebOnly == false else {
            throw BrowserToolError.validation("Temporary chat cannot start or control a durable preview")
        }
        do {
            let outcome = try await preview.start(
                owner: owner,
                relativeRoot: root,
                entry: entry,
                cancellation: cancellation
            )
            return ToolExecutionOutput(
                summary: "Preview started at \(outcome.url)",
                fullOutputSHA256: ""
            )
        } catch let error as BrowserPreviewError {
            switch error {
            case .notShowingPreview:
                throw BrowserToolError.validation(error.errorDescription ?? "Preview state changed")
            default:
                throw BrowserToolError.validation(error.errorDescription ?? "Preview could not start")
            }
        }
    }

    private func previewReload(owner: BrowserOwnerID, cancellation: CancellationToken?) async throws -> ToolExecutionOutput {
        guard let preview else { throw BrowserToolError.configuration("Preview service is unavailable") }
        do {
            let output = try await preview.reload(owner: owner, cancellation: cancellation)
            // The reload may have awaited the page; a run cancelled during
            // that window must not present its result as live work.
            try cancellation?.throwIfCancelled()
            return output
        } catch let error as BrowserPreviewError {
            switch error {
            case .noPreview: throw BrowserToolError.notFound("No preview is active for this task")
            case .noBrowser: throw BrowserToolError.notFound("This task's browser session was released")
            default:
                throw BrowserToolError.validation(error.errorDescription ?? "Preview could not reload")
            }
        }
    }

    // MARK: - Result envelope (identical to the original environment.run)

    private func run(
        owner: BrowserOwnerID,
        action: BrowserAction,
        tabID: UUID? = nil,
        documentID: String? = nil,
        visualEvidenceSHA256: String? = nil,
        visualFallbackReason: String? = nil,
        timeoutMilliseconds: Int = 15_000,
        cancellation: CancellationToken? = nil
    ) async throws -> ToolExecutionOutput {
        try cancellation?.throwIfCancelled()
        // Cancellation is runtime evidence that the owning run is finished.
        // It is checked again immediately before any session would be
        // created, so a late callback from a cancelled (deleted, archived or
        // superseded) run can never recreate a browser for its owner.
        let sessionID: UUID
        do {
            sessionID = try await center.taskSession(for: owner).sessionID
        } catch {
            throw BrowserToolError.validation(error.localizedDescription)
        }
        let command = BrowserCommand(
            sessionID: sessionID,
            tabID: tabID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: timeoutMilliseconds,
            visualEvidenceSHA256: visualEvidenceSHA256,
            visualFallbackReason: visualFallbackReason,
            action: action
        )
        // The owner is applied explicitly; visibility is irrelevant.
        let result = await center.execute(command, in: owner, cancellation: cancellation)
        try cancellation?.throwIfCancelled()
        let data = try JSONEncoder().encode(result)
        // The protocol already bounds nodes, events and tabs. Byte truncation
        // here creates invalid JSON and can remove action evidence mid-field.
        let summary = String(decoding: data, as: UTF8.self)
        guard result.status == .ok || result.status == .needsUser else {
            throw BrowserToolError.validation(result.message ?? "Browser action failed")
        }
        let artifacts = result.page?.screenshotArtifact.map {
            [ToolArtifactReference(
                id: $0.id, relativePath: $0.relativePath, mimeType: $0.mimeType,
                byteCount: $0.byteCount, sha256: $0.sha256
            )]
        } ?? []
        // The protocol bounds nodes, events and tabs well below this ceiling,
        // but the default summary budget would still cut the JSON mid-field.
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            artifacts: artifacts,
            requiresUserAction: false,
            maximumSummaryCharacters: Self.summaryCeilingCharacters
        )
    }
}
