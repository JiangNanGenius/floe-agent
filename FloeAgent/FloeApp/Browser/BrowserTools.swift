// FloeApp — compiled browser tools backed by the visible WKWebView center.

#if canImport(SwiftUI) && canImport(WebKit)
import Foundation
import CryptoKit
import FloeCore
import FloeModels
import FloeTools

private final class BrowserToolEnvironment: @unchecked Sendable {
    weak var center: BrowserSessionCenter?

    init(center: BrowserSessionCenter) {
        self.center = center
    }

    @MainActor
    func run(
        action: BrowserAction,
        tabID: UUID? = nil,
        documentID: String? = nil,
        visualEvidenceSHA256: String? = nil,
        visualFallbackReason: String? = nil,
        timeoutMilliseconds: Int = 15_000
    ) async throws -> ToolExecutionOutput {
        guard let center else { throw FloeError.invalidConfiguration("The visible browser is unavailable") }
        let command = BrowserCommand(
            sessionID: center.sessionID,
            tabID: tabID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: timeoutMilliseconds,
            visualEvidenceSHA256: visualEvidenceSHA256,
            visualFallbackReason: visualFallbackReason,
            action: action
        )
        let result = await center.execute(command)
        let data = try JSONEncoder().encode(result)
        // The protocol already bounds nodes, events and tabs. Byte truncation
        // here creates invalid JSON and can remove action evidence mid-field.
        let summary = String(decoding: data, as: UTF8.self)
        guard result.status == .ok || result.status == .needsUser else {
            throw FloeError.validationFailed(result.message ?? "Browser action failed")
        }
        let artifacts = result.page?.screenshotArtifact.map {
            [ToolArtifactReference(
                id: $0.id, relativePath: $0.relativePath, mimeType: $0.mimeType,
                byteCount: $0.byteCount, sha256: $0.sha256
            )]
        } ?? []
        return ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            artifacts: artifacts,
            requiresUserAction: result.status == .needsUser
        )
    }
}

private struct BrowserTabsTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "browser.tabs"
    static let toolDescription = "List tabs in this task's browser session with exact tab IDs and active state. Does not open, switch or close tabs."
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        return try await environment.run(action: .listTabs)
    }
}

private struct BrowserTabTool: AgentTool {
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
    let environment: BrowserToolEnvironment
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
        let action: BrowserAction
        switch args.action {
        case "create": action = .create
        case "activate": action = .activateTab(args.tabID!)
        default: action = .closeTab(args.tabID!)
        }
        return try await environment.run(action: action)
    }
}

private struct BrowserEventsTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let afterSequence: Int?; let limit: Int? }
    static let name = "browser.events"
    static let toolDescription = "Read bounded CDP-style lifecycle and DOM events from Floe's visible browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"afterSequence":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        if let sequence = args.afterSequence, sequence < 0 { throw FloeError.validationFailed("afterSequence must be non-negative") }
        if let limit = args.limit, !(1...50).contains(limit) { throw FloeError.validationFailed("limit must be between 1 and 50") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            action: .events(afterSequence: args.afterSequence, limit: args.limit ?? 20),
            tabID: args.tabID
        )
    }
}

private struct BrowserWaitTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let condition: String
        let value: String?
        let quietMilliseconds: Int?
        let timeoutMilliseconds: Int?
    }
    static let name = "browser.wait"
    static let toolDescription = "Wait for load, DOM readiness, selector, text, document change, or approximate idle in Floe's visible browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"condition":{"type":"string","enum":["load","dom","selector","text","documentChanged","idle"]},"value":{"type":"string","maxLength":512},"quietMilliseconds":{"type":"integer","minimum":100,"maximum":5000},"timeoutMilliseconds":{"type":"integer","minimum":250,"maximum":30000}},"required":["condition"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
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
        let condition: BrowserWaitCondition
        switch args.condition {
        case "load": condition = .load
        case "dom": condition = .domContentLoaded
        case "selector": condition = .selector(args.value ?? "")
        case "text": condition = .text(args.value ?? "")
        case "documentChanged": condition = .documentChanged(from: args.value ?? "")
        default: condition = .idle(milliseconds: args.quietMilliseconds ?? 500)
        }
        return try await environment.run(
            action: .wait(condition),
            tabID: args.tabID,
            timeoutMilliseconds: args.timeoutMilliseconds ?? 15_000
        )
    }
}

private struct BrowserNavigateTool: AgentTool {
    struct Arguments: Decodable, Sendable { let url: String; let tabID: UUID? }
    static let name = "browser.navigate"
    static let toolDescription = "Open an http or https URL in Floe's visible browser"
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string"},"tabID":{"type":"string"}},"required":["url"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws { _ = try BrowserURLPolicy.validate(args.url) }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(action: .navigate(url: args.url), tabID: args.tabID)
    }
}

private struct BrowserObserveTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let cursor: Int? }
    static let name = "browser.observe"
    static let toolDescription = "FIRST choice for reading a page: return a bounded semantic DOM snapshot with stable element refs, text, values, state, and bounds. Continue pagination before concluding that structured information is missing."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"cursor":{"type":"integer","minimum":0}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        if let cursor = args.cursor, cursor < 0 { throw FloeError.validationFailed("cursor must be non-negative") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(action: .observe(cursor: args.cursor), tabID: args.tabID)
    }
}

private struct BrowserScreenshotTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID? }
    static let name = "browser.screenshot"
    static let toolDescription = "Capture the current viewport when browser.observe is unavailable or semantically insufficient. Returns on-device OCR visualTextRegions with text-N references and exact screenshot-pixel bounds. Prefer browser.clickVisualText for a matching text anchor; use browser.clickPoint only when neither DOM refs nor text anchors identify the target."
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(action: .screenshot, tabID: args.tabID)
    }
}

private struct BrowserClickVisualTextTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let documentID: String
        let reference: String
        let screenshotSHA256: String
    }
    static let name = "browser.clickVisualText"
    static let toolDescription = "Click an OCR-backed text-N reference from the latest browser.screenshot when no semantic DOM ref represents that visible text. The reference is bound to the current document and screenshot digest; a post-click screenshot must show an observable change."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"documentID":{"type":"string"},"reference":{"type":"string","pattern":"^text-[1-9][0-9]*$"},"screenshotSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$"}},"required":["documentID","reference","screenshotSHA256"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty,
              args.reference.range(of: #"^text-[1-9][0-9]*$"#, options: .regularExpression) != nil,
              args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed(
                "documentID, a text-N reference, and its fresh screenshot sha256 are required"
            )
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            action: .click(.visualText(reference: args.reference)),
            tabID: args.tabID,
            documentID: args.documentID,
            visualEvidenceSHA256: args.screenshotSHA256,
            visualFallbackReason: "insufficientStructuredInformation"
        )
    }
}

private struct BrowserClickTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let ref: String; let documentID: String }
    static let name = "browser.click"
    static let toolDescription = "Preferred browser action: click a stable element ref returned by browser.observe. Use this before any coordinate fallback."
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"}},"required":["ref","documentID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else { throw FloeError.validationFailed("ref and documentID are required") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            action: .click(.element(ref: args.ref, documentID: args.documentID)),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

/// Coordinate fallback for canvas/custom controls after a fresh screenshot.
/// It still uses public WebKit DOM hit-testing; it does not forge trusted iOS
/// touch events and therefore may return takeover-required on protected UI.
private struct BrowserClickPointTool: AgentTool {
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
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.documentID.isEmpty, args.x.isFinite, args.y.isFinite,
              (0...10_000).contains(args.x), (0...10_000).contains(args.y) else {
            throw FloeError.validationFailed("documentID and bounded screenshot pixel coordinates are required")
        }
        guard args.screenshotSHA256.count == 64,
              args.screenshotSHA256.allSatisfy(\.isHexDigit) else {
            throw FloeError.validationFailed("a fresh browser screenshot sha256 is required")
        }
        guard ["noStructuredTarget", "insufficientStructuredInformation"]
            .contains(args.fallbackReason) else {
            throw FloeError.validationFailed("fallbackReason must explain why structured access is insufficient")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            action: .click(.point(x: args.x, y: args.y)),
            tabID: args.tabID,
            documentID: args.documentID,
            visualEvidenceSHA256: args.screenshotSHA256,
            visualFallbackReason: args.fallbackReason
        )
    }
}

private struct BrowserTypeTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let tabID: UUID?
        let ref: String
        let documentID: String
        let text: String
        let submit: Bool?
    }
    static let name = "browser.type"
    static let toolDescription = "Type into a non-password element in Floe's visible browser"
    static let parametersJSON = #"{"type":"object","properties":{"tabID":{"type":"string"},"ref":{"type":"string"},"documentID":{"type":"string"},"text":{"type":"string","maxLength":16384},"submit":{"type":"boolean"}},"required":["ref","documentID","text"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI, .sendsDataToProvider]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard !args.ref.isEmpty, !args.documentID.isEmpty else { throw FloeError.validationFailed("ref and documentID are required") }
        guard args.text.utf8.count <= 16 * 1024 else { throw FloeError.validationFailed("text exceeds 16 KiB") }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(
            action: .type(.element(ref: args.ref, documentID: args.documentID), text: args.text, submit: args.submit ?? false),
            tabID: args.tabID,
            documentID: args.documentID
        )
    }
}

private struct BrowserScrollTool: AgentTool {
    struct Arguments: Decodable, Sendable { let tabID: UUID?; let deltaX: Double?; let deltaY: Double }
    static let name = "browser.scroll"
    static let toolDescription = "Scroll Floe's visible browser viewport"
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let environment: BrowserToolEnvironment
    func validate(_ args: Arguments) throws {
        guard args.deltaY.isFinite, args.deltaX?.isFinite != false,
              abs(args.deltaY) <= 20_000, abs(args.deltaX ?? 0) <= 20_000 else {
            throw FloeError.validationFailed("scroll delta is invalid")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.run(action: .scroll(deltaX: args.deltaX ?? 0, deltaY: args.deltaY), tabID: args.tabID)
    }
}

@MainActor
func registerBrowserTools(center: BrowserSessionCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(BrowserTabsTool.self)
    ToolCatalog.register(BrowserTabTool.self)
    registry.register(BrowserTabsTool(environment: BrowserToolEnvironment(center: center)))
    registry.register(BrowserTabTool(environment: BrowserToolEnvironment(center: center)))
    let environment = BrowserToolEnvironment(center: center)
    ToolCatalog.register(BrowserNavigateTool.self)
    ToolCatalog.register(BrowserObserveTool.self)
    ToolCatalog.register(BrowserEventsTool.self)
    ToolCatalog.register(BrowserWaitTool.self)
    ToolCatalog.register(BrowserScreenshotTool.self)
    ToolCatalog.register(BrowserClickVisualTextTool.self)
    ToolCatalog.register(BrowserClickTool.self)
    ToolCatalog.register(BrowserClickPointTool.self)
    ToolCatalog.register(BrowserTypeTool.self)
    ToolCatalog.register(BrowserScrollTool.self)
    registry.register(BrowserNavigateTool(environment: environment))
    registry.register(BrowserObserveTool(environment: environment))
    registry.register(BrowserEventsTool(environment: environment))
    registry.register(BrowserWaitTool(environment: environment))
    registry.register(BrowserScreenshotTool(environment: environment))
    registry.register(BrowserClickVisualTextTool(environment: environment))
    registry.register(BrowserClickTool(environment: environment))
    registry.register(BrowserClickPointTool(environment: environment))
    registry.register(BrowserTypeTool(environment: environment))
    registry.register(BrowserScrollTool(environment: environment))
}
#endif
