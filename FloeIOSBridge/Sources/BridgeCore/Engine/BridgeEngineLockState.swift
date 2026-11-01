import Foundation

/// Fail-closed view of the SpringBoard lock-state notification source.
///
/// `BRLockStateAvailable()` only means the notify token was registered. It does
/// not prove the current value was ever read. A first or later read failure is
/// `unknown`, never `unlocked`, so input and frames stay refused until a
/// successful read establishes the state.
public enum BridgeEngineLockState: String, Equatable, Sendable {
    case unavailable
    case unknown
    case unlocked
    case locked

    public var permitsAutomation: Bool { self == .unlocked }

    public static func classify(available: Bool,
                                known: Bool,
                                rawLocked: Bool) -> BridgeEngineLockState {
        guard available else { return .unavailable }
        guard known else { return .unknown }
        return rawLocked ? .locked : .unlocked
    }
}
