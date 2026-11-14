// SPDX-License-Identifier: MPL-2.0
// Pure JVM regression for owner-fenced native run observation.
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the old-cleanup boundary:
 *  - ending A's proof must not end B's newer proof;
 *  - a Stop that lands while A's snapshot is in flight must refuse A;
 *  - B remains admissible under the same exact-owner predicate.
 */
class DeviceRunLivenessOwnerStopTest {

    private fun owner(task: Int, run: Int): PhoneControlOwner = PhoneControlOwner(
        UUID.fromString("00000000-0000-0000-0000-${task.toString().padStart(12, '0')}"),
        UUID.fromString("00000000-0000-0000-0000-${run.toString().padStart(12, '0')}"),
    )

    private class Subscription : AutoCloseable {
        var closeCount = 0
        override fun close() {
            closeCount += 1
        }
    }

    private class Source : DeviceRunReadPort {
        var epoch: Long? = 7
        var beforeRead: (suspend () -> Unit)? = null
        var readCount = 0
        val subscriptions = mutableListOf<Subscription>()

        override fun currentEpoch(): Long? = epoch
        override fun snapshotFailureCode(): String? = null

        override suspend fun snapshot(owner: PhoneControlOwner): DeviceRunProof? {
            readCount += 1
            beforeRead?.invoke()
            return DeviceRunProof(
                taskID = owner.taskID.toString().uppercase(),
                runID = owner.runID.toString().uppercase(),
                terminal = false,
                liveOwner = true,
                watermark = 40,
            )
        }

        override fun observe(
            owner: PhoneControlOwner,
            afterSequence: Long,
            onTerminal: (Long) -> Unit,
            onLost: () -> Unit,
        ): AutoCloseable = Subscription().also { subscriptions += it }
    }

    @Test
    fun endingAnOldOwnerDoesNotEndANewerOwnerProof() = runBlocking {
        val source = Source()
        val live = DeviceRunLiveness(source) {}
        val a = owner(1, 11)
        val b = owner(2, 22)

        assertTrue(live.confirm(a, 7))
        assertTrue(live.confirm(b, 7))
        assertEquals(true, live.answer(b, 7))

        live.stop(a)

        assertEquals("old A cleanup must not retire B", true, live.answer(b, 7))
        assertEquals(2, source.readCount)
        assertTrue(source.subscriptions[1].closeCount == 0)
        live.stop(b)
        assertEquals(false, live.answer(b, 7))
    }

    @Test
    fun stopDuringSnapshotRefusesOnlyTheStoppedOwner() = runBlocking {
        val source = Source()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val stopped = mutableSetOf<PhoneControlOwner>()
        val live = DeviceRunLiveness(source, ownerStopped = { it in stopped }) {}
        val release = CompletableDeferred<Unit>()
        source.beforeRead = { release.await() }

        var admittedA = true
        val reading = launch(start = CoroutineStart.UNDISPATCHED) {
            admittedA = live.confirm(a, 7)
        }
        stopped += a
        release.complete(Unit)
        reading.join()

        assertFalse("A's late snapshot cannot revive a stopped owner", admittedA)
        assertEquals("control_stopped", live.refusalCode)
        assertTrue("B's own snapshot is unaffected", live.confirm(b, 7))
        assertEquals(true, live.answer(b, 7))
    }

    @Test
    fun onlyTheExplicitRearmGestureMayCrossTheStopFence() = runBlocking {
        val source = Source()
        val a = owner(1, 11)
        val b = owner(2, 22)
        val stopped = mutableSetOf(a)
        val live = DeviceRunLiveness(source, ownerStopped = { it in stopped }) {}

        assertFalse("automatic admission stays denied", live.confirm(a, 7))
        assertEquals("control_stopped", live.refusalCode)
        assertTrue("the user's explicit re-allow may confirm its live run",
            live.confirm(a, 7, allowStopped = true))
        assertTrue("a different live owner is still independently admitted",
            live.confirm(b, 7))
        live.stop(b)
    }

    @Test
    fun ownerStopIsNotAGlobalStop() = runBlocking {
        val source = Source()
        val live = DeviceRunLiveness(source) {}
        val a = owner(1, 11)
        val b = owner(2, 22)

        assertTrue(live.confirm(a, 7))
        live.stop(a)
        assertEquals(false, live.answer(a, 7))
        assertTrue("B can still obtain its own fresh proof", live.confirm(b, 7))
        assertEquals(true, live.answer(b, 7))
        live.stop(b)
    }
}
