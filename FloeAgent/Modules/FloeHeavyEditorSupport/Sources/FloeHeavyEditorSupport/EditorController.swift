// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import WebKit

@MainActor @Observable public final class HeavyEditorController: NSObject {
    public let descriptor: HeavyEditorDescriptor
    public private(set) var document: HeavyEditorDocument
    public private(set) var isReady = false
    public private(set) var isWorking = false
    public var errorMessage: String?
    public var importRequested = false
    public var onAssistant: (() -> Void)?
    @ObservationIgnored public let webView: WKWebView
    @ObservationIgnored private let store: HeavyEditorProjectStore
    @ObservationIgnored private let owner: HeavyEditorOwner
    @ObservationIgnored private let hooks: HeavyEditorHostHooks
    @ObservationIgnored private let nativeExtension: HeavyEditorNativeExtension?
    @ObservationIgnored private var nativeCapability: String?
    @ObservationIgnored private var allowedCommands: Set<String> = []
    @ObservationIgnored private var tail: Task<EditorJSON, any Error>?
    @ObservationIgnored private var tailID: UUID?
    @ObservationIgnored private var requests: [UUID: Task<EditorJSON, any Error>] = [:]
    @ObservationIgnored private var activeOperation: UUID?
    @ObservationIgnored private var activeCommand: String?
    @ObservationIgnored private var navigationBridge: HeavyEditorNavigation?
    @ObservationIgnored private var messageBridge: HeavyEditorMessageBridge?

    public init(descriptor: HeavyEditorDescriptor, document: HeavyEditorDocument,
                store: HeavyEditorProjectStore, owner: HeavyEditorOwner, hooks: HeavyEditorHostHooks,
                nativeExtension: HeavyEditorNativeExtension? = nil) throws {
        guard descriptor.kind == document.kind else { throw HeavyEditorError.wrongDocument }
        self.descriptor = descriptor; self.document = document; self.store = store; self.owner = owner; self.hooks = hooks
        self.nativeExtension = nativeExtension
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(HeavyEditorResourceHandler(root: descriptor.resourceRoot), forURLScheme: "floe-editor")
        // WebKit's custom URL scheme does not provide fetch/XHR for WASM on
        // every Apple target. Bootstrap only fixed, bundled binary assets;
        // this exposes no host file reader, project data or model-selected URL.
        configuration.userContentController.addUserScript(WKUserScript(
            source: try Self.binaryAssetsScript(root: descriptor.resourceRoot),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let messages = HeavyEditorMessageBridge(); messages.controller = self
        configuration.userContentController.add(messages, name: "floeEditor")
        messageBridge = messages
        let navigation = HeavyEditorNavigation(); navigation.controller = self
        webView.navigationDelegate = navigation; navigationBridge = navigation
        webView.load(URLRequest(url: URL(string: "floe-editor://bundle/index.html")!))
    }

    private static func binaryAssetsScript(root: URL) throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var assets: [String: String] = [:]
        var total = 0
        for file in try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            where file.pathExtension == "wasm" {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                  size >= 0, size <= 32 * 1024 * 1024 - total,
                  file.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path else {
                throw HeavyEditorError.invalidDocument
            }
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard bytes.count == size else { throw HeavyEditorError.invalidDocument }
            total += size; assets[file.lastPathComponent] = bytes.base64EncodedString()
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: assets, options: [.sortedKeys]), as: UTF8.self)
        return "Object.defineProperty(globalThis,'FloeBundledBinaryAssets',{value:Object.freeze(" + json + "),writable:false,configurable:false});"
    }

    public func reload() async throws {
        let fresh = try await store.read()
        guard fresh.id == document.id, fresh.kind == descriptor.kind else { throw HeavyEditorError.wrongDocument }
        document = fresh
        _ = try await call("return JSON.stringify(await window.FloeEditor.load(value));", value: try encoded(document))
    }
    public func waitUntilReady(timeout: Duration = .seconds(30)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isReady {
            try Task.checkCancellation()
            if let errorMessage { throw HeavyEditorError.engine(errorMessage) }
            guard ContinuousClock.now < deadline else { throw HeavyEditorError.unavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    public func describe() async throws -> EditorJSON {
        try await waitUntilReady()
        try await hooks.authorize(access(.read, "document.describe"))
        let details = try await call("return JSON.stringify({commands:window.FloeEditor.catalog(),selection:window.FloeEditor.selection??null});", value: .null)
        return .object(["projectID": .string(document.id.uuidString), "kind": .string(descriptor.kind.rawValue),
                        "title": .string(document.title), "baseRevision": .number(Double(document.revision)),
                        "commands": details["commands"], "selection": details["selection"]])
    }
    public func commandMetadata(_ name: String) async throws -> EditorJSON {
        try await waitUntilReady()
        guard allowedCommands.contains(name) else { throw HeavyEditorError.invalidCommand }
        return try await call("return JSON.stringify(window.FloeEditor.command(value));", value: .string(name))
    }
    public func execute(_ name: String, arguments: EditorJSON = .object([:]), expectedRevision: UInt64? = nil) async throws -> EditorJSON {
        try Task.checkCancellation()
        guard isReady, allowedCommands.contains(name) else { throw HeavyEditorError.invalidCommand }
        guard requests.count < 256 else { throw HeavyEditorError.unavailable }
        let id = UUID()
        let predecessor = tail
        let task = Task { @MainActor [self] in
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            return try await perform(name, arguments: arguments, expectedRevision: expectedRevision, operationID: id)
        }
        tail = task; tailID = id; requests[id] = task
        defer { requests[id] = nil; if tailID == id { tail = nil; tailID = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                if self?.activeOperation == id { self?.abortEngine() }
            }
        }
    }
    public func cancel() {
        if let activeOperation { requests[activeOperation]?.cancel() }
        abortEngine()
    }
    private func abortEngine() {
        // Computation workers receive the same cancellation request; no guest or
        // host process is created by this internal editor service.
        webView.evaluateJavaScript("window.FloeEditor?.cancel()", completionHandler: nil)
        let command = activeCommand ?? ""
        if let cancel = nativeExtension?.cancel { Task { await cancel(command) } }
    }
    /// Call on real editor navigation/close, not a transient view reconstruction.
    /// Long calculations remain service-owned; a transport may stop its own audio.
    public func endPresentation() async { await nativeExtension?.presentationClosed?() }
    public func importFile(name: String, data: Data, expectedRevision: UInt64? = nil) async throws {
        _ = try await execute("file.import", arguments: .object(["name": .string(name), "base64": .string(data.base64EncodedString())]), expectedRevision: expectedRevision)
    }
    public func save() async throws {
        _ = try await execute("document.save")
    }
    fileprivate func ready() async {
        do {
            try await hooks.authorize(access(.read, "document.open"))
            let catalog = try await call("return JSON.stringify(window.FloeEditor.catalog());", value: .null)
            allowedCommands = Set(catalog.array.compactMap { $0["id"].string })
            try await reload(); isReady = true
        } catch { errorMessage = error.localizedDescription }
    }
    fileprivate func receive(_ message: EditorJSON) async {
        let id = message["requestID"].string ?? ""
        do {
            switch message["type"].string {
            case "ready": await ready(); return
            case "import": importRequested = true; return
            case "assistant": onAssistant?(); return
            case "native":
                guard isWorking, let nativeCapability, message["token"].string == nativeCapability,
                      let operation = message["operation"].string,
                      let nativeExtension, nativeExtension.operations.contains(operation) else { throw HeavyEditorError.invalidCommand }
                let response = try await nativeExtension.run(operation, message["arguments"])
                await reply(id, result: response, error: nil)
            case "request":
                guard let command = message["command"].string else { throw HeavyEditorError.invalidCommand }
                let revision = message["revision"].number.flatMap { $0 >= 0 && $0 < Double(UInt64.max) ? UInt64($0) : nil }
                let response = try await execute(command, arguments: message["arguments"], expectedRevision: revision)
                await reply(id, result: response, error: nil)
            default: throw HeavyEditorError.invalidCommand
            }
        } catch {
            errorMessage = error.localizedDescription
            await reply(id, result: .null, error: error.localizedDescription)
        }
    }
    private func access(_ mode: HeavyEditorAccess, _ command: String) -> HeavyEditorAccessRequest {
        HeavyEditorAccessRequest(documentID: document.id, owner: owner, revision: document.revision, access: mode, command: command)
    }
    private func perform(_ name: String, arguments: EditorJSON, expectedRevision: UInt64?, operationID: UUID) async throws -> EditorJSON {
        if let expectedRevision, expectedRevision != document.revision { throw HeavyEditorError.revisionConflict }
        isWorking = true; activeOperation = operationID; activeCommand = name
        defer { isWorking = false; activeOperation = nil; activeCommand = nil }
        // Mutation/access metadata comes from the bundled registry, never caller fields.
        let metadata = try await call("return JSON.stringify(window.FloeEditor.command(value));", value: .string(name))
        let mode = HeavyEditorAccess(rawValue: metadata["access"].string ?? "read") ?? .read
        try await hooks.authorize(access(mode, name))
        let capability = UUID().uuidString
        nativeCapability = capability
        defer { nativeCapability = nil }
        let request: EditorJSON = .object(["command": .string(name), "arguments": arguments, "revision": .number(Double(document.revision)), "nativeToken": .string(capability)])
        do {
            let response = try await call("return JSON.stringify(await window.FloeEditor.execute(value));", value: request)
            try Task.checkCancellation()
            if mode == .edit || mode == .importFile {
                try await hooks.authorize(access(mode, name))
                try Task.checkCancellation()
                let updated = try await store.commit(content: response["state"], title: response["state"]["data"]["title"].string, expectedRevision: document.revision)
                document = updated; await hooks.didSave(updated)
            }
            var receipts: [EditorJSON] = []
            for item in response["artifacts"].array {
                try await hooks.authorize(access(.exportFile, name))
                try Task.checkCancellation()
                guard let filename = item["name"].string, let media = item["mediaType"].string,
                      let base64 = item["base64"].string, let bytes = Data(base64Encoded: base64) else { throw HeavyEditorError.invalidDocument }
                let receipt = try await hooks.export(document.id, HeavyEditorArtifact(name: filename, mediaType: media, data: bytes))
                receipts.append(try encoded(receipt))
            }
            _ = try await call("window.FloeEditor.acknowledge(value); return 'null';", value: .number(Double(document.revision)))
            if case .object(var object) = response { object["exports"] = .array(receipts); return .object(object) }
            throw HeavyEditorError.invalidDocument
        } catch {
            // Retain the durable original if engine execution or a staged save fails.
            try? await reload()
            throw error
        }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> EditorJSON { try EditorJSON.decode(JSONEncoder().encode(value)) }
    private func call(_ body: String, value: EditorJSON) async throws -> EditorJSON {
        let argument = try JSONSerialization.jsonObject(with: value.data(), options: [.fragmentsAllowed])
        let result = try await webView.callAsyncJavaScript(body, arguments: ["value": argument], in: nil, contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8) else { throw HeavyEditorError.invalidDocument }
        return try EditorJSON.decode(data)
    }
    private func reply(_ id: String, result: EditorJSON, error: String?) async {
        let value: EditorJSON = .object(["requestID": .string(id), "result": result, "error": error.map(EditorJSON.string) ?? .null])
        _ = try? await call("window.FloeEditor.hostReply(value); return 'null';", value: value)
    }
}

@MainActor private final class HeavyEditorMessageBridge: NSObject, WKScriptMessageHandler {
    weak var controller: HeavyEditorController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == "floe-editor",
              let data = try? JSONSerialization.data(withJSONObject: message.body), let value = try? EditorJSON.decode(data) else { return }
        Task { await controller?.receive(value) }
    }
}
@MainActor private final class HeavyEditorNavigation: NSObject, WKNavigationDelegate {
    weak var controller: HeavyEditorController?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        return url?.scheme == "floe-editor" && url?.host == "bundle" ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        controller?.errorMessage = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        controller?.errorMessage = error.localizedDescription
    }
}

private final class HeavyEditorResourceHandler: NSObject, WKURLSchemeHandler {
    private let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url, url.host == "bundle" else { throw HeavyEditorError.invalidDocument }
            let target = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/"), try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw HeavyEditorError.invalidDocument }
            let data = try Data(contentsOf: target)
            let mime = ["html":"text/html", "js":"application/javascript", "css":"text/css", "wasm":"application/wasm", "json":"application/json", "woff2":"font/woff2", "svg":"image/svg+xml", "ttf":"font/ttf"][target.pathExtension] ?? "application/octet-stream"
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { }
}
