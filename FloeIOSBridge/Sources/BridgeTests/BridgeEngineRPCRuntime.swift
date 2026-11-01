import Foundation
import UIKit
import XCTest
import BridgeCore

/// The real device-side RPC executor and the shared frame provider.
///
/// One object is created after `BridgeSharedState.markEngineEntry` accepts the
/// actual XCTest entry and registered in both `BridgeRuntime.engineRegistry`
/// and `BridgeRuntime.screenFrames` under one stable per-process owner. The
/// registry first-wins semantics and the process-lifetime lifetime are what
/// let a listener Stop/Start reuse the initialized driver instead of
/// bootstrapping XCTest again.
@MainActor
final class BridgeEngineRPCRuntime: BridgeRPCExecutor, BridgeScreenFrameProvider, @unchecked Sendable {
    let processIdentifier = Int32(ProcessInfo.processInfo.processIdentifier)
    let owner: String
    let gate = BridgeEngineSerialGate()
    let state = BridgeEngineRuntimeState()
    let refs = BridgeEngineElementRefStore()
    let sdk: BridgeEngineSDKSupport
    let capabilities: Set<BridgeEnginePrivateCapability>
    let supportedMethods: Set<String>
    /// Set for exactly one SDK-gate execution, then invalidated and cleared in
    /// the executor's `defer`. Mutation helpers read only this immutable
    /// per-invocation grant; they never read a request parameter for it.
    private(set) var activeAuthorization: BridgeEngineInvocationAuthorization?

    init(issueCapture: BridgeEngineIssueCapture, files: BridgeTestFiles) {
        self.owner = "floe-ios-bridge-test-engine-\(ProcessInfo.processInfo.processIdentifier)"
        self.sdk = BridgeEngineSDKSupport(files: files, issueCapture: issueCapture)
        var detected: Set<BridgeEnginePrivateCapability> = []
        if BRRedactedTypingAvailable() { detected.insert(.redactedTyping) }
        if BRContinuousDragAvailable() { detected.insert(.continuousDrag) }
        if BRLockButtonAvailable() { detected.insert(.lockButton) }
        if BRLockStateAvailable() { detected.insert(.lockState) }
        if BRForegroundHelperAvailable() { detected.insert(.foregroundHelper) }
        if BRInstalledAppsAvailable() { detected.insert(.installedApps) }
        if BROpenURLAvailable() { detected.insert(.openURL) }
        if BRAppStateAvailable() { detected.insert(.appState) }
        self.capabilities = detected
        self.supportedMethods = BridgeEngineMethodCatalog.supportedMethods(capabilities: detected)
    }

    // MARK: - Entry and readiness

    func markEntryAccepted() {
        state.setEntryAccepted(true)
        sdk.files.log("rpc_engine_ready owner=\(owner) methods=\(supportedMethods.count)")
    }

    nonisolated var readiness: BridgeRPCEngineReadiness {
        guard state.isEntryAccepted else {
            return .notReady(reason: "The real XCTest engine entry has not been accepted.")
        }
        let snapshot = BridgeSharedState.shared.snapshot()
        guard snapshot.enginePid == processIdentifier else {
            return .notReady(reason: "The shared lifecycle is not owned by this process.")
        }
        guard snapshot.engineRunning else {
            return .notReady(reason: "The automation engine is stopped.")
        }
        guard BridgeSharedState.shared.engineAcceptsCommands() else {
            return .notReady(reason: "The shared lifecycle does not accept engine commands.")
        }
        guard engineHeartbeatCurrent() else {
            return .notReady(reason: "The embedded engine heartbeat is stale or missing.")
        }
        return .ready(generation: snapshot.generation)
    }

    nonisolated func engineHeartbeatCurrent() -> Bool {
        let record = BridgeAtomicFile.readJSON(BridgePaths.engineHeartbeatFile)
        let status = BridgeLivenessBeatStatus.engineHeartbeat(record: record)
        return status.freshness == .current
    }

    /// Conservative system-authorization check before any generic input. An
    /// unreadable SpringBoard alert state is treated as present, never as
    /// permission to type or tap.
    @MainActor
    func systemAuthorizationSurfacePresent() -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if stateName(springboard) == "runningForeground" { return true }
        // LocalAuthentication/AuthKit/AuthenticationServices present account or
        // passcode UI in their own process. If one is actually foreground, it
        // owns the screen even when the underlying app is still visible.
        for bundle in Self.authorizationOverlayBundleIdentifiers where bundle != "com.apple.springboard" {
            if stateName(XCUIApplication(bundleIdentifier: bundle)) == "runningForeground" {
                return true
            }
        }
        var count = 0
        let result = sdk.call(stage: "system-alert-check") {
            count = springboard.alerts.count
        }
        if result.error != nil || result.outcome.recordedIssueCount > 0 { return true }
        return count > 0
    }

    static let authorizationOverlayBundleIdentifiers = [
        "com.apple.springboard",
        "com.apple.AuthKitUI",
        "com.apple.LocalAuthentication.RemoteUI",
        "com.apple.AuthenticationServices.UI",
        "com.apple.PasscodeSettings",
    ]

    /// Establishes the live foreground app for a mutation without trusting the
    /// last-controlled fallback. A strict helper result that names a different
    /// app is a refusal; if the private helper is unavailable, only a live
    /// positive `runningForeground` state for the exact target is accepted.
    @MainActor
    func targetIsLiveForeground(_ targetBundle: String) -> Bool {
        if let observed = BRCurrentForegroundBundleID(), !observed.isEmpty {
            return observed == targetBundle
        }
        return stateName(XCUIApplication(bundleIdentifier: targetBundle)) == "runningForeground"
    }

    enum MutationGuardResult {
        case allowed(BridgeEngineTouchDecision)
        case denied(BridgeRPCExecutionOutcome)
    }

    /// The one authorization gate used immediately before every synthetic
    /// touch or key event. It reads live lock, authorization-overlay,
    /// foreground and keyboard-focus facts, then applies the immutable
    /// per-invocation context. No mutating SDK call may precede this.
    @MainActor
    func mutationGuard(stage: String,
                       targetBundle: String,
                       permit: BridgeRPCDispatchPermit,
                       generation: UInt64) -> MutationGuardResult {
        guard stepAllowed(permit, generation: generation) else {
            return .denied(.failure(.fenced))
        }
        guard let authorization = activeAuthorization, authorization.isActive else {
            return .denied(permissionDenied("The per-invocation authorization context is unavailable; no input was performed."))
        }
        let authorizationSurfacePresent = systemAuthorizationSurfacePresent()
        let targetIsForeground = targetIsLiveForeground(targetBundle)
        let app = XCUIApplication(bundleIdentifier: targetBundle)
        let fields = sdk.focusedFields(app: app)
        let focusStateKnown = fields != nil
        var focusedSecure = fields?.contains(where: { $0.candidate.isSecure }) ?? false
        if !focusedSecure,
           BridgeEngineInputPolicy.isSystemSecureSettingsSurface(bundleIdentifier: targetBundle) {
            // Apple passcode/settings surfaces can expose a keypad without a
            // focused secureTextField to the accessibility query. Treat any
            // secure field on the surface (or an unreadable secure-field query)
            // as the same conservative refusal.
            if let rects = sdk.secureFieldRects(app: app) {
                focusedSecure = !rects.isEmpty
            } else {
                focusedSecure = true
            }
            if !focusedSecure, targetBundle.lowercased() == "com.apple.preferences" {
                // A Settings passcode prompt can be a custom digit keypad with
                // no secureTextField. Any standard 10-digit keypad on this
                // surface is treated as passcode input; an unreadable check is
                // also refused.
                if let keypad = sdk.passcodeKeypadPresent(app: app) {
                    focusedSecure = keypad
                } else {
                    focusedSecure = true
                }
            }
        }
        let decision = BridgeEngineTouchPolicy.decide(
            authorization: authorization,
            screenLocked: !lockState().permitsAutomation,
            authorizationSurfacePresent: authorizationSurfacePresent,
            bundleIdentifier: targetBundle,
            ownerBundleIdentifier: BridgeBuild.hostBundleIdentifier,
            foregroundBundleIdentifier: targetIsForeground ? targetBundle : nil,
            focusStateKnown: focusStateKnown,
            focusedSecure: focusedSecure
        )
        guard decision.allowed else {
            if decision.requiresSensitiveGrant {
                return .denied(permissionDenied("sensitive_input_required"))
            }
            return .denied(permissionDenied(decision.reason))
        }
        return .allowed(decision)
    }

    enum GuardedCallResult<T> {
        case value(T)
        case denied(BridgeRPCExecutionOutcome)
    }

    /// Runs one SDK mutation only when the same guard and the same immutable
    /// context authorize it. Used for direct synthesized touches and key
    /// events that do not pass through `performTouch`.
    @MainActor
    func guardedCall<T>(stage: String,
                        targetBundle: String,
                        permit: BridgeRPCDispatchPermit,
                        generation: UInt64,
                        _ body: () -> T) -> GuardedCallResult<T> {
        switch mutationGuard(stage: stage,
                             targetBundle: targetBundle,
                             permit: permit,
                             generation: generation) {
        case .denied(let outcome):
            return .denied(outcome)
        case .allowed(let decision):
            guard let value = BridgeEngineTouchPolicy.authorize(decision, body) else {
                return .denied(permissionDenied("The input was not authorized."))
            }
            return .value(value)
        }
    }

    // MARK: - Executor

    nonisolated func execute(_ invocation: BridgeRPCInvocation,
                             permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome {
        guard readiness.isReady else {
            return .failure(BridgeRPCError(
                code: BridgeRPCError.engineNotReady.code,
                message: BridgeRPCError.engineNotReady.message,
                data: ["reason": .string("The embedded automation engine is not ready.")]
            ))
        }
        guard supportedMethods.contains(invocation.method) else {
            return .failure(BridgeRPCError(
                code: BridgeRPCError.methodNotAvailable.code,
                message: BridgeRPCError.methodNotAvailable.message,
                data: ["method": .string(invocation.method)]
            ))
        }
        let generation = BridgeSharedState.shared.snapshot().generation
        await gate.acquire()
        defer { gate.release() }
        guard permit.canContinueExecution, lifecycleIsCurrent(generation) else {
            return .failure(.fenced)
        }
        return await dispatchOnMain(invocation,
                                    permit: permit,
                                    generation: generation)
    }

    @MainActor
    private func dispatchOnMain(_ invocation: BridgeRPCInvocation,
                                permit: BridgeRPCDispatchPermit,
                                generation: UInt64) async -> BridgeRPCExecutionOutcome {
        let params: BridgeEngineParameters
        do {
            params = try BridgeEngineParameters(invocation.params)
        } catch let error as BridgeEngineParameterError {
            return invalidParams(error.message)
        } catch {
            return invalidParams("Invalid parameters.")
        }
        let authorization = BridgeEngineInvocationAuthorization(
            clientID: invocation.clientID,
            operationID: invocation.operationID,
            sensitiveInputGranted: invocation.sensitiveInputGranted
        )
        activeAuthorization = authorization
        defer {
            authorization.invalidate()
            if activeAuthorization === authorization {
                activeAuthorization = nil
            }
        }
        do {
            return try await route(invocation,
                                   params: params,
                                   permit: permit,
                                   generation: generation)
        } catch let error as BridgeEngineParameterError {
            return invalidParams(error.message)
        } catch let fence as SettleFence {
            return fence.outcome
        } catch {
            sdk.files.log("rpc_engine_error method=\(invocation.method) generic=1")
            return .failure(BridgeRPCError(
                code: BridgeRPCError.internalError.code,
                message: "The automation method failed."
            ))
        }
    }

    @MainActor
    private func route(_ invocation: BridgeRPCInvocation,
                       params: BridgeEngineParameters,
                       permit: BridgeRPCDispatchPermit,
                       generation: UInt64) async throws -> BridgeRPCExecutionOutcome {
        switch invocation.method {
        case "device_info":
            return try deviceInfo(params, permit: permit, generation: generation)
        case "page_source":
            return try pageSource(params, permit: permit, generation: generation)
        case "screen_text":
            return try screenText(params, permit: permit, generation: generation)
        case "reset":
            return try reset(permit: permit, generation: generation)
        case "screenshot":
            return try screenshot(params, permit: permit, generation: generation)
        case "tap":
            return try await tap(params, permit: permit, generation: generation)
        case "double_tap":
            return try await doubleTap(params, permit: permit, generation: generation)
        case "long_press":
            return try await longPress(params, permit: permit, generation: generation)
        case "swipe":
            return try await swipe(params, permit: permit, generation: generation)
        case "page":
            return try await page(params, permit: permit, generation: generation)
        case "collect":
            return try await collect(params, permit: permit, generation: generation)
        case "scroll_to_element":
            return try await scrollToElement(params, permit: permit, generation: generation)
        case "scroll":
            return try legacyScroll(params, permit: permit, generation: generation)
        case "type":
            return try await typeText(params: params,
                                      permit: permit,
                                      generation: generation)
        case "clear_text":
            return try await clearText(permit: permit,
                                       generation: generation)
        case "home":
            return try await home(permit: permit, generation: generation)
        case "lock":
            return try await lockScreen(permit: permit, generation: generation)
        case "unlock":
            return try await unlockScreen(permit: permit, generation: generation)
        case "is_locked":
            return try isLocked(permit: permit, generation: generation)
        case "list_apps":
            return try listApps(params, permit: permit, generation: generation)
        case "resolve_app":
            return try resolveApp(params, permit: permit, generation: generation)
        case "open_url":
            return try openURL(params, permit: permit, generation: generation)
        case "launch_app":
            return try launchApp(params, permit: permit, generation: generation)
        case "activate_app":
            return try activateApp(params, permit: permit, generation: generation)
        case "terminate_app":
            return try terminateApp(params, permit: permit, generation: generation)
        case "find_element":
            return try findElement(params, permit: permit, generation: generation)
        case "tap_element":
            return try await tapElement(params, permit: permit, generation: generation)
        case "find_and_tap":
            return try await findAndTap(params, permit: permit, generation: generation)
        case "drag":
            return try await drag(params, permit: permit, generation: generation)
        case "wait":
            return try await wait(params, permit: permit, generation: generation)
        default:
            return .failure(BridgeRPCError(
                code: BridgeRPCError.methodNotAvailable.code,
                message: BridgeRPCError.methodNotAvailable.message,
                data: ["method": .string(invocation.method)]
            ))
        }
    }

    // MARK: - Dispatch fences

    nonisolated func lifecycleIsCurrent(_ generation: UInt64) -> Bool {
        let snapshot = BridgeSharedState.shared.snapshot()
        return snapshot.generation == generation
            && snapshot.engineRunning
            && snapshot.enginePid == processIdentifier
            && snapshot.phase == .ready
            && snapshot.serviceRunning
    }

    /// Authorizes dispatch on the MainActor immediately before the first real
    /// SDK call. Returns a terminal outcome when the permit or lifecycle has
    /// already been fenced.
    @MainActor
    func beginSDK(_ permit: BridgeRPCDispatchPermit,
                  generation: UInt64) -> BridgeRPCExecutionOutcome? {
        guard permit.canContinueExecution else { return .failure(.fenced) }
        guard lifecycleIsCurrent(generation) else { return .failure(.fenced) }
        guard permit.authorizeDispatch() else { return .failure(.fenced) }
        return nil
    }

    /// Called before every subsequent SDK step, loop iteration, page or wait.
    func stepAllowed(_ permit: BridgeRPCDispatchPermit,
                     generation: UInt64) -> Bool {
        permit.canContinueExecution && lifecycleIsCurrent(generation)
    }



    // MARK: - JSON helpers

    func failure(_ code: Int, _ message: String, reason: String? = nil) -> BridgeRPCExecutionOutcome {
        .failure(BridgeRPCError(
            code: code,
            message: message,
            data: reason.map { ["reason": .string($0)] }
        ))
    }

    func invalidParams(_ message: String) -> BridgeRPCExecutionOutcome {
        .failure(BridgeRPCError(
            code: BridgeRPCError.invalidParams.code,
            message: message
        ))
    }

    func methodNotAvailable(_ reason: String) -> BridgeRPCExecutionOutcome {
        .failure(BridgeRPCError(
            code: BridgeRPCError.methodNotAvailable.code,
            message: ReasonText.methodNotAvailable,
            data: ["reason": .string(reason)]
        ))
    }

    func permissionDenied(_ reason: String) -> BridgeRPCExecutionOutcome {
        .failure(BridgeRPCError(
            code: BridgeRPCError.permissionDenied.code,
            message: BridgeRPCError.permissionDenied.message,
            data: ["reason": .string(reason)]
        ))
    }

    func success(_ pairs: (String, BridgeRPCJSONValue)...) -> BridgeRPCExecutionOutcome {
        .success(.object(Dictionary(uniqueKeysWithValues: pairs)))
    }

    func screenJSON(_ metrics: BridgeEngineScreenMetrics) -> BridgeRPCJSONValue {
        .object([
            "coordinate_space": .string("points"),
            "point_width": .double(metrics.pointWidth),
            "point_height": .double(metrics.pointHeight),
            "pixel_width": .int(metrics.pixelWidth),
            "pixel_height": .int(metrics.pixelHeight),
            "scale": .double(metrics.scale),
        ])
    }

    func stateName(_ app: XCUIApplication) -> String {
        sdk.state(of: app)
    }

    func currentForegroundBundleIdentifier() -> String? {
        sdk.foregroundBundleIdentifier(lastControlled: state.lastControlledBundleIdentifier)
    }

    func markControlled(_ bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        state.setLastControlled(bundleIdentifier)
    }

    /// Resolves the target app for actions. An omitted bundle id means the
    /// actually observed foreground app; it never silently defaults to the
    /// host when another app is in front.
    @MainActor
    func targetApp(_ bundleIdentifier: String?) -> (bundle: String, app: XCUIApplication)? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return (bundleIdentifier, XCUIApplication(bundleIdentifier: bundleIdentifier))
        }
        guard let foreground = currentForegroundBundleIdentifier() else { return nil }
        return (foreground, XCUIApplication(bundleIdentifier: foreground))
    }

    func appFrame(_ app: XCUIApplication) -> BridgeUIRect? {
        var frame = CGRect.zero
        let result = sdk.call(stage: "app-frame") { frame = app.frame }
        guard result.error == nil,
              result.outcome.recordedIssueCount == 0,
              frame.width > 1, frame.height > 1 else { return nil }
        return BridgeUIRect(x: Double(frame.origin.x),
                            y: Double(frame.origin.y),
                            width: Double(frame.size.width),
                            height: Double(frame.size.height))
    }

    func appStateName(_ bundleIdentifier: String) -> String {
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        return sdk.state(of: app)
    }

    /// Fail-closed tri-state lock observation. A registered notification token
    /// whose current value was never read is `unknown`, never `unlocked`.
    nonisolated func lockState() -> BridgeEngineLockState {
        BridgeEngineLockState.classify(
            available: BRLockStateAvailable(),
            known: BRLockStateKnown(),
            rawLocked: BRIsLocked()
        )
    }

    nonisolated func isLocked() -> Bool {
        !lockState().permitsAutomation
    }

    enum ReasonText {
        static let methodNotAvailable = "The method is registered in the schema but not available in this build."
    }
}

/// Thread-safe mutable facts owned by the runtime. Nothing here contains raw
/// input text, credentials or screenshot bytes.
final class BridgeEngineRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var entryAccepted = false
    private var lastControlled: String?
    private var collected: Set<String> = []

    var isEntryAccepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entryAccepted
    }

    func setEntryAccepted(_ accepted: Bool) {
        lock.lock()
        entryAccepted = accepted
        lock.unlock()
    }

    var lastControlledBundleIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastControlled
    }

    func setLastControlled(_ bundleIdentifier: String?) {
        lock.lock()
        lastControlled = bundleIdentifier
        lock.unlock()
    }

    func reset() {
        lock.lock()
        collected.removeAll()
        lock.unlock()
    }

    func resetCollected() {
        lock.lock()
        collected.removeAll()
        lock.unlock()
    }

    func collect(existing: Bool, labels: [String]) -> (new: [String], total: Int) {
        lock.lock()
        defer { lock.unlock() }
        if !existing { collected.removeAll() }
        var new: [String] = []
        for label in labels where !label.isEmpty {
            if collected.insert(label).inserted { new.append(label) }
        }
        return (new, collected.count)
    }

    var collectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return collected.count
    }


}
