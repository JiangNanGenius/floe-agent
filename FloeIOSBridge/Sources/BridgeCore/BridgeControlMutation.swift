import Foundation

/// Result of the final, immediately-before-SDK admission check for a generic
/// mutation. The check is deliberately value-based so it can be exercised
/// without XCUITest or a device.
public enum BridgeControlMutationDecision: Equatable, Sendable {
    case allowed
    case staleGeneration
    case engineNotReady
    case targetNotForeground

    public var isAllowed: Bool { self == .allowed }

    public var code: String {
        switch self {
        case .allowed: return "allowed"
        case .staleGeneration: return "stale_generation"
        case .engineNotReady: return "engine_not_ready"
        case .targetNotForeground: return "not_foreground"
        }
    }
}

/// The narrow admission contract shared by the generic mutation helpers.
///
/// The caller must have finished every potentially blocking snapshot/query
/// and read the expected app's current foreground state immediately before
/// calling `admit`. `admit` rechecks the accepted generation and engine
/// readiness from the same lifecycle snapshot and invokes the mutation closure
/// only when all checks pass. No lock is held while the SDK mutation runs.
public enum BridgeControlMutationAdmission {
    public static func evaluate(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        engineAcceptsCommands: Bool,
        requiresForeground: Bool,
        expectedForeground: Bool
    ) -> BridgeControlMutationDecision {
        guard expectedGeneration == currentGeneration else {
            return .staleGeneration
        }
        guard engineAcceptsCommands else {
            return .engineNotReady
        }
        if requiresForeground && !expectedForeground {
            return .targetNotForeground
        }
        return .allowed
    }

    /// Executes `mutation` exactly when the final admission check is allowed.
    /// A refused command can never enter the SDK closure. The closure is
    /// synchronous and no global lock is held around it, so a host Stop can
    /// still fence the shared state while an already-entered SDK call runs.
    @discardableResult
    public static func admit(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        engineAcceptsCommands: Bool,
        requiresForeground: Bool,
        expectedForeground: Bool,
        mutation: () -> Void
    ) -> BridgeControlMutationDecision {
        let decision = evaluate(
            expectedGeneration: expectedGeneration,
            currentGeneration: currentGeneration,
            engineAcceptsCommands: engineAcceptsCommands,
            requiresForeground: requiresForeground,
            expectedForeground: expectedForeground
        )
        if decision.isAllowed {
            mutation()
        }
        return decision
    }
}
