// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for the process-local Agent-owned external launch fact.
// No Android service, Activity, device or notification state is constructed.
package com.floe.android.contracts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.After
import org.junit.Test

/**
 * Full15/121 boundary: the foreground artifact handoff starts the viewer
 * directly from Floe's Activity, outside the phone-control session. Its
 * programmatic loading semantics must still be attributable to that exact
 * Agent-owned launch rather than becoming fresh human presence.
 *
 * These are contract tests for the bounded host fact, not a claim about the
 * specific accessibility event that occurred on the device (the original
 * export did not capture its type or timestamp).
 */
class OwnedExternalViewLaunchTest {

    private val task = "aaaaaaaa-1111-2222-3333-444444444444"
    private val run = "bbbbbbbb-5555-6666-7777-888888888888"
    private val gallery = "com.sec.android.gallery3d"
    private val component = "$gallery/com.sec.android.gallery3d.app.GalleryActivity"
    private var liveHostEpoch = 9L
    private var liveHostGeneration = 3L

    @After
    fun releaseLaunch() { OwnedExternalViewLaunch.clear() }

    private fun note(
        uptime: Long = 10_000L,
        elapsed: Long = 100_000L,
        epoch: Long = 9L,
        packageName: String = gallery,
        taskID: String = task,
        runID: String = run,
    ) = OwnedExternalViewLaunch.note(
        taskID = taskID,
        runID = runID,
        nativeEpoch = epoch,
        hostGeneration = 3L,
        targetPackage = packageName,
        targetComponent = component,
        uptimeMillis = uptime,
        elapsedRealtimeMillis = elapsed,
        isCurrentHost = { liveHostEpoch == epoch && liveHostGeneration == 3L },
    )

    private fun match(
        packageName: String? = gallery,
        eventUptime: Long? = 11_000L,
        nowUptime: Long = 11_000L,
        nowElapsed: Long = 101_000L,
        epoch: Long = 9L,
        expectedTask: String? = task,
        expectedRun: String? = run,
    ): OwnedExternalViewLaunch.Snapshot? = OwnedExternalViewLaunch.matchActive(
        targetPackage = packageName,
        eventUptimeMillis = eventUptime,
        nowUptimeMillis = nowUptime,
        nowElapsedRealtimeMillis = nowElapsed,
        expectedNativeEpoch = epoch,
        expectedTaskID = expectedTask,
        expectedRunID = expectedRun,
    )

    @Test
    fun exactOwnedViewerLoadingSemanticsMatch() {
        assertNotNull(note())
        val first = match(eventUptime = 10_400L, nowUptime = 10_500L, nowElapsed = 100_500L)
        assertNotNull(first)
        assertEquals(task, first?.taskID)
        assertEquals(gallery, first?.targetPackage)
        // A viewer may emit several loading events; the record is not consumed.
        assertNotNull(match(eventUptime = 14_000L, nowUptime = 14_100L, nowElapsed = 104_100L))
    }

    @Test
    fun foreignPackageOrNoPackageNeverMatches() {
        assertNotNull(note())
        assertNull(match(packageName = "com.sec.android.app.myfiles"))
        assertNull(match(packageName = "com.android.systemui"))
        assertNull(match(packageName = null))
        assertNull(match(packageName = ""))
    }

    @Test
    fun expiryClearsTheRecord() {
        assertNotNull(note())
        // Exactly at the monotonic end it is still owned; one ms later it is not.
        assertNotNull(match(eventUptime = 15_000L, nowUptime = 15_000L, nowElapsed = 105_000L))
        assertNull(match(eventUptime = 15_001L, nowUptime = 15_001L, nowElapsed = 105_001L))
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun staleOrFutureEventStampNeverMatches() {
        assertNotNull(note(uptime = 10_000L))
        // Older than the small start skew.
        assertNull(match(eventUptime = 9_700L, nowUptime = 10_100L, nowElapsed = 100_100L))
        // The small skew still accepts a dispatch generated just before note().
        assertNotNull(match(eventUptime = 9_800L, nowUptime = 10_100L, nowElapsed = 100_100L))
        // Past the bounded end.
        assertNull(match(eventUptime = 15_001L, nowUptime = 15_001L, nowElapsed = 104_000L))
        // A reader before the recorded launch can never match it.
        assertNull(match(nowElapsed = 99_000L))
    }

    @Test
    fun aStoppedGenerationOrAnotherTaskCannotInheritTheLaunch() {
        assertNotNull(note())
        assertNull(match(epoch = 10L))
        assertNull(match(expectedTask = "cccccccc-0000-0000-0000-000000000000"))
        assertNull(match(expectedRun = "dddddddd-0000-0000-0000-000000000000"))
        // Unknown ownership never suppresses an input stamp for a later task.
        assertNull(match(expectedTask = null, expectedRun = null))
        assertNull(match(epoch = 0L))
        assertNull(match(expectedTask = ""))
        // Case-insensitive identity keeps the same task/run equal across the
        // native uppercase and JVM lowercase spellings.
        assertNotNull(match(expectedTask = task.uppercase(), expectedRun = run.uppercase()))
    }

    @Test
    fun aNewerLaunchReplacesTheOldOne() {
        assertNotNull(note())
        val second = note(uptime = 50_000L, elapsed = 140_000L,
            packageName = "com.sec.android.app.videoplayer")
        assertNotNull(second)
        assertNull(match(packageName = gallery, eventUptime = 51_000L,
            nowUptime = 51_000L, nowElapsed = 141_000L))
        assertNotNull(match(packageName = "com.sec.android.app.videoplayer",
            eventUptime = 51_000L, nowUptime = 51_000L, nowElapsed = 141_000L))
    }

    @Test
    fun invalidIdentityClearsRatherThanKeepingAnOlderLaunch() {
        assertNotNull(note())
        assertNull(note(packageName = " "))
        assertNull(OwnedExternalViewLaunch.current())
        assertNotNull(note())
        assertNull(note(epoch = 0L))
        assertNull(OwnedExternalViewLaunch.current())
        assertNotNull(note())
        assertNull(note(taskID = ""))
        assertNull(OwnedExternalViewLaunch.current())
        assertNotNull(note())
        assertNull(note(packageName = "x".repeat(OwnedExternalViewLaunch.MAX_PACKAGE_CHARS + 1)))
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun clearEndsAttributionImmediately() {
        assertNotNull(note())
        assertNotNull(OwnedExternalViewLaunch.clear())
        assertNull(OwnedExternalViewLaunch.current())
        assertNull(match())
        assertNull(OwnedExternalViewLaunch.clear())
    }

    @Test
    fun changedHostGenerationInvalidatesEvenTheSameTaskAndNativeEpoch() {
        assertNotNull(note())
        liveHostGeneration++
        assertNull(match())
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun retiredHostEpochCannotBeRevivedByTheCachedExpectedEpoch() {
        assertNotNull(note())
        liveHostEpoch++
        assertNull(match(epoch = 9L))
        assertNull(OwnedExternalViewLaunch.current())
    }

    @Test
    fun lateStopFromAnOlderRunLeavesTheNewRunLaunchIntact() {
        val nextRun = "eeeeeeee-0000-0000-0000-000000000000"
        assertNotNull(note(runID = nextRun))
        assertNull(OwnedExternalViewLaunch.clearForOwner(task, run))
        assertNotNull(match(expectedRun = nextRun))
        assertNotNull(OwnedExternalViewLaunch.clearForOwner(task, nextRun))
        assertNull(match(expectedRun = nextRun))
    }
}
