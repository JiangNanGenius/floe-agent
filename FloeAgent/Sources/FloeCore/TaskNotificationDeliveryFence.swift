// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Tracks only outstanding system-add callbacks. Replaced or invalidated
/// callbacks cannot put an obsolete failure back into the notification outbox.
public struct TaskNotificationDeliveryFence: Sendable {
    private var owners: [String: UUID] = [:]
    public init() {}
    public mutating func begin(identifier: String) -> UUID {
        let owner = UUID(); owners[identifier] = owner; return owner
    }
    public mutating func invalidate(identifier: String) { owners[identifier] = nil }
    public func isCurrent(identifier: String, owner: UUID) -> Bool { owners[identifier] == owner }
    @discardableResult public mutating func finish(identifier: String, owner: UUID) -> Bool {
        guard owners[identifier] == owner else { return false }
        owners[identifier] = nil
        return true
    }
}
