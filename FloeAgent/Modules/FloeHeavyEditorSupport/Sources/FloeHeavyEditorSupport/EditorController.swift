// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import WebKit

@MainActor @Observable public final class HeavyEditorController: NSObject {
    public let descriptor: HeavyEditorDescriptor
    public private(set) var document: HeavyEditorDocument
    public private(set) var isReady = false
    public private(set) var isWorking = false
    public private(set) var engineDiagnostics: [String] = []
    public private(set) var presentation: EditorJSON = .object([:])
    public private(set) var commandCatalog: [EditorJSON] = []
    public var nativeModal: HeavyEditorNativeModal?
    public var errorMessage: String?
    public var importRequested = false
    public private(set) var importCommand = "file.import"
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
    @ObservationIgnored private var activeAuthorizer: HeavyEditorOperationAuthorizer?
    @ObservationIgnored private var activeAccess: HeavyEditorAccess = .read
    @ObservationIgnored private var activeNativeOperation: UUID?
    @ObservationIgnored private var activeNativeInvocations: Set<UUID> = []
    @ObservationIgnored private var navigationBridge: HeavyEditorNavigation?
    @ObservationIgnored private var messageBridge: HeavyEditorMessageBridge?
    @ObservationIgnored private var presentationRefresh: Task<Void, Never>?

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
        return """
        Object.defineProperty(globalThis,'FloeBundledBinaryAssets',{value:Object.freeze(\(json)),writable:false,configurable:false});
        const floeEngineFailure = value => globalThis.webkit?.messageHandlers?.floeEditor?.postMessage({type:'engineFailure',message:String(value).slice(0,2048)});
        globalThis.addEventListener('error',event=>floeEngineFailure(event.message));
        globalThis.addEventListener('unhandledrejection',event=>floeEngineFailure(event.reason?.stack??event.reason?.message??event.reason));
        """
    }

    public func reload() async throws {
        let fresh = try await store.read()
        guard fresh.id == document.id, fresh.kind == descriptor.kind else { throw HeavyEditorError.wrongDocument }
        document = fresh
        _ = try await call("return JSON.stringify(await window.FloeEditor.load(value));", value: try encoded(document))
        if isReady { try await refreshPresentation() }
    }
    public func refreshPresentation() async throws {
        guard isReady else { return }
        try await hooks.authorize(access(.read, "document.presentation"))
        let value = try await call("return JSON.stringify({presentation:window.FloeEditor.nativeSnapshot(),commands:window.FloeEditor.commandIndex()});", value: .null)
        presentation = value["presentation"]; commandCatalog = value["commands"].array
    }
    public func commandForm(_ name: String, arguments: EditorJSON = .object([:]), discovery: HeavyEditorDiscoveryPage? = nil, authorization: HeavyEditorOperationAuthorizer? = nil) async throws -> EditorJSON {
        try await waitUntilReady()
        guard allowedCommands.contains(name) else { throw HeavyEditorError.invalidCommand }
        try await authorize(.read, "document.parameters", using: authorization)
        return try await call("return JSON.stringify(window.FloeEditor.formDescription(value.command,value.arguments,value.discovery));",
            value: .object(["command": .string(name), "arguments": arguments, "discovery": try discovery.map(encoded) ?? .null]))
    }
    public func showCommand(_ name: String, preset: EditorJSON = .object([:])) {
        guard isReady, allowedCommands.contains(name) else { return }
        let metadata = commandCatalog.first { $0["id"].string == name }
        if metadata?["access"].string == "importFile" { requestImport(name); return }
        if metadata?["fields"].array.isEmpty == true {
            runCommand(name, arguments: preset, showResult: metadata?["access"].string == "read" && metadata?["sideEffecting"].bool != true)
            return
        }
        nativeModal = .command(.init(command: name, arguments: preset, baseRevision: document.revision))
    }
    public func requestImport(_ command: String = "file.import") {
        guard allowedCommands.contains(command) else { return }
        importCommand = command; importRequested = true
    }
    public func runCommand(_ name: String, arguments: EditorJSON = .object([:]), showResult: Bool = false) {
        Task { @MainActor [self] in
            do {
                let response = try await execute(name, arguments: arguments)
                if showResult { presentResult(name, value: response["result"]) }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    public func presentResult(_ command: String, value: EditorJSON) {
        let title = commandCatalog.first { $0["id"].string == command }?["title"].string ?? descriptor.title
        nativeModal = .result(.init(title: title, value: value))
    }
    private func schedulePresentationRefresh() {
        guard isReady, !isWorking, presentationRefresh == nil else { return }
        presentationRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            defer { self.presentationRefresh = nil }
            guard !self.isWorking else { return }
            do { try await self.refreshPresentation() } catch { self.errorMessage = error.localizedDescription }
        }
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
    public func describe(command: String? = nil, arguments: EditorJSON = .object([:]), discovery: HeavyEditorDiscoveryPage = .init(), authorization: HeavyEditorOperationAuthorizer? = nil) async throws -> EditorJSON {
        try await waitUntilReady()
        guard !isWorking else { throw HeavyEditorError.unavailable }
        let revision = document.revision
        try await authorize(.read, "document.describe", using: authorization)
        let details = try await call("return JSON.stringify({commands:window.FloeEditor.commandIndex().filter(command=>!command.hidden),selection:window.FloeEditor.selection??null});", value: .null)
        var value: [String: EditorJSON] = ["projectID": .string(document.id.uuidString), "kind": .string(descriptor.kind.rawValue),
            "title": .string(document.title), "baseRevision": .number(Double(revision)),
            "commands": details["commands"], "selection": details["selection"]]
        if allowedCommands.contains("file.import") { value["importCommand"] = .string("file.import") }
        if let command {
            let metadata = try await commandMetadata(command)
            guard metadata["hidden"] != .bool(true) || command == "file.import" else { throw HeavyEditorError.invalidCommand }
            var form = try await commandForm(command, arguments: arguments, discovery: discovery, authorization: authorization).object
            if command == "file.import" {
                form["fields"] = .array((form["fields"]?.array ?? []).filter { !["name", "base64"].contains($0["key"].string ?? "") })
            }
            value["form"] = .object(form)
        }
        guard !isWorking, document.revision == revision else { throw HeavyEditorError.revisionConflict }
        let result = EditorJSON.object(value)
        guard try result.data().count <= 512 * 1024 else { throw HeavyEditorError.engine("Use a narrower command or selection for parameter discovery.") }
        return result
    }
    public func commandMetadata(_ name: String) async throws -> EditorJSON {
        try await waitUntilReady()
        guard allowedCommands.contains(name) else { throw HeavyEditorError.invalidCommand }
        return try await call("return JSON.stringify(window.FloeEditor.command(value));", value: .string(name))
    }
    public func execute(_ name: String, arguments: EditorJSON = .object([:]), expectedRevision: UInt64? = nil, authorization: HeavyEditorOperationAuthorizer? = nil) async throws -> EditorJSON {
        try Task.checkCancellation()
        guard isReady, allowedCommands.contains(name) else { throw HeavyEditorError.invalidCommand }
        guard requests.count < 256 else { throw HeavyEditorError.unavailable }
        let id = UUID()
        let predecessor = tail
        let task = Task { @MainActor [self] in
            _ = try? await predecessor?.value
            try Task.checkCancellation()
            return try await perform(name, arguments: arguments, expectedRevision: expectedRevision, operationID: id, authorization: authorization)
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
        if let cancel = nativeExtension?.cancelInvocation {
            let owned = activeNativeInvocations
            Task { for nativeID in owned { await cancel(nativeID, command) } }
        } else if activeNativeOperation != nil, let cancel = nativeExtension?.cancel {
            Task { await cancel(command) }
        }
    }
    /// Call on real editor navigation/close, not a transient view reconstruction.
    /// Long calculations remain service-owned; a transport may stop its own audio.
    public func endPresentation() async { await nativeExtension?.presentationClosed?() }
    public func importFile(name: String, data: Data, arguments: EditorJSON = .object([:]), expectedRevision: UInt64? = nil, authorization: HeavyEditorOperationAuthorizer? = nil) async throws {
        let metadata = try await commandMetadata("file.import")
        let payloadFields: Set<String> = ["name", "base64"]
        let optionFields = Set(metadata["fields"].array.compactMap { $0["key"].string }).subtracting(payloadFields)
        guard case .object(var values) = arguments, Set(values.keys).isSubset(of: optionFields) else { throw HeavyEditorError.invalidCommand }
        values["name"] = .string(name); values["base64"] = .string(data.base64EncodedString())
        _ = try await execute("file.import", arguments: .object(values), expectedRevision: expectedRevision, authorization: authorization)
    }
    public func save() async throws {
        _ = try await execute("document.save")
    }
    fileprivate func ready() async {
        do {
            try await hooks.authorize(access(.read, "document.open"))
            let catalog = try await call("return JSON.stringify(window.FloeEditor.commandIndex());", value: .null)
            allowedCommands = Set(catalog.array.compactMap { $0["id"].string })
            _ = try await call("await window.FloeEditor.setNativeChrome(true);return 'null';", value: .null)
            try await reload(); isReady = true
            try await refreshPresentation()
        } catch {
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"].map { String(describing: $0) } ?? error.localizedDescription
            engineDiagnostics.append(String(detail.prefix(2048)))
            if engineDiagnostics.count > 8 { engineDiagnostics.removeFirst(engineDiagnostics.count - 8) }
            errorMessage = EditorText.t("无法打开编辑器，请重新打开后继续。", "Unable to open the editor. Reopen it to continue.")
        }
    }
    fileprivate func receive(_ message: EditorJSON) async {
        let id = message["requestID"].string ?? ""
        do {
            switch message["type"].string {
            case "showCommand": if let command = message["command"].string { showCommand(command, preset: message["arguments"]) }; return
            case "showResult":
                nativeModal = .result(.init(title: message["title"].string ?? descriptor.title, value: message["value"]))
                return
            case "presentationChanged": schedulePresentationRefresh(); return
            case "engineFailure":
                engineDiagnostics.append(String((message["message"].string ?? "Unknown engine failure").prefix(2048)))
                if engineDiagnostics.count > 8 { engineDiagnostics.removeFirst(engineDiagnostics.count - 8) }
                if !isReady { errorMessage = EditorText.t("无法打开编辑器，请重新打开后继续。", "Unable to open the editor. Reopen it to continue.") }
                return
            case "ready": await ready(); return
            case "import": importRequested = true; return
            case "assistant": onAssistant?(); return
            case "native":
                guard isWorking, let nativeCapability, message["token"].string == nativeCapability,
                      let operation = message["operation"].string,
                      let nativeExtension, nativeExtension.operations.contains(operation) else { throw HeavyEditorError.invalidCommand }
                guard let activeOperation, let activeCommand else { throw HeavyEditorError.invalidCommand }
                try await authorize(activeAccess, activeCommand, using: activeAuthorizer)
                guard self.activeOperation == activeOperation, message["token"].string == self.nativeCapability,
                      requests[activeOperation]?.isCancelled == false else { throw CancellationError() }
                let nativeCallID = UUID(); activeNativeOperation = nativeCallID; activeNativeInvocations.insert(nativeCallID)
                defer { if activeNativeOperation == nativeCallID { activeNativeOperation = nil } }
                let response: EditorJSON
                if let run = nativeExtension.runInvocation { response = try await run(nativeCallID, operation, message["arguments"]) }
                else { response = try await nativeExtension.run(operation, message["arguments"]) }
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
    private func authorize(_ mode: HeavyEditorAccess, _ command: String, using authorization: HeavyEditorOperationAuthorizer?) async throws {
        try Task.checkCancellation()
        let request = access(mode, command)
        try await authorization?(request)
        try await hooks.authorize(request)
        try Task.checkCancellation()
    }
    private func perform(_ name: String, arguments: EditorJSON, expectedRevision: UInt64?, operationID: UUID, authorization: HeavyEditorOperationAuthorizer?) async throws -> EditorJSON {
        if let expectedRevision, expectedRevision != document.revision { throw HeavyEditorError.revisionConflict }
        isWorking = true; activeOperation = operationID; activeCommand = name; activeAuthorizer = authorization; activeNativeInvocations = []
        defer { isWorking = false; activeOperation = nil; activeCommand = nil; activeAuthorizer = nil; activeAccess = .read; activeNativeInvocations = [] }
        // Mutation/access metadata comes from the bundled registry, never caller fields.
        let metadata = try await call("return JSON.stringify(window.FloeEditor.command(value));", value: .string(name))
        let mode = HeavyEditorAccess(rawValue: metadata["access"].string ?? "read") ?? .read
        activeAccess = mode
        try await authorize(mode, name, using: authorization)
        let capability = UUID().uuidString
        nativeCapability = capability
        defer { nativeCapability = nil }
        let request: EditorJSON = .object(["command": .string(name), "arguments": arguments, "revision": .number(Double(document.revision)), "nativeToken": .string(capability)])
        do {
            let response = try await call("return JSON.stringify(await window.FloeEditor.execute(value));", value: request)
            try Task.checkCancellation()
            if mode == .edit || mode == .importFile {
                try await authorize(mode, name, using: authorization)
                try Task.checkCancellation()
                let updated = try await store.commit(content: response["state"], title: response["state"]["data"]["title"].string, expectedRevision: document.revision)
                document = updated; await hooks.didSave(updated)
            }
            var receipts: [EditorJSON] = []
            for item in response["artifacts"].array {
                try await authorize(.exportFile, name, using: authorization)
                try Task.checkCancellation()
                guard let filename = item["name"].string, let media = item["mediaType"].string,
                      let base64 = item["base64"].string, let bytes = Data(base64Encoded: base64) else { throw HeavyEditorError.invalidDocument }
                let receipt = try await hooks.export(document.id, HeavyEditorArtifact(name: filename, mediaType: media, data: bytes))
                receipts.append(try encoded(receipt))
            }
            _ = try await call("window.FloeEditor.acknowledge(value); return 'null';", value: .number(Double(document.revision)))
            try await refreshPresentation()
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
        // Foundation may intern empty NSArray instances. Passing the decoded
        // object graph through WK preserves those aliases: modifying glyphs[]
        // could then also modify axes[]/masters[]. Transfer JSON values as text
        // and parse inside the page so every array/object has JSON semantics.
        let argument = String(decoding: try value.data(), as: UTF8.self)
        let result = try await webView.callAsyncJavaScript("const value=JSON.parse(serializedValue);\n" + body,
            arguments: ["serializedValue": argument], in: nil, contentWorld: .page)
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
