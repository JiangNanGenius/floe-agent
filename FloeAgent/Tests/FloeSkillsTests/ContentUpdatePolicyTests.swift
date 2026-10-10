// FloeSkillsTests — pure scheduling policy for content updates: cooldown,
// backoff, WiFi-only automatic downloads and retry scheduling.

import Foundation
import Testing
@testable import FloeSkills

@Suite("Content update policy")
struct ContentUpdatePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Automatic check respects cooldown, backoff and the master toggle")
    func automaticCheckDue() {
        // Fresh state: allowed.
        #expect(ContentUpdatePolicy.automaticCheckDue(
            lastCheck: nil, retryAfter: nil, now: now, automaticChecksEnabled: true))
        // Within the 24 h cooldown: refused.
        #expect(!ContentUpdatePolicy.automaticCheckDue(
            lastCheck: now.addingTimeInterval(-60), retryAfter: nil,
            now: now, automaticChecksEnabled: true))
        // Cooldown expired: allowed again.
        #expect(ContentUpdatePolicy.automaticCheckDue(
            lastCheck: now.addingTimeInterval(-25 * 3_600), retryAfter: nil,
            now: now, automaticChecksEnabled: true))
        // Inside a failure backoff window: refused even past the cooldown.
        #expect(!ContentUpdatePolicy.automaticCheckDue(
            lastCheck: now.addingTimeInterval(-25 * 3_600),
            retryAfter: now.addingTimeInterval(60),
            now: now, automaticChecksEnabled: true))
        // Backoff expired: allowed.
        #expect(ContentUpdatePolicy.automaticCheckDue(
            lastCheck: now.addingTimeInterval(-25 * 3_600),
            retryAfter: now.addingTimeInterval(-60),
            now: now, automaticChecksEnabled: true))
        // Master toggle off: refused regardless.
        #expect(!ContentUpdatePolicy.automaticCheckDue(
            lastCheck: nil, retryAfter: nil, now: now, automaticChecksEnabled: false))
    }

    @Test("A normal (non-forced) visit respects the same cooldown and backoff")
    func manualNonForcedCheckRespectsCooldown() {
        #expect(ContentUpdatePolicy.manualCheckAllowed(
            retryAfter: nil, now: now, lastCheck: nil))
        #expect(!ContentUpdatePolicy.manualCheckAllowed(
            retryAfter: nil, now: now, lastCheck: now.addingTimeInterval(-60)))
        #expect(!ContentUpdatePolicy.manualCheckAllowed(
            retryAfter: now.addingTimeInterval(30), now: now, lastCheck: nil))
        #expect(ContentUpdatePolicy.manualCheckAllowed(
            retryAfter: now.addingTimeInterval(-30),
            now: now, lastCheck: now.addingTimeInterval(-25 * 3_600)))
    }

    @Test("WiFi-only automatic downloads stay off until WiFi is confirmed")
    func wifiOnlyGate() {
        // Unknown interface must never allow a download.
        #expect(!ContentUpdatePolicy.automaticDownloadAllowed(
            wifiOnly: true, onWiFiKnown: false, onWiFi: false))
        #expect(!ContentUpdatePolicy.automaticDownloadAllowed(
            wifiOnly: true, onWiFiKnown: false, onWiFi: true))
        // Known non-WiFi: refused; known WiFi (or wired): allowed.
        #expect(!ContentUpdatePolicy.automaticDownloadAllowed(
            wifiOnly: true, onWiFiKnown: true, onWiFi: false))
        #expect(ContentUpdatePolicy.automaticDownloadAllowed(
            wifiOnly: true, onWiFiKnown: true, onWiFi: true))
        // Policy off: any interface works, even unknown.
        #expect(ContentUpdatePolicy.automaticDownloadAllowed(
            wifiOnly: false, onWiFiKnown: false, onWiFi: false))
    }

    @Test("Retry backoff steps 30 min beyond the prior window, floors at 15 min, caps at 24 h")
    func retryBackoff() {
        // First failure: one base*2 step from now (preserved legacy
        // schedule), floored at the base window.
        let first = ContentUpdatePolicy.nextRetry(priorRetryAfter: nil, now: now)
        #expect(first == now.addingTimeInterval(ContentUpdatePolicy.retryBase * 2))
        // Each subsequent failure steps the same increment beyond the prior
        // deadline…
        let second = ContentUpdatePolicy.nextRetry(priorRetryAfter: first, now: now)
        #expect(second == first.addingTimeInterval(ContentUpdatePolicy.retryBase * 2))
        // A far-future prior deadline is capped at 24 h from now…
        let capped = ContentUpdatePolicy.nextRetry(
            priorRetryAfter: now.addingTimeInterval(48 * 3_600), now: now)
        #expect(capped == now.addingTimeInterval(ContentUpdatePolicy.retryCap))
        // …and the floor keeps any retry at least the base window out.
        let floored = ContentUpdatePolicy.nextRetry(
            priorRetryAfter: now.addingTimeInterval(-60 * 3_600), now: now)
        #expect(floored == now.addingTimeInterval(ContentUpdatePolicy.retryBase))
    }
}
