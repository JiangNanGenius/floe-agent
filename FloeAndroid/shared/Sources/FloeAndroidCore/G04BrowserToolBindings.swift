// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserToolBindings — the frozen 16 browser/preview `AgentTool` runners
// registered through the ORIGINAL `ToolCatalog` + `ToolRunnerRegistry` ONLY
// after every real dependency (center, policy, renderer proxy, preview
// transport, resource port, download sink, handoff routes) was constructed
// and bound for the accepted generation. Until that bind, none of these
// names exists in the registry: discovery never advertises a ready browser
// it cannot run, and the frozen fail-closed "no runner registered" refusal
// is the honest answer (no blanket ready/unregistered-success strings).
//
// Thin by design: each adapter decodes the model-facing JSON into the typed
// `BrowserToolArguments` union, assembles the trusted `BrowserToolCaller`
// from the runtime-issued `ToolContext` (never from model fields), records
// the admitted owner run exactly like the original environment, and calls
// `BrowserToolSurface.invoke`, which owns all owner resolution, ceilings,
// handoff attribution, validation bounds and the result envelope.
//
// Names, descriptions, parameter schemas, risk labels and effects are the
// original iOS texts (BrowserTools.swift + LocalPreviewServer.swift @
// 3fd597b…), with TWO documented Android deltas forced by platform truth —
// both inside capability honesty, never capability invention:
//   1. `browser.screenshot`: on-device OCR (Vision) is unavailable on
//      Android, so the description states visualTextRegions may be empty
//      and DOM observation stays the FIRST choice.
//   2. `browser.clickVisualText`: with no recognizer the surface answers the
//      original "reference absent or stale" refusal; the description states
//      the platform availability instead of promising anchors.
import Foundation
import FloeCore
import FloeTools
import FloeAgentRuntime
import FloeBrowser

/// Trusted routing facts + live-generation service handles shared by all 16
/// adapters. Installed ONLY by the domain extension after attach; an
/// unbound instance answers `invalidConfiguration` (never a silent fall
/// through to another generation's services).
struct G04BrowserToolRouting: Sendable {
    let epoch: UInt64
    let center: BrowserSessionCenter
    let surface: BrowserToolSurface
    let bridge: G04BrowserHandoffBridge
    let ladder: G04BrowserWorkspaceLadder
    /// Synchronous liveness mirror maintained by the extension (attach/
    /// retirement); `AnyAgentTool.isAvailable` consults it so retired
    /// generations never advertise runnable browser tools.
    let isLive: @Sendable () -> Bool

    /// Assembles the trusted caller facts for one call. Model JSON never
    /// contributes an identity: task, run, child facts and ceilings come
    /// from the runtime-issued context; the owner triple comes from the
    /// ORIGINAL persisted selection at the CURRENT native epoch.
    func makeCaller(_ context: ToolContext) async throws -> BrowserToolCaller {
        guard isLive() else {
            throw FloeError.invalidConfiguration("Browser is unavailable")
        }
        guard let conversationID = context.conversationID else {
            throw FloeError.validationFailed(
                "Browser tools require a task-owned run. Open a task and use its browser.")
        }
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Temporary chat cannot open or control a durable browser session")
        }
        let owner = try await ladder.ownerVerified(taskID: conversationID)
        // The task workspace the runtime already froze for this run must be
        // the SAME original root the ladder resolved; a mismatch means the
        // run is not operating on the selected workspace any more.
        if let contextRoot = context.workspaceRootURL?.standardizedFileURL.path {
            let resolvedRoot = await LinuxWorkspaceAuthority
                .resolveWorkspace(conversationID: conversationID)?
                .rootURL.standardizedFileURL.path
            guard resolvedRoot == nil || resolvedRoot == contextRoot else {
                throw FloeError.validationFailed(
                    "This run's workspace binding no longer matches the task's selected workspace")
            }
        }
        let child: BrowserToolCaller.Child? = context.childExecution.map {
            BrowserToolCaller.Child(rootTaskID: $0.identity.rootTaskID,
                                    parentRunID: $0.identity.parentRunID,
                                    depth: $0.identity.depth)
        }
        // A runtime-admitted call is explicit lifecycle evidence: record it
        // exactly like the original environment (lifts the release fence for
        // this run WITHOUT creating any session; a late callback from a
        // cancelled run is still refused by its own cancellation).
        await center.recordOwnerRun(conversationID: conversationID, runID: context.runID)
        bridge.recordOwnerRun(conversationID: conversationID, runID: context.runID)
        return BrowserToolCaller(
            conversationID: conversationID,
            runID: context.runID,
            temporaryReadOnly: context.temporaryReadOnly,
            publicWebOnly: context.publicWebOnly,
            childExecution: child,
            owner: owner)
    }

    /// One invoke path for every frozen name: typed arguments in, the
    /// ORIGINAL envelope out, with BrowserToolError mapped onto the same
    /// FloeError shapes the original tool path produced.
    func invoke(name: String, arguments: BrowserToolArguments,
                context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let caller = try await makeCaller(context)
        do {
            return try await surface.invoke(
                name: name, caller: caller, arguments: arguments,
                cancellation: context.cancellation)
        } catch let error as BrowserToolError {
            switch error {
            case .validation(let message):
                throw FloeError.validationFailed(message)
            case .notFound(let message):
                throw FloeError.notFound(message)
            case .configuration(let message):
                throw FloeError.invalidConfiguration(message)
            }
        }
    }

    func previewWorkspaceGate(_ context: ToolContext) throws {
        // The original preview tools required an OPEN task workspace.
        guard context.workspaceRootURL != nil else {
            throw FloeError.notFound("No task workspace is open")
        }
    }

    /// Trusted-UI caller (panel-driven `toolSubmit` only). Ownership is the
    // SAME ladder revalidation as the model path; run attribution is the
    // trusted mirror's recorded run (never re-admitted from the UI, so a
    // cancelled run cannot be lifted back to life by a tap). No
    // `childExecution`: UI submissions are task-level, not delegated.
    func makeUICaller(taskID: UUID) async throws -> BrowserToolCaller {
        let owner = try await ladder.ownerVerified(taskID: taskID)
        return BrowserToolCaller(
            conversationID: taskID,
            runID: bridge.recordedRun(for: taskID),
            temporaryReadOnly: false,
            publicWebOnly: false,
            childExecution: nil,
            owner: owner)
    }
}

// MARK: - Trusted-UI argument codec (closed per-name grammar)

/// Decodes the model-shape argument JSON into the typed union for the
/// trusted-UI `toolSubmit` path only (the model path decodes through the
/// AgentTool `Arguments` types above). Every name has a CLOSED field set;
/// unknown keys are refused, and the surface re-enforces all bounds.
public enum G04BrowserToolArgumentsCodec {
    public static func decode(name: String, json: String) throws -> BrowserToolArguments {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FloeError.validationFailed("Invalid arguments JSON") }
        func require(_ key: String, _ kind: String) throws -> Any {
            guard let value = object[key] else {
                throw FloeError.validationFailed("missing required argument '\(key)' (\(kind))")
            }
            return value
        }
        func string(_ key: String, required: Bool = true) throws -> String? {
            guard let value = object[key] else {
                if required { throw FloeError.validationFailed("missing required argument '\(key)'") }
                return nil
            }
            if value is NSNull { return nil }
            guard let text = value as? String else {
                throw FloeError.validationFailed("argument '\(key)' must be a string")
            }
            return text
        }
        func uuid(_ key: String) throws -> UUID? {
            guard let text = try string(key, required: false) else { return nil }
            guard let id = UUID(uuidString: text) else {
                throw FloeError.validationFailed("argument '\(key)' must be a UUID")
            }
            return id
        }
        func int(_ key: String) throws -> Int? {
            guard let number = object[key] as? NSNumber else {
                if object[key] == nil || object[key] is NSNull { return nil }
                throw FloeError.validationFailed("argument '\(key)' must be an integer")
            }
            return number.intValue
        }
        func double(_ key: String) throws -> Double? {
            guard let number = object[key] as? NSNumber else {
                if object[key] == nil || object[key] is NSNull { return nil }
                throw FloeError.validationFailed("argument '\(key)' must be a number")
            }
            return number.doubleValue
        }
        func bool(_ key: String) throws -> Bool? {
            guard let number = object[key] as? NSNumber else {
                if object[key] == nil || object[key] is NSNull { return nil }
                throw FloeError.validationFailed("argument '\(key)' must be a boolean")
            }
            return number.boolValue
        }
        switch name {
        case G04BrowserPanelTool.name:
            let action = try string("action")
            return try .panel(action: requireChecked(action, "action"),
                              reason: string("reason", required: false),
                              tabID: uuid("tabID"))
        case G04BrowserTabsTool.name:
            guard object.isEmpty else {
                throw FloeError.validationFailed("browser.tabs takes no arguments")
            }
            return .tabs
        case G04BrowserTabTool.name:
            return try .tab(action: requireChecked(string("action"), "action"),
                            tabID: uuid("tabID"))
        case G04BrowserEventsTool.name:
            return try .events(tabID: uuid("tabID"),
                               afterSequence: int("afterSequence"),
                               limit: int("limit"))
        case G04BrowserWaitTool.name:
            return try .wait(tabID: uuid("tabID"),
                             condition: requireChecked(string("condition"), "condition"),
                             value: string("value", required: false),
                             quietMilliseconds: int("quietMilliseconds"),
                             timeoutMilliseconds: int("timeoutMilliseconds"))
        case G04BrowserNavigateTool.name:
            return try .navigate(url: requireChecked(string("url"), "url"),
                                 tabID: uuid("tabID"))
        case G04BrowserObserveTool.name:
            return try .observe(tabID: uuid("tabID"), cursor: int("cursor"))
        case G04BrowserScreenshotTool.name:
            return try .screenshot(tabID: uuid("tabID"))
        case G04BrowserClickVisualTextTool.name:
            return try .clickVisualText(tabID: uuid("tabID"),
                                        documentID: requireChecked(string("documentID"), "documentID"),
                                        reference: requireChecked(string("reference"), "reference"),
                                        screenshotSHA256: requireChecked(string("screenshotSHA256"), "screenshotSHA256"))
        case G04BrowserClickTool.name:
            return try .click(tabID: uuid("tabID"),
                              ref: requireChecked(string("ref"), "ref"),
                              documentID: requireChecked(string("documentID"), "documentID"))
        case G04BrowserClickPointTool.name:
            guard let x = try double("x"), let y = try double("y") else {
                throw FloeError.validationFailed("x and y are required")
            }
            return try .clickPoint(tabID: uuid("tabID"),
                                   documentID: requireChecked(string("documentID"), "documentID"),
                                   x: x, y: y,
                                   screenshotSHA256: requireChecked(string("screenshotSHA256"), "screenshotSHA256"),
                                   fallbackReason: requireChecked(string("fallbackReason"), "fallbackReason"))
        case G04BrowserTypeTool.name:
            return try .type(tabID: uuid("tabID"),
                             ref: requireChecked(string("ref"), "ref"),
                             documentID: requireChecked(string("documentID"), "documentID"),
                             text: requireChecked(string("text"), "text"),
                             submit: bool("submit"))
        case G04BrowserScrollTool.name:
            guard let deltaY = try double("deltaY") else {
                throw FloeError.validationFailed("deltaY is required")
            }
            return try .scroll(tabID: uuid("tabID"), deltaX: try double("deltaX"),
                               deltaY: deltaY)
        case G04PreviewStartTool.name:
            return try .previewStart(root: string("root", required: false),
                                     entry: string("entry", required: false))
        case G04PreviewReloadTool.name:
            guard object.isEmpty else {
                throw FloeError.validationFailed("preview.reload takes no arguments")
            }
            return .previewReload
        case G04PreviewStopTool.name:
            guard object.isEmpty else {
                throw FloeError.validationFailed("preview.stop takes no arguments")
            }
            return .previewStop
        default:
            throw FloeError.validationFailed("Unknown browser tool '\(name)'")
        }
    }

    private static func requireChecked(_ value: String?, _ key: String) throws -> String {
        guard let value else {
            throw FloeError.validationFailed("missing required argument '\(key)'")
        }
        return value
    }
}

extension G04BrowserWorkspaceLadder {
    /// Owner resolution with the FULL ladder revalidation pass (conversation
    /// ordinary + selected workspace + private-task root + live epoch). The
    /// surface's `ownerAuthority` closure consumes the same check again at
    /// session admission/preview/handoff boundaries; this call gates the
    /// tool ENTRY itself so a stale selection never reaches the surface.
    func ownerVerified(taskID: UUID) async throws -> BrowserOwnerID {
        let cancellation = CancellationToken()
        guard let owner = await owner(forTask: taskID) else {
            throw FloeError.validationFailed(
                "The runtime did not resolve an exact workspace ownership binding for this task")
        }
        _ = try await service(for: owner, cancellation: cancellation)
        guard await G04BrowserOwnerAuthority.revalidate(owner: owner) else {
            throw FloeError.validationFailed(
                "This task's browser ownership binding is no longer admitted")
        }
        return owner
    }
}

// MARK: - The 13 browser tools + 3 preview tools (frozen family)

/// One concrete AgentTool per frozen name. `@unchecked Sendable` is not
/// used: every field is value-type or an actor reference already Sendable.
struct G04BrowserPanelTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let reason: String?
        let tabID: UUID?
    }
    static let name = "browser.panel"
    static let toolDescription = "Browser navigation and previews run without opening the user's panel. Only when human interaction is necessary (login, verification, file selection or an explicit user interaction request), call requestUser with a concise reason explaining what the user must do. It opens this task's browser panel, hands browser control to the user. The task may continue other work; browser mutations are unavailable until the user returns control. The return event is delivered to this task; observe the page again before acting. Do not use it for ordinary navigation or progress display. hide closes only the browser panel after the user has returned control; it never changes the main navigation sidebar."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["requestUser","hide"]},"reason":{"type":"string","maxLength":500},"tabID":{"type":"string","format":"uuid"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard ["requestUser", "hide"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown browser panel action")
        }
        if args.action == "requestUser" {
            guard let reason = args.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty, reason.count <= 500 else {
                throw FloeError.validationFailed("Explain the required human interaction in 1–500 characters")
            }
        } else if args.tabID != nil || args.reason != nil {
            throw FloeError.validationFailed("hide does not accept a tab or interaction reason")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .panel(action: args.action, reason: args.reason, tabID: args.tabID),
            context: context)
    }
}

struct G04BrowserTabsTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "browser.tabs"
    static let toolDescription = "List tabs in this task's browser session with exact tab IDs and active state. Does not open, switch or close tabs."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try await routing.invoke(name: Self.name, arguments: .tabs, context: context)
    }
}

struct G04BrowserTabTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let action: String
        let tabID: UUID?
    }
    static let name = "browser.tab"
    static let toolDescription = "Create, activate, or close a tab in this task's browser session. Create returns a new tab ID; use browser.navigate on that ID to open a URL. Activate/close require an exact tabID from browser.tabs. Does not manage other apps' tabs."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","activate","close"]},"tabID":{"type":"string","format":"uuid"}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard ["create", "activate", "close"].contains(args.action) else {
            throw FloeError.validationFailed("Unknown tab action")
        }
        guard (args.action == "create") == (args.tabID == nil) else {
            throw FloeError.validationFailed("Create must omit tabID; activate/close require tabID")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .tab(action: args.action, tabID: args.tabID),
            context: context)
    }
}

struct G04BrowserEventsTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let afterSequence: Int?; let limit: Int? }
    static let name = "browser.events"
    static let toolDescription = "Read bounded CDP-style lifecycle and DOM events from this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"afterSequence":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        if let sequence = args.afterSequence, sequence < 0 {
            throw FloeError.validationFailed("afterSequence must be non-negative")
        }
        if let limit = args.limit, !(1...50).contains(limit) {
            throw FloeError.validationFailed("limit must be between 1 and 50")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .events(tabID: args.tabID, afterSequence: args.afterSequence, limit: args.limit),
            context: context)
    }
}

struct G04BrowserWaitTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let condition: String
        let value: String?
        let quietMilliseconds: Int?
        let timeoutMilliseconds: Int?
    }
    static let name = "browser.wait"
    static let toolDescription = "Wait for load, DOM readiness, selector, text, document change, or approximate idle in this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"condition":{"type":"string","enum":["load","dom","selector","text","documentChanged","idle"]},"value":{"type":"string","maxLength":512},"quietMilliseconds":{"type":"integer","minimum":100,"maximum":5000},"timeoutMilliseconds":{"type":"integer","minimum":250,"maximum":30000}},"required":["condition"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard ["load", "dom", "selector", "text", "documentChanged", "idle"].contains(args.condition) else {
            throw FloeError.validationFailed("Unknown browser wait condition")
        }
        if ["selector", "text", "documentChanged"].contains(args.condition),
           args.value?.isEmpty != false {
            throw FloeError.validationFailed("This wait condition requires value")
        }
        if let value = args.value, value.utf8.count > 512 {
            throw FloeError.validationFailed("Browser wait value exceeds 512 bytes")
        }
        if let quiet = args.quietMilliseconds, !(100...5_000).contains(quiet) {
            throw FloeError.validationFailed("quietMilliseconds must be between 100 and 5000")
        }
        if let timeout = args.timeoutMilliseconds, !(250...30_000).contains(timeout) {
            throw FloeError.validationFailed("timeoutMilliseconds must be between 250 and 30000")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .wait(tabID: args.tabID, condition: args.condition, value: args.value,
                             quietMilliseconds: args.quietMilliseconds,
                             timeoutMilliseconds: args.timeoutMilliseconds),
            context: context)
    }
}

struct G04BrowserNavigateTool: AgentTool {
    struct Arguments: Decodable, Sendable { let url: String; let tabID: UUID? }
    static let name = "browser.navigate"
    static let toolDescription = "Navigate this task's browser to an http or https URL without opening the user's panel. Use browser.panel requestUser only for a required human interaction"
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string"},"tabID":{"type":"string"}},"required":["url"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard !args.url.isEmpty else {
            throw FloeError.validationFailed("Only http and https URLs are allowed")
        }
        // The FULL policy decision (grants included) runs inside the
        // surface BEFORE any session work, exactly like the original.
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .navigate(url: args.url, tabID: args.tabID),
            context: context)
    }
}

struct G04BrowserObserveTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let cursor: Int? }
    static let name = "browser.observe"
    static let toolDescription = "FIRST choice for reading a page: return a bounded semantic DOM snapshot with stable element refs, text, values, state, and bounds. Continue pagination before concluding that structured information is missing."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"cursor":{"type":"integer","minimum":0}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        if let cursor = args.cursor, cursor < 0 {
            throw FloeError.validationFailed("cursor must be non-negative")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name, arguments: .observe(tabID: args.tabID, cursor: args.cursor),
            context: context)
    }
}

struct G04BrowserScreenshotTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID? }
    static let name = "browser.screenshot"
    /// Android delta 1 (documented): on-device OCR is unavailable on this
    /// platform, so visualTextRegions may legitimately be EMPTY. The
    /// description states the truth instead of promising anchors; the
    /// capture itself is a real viewport JPEG or a typed failure, never a
    /// placeholder image.
    static let toolDescription = "Capture the current viewport when browser.observe is unavailable or semantically insufficient. Returns the real viewport screenshot; on-device OCR visual-text regions may be empty on this platform, so browser.observe stays the first structured source."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name, arguments: .screenshot(tabID: args.tabID), context: context)
    }
}

struct G04BrowserClickVisualTextTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let reference: String
        let screenshotSHA256: String
    }
    static let name = "browser.clickVisualText"
    /// Android delta 2 (documented): without an on-device recognizer no
    /// text-N reference can exist; the surface answers the original
    /// "reference absent or stale" refusal. The description states that
    /// availability honestly.
    static let toolDescription = "Click an OCR-backed text-N reference from the latest browser.screenshot when no semantic DOM ref represents that visible text. On-device OCR is not available on every platform: when no text-N anchor exists this returns the original absent-or-stale refusal, and browser.click or browser.clickPoint remain the structured/visual alternatives."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"documentID":{"type":"string"},"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["documentID","reference","screenshotSHA256"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty,
              args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed(
                "documentID, a text-N reference, and its fresh screenshot sha256 are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .clickVisualText(tabID: args.tabID, documentID: args.documentID,
                                        reference: args.reference,
                                        screenshotSHA256: args.screenshotSHA256),
            context: context)
    }
}

struct G04BrowserClickTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let ref: String; let documentID: String }
    static let name = "browser.click"
    static let toolDescription = "Preferred browser action: click a stable element ref returned by browser.observe. Use this before any coordinate fallback."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"}},"required":["ref","documentID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else {
            throw FloeError.validationFailed("ref and documentID are required")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .click(tabID: args.tabID, ref: args.ref, documentID: args.documentID),
            context: context)
    }
}

struct G04BrowserClickPointTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let x: Double
        let y: Double
        let screenshotSHA256: String
        let fallbackReason: String
    }
    static let name = "browser.clickPoint"
    static let toolDescription = "LAST-RESORT visual fallback after browser.observe: click x/y in the exact pixel coordinate space of the fresh browser.screenshot artifact. Provide that screenshot's sha256 and the exact fallback reason. Floe converts screenshot pixels to the page's CSS viewport and reports success only when a post-click screenshot or page state shows an observable change. Canvas-internal controls may use this fallback; ordinary DOM controls with stable refs are rejected and must use browser.click."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"documentID":{"type":"string"},"x":{"type":"number","minimum":0,"maximum":10000},"y":{"type":"number","minimum":0,"maximum":10000},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"},"fallbackReason":{"type":"string","enum":["noStructuredTarget","insufficientStructuredInformation"]}},"required":["documentID","x","y","screenshotSHA256","fallbackReason"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty, args.x.isFinite, args.y.isFinite,
              (0...10_000).contains(args.x), (0...10_000).contains(args.y) else {
            throw FloeError.validationFailed("documentID and bounded screenshot pixel coordinates are required")
        }
        guard args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed("a fresh browser screenshot sha256 is required")
        }
        guard ["noStructuredTarget", "insufficientStructuredInformation"].contains(args.fallbackReason) else {
            throw FloeError.validationFailed("fallbackReason must explain why structured access is insufficient")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .clickPoint(tabID: args.tabID, documentID: args.documentID,
                                   x: args.x, y: args.y,
                                   screenshotSHA256: args.screenshotSHA256,
                                   fallbackReason: args.fallbackReason),
            context: context)
    }
}

struct G04BrowserTypeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let ref: String
        let documentID: String
        let text: String
        let submit: Bool?
    }
    static let name = "browser.type"
    static let toolDescription = "Type into a non-password element in this task's browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"},"text":{"type":"string","maxLength":16384},"submit":{"type":"boolean"}},"required":["ref","documentID","text"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .sendsDataToProvider]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else {
            throw FloeError.validationFailed("ref and documentID are required")
        }
        guard args.text.utf8.count <= 16 * 1024 else {
            throw FloeError.validationFailed("text exceeds 16 KiB")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .type(tabID: args.tabID, ref: args.ref, documentID: args.documentID,
                             text: args.text, submit: args.submit),
            context: context)
    }
}

struct G04BrowserScrollTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let deltaX: Double?; let deltaY: Double }
    static let name = "browser.scroll"
    static let toolDescription = "Scroll this task's browser viewport"
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {
        guard args.deltaY.isFinite, args.deltaX?.isFinite != false,
              abs(args.deltaY) <= 20_000, abs(args.deltaX ?? 0) <= 20_000 else {
            throw FloeError.validationFailed("scroll delta is invalid")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await routing.invoke(
            name: Self.name,
            arguments: .scroll(tabID: args.tabID, deltaX: args.deltaX, deltaY: args.deltaY),
            context: context)
    }
}

struct G04PreviewStartTool: AgentTool {
    struct Arguments: Decodable, Sendable { let root: String?; let entry: String? }
    static let name = "preview.start"
    static let toolDescription = "Serve static files from the current task workspace in its browser session without opening the user's panel. Use browser.panel requestUser only if human interaction is necessary. root is a workspace-relative directory (a file path is accepted; its parent is served with that file as the entry); entry is relative to root and defaults to index.html/index.htm/public/index.html/dist/index.html/build/index.html or the only HTML file in the directory."
    static let parametersJSON = #"{"type":"object","properties":{"root":{"type":"string","description":"Workspace-relative directory to serve; a file path serves its parent with that file as entry"},"entry":{"type":"string","description":"Entry file relative to root; defaults to common index names or the only HTML file"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try routing.previewWorkspaceGate(context)
        return try await routing.invoke(
            name: Self.name, arguments: .previewStart(root: args.root, entry: args.entry),
            context: context)
    }
}

struct G04PreviewReloadTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.reload"
    static let toolDescription = "Reload this task's active local static preview. Only the calling task's preview is affected."
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try routing.previewWorkspaceGate(context)
        return try await routing.invoke(name: Self.name, arguments: .previewReload, context: context)
    }
}

struct G04PreviewStopTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.stop"
    static let toolDescription = "Stop this task's active local static preview. Other tasks' previews keep serving."
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let routing: G04BrowserToolRouting
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try routing.previewWorkspaceGate(context)
        return try await routing.invoke(name: Self.name, arguments: .previewStop, context: context)
    }
}

// MARK: - Registration (frozen 16; exact removal)

public enum G04BrowserToolNames {
    public static let all: [String] = [
        G04BrowserPanelTool.name, G04BrowserTabsTool.name, G04BrowserTabTool.name,
        G04BrowserEventsTool.name, G04BrowserWaitTool.name, G04BrowserNavigateTool.name,
        G04BrowserObserveTool.name, G04BrowserScreenshotTool.name,
        G04BrowserClickVisualTextTool.name, G04BrowserClickTool.name,
        G04BrowserClickPointTool.name, G04BrowserTypeTool.name, G04BrowserScrollTool.name,
        G04PreviewStartTool.name, G04PreviewReloadTool.name, G04PreviewStopTool.name,
    ]
}

/// Registers EXACTLY the frozen family through the original catalog and the
/// generation's own runner registry. The catalog carries the descriptors for
/// discovery; the runners bind to THIS generation's routing and answer
/// unavailable (`isAvailable == false`) the instant the generation retires,
/// and are fully removed by `unregister` so no stale runner outlives its
/// epoch.
enum G04BrowserToolRegistration {
    static func register(_ routing: G04BrowserToolRouting,
                         registry: ToolRunnerRegistry) {
        registerType(G04BrowserPanelTool.self)
        registerType(G04BrowserTabsTool.self)
        registerType(G04BrowserTabTool.self)
        registerType(G04BrowserEventsTool.self)
        registerType(G04BrowserWaitTool.self)
        registerType(G04BrowserNavigateTool.self)
        registerType(G04BrowserObserveTool.self)
        registerType(G04BrowserScreenshotTool.self)
        registerType(G04BrowserClickVisualTextTool.self)
        registerType(G04BrowserClickTool.self)
        registerType(G04BrowserClickPointTool.self)
        registerType(G04BrowserTypeTool.self)
        registerType(G04BrowserScrollTool.self)
        registerType(G04PreviewStartTool.self)
        registerType(G04PreviewReloadTool.self)
        registerType(G04PreviewStopTool.self)

        bind(G04BrowserPanelTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserTabsTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserTabTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserEventsTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserWaitTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserNavigateTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserObserveTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserScreenshotTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserClickVisualTextTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserClickTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserClickPointTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserTypeTool(routing: routing), routing: routing, registry: registry)
        bind(G04BrowserScrollTool(routing: routing), routing: routing, registry: registry)
        bind(G04PreviewStartTool(routing: routing), routing: routing, registry: registry)
        bind(G04PreviewReloadTool(routing: routing), routing: routing, registry: registry)
        bind(G04PreviewStopTool(routing: routing), routing: routing, registry: registry)
    }

    static func unregister(registry: ToolRunnerRegistry) {
        let names = Set(G04BrowserToolNames.all)
        registry.unregister { names.contains(ToolAliasTable.canonical($0)) }
    }

    private static func registerType<T: AgentTool>(_ type: T.Type) {
        ToolCatalog.register(type)
    }

    private static func bind<T: AgentTool>(_ tool: T, routing: G04BrowserToolRouting,
                                           registry: ToolRunnerRegistry) {
        var erased = AnyAgentTool(tool)
        // A retired generation answers "disabled/not configured" through the
        // ORIGINAL availability filter (runner present, catalog honest):
        // no browser tool survives its epoch as a silently-available stub.
        erased.isAvailable = routing.isLive
        registry.register(erased)
    }
}
