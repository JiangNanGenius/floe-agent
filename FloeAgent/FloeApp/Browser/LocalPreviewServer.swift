#if canImport(Network) && canImport(WebKit) && canImport(SwiftUI)
import Foundation
import Network
import FloeCore
import FloeModels
import FloeTools

final class LocalPreviewServer: @unchecked Sendable {
    struct Session: Sendable {
        let root: URL
        let entry: String
        let url: URL
    }

    private let listener: NWListener
    private let root: URL
    private let token: String
    private let queue = DispatchQueue(label: "org.floeagent.preview")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    private init(listener: NWListener, root: URL, token: String) {
        self.listener = listener
        self.root = root
        self.token = token
    }

    static func start(root: URL, entry: String?) async throws -> (LocalPreviewServer, Session) {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeError.notFound("Preview root is not a directory")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = LocalPreviewServer(listener: listener, root: canonicalRoot, token: token)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        try await server.begin()
        guard let port = listener.port?.rawValue else {
            throw FloeError.internalError("Preview listener did not receive a port")
        }
        let selectedEntry = try server.resolveEntry(entry)
        let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(selectedEntry)")!
        BrowserURLPolicy.authorizePreview(url)
        return (server, Session(root: canonicalRoot, entry: selectedEntry, url: url))
    }

    func stop() {
        listener.cancel()
        let snapshot = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        snapshot.forEach { $0.cancel() }
        if let port = listener.port?.rawValue,
           let url = URL(string: "http://127.0.0.1:\(port)/\(token)/") {
            BrowserURLPolicy.revokePreview(url)
        }
    }

    private func begin() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PreviewContinuationGate()
            listener.stateUpdateHandler = { state in
                let claim = gate.claim(for: state)
                guard claim else { return }
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else { return }
            let response = self.response(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: Data) -> Data {
        guard let text = String(data: request, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return http(status: "400 Bad Request", body: Data())
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
            return http(status: "405 Method Not Allowed", body: Data())
        }
        let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard let decoded = rawPath.removingPercentEncoding else {
            return http(status: "400 Bad Request", body: Data())
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.first == token else {
            return http(status: "404 Not Found", body: Data())
        }
        let relative = components.dropFirst().joined(separator: "/")
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(".."),
              !relative.contains("\\") else {
            return http(status: "404 Not Found", body: Data())
        }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= 20 * 1024 * 1024,
              let data = try? Data(floeContentsOf: candidate, options: [.mappedIfSafe]) else {
            return http(status: "404 Not Found", body: Data())
        }
        return http(
            status: "200 OK",
            mime: Self.mimeType(for: candidate.pathExtension),
            body: parts[0] == "HEAD" ? Data() : data,
            declaredLength: data.count
        )
    }

    private func http(
        status: String,
        mime: String = "text/plain; charset=utf-8",
        body: Data,
        declaredLength: Int? = nil
    ) -> Data {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(declaredLength ?? body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }

    private func resolveEntry(_ requested: String?) throws -> String {
        let candidates = [requested, "index.html", "public/index.html"].compactMap { $0 }
        for candidate in candidates {
            guard !candidate.isEmpty,
                  !candidate.split(separator: "/").contains(".."),
                  !candidate.hasPrefix("/") else { continue }
            let url = root.appendingPathComponent(candidate).standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if url.path.hasPrefix(rootPrefix), FileManager.default.fileExists(atPath: url.path) {
                return candidate
            }
        }
        throw FloeError.notFound("No preview entry file was found")
    }

    private static func mimeType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}

private final class PreviewContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim(for state: NWListener.State) -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            switch state {
            case .ready, .failed, .cancelled:
                resumed = true
                return true
            default:
                return false
            }
        }
    }
}

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
        let selectedRoot: URL
        if let relativeRoot, !relativeRoot.isEmpty {
            guard !relativeRoot.hasPrefix("/"), !relativeRoot.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("Preview root must be a safe workspace-relative path")
            }
            selectedRoot = root.appendingPathComponent(relativeRoot)
        } else {
            selectedRoot = root
        }
        server?.stop()
        let started = try await LocalPreviewServer.start(root: selectedRoot, entry: entry)
        server = started.0
        session = started.1
        activeURL = started.1.url
        browser.requestPresentation()
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
        browser.requestPresentation()
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
    static let toolDescription = "Serve static files from the current task workspace and open them in Floe's visible browser"
    static let parametersJSON = #"{"type":"object","properties":{"root":{"type":"string"},"entry":{"type":"string"}},"additionalProperties":false}"#
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
