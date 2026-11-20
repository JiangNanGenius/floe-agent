// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import WebKit
import FloeGameCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(UIKit)
@MainActor
private final class GameViewportWebView: WKWebView {
    private var notifiedSize: CGSize?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifiedSize = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard window != nil, size.width > 0, size.height > 0, notifiedSize != size else { return }
        notifiedSize = size
        // WebKit can finish loading offscreen without notifying the game when
        // its SwiftUI viewport is attached. Let layout settle before the event.
        evaluateJavaScript("requestAnimationFrame(() => window.dispatchEvent(new Event('resize'))); void 0")
    }
}
#endif

public enum GameInputDirection: String, Sendable { case left, right, up, down }
public enum GameInputButton: String, Sendable { case confirm, cancel, action1, action2, action3, action4, start, select }
public enum GamePointerPhase: String, Sendable { case began, moved, ended }
public enum GameWebPlayerError: Error { case notReady, invalidState, staleRun, unsupportedOperation, timedOut }

/// An actual offline WebKit adapter, owned by the host service rather than a View.
/// The only bridge messages are readiness and bounded logs. No native API,
/// credentials, network proxy, file operation or general evaluator is exposed.
@MainActor
public final class GameWebPlayer: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public let webView: WKWebView
    public let package: GameWebArtifactPackage
    public let plan: GameLaunchPlan
    /// Stable origin/store scope derived from the host-resolved project owner,
    /// engine and environment. Editing the source or rebuilding the artifact
    /// must not change this value.
    public let storageIdentity: GameWebStorageIdentity
    @Published public private(set) var loaded = false
    @Published public private(set) var gameReady = false
    @Published public private(set) var failure: String?
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var blockedNavigations = 0
    public private(set) var supportsInput = false
    public private(set) var supportsState = false
    public private(set) var lastSaveFlushStatus = GameWebSaveFlushStatus.notRequired
    /// Imported games can receive browser events without implementing Floe's
    /// optional state/input protocol. This does not claim their engine is ready.
    public var canSimulateInput: Bool { loaded || (gameReady && supportsInput) }
    private let handler: GameArtifactSchemeHandler
    private var generation = 0
    /// Host-observed run fence. Restarting the same player advances this value
    /// even when its project, source revision and storage identity are equal.
    public var runGeneration: Int { generation }
    private var lease: UUID?
    private var pressedKeys: Set<GameKeyboardKey> = []
    private var preparation: Task<Void, any Error>?
    private let saveFlush = GameWebSaveFlush()
    private struct PendingStop { let navigation: ObjectIdentifier; let continuation: CheckedContinuation<Bool, Never> }
    private var pendingStop: PendingStop?
    private struct PendingReply {
        let generation: Int
        let continuation: CheckedContinuation<Data, any Error>
    }
    private var pendingReplies: [UUID: PendingReply] = [:]
    private var developerConfiguration: GameDeveloperBridgeConfiguration?
    private var developerLease: GameDeveloperBridgeLease?

    public init(package: GameWebArtifactPackage, plan: GameLaunchPlan, current: GameProjectContext) throws {
        try plan.validate(current: current)
        guard plan.route == .webKit, plan.artifact == package.prepared else { throw GameProjectError.invalidArtifact }
        let identity = try package.prepared.storageIdentity()
        self.package = package; self.plan = plan; self.storageIdentity = identity
        handler = GameArtifactSchemeHandler(package: package, originHost: identity.originHost)
        let configuration = WKWebViewConfiguration()
        // Durable per-project browser storage (localStorage/IndexedDB) for the
        // imported game's own save system. This named store is isolated from
        // the default App/browser store and from every other project identity.
        configuration.websiteDataStore = GameWebStorage.persistentStore(for: identity)
        // Chat can own a running game without presenting a player window.
        // Keep its event loop available to input and frame capture at idle priority.
        configuration.preferences.inactiveSchedulingPolicy = .throttle
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(handler, forURLScheme: GameArtifactSchemeHandler.scheme)
        // Preparation loads the document before the player is attached to its
        // SwiftUI surface. Engines measure this viewport during startup.
        let initialViewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        #if os(macOS)
        webView = WKWebView(frame: initialViewport, configuration: configuration)
        #else
        webView = GameViewportWebView(frame: initialViewport, configuration: configuration)
        #endif
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self; webView.allowsLinkPreview = false
        configuration.userContentController.add(WeakGameBridge(owner: self), name: "floeGame")
    }

    public func start(current: GameProjectContext) async throws {
        try plan.validate(current: current)
        saveFlush.cancel()
        finishStop(false)
        cancelReplies()
        generation += 1; let token = generation
        loaded = false; gameReady = false; failure = nil; supportsInput = false; supportsState = false
        lastSaveFlushStatus = .notRequired
        lease = nil; pressedKeys.removeAll(); preparation?.cancel()
        webView.stopLoading()
        let oldReads = handler.cancelReads()
        for read in oldReads { _ = await read.result }
        guard token == generation else { throw GameWebPlayerError.staleRun }
        let package = package
        let verify = Task.detached { try package.verify() }
        preparation = verify
        try await verify.value
        try Task.checkCancellation()
        guard token == generation else { throw GameWebPlayerError.staleRun }
        let lease = UUID(); self.lease = lease
        if let configuration = developerConfiguration {
            let developerToken = developerLease?.token ?? UUID()
            let developerLease = GameDeveloperBridgeLease(token: developerToken,
                                                          engine: configuration.engine,
                                                          generation: generation)
            self.developerLease = developerLease
            let source = try Self.developerUserScript(configuration: configuration, lease: developerLease)
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: Self.bridge(lease), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else {
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: Self.bridge(lease), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        handler.activate()
        let url = URL(string: GameArtifactSchemeHandler.scheme + "://" + storageIdentity.originHost + "/" + package.prepared.entry.value)!
        webView.load(URLRequest(url: url))
    }

    @discardableResult public func stop() async -> Bool {
        let shouldFlush = loaded || gameReady || saveFlush.isPending
        generation += 1; let token = generation
        cancelReplies()
        lease = nil; pressedKeys.removeAll(); loaded = false; gameReady = false
        finishStop(false)
        supportsInput = false; supportsState = false
        let preparing = preparation; preparation = nil
        preparing?.cancel(); webView.stopLoading()
        let reads = handler.cancelReads()
        let flushStatus = shouldFlush ? await saveFlush.perform(on: webView) : .notRequired
        // start()/another stop() may run while the engine is persisting. The
        // old close must never navigate, change status or stop the new run.
        guard token == generation else {
            if let preparing { _ = await preparing.result }
            for read in reads { _ = await read.result }
            return false
        }
        lastSaveFlushStatus = flushStatus
        if flushStatus == .failed {
            logs.append("Unable to finish writing game save files before closing")
            if logs.count > 100 { logs.removeFirst(logs.count - 100) }
        }
        let navigation = webView.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
        let confirmed: Bool
        if let navigation {
            confirmed = await withCheckedContinuation { continuation in
                let id = ObjectIdentifier(navigation)
                pendingStop = .init(navigation: id, continuation: continuation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, pendingStop?.navigation == id else { return }
                    failure = "Unable to confirm the game stopped"
                    finishStop(false)
                }
            }
        } else { confirmed = false }
        if let preparing { _ = await preparing.result }
        for read in reads { _ = await read.result }
        return confirmed
    }

    public func input(_ direction: GameInputDirection, pressed: Bool) async throws {
        guard canSimulateInput else { throw GameWebPlayerError.notReady }
        let token = generation
        let bytes: Data
        if gameReady, supportsInput {
            bytes = try await invoke("return !!(window.FloeGame && window.FloeGame.input(direction, pressed));",
                arguments: ["direction": direction.rawValue, "pressed": pressed])
        } else { bytes = try await browserKey(direction.rawValue, pressed: pressed) }
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.unsupportedOperation }
    }

    public func input(_ button: GameInputButton, pressed: Bool) async throws {
        guard canSimulateInput else { throw GameWebPlayerError.notReady }
        let token = generation
        let bytes: Data
        if gameReady, supportsInput {
            bytes = try await invoke("return !!(window.FloeGame && window.FloeGame.input(button, pressed));",
                arguments: ["button": button.rawValue, "pressed": pressed])
        } else { bytes = try await browserKey(button.rawValue, pressed: pressed) }
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.unsupportedOperation }
    }

    /// Engine adapters receive normalized viewport coordinates, not screen taps
    /// into the surrounding App. Optional operations stay explicit and typed.
    public func pointer(_ phase: GamePointerPhase, x: Double, y: Double, button: Int = 0) async throws {
        guard loaded || gameReady, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), (0...2).contains(button) else { throw GameWebPlayerError.invalidState }
        let token = generation
        let bytes = try await invoke("""
            if (window.FloeGame && typeof window.FloeGame.pointer === 'function') return !!window.FloeGame.pointer(phase,x,y,button);
            const clientX=x*innerWidth,clientY=y*innerHeight,target=document.elementFromPoint(clientX,clientY)||document.body;
            if(!target)return false;
            const options={bubbles:true,cancelable:true,clientX,clientY,button,buttons:phase==='ended'?0:1,pointerId:1,pointerType:'mouse',isPrimary:true};
            const mouse={began:'mousedown',moved:'mousemove',ended:'mouseup'}[phase],pointer={began:'pointerdown',moved:'pointermove',ended:'pointerup'}[phase];
            target.dispatchEvent(new PointerEvent(pointer,options));target.dispatchEvent(new MouseEvent(mouse,options));
            if(phase==='ended')target.dispatchEvent(new MouseEvent('click',options));return true;
            """,
            arguments: ["phase": phase.rawValue, "x": x, "y": y, "button": button])
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.unsupportedOperation }
    }

    public func choose(_ index: Int) async throws {
        guard gameReady, (0..<10_000).contains(index) else { throw GameWebPlayerError.invalidState }
        let token = generation
        let bytes = try await invoke("return !!(window.FloeGame && typeof window.FloeGame.choose === 'function' && window.FloeGame.choose(index));", arguments: ["index": index])
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.unsupportedOperation }
    }

    public func key(_ key: GameKeyboardKey, pressed: Bool) async throws {
        guard canSimulateInput else { throw GameWebPlayerError.notReady }
        let token = generation
        let bytes = try await browserKey(key.rawValue, pressed: pressed)
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.unsupportedOperation }
    }

    /// Inspect the real browser in an isolated content world so imported page
    /// scripts cannot manufacture support by replacing WebAssembly globals.
    /// This fixed read-only operation exposes no general script evaluator.
    public func browserCapabilities() async throws -> GameWebBrowserCapabilities {
        guard loaded else { throw GameWebPlayerError.notReady }
        let token = generation
        let bytes = try await invoke("""
            return {webAssembly:typeof WebAssembly==='object',
                    suspending:typeof WebAssembly==='object'&&typeof WebAssembly.Suspending==='function',
                    promising:typeof WebAssembly==='object'&&typeof WebAssembly.promising==='function'};
            """, world: .defaultClient)
        guard token == generation else { throw GameWebPlayerError.staleRun }
        return try JSONDecoder().decode(GameWebBrowserCapabilities.self, from: bytes)
    }

    public func snapshotState() async throws -> Data {
        guard gameReady, supportsState else { throw GameWebPlayerError.notReady }
        let token = generation
        let bytes = try await invoke("return window.FloeGame ? window.FloeGame.snapshot() : null;")
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard let _ = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw GameWebPlayerError.invalidState }
        guard bytes.count <= GameWebRuntimePolicy(engine: package.prepared.engine).maximumStateBytes else { throw GameWebPlayerError.invalidState }
        return bytes
    }

    public func restoreState(_ data: Data) async throws {
        guard gameReady, supportsState, data.count <= GameWebRuntimePolicy(engine: package.prepared.engine).maximumStateBytes else { throw GameWebPlayerError.notReady }
        let object = try JSONSerialization.jsonObject(with: data)
        let token = generation
        let bytes = try await invoke("return !!(window.FloeGame && window.FloeGame.restore(state));", arguments: ["state": object])
        guard token == generation else { throw GameWebPlayerError.staleRun }
        guard try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) as? Bool == true else { throw GameWebPlayerError.invalidState }
    }

    public func capturePNG() async throws -> Data {
        guard loaded else { throw GameWebPlayerError.notReady }
        let token = generation
        let snapshot = WKSnapshotConfiguration()
        snapshot.afterScreenUpdates = webView.window != nil
        // Snapshotting involves the web and graphics processes. A busy scene
        // can take longer than a bridge command to return its painted frame.
        let bytes = try await boundedReply(timeout: 12) { id in
            webView.takeSnapshot(with: snapshot) { [weak self] image, error in
                guard let self, pendingReplies[id] != nil else { return }
                if let error { self.finishReply(id, result: .failure(error)); return }
                guard let image else { self.finishReply(id, result: .failure(GameWebPlayerError.invalidState)); return }
#if os(macOS)
                let bytes = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
#else
                let bytes = image.pngData()
#endif
                guard let bytes else { self.finishReply(id, result: .failure(GameWebPlayerError.invalidState)); return }
                self.finishReply(id, result: .success(bytes))
            }
        }
        guard token == generation else { throw GameWebPlayerError.staleRun }
        return bytes
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard !navigationAction.shouldPerformDownload else {
            blockedNavigations += 1; decisionHandler(.cancel); return
        }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if lease != nil, navigationAction.targetFrame?.isMainFrame == true,
           url.scheme == GameArtifactSchemeHandler.scheme, url.host == storageIdentity.originHost,
           url.path == "/" + package.prepared.entry.value { decisionHandler(.allow) }
        else { blockedNavigations += 1; decisionHandler(.cancel) }
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation, pendingStop?.navigation == ObjectIdentifier(navigation), webView.url?.absoluteString == "about:blank" {
            finishStop(true)
        }
        if lease != nil, webView.url?.scheme == GameArtifactSchemeHandler.scheme { loaded = true }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if lease != nil { failure = String(describing: error) }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false; gameReady = false; failure = "Web content process terminated"; finishStop(true)
        cancelReplies()
    }

    private func finishStop(_ confirmed: Bool) {
        let waiter = pendingStop; pendingStop = nil
        waiter?.continuation.resume(returning: confirmed)
    }

    private func browserKey(_ input: String, pressed: Bool) async throws -> Data {
        let legacy: [String: GameKeyboardKey] = ["confirm": .enter, "cancel": .escape, "action1": .z, "action2": .x, "action3": .a, "action4": .s, "start": .enter, "select": .tab]
        guard let key = GameKeyboardKey(rawValue: input) ?? legacy[input] else { throw GameWebPlayerError.unsupportedOperation }
        let token = generation, previouslyHeld = pressedKeys.contains(key), descriptor = key.descriptor
        if pressed { pressedKeys.insert(key) } else { pressedKeys.remove(key) }
        let shift = pressedKeys.contains(.shift) || pressedKeys.contains(.rightShift)
        let control = pressedKeys.contains(.control) || pressedKeys.contains(.rightControl)
        let alt = pressedKeys.contains(.alt) || pressedKeys.contains(.rightAlt)
        let meta = pressedKeys.contains(.meta) || pressedKeys.contains(.rightMeta)
        do {
            return try await invoke("""
                const detail={key:eventKey,code:eventCode,keyCode:virtualKey,which:virtualKey,location:location,
                  shiftKey:shiftKey,ctrlKey:ctrlKey,altKey:altKey,metaKey:metaKey,repeat:repeating,bubbles:true,cancelable:true};
                if(window.FloeGame && typeof window.FloeGame.key==='function'){
                  if(await window.FloeGame.key({...detail,pressed:pressed})===true)return true;
                }
                let target=document.activeElement;
                if(!target || target===document.body || target===document.documentElement){
                  target=Array.from(document.querySelectorAll('canvas')).find(c=>{const r=c.getBoundingClientRect();return r.width>0&&r.height>0})||document;
                }
                target.dispatchEvent(new KeyboardEvent(pressed?'keydown':'keyup',detail));return true;
                """, arguments: ["eventKey": shift ? descriptor.shiftedKey ?? descriptor.key : descriptor.key,
                    "eventCode": descriptor.code, "virtualKey": descriptor.keyCode, "location": descriptor.location,
                    "pressed": pressed, "shiftKey": shift, "ctrlKey": control, "altKey": alt, "metaKey": meta, "repeating": pressed && previouslyHeld])
        } catch {
            if token == generation {
                if previouslyHeld { pressedKeys.insert(key) } else { pressedKeys.remove(key) }
            }
            throw error
        }
    }

    // Authoring/playtesting does not inherit the App's camera, microphone,
    // orientation, location or file-picker permissions through browser content.
    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
#if os(iOS)
    public func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
#endif
    @available(iOS 27.0, macOS 27.0, *)
    public func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo,
                        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame, let lease,
              let text = message.body as? String, text.utf8.count <= 8_192,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["lease"] as? String == lease.uuidString, let kind = object["kind"] as? String else { return }
        if kind == "ready", let details = object["payload"] as? [String: Any] {
            supportsInput = details["input"] as? Bool == true; supportsState = details["state"] as? Bool == true
            gameReady = true
        } else if kind == "log", let value = object["payload"] as? String {
            logs.append(String(value.prefix(2_048))); if logs.count > 100 { logs.removeFirst(logs.count - 100) }
        }
    }

    /// Private fixed-operation bridge; JSON Data is Sendable across the suspension.
    private func invoke(_ script: String, arguments: [String: Any] = [:], world: WKContentWorld = .page) async throws -> Data {
        try await boundedReply { id in
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) { [weak self] result in
                // A late browser reply must not allocate/serialize results for
                // a timed-out, cancelled or replaced run.
                guard let self, pendingReplies[id] != nil else { return }
                switch result {
                case .success(let value):
                    do {
                        let mirror = Mirror(reflecting: value)
                        let object: Any = mirror.displayStyle == .optional ? (mirror.children.first?.value ?? NSNull()) : value
                        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
                        guard bytes.count <= GameWebRuntimePolicy(engine: self.package.prepared.engine).maximumStateBytes else { throw GameWebPlayerError.invalidState }
                        self.finishReply(id, result: .success(bytes))
                    } catch { self.finishReply(id, result: .failure(error)) }
                case .failure(let error): self.finishReply(id, result: .failure(error))
                }
            }
        }
    }

    /// Fixed player operations share a finite deadline and one completion.
    /// Imported games may return unresolved promises. Their callback cannot
    /// keep Save/Close waiting or write into a subsequently started run.
    private func boundedReply(timeout: TimeInterval = 4, _ begin: (UUID) -> Void) async throws -> Data {
        guard pendingReplies.count < 32 else { throw GameWebPlayerError.notReady }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pendingReplies[id] = PendingReply(generation: generation, continuation: continuation)
                begin(id)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finishReply(id, result: .failure(GameWebPlayerError.timedOut))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finishReply(id, result: .failure(CancellationError()))
            }
        }
    }

    private func finishReply(_ id: UUID, result: Result<Data, any Error>) {
        guard let pending = pendingReplies.removeValue(forKey: id) else { return }
        guard pending.generation == generation else {
            pending.continuation.resume(throwing: GameWebPlayerError.staleRun)
            return
        }
        pending.continuation.resume(with: result)
    }

    private func cancelReplies() {
        let previous = pendingReplies
        pendingReplies.removeAll()
        previous.values.forEach { $0.continuation.resume(throwing: GameWebPlayerError.staleRun) }
    }

    private static func bridge(_ lease: UUID) -> String {
        """
        (function(){const lease='\(lease.uuidString)';function send(kind,payload){try{window.webkit.messageHandlers.floeGame.postMessage(JSON.stringify({lease:lease,kind:kind,payload:payload}))}catch(e){}}
        Object.defineProperty(window,'floeGameHost',{value:Object.freeze({ready:p=>send('ready',p),log:p=>send('log',String(p).slice(0,2048))}),writable:false});
        for(const level of ['log','info','warn','error']){const original=console[level]?.bind(console);console[level]=function(...args){
          try{original?.(...args)}catch(e){}
          const text=args.slice(0,8).map(v=>{try{return String(v).slice(0,512)}catch(e){return '[unprintable]'}}).join(' ');
          send('log',('['+level+'] '+text).slice(0,2048));
        }}
        addEventListener('error',e=>send('log',String(e.message)));addEventListener('unhandledrejection',e=>send('log',String(e.reason)));
        })();
        """
    }
}

@MainActor private final class WeakGameBridge: NSObject, WKScriptMessageHandler {
    weak var owner: GameWebPlayer?
    init(owner: GameWebPlayer) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Development bridge

extension GameWebPlayer {
    public var developerBridgeLease: GameDeveloperBridgeLease? { developerLease }

    public var hasDeveloperBridge: Bool { developerLease != nil }

    /// Attaches a host-owned, development-only bridge. It must be configured
    /// before `start` for document-start registration; attaching after load is
    /// supported but project scripts that registered during boot will not be
    /// replayed. No project content can enable this method.
    @discardableResult
    public func enableDeveloperBridge(_ configuration: GameDeveloperBridgeConfiguration) async throws -> GameDeveloperBridgeLease {
        guard configuration.engine == package.prepared.engine else {
            throw GameDeveloperBridgeError.invalidState("configuration engine does not match the prepared game")
        }
        if let existing = developerLease, existing.engine == configuration.engine,
           developerConfiguration == configuration {
            return existing
        }
        let token = developerLease?.token ?? UUID()
        let lease = GameDeveloperBridgeLease(token: token, engine: configuration.engine,
                                             generation: generation)
        developerConfiguration = configuration
        developerLease = lease
        if loaded || gameReady {
            do {
                let source = try Self.developerUserScript(configuration: configuration, lease: lease)
                try await installDeveloperScript(source)
            } catch {
                developerConfiguration = nil
                developerLease = nil
                throw error
            }
        }
        return lease
    }

    public func disableDeveloperBridge() {
        developerConfiguration = nil
        developerLease = nil
        guard webView.url?.scheme == GameArtifactSchemeHandler.scheme else { return }
        webView.evaluateJavaScript("try{window.FloeDeveloper&&window.FloeDeveloper.__detach()}catch(e){}") { _, _ in }
    }

    /// Sends one fixed operation to the installed helper. The payload is JSON
    /// data from the typed core; the page script is selected here, never by a
    /// caller or project.
    public func developerExchange(_ operation: GameDeveloperBridgeOperation,
                                  payload: Data,
                                  lease: GameDeveloperBridgeLease) async throws -> Data {
        guard let configuration = developerConfiguration,
              let current = developerLease,
              current.token == lease.token,
              current.engine == configuration.engine,
              current.generation == generation,
              configuration.engine == package.prepared.engine,
              loaded else {
            throw GameDeveloperBridgeError.staleRun
        }
        guard payload.count <= configuration.maximumRequestBytes else {
            throw GameDeveloperBridgeError.payloadTooLarge("request \(payload.count) bytes")
        }
        guard isValidArtifactPage else { throw GameDeveloperBridgeError.staleRun }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: payload) }
        catch { throw GameDeveloperBridgeError.invalidPayload("payload is not JSON") }
        guard let object = root as? [String: Any] else {
            throw GameDeveloperBridgeError.invalidPayload("payload must be a JSON object")
        }
        let token = lease.token.uuidString
        let operationName = operation.rawValue
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("""
                const endpoint = window.FloeDeveloper;
                if (!endpoint || endpoint.token !== token) {
                  return {ok:false, token:token, error:{code:'bridge-unavailable', message:'The development helper is not installed in this page.'}};
                }
                try {
                  const value = await endpoint.__exchange(operation, payload);
                  return {ok:true, token:endpoint.token, value:value};
                } catch (error) {
                  return {ok:false, token:token, error:{code:'runtime', message:String(error && error.message ? error.message : error).slice(0,1024)}};
                }
                """,
                arguments: ["token": token, "operation": operationName, "payload": object],
                in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    do {
                        let data = try JSONSerialization.data(withJSONObject: value,
                            options: [.fragmentsAllowed, .sortedKeys])
                        continuation.resume(returning: data)
                    } catch { continuation.resume(throwing: GameDeveloperBridgeError.invalidPayload("response is not JSON")) }
                case .failure(let error):
                    continuation.resume(throwing: GameDeveloperBridgeError.runtime(String(describing: error)))
                }
            }
        }
        guard result.count <= configuration.maximumResponseBytes else {
            throw GameDeveloperBridgeError.payloadTooLarge("response \(result.count) bytes")
        }
        let envelope: [String: Any]
        do { envelope = try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:] }
        catch { throw GameDeveloperBridgeError.invalidPayload("response envelope") }
        guard envelope["token"] as? String == token else {
            throw GameDeveloperBridgeError.staleRun
        }
        if envelope["ok"] as? Bool == false {
            let error = envelope["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? "The development bridge rejected the operation."
            throw GameDeveloperBridgeError.runtime(String(message.prefix(1_024)))
        }
        guard let value = envelope["value"] else {
            throw GameDeveloperBridgeError.unsupportedOperation
        }
        do {
            return try JSONSerialization.data(withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw GameDeveloperBridgeError.invalidPayload("response value")
        }
    }

    private var isValidArtifactPage: Bool {
        guard let url = webView.url,
              url.scheme == GameArtifactSchemeHandler.scheme,
              url.host == storageIdentity.originHost,
              url.path == "/" + package.prepared.entry.value else { return false }
        return true
    }

    private func installDeveloperScript(_ source: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            webView.evaluateJavaScript(source) { _, error in
                if let error { continuation.resume(throwing: GameDeveloperBridgeError.runtime(String(describing: error))) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private static func developerUserScript(configuration: GameDeveloperBridgeConfiguration,
                                            lease: GameDeveloperBridgeLease) throws -> String {
        guard let helperURL = Bundle.module.url(forResource: GameDeveloperBridgePage.helperResource,
                                                withExtension: "js",
                                                subdirectory: GameDeveloperBridgePage.helperDirectory),
              let helper = try? String(contentsOf: helperURL, encoding: .utf8),
              !helper.isEmpty else {
            throw GameDeveloperBridgeError.bridgeUnavailable("FloeDeveloper.js is missing from the resource bundle")
        }
        var hook = ""
        if configuration.includeEngineHook,
           let hookURL = Bundle.module.url(forResource: configuration.engine.rawValue,
                                           withExtension: "js",
                                           subdirectory: GameDeveloperBridgePage.hookDirectory),
           let source = try? String(contentsOf: hookURL, encoding: .utf8) {
            hook = source
        }
        let bootstrap: [String: Any] = [
            "token": lease.token.uuidString,
            "engine": configuration.engine.rawValue,
            "maximumRequestBytes": configuration.maximumRequestBytes,
            "maximumResponseBytes": configuration.maximumResponseBytes,
        ]
        let json = try JSONSerialization.data(withJSONObject: bootstrap,
            options: [.sortedKeys, .withoutEscapingSlashes])
        let bootstrapText = String(decoding: json, as: UTF8.self)
        return """
        (function(){
          window.\(GameDeveloperBridgePage.bootstrapName) = \(bootstrapText);
          \(helper)
          \(hook)
        })();
        """
    }
}
