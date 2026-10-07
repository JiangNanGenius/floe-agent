// FloeWorkbench — CAD document session identity and transaction gating.
//
// Two correctness properties from review:
//   * A CAD document identity must include the canonical workspace root (and
//     environment/owner), not just the workspace-relative path, so two roots
//     with the same file name never share an engine session.
//   * Document transactions must be serialized as a unit (open → edit → save →
//     commit), not command by command, because the engine session is stateful
//     and actor reentrancy otherwise lets two grants interleave at awaits.

import Foundation

public enum CadDocumentIdentity {
    /// Stable session key for a resolved document. `rootPath` must already be
    /// canonicalized (standardized + symlink-resolved).
    public static func sessionKey(environmentID: String?, ownerKind: String?,
                                  ownerID: UUID?, rootPath: String,
                                  relativePath: String) -> String {
        [
            environmentID ?? "-",
            ownerKind ?? "-",
            ownerID?.uuidString ?? "-",
            rootPath,
            relativePath,
        ].joined(separator: "\u{1F}")
    }
}

/// A minimal fair async mutex. `lock()` waits for the current holder; `unlock()`
/// hands off to the next waiter. Used to serialize whole document transactions.
public actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// Runs `body` while holding the lock; always releases.
    public func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let result = try await body()
            unlock()
            return result
        } catch {
            unlock()
            throw error
        }
    }

    public var isBusy: Bool { isLocked }
}
