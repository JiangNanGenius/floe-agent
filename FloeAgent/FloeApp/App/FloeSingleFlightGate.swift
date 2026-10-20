// FloeApp — one shared in-flight async operation per gate.
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// One shared in-flight operation per gate.
///
/// Callers join the CURRENT attempt instead of starting duplicate work (the
/// launch bootstrap, interrupted-run recovery and configuration publication
/// must happen once per process). Retirement and waiting semantics:
///
/// - an attempt retires itself in the same main-actor turn in which its body
///   returns, BEFORE completion becomes visible, so a caller that arrives
///   after a failed attempt starts a real retry instead of rejoining an
///   already-finished failed attempt;
/// - retirement is generation-checked, so an older attempt can never clear a
///   newer one;
/// - waiting is cancellation-aware: a cancelled caller stops waiting and
///   returns promptly WITHOUT cancelling the shared attempt other callers (and
///   the shared work) continue with. An already-cancelled caller starts no
///   attempt at all;
/// - the attempt's Task is unstructured and owned by the runtime, never by a
///   caller, so no caller cancellation tears down shared work.
///
/// Deliberately not a service graph: the gate owns no environment, store or
/// task beyond the single attempt it joins.
@MainActor
final class FloeSingleFlightGate {
    /// One waiter's continuation, resumed exactly once by attempt completion
    /// or this caller's cancellation. The lock makes the cancellation handler
    /// (nonisolated) and the main-actor completion race safely. Completion is
    /// LATCHED: a completion that lands before `wait()` registers still
    /// resumes the later registration immediately instead of being lost.
    ///
    /// Internal so hosted qualification can prove the rendezvous directly,
    /// without depending on scheduler luck.
    final class AttemptWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false
        private var cancelled = false

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if finished || cancelled || Task.isCancelled {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    self.continuation = continuation
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                cancelled = true
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume()
            }
        }

        func complete() {
            lock.lock()
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private var attempt: (id: UInt64, waiters: [UUID: AttemptWaiter])?
    private var generation: UInt64 = 0

    /// True while an attempt is in flight. Retired synchronously when the body
    /// returns; exposed for hosted qualification.
    var isRunning: Bool { attempt != nil }

    /// Runs `body` as the shared attempt, or joins the attempt already running.
    func run(_ body: @escaping @MainActor @Sendable () async -> Void) async {
        // An already-cancelled caller never starts a new attempt and never
        // waits for one: it returns immediately.
        if Task.isCancelled { return }
        if attempt == nil {
            generation &+= 1
            let attemptID = generation
            attempt = (id: attemptID, waiters: [:])
            Task { @MainActor [weak self] in
                await body()
                self?.finish(attemptID: attemptID)
            }
        }
        await joinCurrentAttempt()
    }

    private func joinCurrentAttempt() async {
        guard let joined = attempt else { return }
        let token = UUID()
        let waiter = AttemptWaiter()
        if var current = attempt {
            current.waiters[token] = waiter
            attempt = current
        }
        await waiter.wait()
        // Stop waiting early (caller cancelled) or completed: drop our slot.
        // Completion already cleared every waiter, so this is a no-op then.
        if var current = attempt, current.id == joined.id {
            current.waiters[token] = nil
            attempt = current
        }
    }

    private func finish(attemptID: UInt64) {
        guard let current = attempt, current.id == attemptID else { return }
        // Retire BEFORE resuming waiters: completion becomes visible only after
        // the gate is ready for an explicit retry.
        attempt = nil
        for waiter in current.waiters.values {
            waiter.complete()
        }
    }
}
