// FloeSyncCore — Sync status shared between iOS engine and cross-platform
// consumers (settings UI state, persistence status flags).

import Foundation

/// Lifecycle of the configuration sync engine.
public enum SyncStatus: Sendable, Hashable {
    /// All pending changes flushed; engine idle.
    case synced
    /// User or system paused syncing (e.g. iCloud account unavailable
    /// degraded to local).
    case paused
    /// Configuration arrived but the matching Keychain secret has not
    /// synced yet.
    case waitingForSecret
    /// Sync failed; carries a stable, user-presentable reason string.
    case error(String)

    public var isOperational: Bool {
        if case .synced = self { return true }
        return false
    }
}
