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

/// Admission policy shared by the App coordinator and focused regressions.
/// A background process may still perform a finite legitimate write, except
/// while the previous system assertion expired or while the last assertion is
/// being handed back after the storage fence. Foreground admission is never
/// blocked by either background-only state.
public enum StorageSuspensionAdmission {
    public static func permitsOperation(
        backgroundNow: Bool,
        needsForeground: Bool,
        finalizingHandoff: Bool
    ) -> Bool {
        guard backgroundNow else { return true }
        return !needsForeground && !finalizingHandoff
    }
}

/// What a completing storage lease may do with its system assertion.
public enum StorageSuspensionLeaseExit: Sendable, Equatable {
    /// End the assertion now: foreground, another budget still protects the
    /// process, or the connection state is already owned elsewhere.
    case endNow
    /// The last background lease completed while owners were still draining.
    /// Hold the assertion until the background transition reaches quiescence.
    case deferUntilQuiescence
    /// The last background lease completed with quiesced owners. Fence SQLite
    /// and drain its writer before returning the assertion.
    case fenceThenEnd

    public static func decide(
        isBackground: Bool,
        quiescenceComplete: Bool,
        leaseCount: Int,
        connectionsSuspended: Bool,
        finalizingHandoff: Bool
    ) -> Self {
        guard isBackground, leaseCount == 1, !finalizingHandoff else { return .endNow }
        guard quiescenceComplete else { return .deferUntilQuiescence }
        guard !connectionsSuspended else { return .endNow }
        return .fenceThenEnd
    }
}

/// Orders the final background storage handoff.
///
/// Giving back the last `UIBackgroundTask` assertion can make the process
/// eligible for suspension immediately. A file/DB suspension fence is not
/// necessarily synchronous (GRDB's suspend notification only sets a flag and
/// interrupts; the lock-owning statement unwinds later on its writer queue),
/// so the assertion must be returned only after the fence has actually
/// drained, never before it is even posted.
@MainActor
public enum StorageBackgroundAssertionHandoff {
    public static func finish(
        fence: () async -> Void,
        endAssertion: () -> Void
    ) async {
        await fence()
        endAssertion()
    }
}

/// The final handoff is asynchronous. A foreground transition or a newer
/// background generation can complete while its fence/drain is still awaited,
/// so the stale callback may act only when it still owns the exact lifecycle
/// generation that requested it.
public enum StorageSuspensionHandoffOwnership {
    public static func isCurrent(
        handoffGeneration: UInt64?,
        currentGeneration: UInt64
    ) -> Bool {
        handoffGeneration == currentGeneration
    }

    public static func mayFence(
        isBackground: Bool,
        startedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        isBackground && startedGeneration == currentGeneration
    }
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
