// FloeAndroid shared/Sources/FloeBrowser — exactly-once continuation gate.
//
// Mirrors the role of iOS `BrowserProbeRequest`'s internal one-shot
// (BrowserTaskSessionStore.swift @ 3fd597b…): the first of
// answer / deadline / cancellation settles the continuation exactly once and
// every later event is dropped. Nothing here waits for an uncooperative
// platform callback.

import Foundation

final class BrowserRaceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var settled = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock {
            if settled {
                continuation.resume(throwing: BrowserProbeError.released)
                return
            }
            self.continuation = continuation
        }
    }

    func attach(_ work: Task<Void, Never>) {
        lock.withLock {
            self.work = work
            if settled { work.cancel() }
        }
    }

    func settle(_ result: Result<T, Error>) {
        lock.withLock {
            guard !settled, let continuation else { return }
            settled = true
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    func cancelWork() {
        lock.withLock { work }?.cancel()
    }
}
