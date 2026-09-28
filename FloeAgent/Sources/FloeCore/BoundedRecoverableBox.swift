import Foundation

/// Thread-safe, one-time recoverable initialization for a reference-type
/// service. It exists to make this exact sequence race-free:
///
///  1. a service must be published ONLY after an asynchronous build/wiring
///     step fully succeeds (a half-wired value is observable to nobody),
///  2. concurrent callers coalesce onto the same build task and see the same
///     success/failure — two callers never build twice,
///  3. a failed build publishes nothing, so the next `ensure` retries.
///
/// All locked sections are synchronous (`withLock`): no raw `lock()` is held
/// across an `await` or called directly in an asynchronous context.
// Mutable state is always accessed under `boxLock`; `@unchecked Sendable` is
// safe here and `Value` is itself Sendable, so no non-Sendable value crosses
// threads. A plain `Sendable` conformance is unavailable on a class with
// mutable stored properties.
public final class BoundedRecoverableBox<Value: AnyObject & Sendable>: @unchecked Sendable {
    private final class BuildToken: @unchecked Sendable {}

    private let boxLock = NSLock()
    private var current: Value?
    private var buildTask: Task<Bool, Never>?
    /// Identity token for the current build (`Task` is a value type, so it
    /// cannot be compared with ===); stale completions use it to avoid
    /// clearing a newer build.
    private var buildToken: AnyObject?
    private var generation = 0

    public init() {}

    /// The ready service, or nil while absent. Synchronous and safe to call
    /// from any context.
    public var value: Value? { boxLock.withLock { current } }

    public var isAvailable: Bool { boxLock.withLock { current != nil } }

    /// Publishes an externally built, already-ready service (used by app
    /// assembly when the durable root resolved at launch). Replaces nothing:
    /// when a value is already present it wins and the offer is ignored, so a
    /// late assembly result can never clobber a recovered service.
    public func publish(_ offered: Value?) {
        guard let offered else { return }
        boxLock.withLock {
            guard current == nil else { return }
            current = offered
        }
    }

    /// Ensures the service is ready. `build` performs the complete
    /// asynchronous wiring and returns the ready value ONLY on success; nil
    /// means failure and publishes nothing. Concurrent calls while a build is
    /// in flight join the same task.
    @discardableResult
    public func ensure(_ build: @escaping @Sendable () async -> Value?) async -> Bool {
        if boxLock.withLock({ current != nil }) { return true }
        let pair: (task: Task<Bool, Never>, token: AnyObject?) = boxLock.withLock {
            if current != nil { return (Task<Bool, Never> { true }, nil) }
            if let existing = buildTask, let existingToken = buildToken {
                return (existing, existingToken)
            }
            generation += 1
            let token = BuildToken()
            buildToken = token
            let created = Task<Bool, Never> {
                guard let ready = await build() else {
                    clearBuild(token: token)
                    return false
                }
                return commit(ready, token: token)
            }
            buildTask = created
            return (created, token)
        }
        let result = await pair.task.value
        boxLock.withLock {
            // Clear only the build this caller joined: a newer build started
            // after a failure must survive.
            guard let token = pair.token, buildToken === token else { return }
            buildTask = nil
            buildToken = nil
        }
        return result
    }

    /// Clears a failed build the instant it finishes (only when the token is
    /// current) so the next `ensure` retries immediately instead of joining
    /// a completed failure.
    private func clearBuild(token: AnyObject) {
        boxLock.withLock {
            guard buildToken === token else { return }
            buildTask = nil
            buildToken = nil
        }
    }

    /// Publishes the built value under the lock. A value another build won
    /// first stays the winner; the caller still reads success because a ready
    /// service of the same identity exists.
    private func commit(_ built: Value, token: AnyObject) -> Bool {
        boxLock.withLock {
            if current != nil { return true }
            current = built
            if buildToken === token {
                buildTask = nil
                buildToken = nil
            }
            return true
        }
    }
}
