#if canImport(Network) && canImport(WebKit) && canImport(SwiftUI)
import Foundation
import Network
import FloeCore
import FloeModels
import FloeTools

/// One long-lived preview owner shared by the file UI and model tools. Keeping
/// ownership here prevents a view dismissal from tearing down a page that is
/// still open in the task browser.
@MainActor
final class LocalPreviewCoordinator: ObservableObject, @unchecked Sendable {
    private weak var browser: BrowserSessionCenter?
    private var server: LocalPreviewServer?
    private var session: LocalPreviewServer.Session?
    @Published private(set) var activeURL: URL?

    init(browser: BrowserSessionCenter) { self.browser = browser }

    func start(root: URL, relativeRoot: String?, entry: String?) async throws -> ToolExecutionOutput {
        guard let browser else { throw FloeError.invalidConfiguration("Visible browser is unavailable") }
        var selectedRoot: URL
        var selectedEntry = entry
        if let relativeRoot, !relativeRoot.isEmpty {
            guard !relativeRoot.hasPrefix("/"), !relativeRoot.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("Preview root must be a safe workspace-relative path")
            }
            let candidate = root.appendingPathComponent(relativeRoot)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                // The model passed a file (commonly the entry page) as root:
                // serve its directory and use the file as the entry.
                selectedRoot = candidate.deletingLastPathComponent()
                selectedEntry = candidate.lastPathComponent
            } else {
                selectedRoot = candidate
            }
        } else {
            selectedRoot = root
        }
        server?.stop()
        let started = try await LocalPreviewServer.start(root: selectedRoot, entry: selectedEntry)
        server = started.0
        session = started.1
        activeURL = started.1.url
        let result = await browser.execute(BrowserCommand(
            sessionID: browser.sessionID,
            action: .navigate(url: started.1.url.absoluteString)
        ))
        guard result.status == .ok else {
            throw FloeError.validationFailed(result.message ?? "Preview could not open in the browser")
        }
        return ToolExecutionOutput(
            summary: "Preview started at \(started.1.url.absoluteString)",
            fullOutputSHA256: ""
        )
    }

    func reload() async throws -> ToolExecutionOutput {
        guard let browser, session != nil else { throw FloeError.notFound("No preview is active") }
        _ = await browser.execute(BrowserCommand(sessionID: browser.sessionID, action: .reload))
        return ToolExecutionOutput(summary: "Preview reloaded", fullOutputSHA256: "")
    }

    func stop() -> ToolExecutionOutput {
        server?.stop()
        server = nil
        session = nil
        activeURL = nil
        return ToolExecutionOutput(summary: "Preview stopped", fullOutputSHA256: "")
    }
}

private struct PreviewStartTool: AgentTool {
    struct Arguments: Decodable, Sendable { let root: String?; let entry: String? }
    static let name = "preview.start"
    static let toolDescription = "Serve static files from the current task workspace in its browser session without opening the user's panel. Use browser.panel requestUser only if human interaction is necessary. root is a workspace-relative directory (a file path is accepted; its parent is served with that file as the entry); entry is relative to root and defaults to index.html/index.htm/public/index.html/dist/index.html/build/index.html or the only HTML file in the directory."
    static let parametersJSON = #"{"type":"object","properties":{"root":{"type":"string","description":"Workspace-relative directory to serve; a file path serves its parent with that file as entry"},"entry":{"type":"string","description":"Entry file relative to root; defaults to common index names or the only HTML file"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let root = context.workspaceRootURL else { throw FloeError.notFound("No task workspace is open") }
        return try await environment.start(root: root, relativeRoot: args.root, entry: args.entry)
    }
}

private struct PreviewReloadTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.reload"
    static let toolDescription = "Reload the active local static preview"
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await environment.reload()
    }
}

private struct PreviewStopTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "preview.stop"
    static let toolDescription = "Stop the active local static preview"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let environment: LocalPreviewCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await environment.stop()
    }
}

@MainActor
func registerPreviewTools(environment: LocalPreviewCoordinator, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(PreviewStartTool.self)
    ToolCatalog.register(PreviewReloadTool.self)
    ToolCatalog.register(PreviewStopTool.self)
    registry.register(PreviewStartTool(environment: environment))
    registry.register(PreviewReloadTool(environment: environment))
    registry.register(PreviewStopTool(environment: environment))
}
#endif
