// SPDX-License-Identifier: MPL-2.0
//
// Process-local ownership fence: at most one live session may own a
// conversation at a time. This is not a permission authority and is never
// persisted as one; the durable run/message rows remain the record of truth.

import Foundation

final class FloeMacSelfConversationClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [UUID: UUID] = [:]

    /// Acquires a fresh claim. Any existing owner - including the same run
    /// identifier - makes the conversation busy: a duplicate start must fail
    /// closed instead of treating re-entry as authorization to replace the
    /// live owner.
    func claim(conversationID: UUID, runID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owners[conversationID] == nil else { return false }
        owners[conversationID] = runID
        return true
    }

    func owner(conversationID: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return owners[conversationID]
    }

    /// Releases only when this exact run still owns the conversation. A late
    /// close of an older terminal session therefore cannot release a newer
    /// run's claim.
    @discardableResult
    func release(conversationID: UUID, runID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owners[conversationID] == runID else { return false }
        owners[conversationID] = nil
        return true
    }

    func reset() {
        lock.lock()
        owners.removeAll()
        lock.unlock()
    }
}
