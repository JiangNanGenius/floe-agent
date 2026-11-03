import Foundation
import os

/// Small unfair-lock wrapper usable from synchronous and asynchronous contexts.
/// `NSLock.lock()` is annotated unavailable from async contexts in the current
/// SDK; this keeps the short critical sections explicit without pulling an
/// actor into every value type.
public final class BridgeRPCLock: @unchecked Sendable {
    private var unfair = os_unfair_lock_s()

    public init() {}

    public func lock() {
        os_unfair_lock_lock(&unfair)
    }

    public func unlock() {
        os_unfair_lock_unlock(&unfair)
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&unfair)
        defer { os_unfair_lock_unlock(&unfair) }
        return try body()
    }
}
