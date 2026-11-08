// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Owns one compiled, Sendable value preparation off the caller's actor.
/// The operation defines its cancellation/commit boundaries; cancellation
/// cancels the owned worker and the caller still joins it before returning.
public enum NativeValuePreparation {
    public static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
