// SPDX-License-Identifier: MPL-2.0
//
// Bounded retry for the pinned Office engine's save-admission race.
//
// The engine admits one save at a time. The *proven*, app-side busy signal
// is native error 9 ("a save is already in progress"): `saveReceipts begin:`
// refuses to start a second tracked save while another receipt is open, and
// the embedding overlay routes every frontend Save through that admission
// so an untracked save cannot steal an in-flight receipt. A retry after that
// busy signal settles succeeds — the same contract a deselect-and-retry
// satisfies.
//
// Native error 8 is deliberately NOT retried here: it is the generic
// "could not complete this save" completion, covering kit sequence-save
// failures and JS-dispatch rejection as well as broker admission refusal,
// so blanket-retrying it would mask a genuine first-save failure. It
// surfaces as a failure with the working copy retained, and the real-engine
// qualification stage evidence (`save.failed` domain/code) decides whether a
// future, reason-preserving bridge change is warranted.

import Foundation

#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

enum OfficeSaveAdmissionRetry {
    /// Settle delay before the retry so the in-flight save activity can
    /// finish.
    static let retryDelayNanoseconds: UInt64 = 600_000_000

    /// Mirrors `FloeOfficeNativeErrorDomain`; kept resolvable without the
    /// framework so the policy stays unit-testable on every host.
    static let errorDomain: String = {
        #if canImport(FloeOfficeNative)
        return FloeOfficeNativeErrorDomain
        #else
        return "org.floeagent.office.native"
        #endif
    }()

    /// Whether a failed save attempt may be retried once: only the proven
    /// pre-dispatch busy signal (another tracked save still open) qualifies.
    /// Generic completion failures (code 8), conflicts, timeouts, missing
    /// sessions and transport errors propagate unchanged so a real
    /// first-save defect is never masked by an automatic retry.
    static func isRetryableBusy(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == errorDomain && ns.code == 9
    }

    /// Runs `attempt` once and, on the busy signal only, retries it exactly
    /// once after the settle delay. The delay throws, so cancellation
    /// prevents the second attempt instead of silently writing again.
    /// `onRetry` observes the scheduled retry (stage recording).
    /// Returns the number of attempts performed (1 or 2).
    @discardableResult
    static func run(
        onRetry: @Sendable () -> Void = {},
        delay: @Sendable () async throws -> Void = {
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        },
        attempt: @Sendable () async throws -> Void
    ) async throws -> Int {
        do {
            try await attempt()
            return 1
        } catch {
            guard isRetryableBusy(error) else { throw error }
            onRetry()
            try await delay()
            try await attempt()
            return 2
        }
    }
}
