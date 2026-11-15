// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the Full15/121 boundary: an Agent-owned artifact VIEW to an
 * authorized external app is followed by `device.observe`, and the viewer's
 * own programmatic loading semantics must not become a false human-presence
 * signal.
 *
 * The record is deliberately narrow: exact owner/epoch/generation/target,
 * bounded, one launch transaction, cleared by any real human signal. A
 * genuine touch is never absorbed; foreign/late/no-owner events keep the
 * conservative takeover path.
 *
 * The original export did not record the exact accessibility event type or
 * timestamp, so these are contract tests for the fixed decision boundary, not
 * a claim about the specific event that occurred on that device.
 */
class PhoneOwnedViewTransitionTest {

    private val task = UUID.fromString("00000000-0000-0000-0000-000000000001")
    private val run = UUID.fromString("00000000-0000-0000-0000-000000000002")
    private val owner = PhoneControlOwner(task, run)
    private val otherOwner = PhoneControlOwner(task, UUID.randomUUID())
    private val gallery = "com.sec.android.gallery3d"
    private val component = "$gallery/com.sec.android.gallery3d.app.GalleryActivity"
    private val epoch = 7L
    private val generation = 7L

    private fun armed(
        transition: PhoneOwnedViewTransition = PhoneOwnedViewTransition(),
        uptime: Long = 1_000L,
        targetPackage: String = gallery,
    ): PhoneOwnedViewTransition {
        assertNotNull(transition.arm(
            owner = owner,
            epoch = epoch,
            generation = generation,
            targetPackage = targetPackage,
            targetComponent = component,
            uptimeMillis = uptime,
        ))
        return transition
    }

    private fun absorbs(
        transition: PhoneOwnedViewTransition,
        packageName: String? = gallery,
        eventUptime: Long? = 1_500L,
        nowUptime: Long = 1_500L,
        fenceOwner: PhoneControlOwner? = owner,
        blocked: Boolean = false,
        currentEpoch: Long = epoch,
        currentGeneration: Long = generation,
    ): Boolean = transition.absorbs(
        packageName = packageName,
        eventUptimeMillis = eventUptime,
        fenceOwner = fenceOwner,
        fenceBlocked = blocked,
        nowUptimeMillis = nowUptime,
        currentEpoch = currentEpoch,
        currentGeneration = currentGeneration,
    )

    @Test
    fun ownedGalleryLoadingIsAttributedOnlyDuringItsLaunchWindow() {
        val transition = armed()
        // The viewer inflates, decodes and scrolls its own grid after VIEW.
        assertTrue(absorbs(transition, eventUptime = 1_100L, nowUptime = 1_200L))
        assertTrue(absorbs(transition, eventUptime = 4_000L, nowUptime = 4_050L))
        // Still one bounded record, not an extended suppression window.
        assertEquals(6_000L, transition.armed?.untilUptimeMillis ?: -1L)
    }

    @Test
    fun clearingTheLaunchPreventsAnyLaterAttribution() {
        // Raw touch is a separate session entry point and never calls
        // absorbs(); the contract here is that a record exists yet the raw
        // signal path must still clear it explicitly.
        val transition = armed()
        assertNotNull(transition.clear())
        assertFalse(absorbs(transition))
        assertNull(transition.armed)
    }

    @Test
    fun foreignPackageEventStaysHuman() {
        val transition = armed()
        assertFalse(absorbs(transition, packageName = "com.sec.android.app.myfiles"))
        assertFalse(absorbs(transition, packageName = "com.android.systemui"))
        assertFalse(absorbs(transition, packageName = null))
        assertFalse(absorbs(transition, packageName = ""))
    }

    @Test
    fun eventOlderThanTheLaunchOrPastTheHorizonStaysHuman() {
        val transition = armed(uptime = 10_000L)
        // A stale/recycled stamp from before the launch is not our dispatch.
        assertFalse(absorbs(transition, eventUptime = 9_000L, nowUptime = 10_100L))
        // At the exact bounded end it is still owned; one ms later it is not.
        assertTrue(absorbs(transition, eventUptime = 15_000L, nowUptime = 15_000L))
        assertFalse(absorbs(transition, eventUptime = 15_001L, nowUptime = 15_001L))
        // Expiry clears the record so a later event cannot revive it.
        assertNull(transition.armed)
    }

    @Test
    fun arrivalAfterHorizonExpiresEvenForAnInWindowEvent() {
        val transition = armed(uptime = 10_000L)
        assertFalse(absorbs(transition, eventUptime = 15_000L, nowUptime = 30_001L))
        assertNull(transition.armed)
    }

    @Test
    fun anotherOwnerOrGenerationCannotInheritTheLaunch() {
        val transition = armed()
        assertFalse(absorbs(transition, fenceOwner = otherOwner))
        assertFalse(absorbs(transition, currentEpoch = epoch + 1))
        assertFalse(absorbs(transition, currentGeneration = generation + 1))
        // No owner at all (taken over / stopped / no arm) stays conservative.
        assertFalse(absorbs(transition, fenceOwner = null))
        // A blocker means the session already fenced; nothing is absorbed.
        assertFalse(absorbs(transition, blocked = true))
        assertNull(transition.armed)
    }

    @Test
    fun clearingEndsAttributionImmediately() {
        val transition = armed()
        assertNotNull(transition.clear())
        assertFalse(absorbs(transition))
        // A re-arm is a new transaction.
        armed(transition, uptime = 50_000L)
        assertTrue(absorbs(transition, eventUptime = 51_000L, nowUptime = 51_000L))
    }

    @Test
    fun aNewLaunchReplacesTheOldTarget() {
        val transition = armed()
        val video = "com.sec.android.app.videoplayer"
        armed(transition, uptime = 2_000L, targetPackage = video)
        assertFalse(absorbs(transition, packageName = gallery, eventUptime = 2_100L, nowUptime = 2_100L))
        assertTrue(absorbs(transition, packageName = video, eventUptime = 2_100L, nowUptime = 2_100L))
    }

    @Test
    fun blankTargetOrInvalidGenerationNeverArms() {
        val transition = PhoneOwnedViewTransition()
        assertNull(transition.arm(owner, epoch, generation, " ", component, 1_000L))
        assertNull(transition.arm(owner, 0L, generation, gallery, component, 1_000L))
        assertNull(transition.arm(owner, epoch, 0L, gallery, component, 1_000L))
        assertFalse(absorbs(transition))
    }

    @Test
    fun smallGenerationSkewStillBelongsToTheLaunch() {
        val transition = armed(uptime = 5_000L)
        // A framework-scheduled dispatch can be stamped a few ms before the
        // record is written; the small skew is bounded and never extends the
        // end of the window.
        assertTrue(absorbs(transition, eventUptime = 4_800L, nowUptime = 5_100L))
        assertFalse(absorbs(transition, eventUptime = 4_700L, nowUptime = 5_100L))
    }
}
