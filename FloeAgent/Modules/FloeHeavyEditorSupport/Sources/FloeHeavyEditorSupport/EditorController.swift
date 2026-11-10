// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import WebKit

@MainActor @Observable public final class HeavyEditorController: NSObject {
    public let descriptor: HeavyEditorDescriptor
    public private(set) var document: HeavyEditorDocument
    public private(set) var isReady = false
    public private(set) var isWorking = false
    public private(set) var queuedOperationCount = 0
    public private(set) var operationPhase: HeavyEditorOperationPhase = .preparing
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
    @ObservationIgnored private let operationQueue = HeavyEditorOperationQueue<EditorJSON>()
    @ObservationIgnored private let callbackBridge = HeavyEditorCallbackBridge<EditorJSON>()
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
        let nativeOperations = try JSONEncoder().encode((nativeExtension?.operations ?? []).sorted())
        configuration.userContentController.addUserScript(WKUserScript(
            source: try Self.binaryAssetsScript(root: descriptor.resourceRoot)
                + "\nglobalThis.FloeEditorNativeOperations="
                + String(decoding: nativeOperations, as: UTF8.self) + ";",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        operationQueue.onStateChanged = { [weak self] in
            guard let self else { return }
            self.queuedOperationCount = self.operationQueue.pendingCount
            if !self.isWorking, self.isReady {
                self.operationPhase = self.queuedOperationCount > 0 ? .queued : .idle
            }
        }
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
        try await refreshPresentation(owner: nil)
    }
    private func refreshPresentation(owner: UUID?) async throws {
        guard isReady else { return }
        let value = try await readPresentation(owner: owner)
        presentation = value["presentation"]; commandCatalog = value["commands"].array
    }
    private func readPresentation(owner: UUID?) async throws -> EditorJSON {
        try await hooks.authorize(access(.read, "document.presentation"))
        return try await call("return JSON.stringify({presentation:window.FloeEditor.nativeSnapshot(),commands:window.FloeEditor.commandIndex()});", value: .null, owner: owner)
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
            } catch is CancellationError {
                // Stopping is an ordinary owned-operation outcome.
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
        do {
            return try await operationQueue.execute(onCancel: { [weak self] id in
                self?.abortEngine(ifOwned: id)
            }) { [self] id in
                guard isReady, callbackBridge.isValid else { throw HeavyEditorError.unavailable }
                return try await perform(name, arguments: arguments, expectedRevision: expectedRevision,
                    operationID: id, authorization: authorization)
            }
        } catch HeavyEditorOperationStateError.queueFull {
            throw HeavyEditorError.engine(EditorText.t("操作正在排队，请稍后再试。", "Several operations are queued. Try again shortly."))
        }
    }
    /// Recheck the same queued native continuation before its host commits a
    /// long-running result. This cannot create/adopt a call or change authority.
    public func validateNativeContinuation(_ invocationID: UUID, command: String) async throws {
        guard let operation = activeOperation, activeCommand == command,
              activeNativeInvocations.contains(invocationID), nativeCapability != nil,
              callbackBridge.isValid, operationQueue.isActive(operation) else { throw CancellationError() }
        let generation = callbackBridge.generation
        try await authorize(activeAccess, command, using: activeAuthorizer)
        try Task.checkCancellation()
        guard activeOperation == operation, activeCommand == command,
              activeNativeInvocations.contains(invocationID), nativeCapability != nil,
              callbackBridge.isValid, callbackBridge.generation == generation,
              operationQueue.isActive(operation) else { throw CancellationError() }
    }
    public func cancel() {
        if isWorking { operationPhase = .stopping }
        operationQueue.cancelActive()
    }
    private func abortEngine(ifOwned operationID: UUID?) {
        guard let operationID, activeOperation == operationID else { return }
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
        guard callbackBridge.isValid else { return }
        let generation = callbackBridge.generation
        do {
            try await hooks.authorize(access(.read, "document.open"))
            let catalog = try await call("return JSON.stringify(window.FloeEditor.commandIndex());", value: .null)
            allowedCommands = Set(catalog.array.compactMap { $0["id"].string })
            _ = try await call("await window.FloeEditor.setNativeChrome(true);return 'null';", value: .null)
            try await reload()
            let loadedDocument = document
            // Publish readiness only after the same live page has supplied its
            // first native snapshot and commands for this loaded original.
            let value = try await readPresentation(owner: nil)
            try Task.checkCancellation()
            guard callbackBridge.isValid, callbackBridge.generation == generation,
                  document == loadedDocument else { throw CancellationError() }
            presentation = value["presentation"]; commandCatalog = value["commands"].array
            isReady = true; operationPhase = .idle
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
                      operationQueue.isActive(activeOperation) else { throw CancellationError() }
                let nativeCallID = UUID(); activeNativeOperation = nativeCallID; activeNativeInvocations.insert(nativeCallID)
                let expectedGeneration = callbackBridge.generation
                defer {
                    activeNativeInvocations.remove(nativeCallID)
                    if activeNativeOperation == nativeCallID { activeNativeOperation = nil }
                }
                // A cancelled native call may still return. Reply only to its
                // original page/operation; a cancelled result only rejects that
                // original JS promise so it can actually settle.
                do {
                    let response: EditorJSON
                    if let run = nativeExtension.runInvocation { response = try await run(nativeCallID, operation, message["arguments"]) }
                    else { response = try await nativeExtension.run(operation, message["arguments"]) }
                    guard self.activeOperation == activeOperation, callbackBridge.isValid,
                          callbackBridge.generation == expectedGeneration,
                          message["token"].string == self.nativeCapability else { return }
                    if operationQueue.isActive(activeOperation) {
                        await reply(id, result: response, error: nil, owner: activeOperation)
                    } else {
                        await reply(id, result: .null, error: EditorText.t("已取消。", "Cancelled."), owner: activeOperation)
                    }
                } catch {
                    guard self.activeOperation == activeOperation, callbackBridge.isValid,
                          callbackBridge.generation == expectedGeneration,
                          message["token"].string == self.nativeCapability else { return }
                    let detail = operationQueue.isActive(activeOperation) ? error.localizedDescription : EditorText.t("已取消。", "Cancelled.")
                    await reply(id, result: .null, error: detail, owner: activeOperation)
                }
            case "request":
                guard let command = message["command"].string else { throw HeavyEditorError.invalidCommand }
                let revision = message["revision"].number.flatMap { $0 >= 0 && $0 < Double(UInt64.max) ? UInt64($0) : nil }
                let response = try await execute(command, arguments: message["arguments"], expectedRevision: revision)
                await reply(id, result: response, error: nil)
            default: throw HeavyEditorError.invalidCommand
            }
        } catch {
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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
        defer { isWorking = false; activeOperation = nil; activeCommand = nil; activeAuthorizer = nil; activeAccess = .read; activeNativeInvocations = []; operationPhase = callbackBridge.isValid ? (queuedOperationCount > 0 ? .queued : .idle) : .unavailable }
        operationPhase = .authorizing
        // Mutation/access metadata comes from the bundled registry, never caller fields.
        let metadata = try await call("return JSON.stringify(window.FloeEditor.command(value));", value: .string(name), owner: operationID)
        let mode = HeavyEditorAccess(rawValue: metadata["access"].string ?? "read") ?? .read
        activeAccess = mode
        try await authorize(mode, name, using: authorization)
        let capability = UUID().uuidString
        nativeCapability = capability
        defer { nativeCapability = nil }
        let request: EditorJSON = .object(["command": .string(name), "arguments": arguments, "revision": .number(Double(document.revision)), "nativeToken": .string(capability)])
        do {
            operationPhase = .running
            let response = try await call("return JSON.stringify(await window.FloeEditor.execute(value));", value: request, timeout: .seconds(180), owner: operationID)
            try Task.checkCancellation()
            if mode == .edit || mode == .importFile {
                try await authorize(mode, name, using: authorization)
                try Task.checkCancellation()
                operationPhase = .saving
                let updated = try await store.commit(content: response["state"], title: response["state"]["data"]["title"].string, expectedRevision: document.revision)
                document = updated; await hooks.didSave(updated)
            }
            operationPhase = .returning
            var receipts: [EditorJSON] = []
            for item in response["artifacts"].array {
                try await authorize(.exportFile, name, using: authorization)
                try Task.checkCancellation()
                guard let filename = item["name"].string, let media = item["mediaType"].string,
                      let base64 = item["base64"].string, let bytes = Data(base64Encoded: base64) else { throw HeavyEditorError.invalidDocument }
                let receipt = try await hooks.export(document.id, HeavyEditorArtifact(name: filename, mediaType: media, data: bytes))
                receipts.append(try encoded(receipt))
            }
            _ = try await call("window.FloeEditor.acknowledge(value); return 'null';", value: .number(Double(document.revision)), owner: operationID)
            try await refreshPresentation(owner: operationID)
            if case .object(var object) = response { object["exports"] = .array(receipts); return .object(object) }
            throw HeavyEditorError.invalidDocument
        } catch {
            // Cancellation is a caller outcome, not proof that JS stopped.
            // Hold this operation's FIFO slot until actual provider settlement
            // and a bounded restore, or quarantine this page generation.
            abortEngine(ifOwned: operationID)
            if error is CancellationError { operationPhase = .stopping }
            await restoreAfterFailure(operationID: operationID)
            throw error
        }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> EditorJSON { try EditorJSON.decode(JSONEncoder().encode(value)) }
    private func call(_ body: String, value: EditorJSON, timeout: Duration = .seconds(15), owner: UUID? = nil, allowCancelledOwner: Bool = false) async throws -> EditorJSON {
        // JSON text preserves value semantics across WK's Foundation bridge.
        let argument = String(decoding: try value.data(), as: UTF8.self)
        // Discovery and independent presentation calls do not inherit another
        // operation's cancellation authority from whichever command is active.
        let expectedGeneration = callbackBridge.generation
        do {
            return try await callbackBridge.perform(timeout: timeout, owner: owner,
                onCancel: { [weak self] in self?.abortEngine(ifOwned: owner) },
                onTimeout: { [weak self] in self?.invalidatePage(ifOwned: owner) }) { [self] complete in
                webView.callAsyncJavaScript("const value=JSON.parse(serializedValue);\n" + body,
                    arguments: ["serializedValue": argument], in: nil, in: .page) { [weak self] result in
                    guard let self, self.callbackBridge.isValid,
                          self.callbackBridge.generation == expectedGeneration else { return }
                    // Late completion settles the old provider but cannot
                    // publish a successful outcome for a cancelled operation.
                    if let owner, !allowCancelledOwner, !self.operationQueue.isActive(owner) {
                        complete(.failure(CancellationError())); return
                    }
                    do {
                        let raw = try result.get()
                        guard let text = raw as? String, let data = text.data(using: .utf8) else { throw HeavyEditorError.invalidDocument }
                        complete(.success(try EditorJSON.decode(data)))
                    } catch { complete(.failure(error)) }
                }
            }
        } catch HeavyEditorOperationStateError.timedOut {
            throw HeavyEditorError.engine(EditorText.t("操作超时，请重新打开作品后重试。", "The operation timed out. Reopen the work and try again."))
        } catch HeavyEditorOperationStateError.invalidated {
            throw HeavyEditorError.engine(EditorText.t("请重新打开作品后继续。", "Reopen the work to continue."))
        } catch HeavyEditorOperationStateError.queueFull {
            throw HeavyEditorError.engine(EditorText.t("操作正在排队，请稍后再试。", "Several operations are queued. Try again shortly."))
        }
    }
    private func invalidatePage(ifOwned owner: UUID?) {
        abortEngine(ifOwned: owner)
        isReady = false
        operationPhase = .unavailable
        callbackBridge.invalidate()
        errorMessage = EditorText.t("操作未能完成，请重新打开作品后重试。", "The operation could not finish. Reopen the work and try again.")
    }
    @MainActor private final class RecoveryWork {
        var task: Task<Void, Never>?
    }
    private func restoreAfterFailure(operationID: UUID) async {
        // This service-owned recovery task does not inherit the failed caller's
        // cancelled status. Both acknowledgement and recovery are bounded;
        // a late file read is checked before touching this page again.
        let recovery = Task { @MainActor [self] in
            guard callbackBridge.isValid, activeOperation == operationID else { return }
            guard await callbackBridge.waitForSettlement(owner: operationID, timeout: .seconds(3)) else {
                invalidatePage(ifOwned: operationID); return
            }
            let deadline = HeavyEditorCallbackBridge<Void>(), work = RecoveryWork()
            do {
                try await deadline.perform(timeout: .seconds(10), owner: operationID,
                    onTimeout: { [self] in work.task?.cancel(); invalidatePage(ifOwned: operationID) }) { [self] complete in
                    work.task = Task { @MainActor [self] in
                        do {
                            let fresh = try await store.read()
                            try Task.checkCancellation()
                            guard activeOperation == operationID, callbackBridge.isValid else { throw CancellationError() }
                            guard fresh.id == document.id, fresh.kind == descriptor.kind else { throw HeavyEditorError.wrongDocument }
                            document = fresh
                            _ = try await call("return JSON.stringify(await window.FloeEditor.load(value));", value: try encoded(fresh), timeout: .seconds(8), owner: operationID, allowCancelledOwner: true)
                            try Task.checkCancellation()
                            if isReady {
                                try await hooks.authorize(access(.read, "document.presentation"))
                                let value = try await call("return JSON.stringify({presentation:window.FloeEditor.nativeSnapshot(),commands:window.FloeEditor.commandIndex()});", value: .null, timeout: .seconds(8), owner: operationID, allowCancelledOwner: true)
                                try Task.checkCancellation()
                                guard activeOperation == operationID, callbackBridge.isValid else { throw CancellationError() }
                                presentation = value["presentation"]; commandCatalog = value["commands"].array
                            }
                            complete(.success(()))
                        } catch { complete(.failure(error)) }
                    }
                }
            } catch {
                work.task?.cancel()
                invalidatePage(ifOwned: operationID)
            }
            deadline.invalidate()
        }
        await recovery.value
    }
    private func reply(_ id: String, result: EditorJSON, error: String?, owner: UUID? = nil) async {
        let value: EditorJSON = .object(["requestID": .string(id), "result": result, "error": error.map(EditorJSON.string) ?? .null])
        _ = try? await call("window.FloeEditor.hostReply(value); return 'null';", value: value, owner: owner)
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
