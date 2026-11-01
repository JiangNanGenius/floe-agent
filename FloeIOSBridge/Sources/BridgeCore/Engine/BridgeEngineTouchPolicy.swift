import Foundation

/// Immutable authorization facts for one RPC invocation.
///
/// The object is created by the executor when it starts the single SDK-gate
/// execution, is passed to every mutation gate through the runtime's scoped
/// property, and is invalidated in the executor's `defer`. Helpers must refuse
/// input when the object is missing or inactive: a context can never be reused
/// across clients, Stop/Resume or a later invocation.
public final class BridgeEngineInvocationAuthorization: @unchecked Sendable {
    public let clientID: String
    public let operationID: String
    public let sensitiveInputGranted: Bool

    private let lock = NSLock()
    private var active = true

    public init(clientID: String, operationID: String, sensitiveInputGranted: Bool) {
        self.clientID = clientID
        self.operationID = operationID
        self.sensitiveInputGranted = sensitiveInputGranted
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Clears the one-shot context. A captured reference cannot authorize a
    /// later touch after this call.
    public func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}

/// The privacy decision for one synthetic touch or key event.
public struct BridgeEngineTouchDecision: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case allowed
        case denied
    }

    public var outcome: Outcome
    public var reason: String
    public var requiresSensitiveGrant: Bool

    public init(outcome: Outcome,
                reason: String,
                requiresSensitiveGrant: Bool) {
        self.outcome = outcome
        self.reason = reason
        self.requiresSensitiveGrant = requiresSensitiveGrant
    }

    public var allowed: Bool { outcome == .allowed }
}

/// Conservative authorization for every synthesized touch and on-screen
/// keyboard key event.
///
/// The owner grant covers a third-party App's secure keyboard only. It never
/// covers the system lock screen, passcode, account authorization, SpringBoard
/// or any secure field in an Apple-owned app. A live focus state that cannot be
/// read is treated as unknown and refused rather than as "no secure field".
public enum BridgeEngineTouchPolicy {
    private static func deny(_ reason: String,
                             requiresSensitiveGrant: Bool = false) -> BridgeEngineTouchDecision {
        BridgeEngineTouchDecision(outcome: .denied,
                                  reason: reason,
                                  requiresSensitiveGrant: requiresSensitiveGrant)
    }

    /// Evaluates the full fact set supplied immediately before a mutation. The
    /// authorization object is the per-invocation context; an absent or
    /// invalidated context denies before any SDK call.
    public static func decide(authorization: BridgeEngineInvocationAuthorization?,
                              screenLocked: Bool,
                              authorizationSurfacePresent: Bool,
                              bundleIdentifier: String?,
                              foregroundBundleIdentifier: String?,
                              focusStateKnown: Bool,
                              focusedSecure: Bool) -> BridgeEngineTouchDecision {
        guard let authorization, authorization.isActive else {
            return deny("The per-invocation authorization context is unavailable; no input was performed.")
        }
        return decide(screenLocked: screenLocked,
                      authorizationSurfacePresent: authorizationSurfacePresent,
                      bundleIdentifier: bundleIdentifier,
                      foregroundBundleIdentifier: foregroundBundleIdentifier,
                      focusStateKnown: focusStateKnown,
                      focusedSecure: focusedSecure,
                      sensitiveInputGranted: authorization.sensitiveInputGranted)
    }

    public static func decide(screenLocked: Bool,
                              authorizationSurfacePresent: Bool,
                              bundleIdentifier: String?,
                              foregroundBundleIdentifier: String?,
                              focusStateKnown: Bool,
                              focusedSecure: Bool,
                              sensitiveInputGranted: Bool) -> BridgeEngineTouchDecision {
        if screenLocked {
            return deny("The screen is locked. System lock-screen and passcode input is never automated.")
        }
        if authorizationSurfacePresent {
            return deny("System authorization, passcode and SpringBoard input is never automated.")
        }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return deny("The target app could not be established; generic touch is refused.")
        }
        if BridgeEngineInputPolicy.isSystemAuthorizationSurface(bundleIdentifier: bundleIdentifier) {
            return deny("System authorization, passcode and SpringBoard input is never automated.")
        }
        guard let foregroundBundleIdentifier, !foregroundBundleIdentifier.isEmpty else {
            return deny("The live foreground app could not be established; generic touch is refused.")
        }
        guard bundleIdentifier == foregroundBundleIdentifier else {
            return deny("The target app is not the live foreground app; generic touch is refused.")
        }
        guard focusStateKnown else {
            return deny("Keyboard focus could not be read; generic touch is refused while the input state is unknown.")
        }
        if focusedSecure {
            if BridgeEngineInputPolicy.isSystemOwnedApp(bundleIdentifier: bundleIdentifier) {
                return deny("Secure input in an Apple system app is never automated, even with the owner grant.")
            }
            guard sensitiveInputGranted else {
                return deny("A secure field has keyboard focus. The device owner's per-client sensitive-input grant is required.",
                            requiresSensitiveGrant: true)
            }
        }
        return BridgeEngineTouchDecision(outcome: .allowed,
                                         reason: "The touch is authorized.",
                                         requiresSensitiveGrant: false)
    }

    /// Runs `body` only for an allowed decision. The runtime uses this exact
    /// gate for every synthesized touch/key event, so a denied decision cannot
    /// reach the underlying SDK call.
    @discardableResult
    public static func authorize<T>(_ decision: BridgeEngineTouchDecision,
                                    _ body: () -> T) -> T? {
        guard decision.allowed else { return nil }
        return body()
    }
}
