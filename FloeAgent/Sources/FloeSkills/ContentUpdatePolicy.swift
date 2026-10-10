// SPDX-License-Identifier: MPL-2.0
//
// Pure content-update scheduling policy. Extracted from the UI facade so the
// rules are unit-testable without the app: cooldown, backoff, WiFi-only
// automatic downloads and retry scheduling. The center applies these
// verbatim; the values are the single source of truth for both the
// automatic and the manual paths.

import Foundation

public enum ContentUpdatePolicy {
    /// Cooldown between automatic checks.
    public static let checkCooldown: TimeInterval = 24 * 3_600
    /// Base backoff step added on every failed check.
    public static let retryBase: TimeInterval = 15 * 60
    /// Maximum backoff window measured from `now`.
    public static let retryCap: TimeInterval = 24 * 3_600
    /// Multiplier applied to the base step; the schedule is deliberately
    /// additive (each failure steps `base * multiplier` beyond the prior
    /// deadline), not exponential.
    public static let retryMultiplier: TimeInterval = 2

    /// Whether an automatic check may run now: enabled, outside the check
    /// cooldown, and not inside a failure backoff window.
    public static func automaticCheckDue(
        lastCheck: Date?,
        retryAfter: Date?,
        now: Date,
        automaticChecksEnabled: Bool
    ) -> Bool {
        guard automaticChecksEnabled else { return false }
        return manualCheckAllowed(retryAfter: retryAfter, now: now, lastCheck: lastCheck)
    }

    /// Whether a non-forced explicit check may run now (a normal page visit
    /// respects the same cooldown/backoff as the automatic path; only an
    /// explicit pull-to-refresh or button passes `force: true`).
    public static func manualCheckAllowed(
        retryAfter: Date?,
        now: Date,
        lastCheck: Date?
    ) -> Bool {
        if let retryAfter, retryAfter > now { return false }
        if let lastCheck, now.timeIntervalSince(lastCheck) < checkCooldown { return false }
        return true
    }

    /// Whether an automatic download may start under the WiFi-only policy.
    /// `onWiFiKnown` is false until the path monitor reports its first
    /// update; an unknown interface must never allow an automatic download
    /// when the WiFi-only gate is on.
    public static func automaticDownloadAllowed(
        wifiOnly: Bool,
        onWiFiKnown: Bool,
        onWiFi: Bool
    ) -> Bool {
        guard wifiOnly else { return true }
        return onWiFiKnown && onWiFi
    }

    /// Next backoff deadline after a failed check. The deliberate schedule is
    /// additive: the new deadline is `base * multiplier` beyond the prior
    /// deadline, capped at `cap` from `now` and floored at `base` from `now`.
    public static func nextRetry(
        priorRetryAfter: Date?,
        now: Date,
        base: TimeInterval = retryBase,
        cap: TimeInterval = retryCap,
        multiplier: TimeInterval = retryMultiplier
    ) -> Date {
        let prior = priorRetryAfter ?? now
        let grown = prior.addingTimeInterval(base * multiplier)
        let capped = min(grown, now.addingTimeInterval(cap))
        return max(capped, now.addingTimeInterval(base))
    }
}
