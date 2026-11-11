// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Tracks the submit call itself. The worker's workspace lease can remain
/// alive long after submission, until that worker's monitoring finishes.
@MainActor final class ChemistrySubmissionTracker {
    enum Failure: Error { case duplicateSubmission }
    private var pending: Set<UUID> = []

    func isSubmitting(_ id: UUID) -> Bool { pending.contains(id) }

    func perform<T>(_ id: UUID, operation: @MainActor () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard pending.insert(id).inserted else { throw Failure.duplicateSubmission }
        defer { pending.remove(id) }
        return try await operation()
    }

    /// A timeout preserves the producer and its original; it never proves
    /// that a job was not submitted. Cancellation leaves that producer alone.
    func waitUntilSettled(_ id: UUID, timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pending.contains(id) {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else { return false }
            try await clock.sleep(until: min(deadline, now.advanced(by: .milliseconds(20))))
        }
        try Task.checkCancellation()
        return true
    }
}
