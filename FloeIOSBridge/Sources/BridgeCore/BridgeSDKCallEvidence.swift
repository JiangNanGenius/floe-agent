import Foundation

/// Bounded, thread-safe counter for XCTest issues recorded while one SDK call
/// is active.
///
/// The collector never retains an `XCTIssue`, its compact/detailed
/// description, source context or any user text. It stores only a per-scope
/// count. The embedded test case's `recordIssue(_:)` override calls
/// `noteIssue()` and always forwards to `super`, so XCTest's normal failure
/// reporting and bootstrap/lifecycle handling are preserved.
public final class BridgeEngineIssueCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken: UInt64 = 1
    private var active: [UInt64: Int] = [:]
    private let maximumActiveScopes = 16

    public init() {}

    /// Starts one scoped SDK call. The returned token must be passed to
    /// `end(_:)` after the call returns or throws.
    public func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        if active.count < maximumActiveScopes {
            active[token] = 0
        }
        return token
    }

    /// Counts one recorded issue against every active scope. Nested scopes are
    /// intentionally inclusive; the caller that owns the token decides which
    /// count applies. No issue content is read.
    public func noteIssue() {
        lock.lock()
        defer { lock.unlock() }
        for token in active.keys {
            active[token, default: 0] += 1
        }
    }

    /// Ends a scope and returns its bounded issue count. An unknown token (for
    /// example after a bounded active-scope overflow) returns zero; callers
    /// must treat an unexpected zero token as unavailable, not as proof.
    public func end(_ token: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return active.removeValue(forKey: token) ?? 0
    }
}

/// The four truthfulness facts around one SDK call: whether the closure was
/// entered, whether it returned normally, whether an XCTest issue was recorded
/// despite a normal return, and whether the SDK explicitly refused focus.
///
/// A normal return alone is never a dispatch/focus success claim. Only
/// independent observed value equality can upgrade a text claim. This is the
/// boundary encoded here so the engine and host tests share one decision.
public struct BridgeSDKCallOutcome: Equatable, Sendable {
    public var entered: Bool
    public var returned: Bool
    public var focusRefused: Bool
    public var recordedIssueCount: Int

    public init(entered: Bool,
                returned: Bool,
                focusRefused: Bool = false,
                recordedIssueCount: Int = 0) {
        self.entered = entered
        self.returned = returned
        self.focusRefused = focusRefused
        self.recordedIssueCount = recordedIssueCount
    }

    public var recordedIssue: Bool { recordedIssueCount > 0 }
    public var thrown: Bool { entered && !returned }
    public var cleanReturn: Bool {
        entered && returned && !focusRefused && recordedIssueCount == 0
    }

    public var classification: String {
        if !entered { return "not-entered" }
        if !returned { return focusRefused ? "focus-refused" : "threw" }
        if recordedIssueCount > 0 { return "returned-with-issue" }
        return "returned-clean"
    }

    /// Text input is focus-sensitive: a normal return is not proof that the
    /// SDK accepted focus or dispatched the text. Value equality independently
    /// proves an effect; without it the dispatch claim stays unknown.
    public func textDispatchClaim(actualValueVerified: Bool) -> String {
        if !entered { return "false" }
        if !returned { return focusRefused ? "false" : "unknown" }
        if actualValueVerified { return "true" }
        return "unknown"
    }

    /// Focus is independently evidenced by observed value equality or by a
    /// matched keyboard-focus probe plus a clean return. A clean return alone
    /// is not enough.
    public func focusClaim(probeMatched: Bool,
                           actualValueVerified: Bool) -> Bool {
        if actualValueVerified { return true }
        return entered && returned && recordedIssueCount == 0 && probeMatched
    }

    /// Tap/swipe synthesize an event. A clean return is the SDK's dispatch
    /// signal; a recorded issue or a thrown call is unknown. An independently
    /// verified effect is also sufficient.
    public func mutationDispatchClaim(actualEffectVerified: Bool = false) -> String {
        if !entered { return "false" }
        if actualEffectVerified { return "true" }
        if !returned || recordedIssueCount > 0 { return "unknown" }
        return "true"
    }
}
