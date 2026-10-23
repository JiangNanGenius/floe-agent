// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A WebKit reply may never arrive. Each read-only readiness probe owns a
/// separate receipt so timeout, cancellation and late replies settle once.
@MainActor
enum OfficeBackendReadinessProbe {
    static func run(timeout: TimeInterval,
                    start: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        guard timeout.isFinite, timeout > 0, timeout <= 30, !Task.isCancelled else { return false }
        let receipt = Receipt()
        let timer = Task {
            do { try await Task.sleep(for: .seconds(timeout)) }
            catch { return }
            receipt.resolve(false)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                receipt.register(continuation)
                guard !Task.isCancelled else {
                    receipt.resolve(false)
                    return
                }
                start { receipt.resolve($0) }
            }
        } onCancel: {
            receipt.resolve(false)
        }
    }

    private final class Receipt: @unchecked Sendable {
        private let lock = NSLock()
        private var settled: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func register(_ waiting: CheckedContinuation<Bool, Never>) {
            let value: Bool? = lock.withLock {
                if let settled { return settled }
                continuation = waiting
                return nil
            }
            if let value { waiting.resume(returning: value) }
        }

        func resolve(_ value: Bool) {
            let waiting: CheckedContinuation<Bool, Never>? = lock.withLock {
                guard settled == nil else { return nil }
                settled = value
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.resume(returning: value)
        }
    }
}
