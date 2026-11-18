// SPDX-License-Identifier: MPL-2.0
//
// Single-value completion gate for the local serial transports. The shared
// ClientCompletion is internal to FloeToolboxClients; this module keeps its
// own identical-semantics gate so the adapters stay self-contained.

import Foundation
import FloeToolboxClients

final class MacSerialCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func wait(seconds: TimeInterval) async throws -> Value {
        let timer = Task {
            do { try await Task.sleep(for: .seconds(max(0.1, seconds))) } catch { return }
            finish(.failure(ClientError.timedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }
}
