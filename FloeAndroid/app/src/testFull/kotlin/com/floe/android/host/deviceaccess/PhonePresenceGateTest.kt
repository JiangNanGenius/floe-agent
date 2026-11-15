// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the host's human-presence decision. No Android
// service, device, display or Compose state is constructed here.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneInteractionStamp
import com.floe.android.phonecontrol.PhoneUserInteractionSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Full15/121 failure boundary: a session that has observed NO human
 * input must never look like a fresh user touch after an earlier approval.
 *
 * The previous gate seeded the session's interaction stamps with the session
 * construction time, so a reconnect, rebind or released arm between the
 * approval and the next `device.observe` could produce
 * `device_presence_required` with no actual user input. These cases keep the
 * genuine-touch behavior identical while making "no observed signal" honest.
 */
class PhonePresenceGateTest {

    private fun stamp(
        elapsed: Long,
        wall: Long,
        source: PhoneUserInteractionSource = PhoneUserInteractionSource.PLATFORM_RAW_TOUCH,
        packageName: String? = null,
    ) = PhoneInteractionStamp(
        elapsedRealtimeMillis = elapsed,
        wallMillis = wall,
        source = source,
        semanticPackage = packageName,
    )

    private fun requires(
        now: Long,
        interaction: PhoneInteractionStamp?,
        approved: Long,
    ): Boolean = PhonePresenceGate.requiresHumanApproval(
        nowElapsedRealtimeMillis = now,
        interaction = interaction,
        presenceApprovedAtMillis = approved,
    )

    @Test
    fun sessionStartIsNotHumanPresence() {
        // No observed signal at all.
        assertFalse(requires(now = 1_000_000L, interaction = null, approved = 0L))
        assertFalse(requires(now = 1_000_000L, interaction = null, approved = 999_000L))
        // A zero-valued placeholder is not a signal either.
        assertFalse(requires(now = 1_000_000L, interaction = stamp(0L, 0L), approved = 0L))
        assertFalse(requires(now = 1_000_000L,
            interaction = stamp(0L, 1_700_000_000_000L), approved = 0L))
        assertFalse(requires(now = 1_000_000L,
            interaction = stamp(999_000L, 0L), approved = 0L))
        // An explicit NONE stamp never asks.
        assertFalse(requires(now = 1_000_000L,
            interaction = stamp(999_000L, 1_700_000_000_000L,
                source = PhoneUserInteractionSource.NONE),
            approved = 0L))
    }

    @Test
    fun realRecentTouchNewerThanApprovalStillAsks() {
        assertTrue(requires(now = 1_000_000L,
            interaction = stamp(999_000L, 1_700_000_000_000L),
            approved = 1_699_999_999_000L))
        // Initial arm with no approval yet: a real touch still needs Allow.
        assertTrue(requires(now = 1_000_000L,
            interaction = stamp(999_000L, 1_700_000_000_000L),
            approved = 0L))
    }

    @Test
    fun approvalAfterTheTouchDoesNotAskAgain() {
        // The human answered AFTER the observed touch: no re-ask.
        assertFalse(requires(now = 1_000_000L,
            interaction = stamp(998_000L, 1_700_000_000_000L),
            approved = 1_700_000_003_000L))
        assertFalse(requires(now = 1_000_000L,
            interaction = stamp(999_999L, 1_700_000_000_000L),
            approved = 1_700_000_000_000L))
    }

    @Test
    fun oldTouchOutsideActiveWindowDoesNotAsk() {
        // 15 000 ms is the exact existing active-window boundary.
        assertTrue(requires(now = 1_015_000L,
            interaction = stamp(1_000_001L, 1_700_000_000_000L), approved = 0L))
        assertFalse(requires(now = 1_015_000L,
            interaction = stamp(1_000_000L, 1_700_000_000_000L), approved = 0L))
        assertFalse(requires(now = 1_100_000L,
            interaction = stamp(1_000_000L, 1_700_000_000_000L), approved = 0L))
    }

    @Test
    fun aNewerApprovalNeverRevivesAnOldSignal() {
        // Stale stamp from before the approval with a fresh approval.
        assertFalse(requires(now = 1_010_000L,
            interaction = stamp(1_000_500L, 1_700_000_000_000L),
            approved = 1_700_000_005_000L))
        // But a genuinely newer signal after that approval still asks.
        assertTrue(requires(now = 1_010_000L,
            interaction = stamp(1_000_500L, 1_700_000_006_000L),
            approved = 1_700_000_005_000L))
    }

    @Test
    fun semanticOwnedViewSignalUsesTheSameHonestGate() {
        // A semantic package signal is still a human signal at this layer; the
        // owned-view bypass is a separate, host-recorded correlation.
        val semantic = stamp(1_000_000L, 1_700_000_000_000L,
            source = PhoneUserInteractionSource.PLATFORM_SEMANTIC,
            packageName = "com.sec.android.gallery3d")
        assertTrue(requires(now = 1_001_000L, interaction = semantic, approved = 0L))
        assertFalse(requires(now = 1_001_000L, interaction = semantic,
            approved = 1_700_000_000_500L))
    }
}
