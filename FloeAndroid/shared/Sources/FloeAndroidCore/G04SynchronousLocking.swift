// SPDX-License-Identifier: MPL-2.0
//
// Shared Swift-6-safe scoped synchronous locking helper for the G04 native
// cohort. `NSLock.lock()/unlock()` are `noasync`-unavailable from async
// contexts; the established pattern in this module (G02TransportGate,
// FacadeEventPump) wraps SHORT critical sections in a synchronous helper so
// async code never calls the pair directly and the lock is never held across
// an `await`. This file generalizes that pattern module-wide once; the
// pre-existing fileprivate variants stay as they are.

import Foundation

extension NSLock {
    /// Synchronous scoped helper. Callers must keep the body bounded and
    /// await-free — the same contract the original inline lock/unlock pairs
    /// already enforced (first-fail-fast guards, epoch flips, snapshot-and-
    /// drain bookkeeping).
    @inline(__always)
    func g04Locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension NSCondition {
    /// Same scoped contract as `NSLock.g04Locked`; `wait`/`signal` stay at
    /// their original call sites — only direct `lock()/unlock()` pairs in
    /// async contexts route through this helper.
    @inline(__always)
    func g04Locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
