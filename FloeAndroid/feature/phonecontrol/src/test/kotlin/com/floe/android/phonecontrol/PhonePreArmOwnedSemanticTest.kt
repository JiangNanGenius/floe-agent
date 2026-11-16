// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the owner-not-armed artifact VIEW boundary.
// No Android service, Activity, device or accessibility event is constructed.
package com.floe.android.phonecontrol

import com.floe.android.contracts.OwnedExternalViewLaunch
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The foreground artifact handoff starts the viewer directly from Floe's own
 * Activity, outside the phone-control session. Its loading semantics can
 * arrive before the first `device.observe` establishes a fence owner. The
 * session must not turn that Agent-owned transition into a false
 * `lastInteraction` stamp, but it also cannot discard the event until the
 * exact task/run/native epoch proves ownership.
 *
 * These tests pin the pure decision boundary. The original C06 export did not
 * capture the exact event type, so this is not a claim about that specific
 * device event; it is the narrow pre-arm corollary of the existing
 * OwnedExternalViewLaunch contract.
 */
class PhonePreArmOwnedSemanticTest {

    private val task = "aaaaaaaa-1111-2222-3333-444444444444"
    private val run = "bbbbbbbb-5555-6666-7777-888888888888"
    private val gallery = "com.sec.android.gallery3d"
    private val component = "$gallery/com.sec.android.gallery3d.app.GalleryActivity"
    private val epoch = 9L
    private val baseUptime = 10_000L
    private val baseElapsed = 100_000L
    private val baseWall = 1_700_000_000_000L

    @After
    fun releaseHostLaunch() {
        OwnedExternalViewLaunch.clear()
    }

    private fun note(
        taskID: String = task,
        runID: String = run,
        nativeEpoch: Long = epoch,
        packageName: String = gallery,
        uptimeMillis: Long = baseUptime,
        elapsedRealtimeMillis: Long = baseElapsed,
        currentHost: Boolean = true,
    ): OwnedExternalViewLaunch.Snapshot? = OwnedExternalViewLaunch.note(
        taskID = taskID,
        runID = runID,
        nativeEpoch = nativeEpoch,
        hostGeneration = 3L,
        targetPackage = packageName,
        targetComponent = component,
        uptimeMillis = uptimeMillis,
        elapsedRealtimeMillis = elapsedRealtimeMillis,
        isCurrentHost = { currentHost },
    )

    private fun capture(
        holder: PhonePreArmOwnedSemantic = PhonePreArmOwnedSemantic(),
        packageName: String? = gallery,
        eventUptimeMillis: Long? = 10_500L,
        nowUptimeMillis: Long = 10_600L,
        nowElapsedRealtimeMillis: Long = 100_600L,
        nowWallMillis: Long = baseWall + 600L,
    ): Boolean = holder.capture(
        targetPackage = packageName,
        eventUptimeMillis = eventUptimeMillis,
        nowUptimeMillis = nowUptimeMillis,
        nowElapsedRealtimeMillis = nowElapsedRealtimeMillis,
        nowWallMillis = nowWallMillis,
    )

    @Test
    fun exactOwnerAndLaunchWindowDeferThenDiscardTheOwnedEvent() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        val held = holder.current
        assertNotNull(held)
        assertEquals(gallery, held?.packageName)
        assertEquals(task, held?.launch?.taskID)
        assertEquals(run, held?.launch?.runID)
        assertEquals(epoch, held?.launch?.nativeEpoch)

        val resolution = holder.resolve(task, run, epoch)
        assertTrue(resolution is PhonePreArmOwnedSemantic.Resolution.Owned)
        assertEquals(gallery,
            (resolution as PhonePreArmOwnedSemantic.Resolution.Owned).candidate.packageName)
        assertNull(holder.current)
        // Ownership resolution does not consume the host record: a viewer may
        // still emit its loading semantics inside the same bounded window.
        assertNotNull(OwnedExternalViewLaunch.current())
        // A candidate resolves exactly once; it can never be replayed.
        assertEquals(PhonePreArmOwnedSemantic.Resolution.None,
            holder.resolve(task, run, epoch))
    }

    @Test
    fun c06FirstHandoffTimelineSurvivesTheHostRecordHorizon() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        // Artifact handoff accepted at t=0; the viewer's semantic event at
        // +798 ms is still inside the 5 s launch window, so the exact host
        // identity is captured even though no phone-control owner exists yet.
        assertTrue(capture(
            holder,
            eventUptimeMillis = baseUptime + 798L,
            nowUptimeMillis = baseUptime + 798L,
            nowElapsedRealtimeMillis = baseElapsed + 798L,
            nowWallMillis = baseWall + 798L,
        ))
        // device.observe arrives at +14.923 s, after the 5 s host record
        // window. Deferring the classification until this principal arrives
        // is what prevents the false platform_semantic presence stamp; the
        // exact task/run/native epoch still proves ownership.
        val resolution = holder.resolve(task, run, epoch)
        assertTrue(resolution is PhonePreArmOwnedSemantic.Resolution.Owned)
        assertNull(holder.current)
    }

    @Test
    fun exactIdentityIsCaseInsensitiveLikeTheSharedContract() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        val resolution = holder.resolve(task.uppercase(), run.uppercase(), epoch)
        assertTrue("case-insensitive identity",
            resolution is PhonePreArmOwnedSemantic.Resolution.Owned)
    }

    @Test
    fun revokedOrReplacedHostLaunchCannotSuppressADeferredEvent() {
        for (invalidate in listOf<() -> Unit>(
            { OwnedExternalViewLaunch.clear() },
            { note() }, // Even an identical new launch is a distinct authority.
        )) {
            assertNotNull(note())
            val holder = PhonePreArmOwnedSemantic()
            assertTrue(capture(holder))
            invalidate()
            assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Human)
        }
        var hostCurrent = true
        assertNotNull(OwnedExternalViewLaunch.note(
            task, run, epoch, 3L, gallery, component, baseUptime, baseElapsed,
            isCurrentHost = { hostCurrent }))
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        hostCurrent = false
        assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Human)
    }

    @Test
    fun retiringOldCandidatePreservesReplacementAndOldEventsExpire() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        val old = holder.current!!
        val replacement = note()!!
        assertFalse(OwnedExternalViewLaunch.clearIfCurrent(old.launch))
        assertTrue(OwnedExternalViewLaunch.current() === replacement)
        assertTrue(holder.isRecent(old, old.observedAtElapsedRealtimeMillis + 14_999L))
        assertFalse(holder.isRecent(old, old.observedAtElapsedRealtimeMillis + 15_000L))
        assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Human)
    }

    @Test
    fun anotherTaskRunOrEpochTurnsTheHeldEventIntoHumanInput() {
        for (identity in listOf(
            task to "cccccccc-0000-0000-0000-000000000000",
            "cccccccc-0000-0000-0000-000000000000" to run,
        )) {
            assertNotNull(note())
            val holder = PhonePreArmOwnedSemantic()
            assertTrue(capture(holder))
            val resolution = holder.resolve(identity.first, identity.second, epoch)
            assertTrue(resolution is PhonePreArmOwnedSemantic.Resolution.Human)
            assertNull(holder.current)
            OwnedExternalViewLaunch.clear()
        }

        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        assertTrue(holder.resolve(task, run, epoch + 1) is PhonePreArmOwnedSemantic.Resolution.Human)
    }

    @Test
    fun missingOrZeroPrincipalNeverInheritsTheLaunch() {
        assertNotNull(note())
        val principals: List<Triple<String?, String?, Long>> = listOf(
            Triple(null, run, epoch),
            Triple(task, null, epoch),
            Triple("", run, epoch),
            Triple(task, run, 0L),
            Triple(task, run, -1L),
        )
        for (principal in principals) {
            val holder = PhonePreArmOwnedSemantic()
            assertTrue(capture(holder))
            val resolution = holder.resolve(principal.first, principal.second, principal.third)
            assertTrue("principal=$principal",
                resolution is PhonePreArmOwnedSemantic.Resolution.Human)
        }
    }

    @Test
    fun foreignPackageNoRecordAndStaleHostAreNeverHeld() {
        val noRecord = PhonePreArmOwnedSemantic()
        assertFalse(capture(noRecord))

        assertNotNull(note())
        assertFalse(capture(PhonePreArmOwnedSemantic(), packageName = "com.sec.android.app.myfiles"))
        assertFalse(capture(PhonePreArmOwnedSemantic(), packageName = null))
        assertFalse(capture(PhonePreArmOwnedSemantic(), packageName = ""))

        OwnedExternalViewLaunch.clear()
        assertNotNull(note(currentHost = false))
        val stopped = PhonePreArmOwnedSemantic()
        assertFalse(capture(stopped))
        assertNull(stopped.current)
        // matchActive cleared the no-longer-current host record.
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun eventOutsideTheLaunchWindowIsNeverHeldAndExpiryClearsTheRecord() {
        assertNotNull(note())
        // Older than the bounded start skew.
        assertFalse(capture(
            PhonePreArmOwnedSemantic(),
            eventUptimeMillis = 9_700L,
            nowUptimeMillis = 10_600L,
        ))
        // The record is still valid for a normal in-window event.
        assertTrue(capture(PhonePreArmOwnedSemantic()))

        // One elapsed ms past the 5 s horizon the host record is expired and
        // can never revive a later event.
        val holder = PhonePreArmOwnedSemantic()
        assertFalse(capture(
            holder,
            eventUptimeMillis = 15_000L,
            nowUptimeMillis = 15_000L,
            nowElapsedRealtimeMillis = 105_001L,
        ))
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun aReaderBeforeTheRecordedLaunchCannotHoldAnEvent() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertFalse(capture(
            holder,
            eventUptimeMillis = 9_000L,
            nowUptimeMillis = 10_000L,
            nowElapsedRealtimeMillis = 99_000L,
        ))
        assertNull(holder.current)
    }

    @Test
    fun aViewerMayEmitSeveralLoadingEventsWithoutConsumingTheRecord() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(
            holder,
            eventUptimeMillis = 10_500L,
            nowUptimeMillis = 10_600L,
            nowElapsedRealtimeMillis = 100_600L,
            nowWallMillis = baseWall + 600L,
        ))
        // The record itself is not consumed by capture().
        assertNotNull(OwnedExternalViewLaunch.current())
        assertTrue(capture(
            holder,
            eventUptimeMillis = 12_000L,
            nowUptimeMillis = 12_100L,
            nowElapsedRealtimeMillis = 102_100L,
            nowWallMillis = baseWall + 2_100L,
        ))
        // The newest event's arrival/wall stamp is retained (the event was
        // delivered 100 ms before the read); the exact owner still wins.
        assertEquals(baseWall + 2_000L, holder.current?.eventWallMillis ?: -1L)
        assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Owned)
    }

    @Test
    fun realInputOrLifecycleClearDropsTheHeldEvent() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        assertNotNull(holder.clear())
        assertNull(holder.current)
        assertEquals(PhonePreArmOwnedSemantic.Resolution.None, holder.resolve(task, run, epoch))

        // A new launch can be captured after the previous decision was cleared.
        assertNotNull(note())
        assertTrue(capture(holder))
        assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Owned)
    }

    @Test
    fun newerLaunchReplacesTheHeldTarget() {
        assertNotNull(note())
        val holder = PhonePreArmOwnedSemantic()
        assertTrue(capture(holder))
        val video = "com.sec.android.app.videoplayer"
        assertNotNull(note(packageName = video, uptimeMillis = 50_000L,
            elapsedRealtimeMillis = 140_000L))
        // The old gallery event is stale for the new record and is not held;
        // the caller takes the ordinary human path for that event.
        assertFalse(capture(
            holder,
            eventUptimeMillis = 51_000L,
            nowUptimeMillis = 51_100L,
            nowElapsedRealtimeMillis = 141_100L,
        ))
        // The new target's loading event is captured and resolves only for the
        // same exact owner.
        assertTrue(capture(
            holder,
            packageName = video,
            eventUptimeMillis = 51_000L,
            nowUptimeMillis = 51_100L,
            nowElapsedRealtimeMillis = 141_100L,
        ))
        assertTrue(holder.resolve(task, run, epoch) is PhonePreArmOwnedSemantic.Resolution.Owned)
    }

    @Test
    fun invalidRecordIdentityCannotHoldAnything() {
        // note() rejects the identity and clears the slot instead of leaving an
        // older launch active for the pre-arm path to consume.
        assertNull(note(nativeEpoch = 0L))
        assertFalse(capture(PhonePreArmOwnedSemantic()))
        assertNull(OwnedExternalViewLaunch.current())
    }
}
