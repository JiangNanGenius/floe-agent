import Foundation

/// A finite execution opportunity supplied by the native App. Packages and
/// extensions never reach UIApplication; without an installed App host this
/// remains an ordinary cancellation/ownership lease.
public final class StorageOperationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var expired = false
    private var expirationHandlers: [@Sendable () -> Void] = []
    private let onFinish: @Sendable () -> Void

    public init(onFinish: @escaping @Sendable () -> Void = {}) {
        self.onFinish = onFinish
    }

    public func check() throws {
        lock.lock()
        let invalid = expired || finished
        lock.unlock()
        if invalid { throw CancellationError() }
        try Task.checkCancellation()
    }

    public func expire() {
        lock.lock()
        let handlers = finished || expired ? [] : expirationHandlers
        expired = true
        expirationHandlers.removeAll()
        lock.unlock()
        for handler in handlers { handler() }
    }

    public func whenExpired(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let callNow = expired && !finished
        if !expired && !finished { expirationHandlers.append(handler) }
        lock.unlock()
        if callNow { handler() }
    }

    public func finish() {
        lock.lock()
        let shouldFinish = !finished
        finished = true
        expirationHandlers.removeAll()
        lock.unlock()
        if shouldFinish { onFinish() }
    }

    deinit { finish() }
}

public enum StorageOperationBudget {
    public typealias Begin = @Sendable () async throws -> StorageOperationLease
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var begin: Begin?
        func install(_ begin: Begin?) {
            lock.lock(); self.begin = begin; lock.unlock()
        }
        func current() -> Begin? {
            lock.lock(); defer { lock.unlock() }; return begin
        }
    }
    private static let registry = Registry()

    /// Installed once by the App's process-owned lifecycle coordinator.
    public static func install(begin: Begin?) { registry.install(begin) }

    public static func begin() async throws -> StorageOperationLease {
        try Task.checkCancellation()
        if let begin = registry.current() { return try await begin() }
        return StorageOperationLease()
    }
}
