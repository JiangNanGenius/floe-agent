// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.host.ConversationWire
import com.floe.android.phonecontrol.PhoneControlOwner
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** Scheduled device calls must follow the native run, without opening its chat. */
class ScheduledDeviceOwnerLivenessTest {
    private val owner = PhoneControlOwner(UUID.randomUUID(), UUID.randomUUID())

    private class Subscription(
        val terminal: (Long) -> Unit,
        val lost: () -> Unit,
    ) : AutoCloseable {
        var closeCount = 0
        override fun close() { closeCount++ }
    }

    private class Source(owner: PhoneControlOwner) : DeviceRunReadPort {
        var epoch: Long? = 7
        var proof: DeviceRunProof? = DeviceRunProof(
            owner.taskID.toString().uppercase(), owner.runID.toString().uppercase(),
            terminal = false, liveOwner = true, watermark = 40,
        )
        var beforeRead: (suspend () -> Unit)? = null
        var whileOpening: ((Subscription) -> Unit)? = null
        var readCount = 0
        val subscriptions = mutableListOf<Subscription>()
        val watermarks = mutableListOf<Long>()
        override fun currentEpoch() = epoch
        override suspend fun snapshot(owner: PhoneControlOwner): DeviceRunProof? {
            readCount++
            beforeRead?.invoke()
            return proof
        }
        override fun observe(
            owner: PhoneControlOwner,
            afterSequence: Long,
            onTerminal: (Long) -> Unit,
            onLost: () -> Unit,
        ): AutoCloseable = Subscription(onTerminal, onLost).also {
            watermarks += afterSequence
            subscriptions += it
            whileOpening?.invoke(it)
        }
    }

    @Test fun unopenedScheduledTaskUsesExactNativeOwnerAndSnapshotWatermark() = runBlocking {
        val source = Source(owner)
        val live = DeviceRunLiveness(source) {}
        assertNull(live.answer(owner, 7))
        assertTrue(live.confirm(owner, 7))
        assertTrue(live.answer(owner, 7) == true)
        assertEquals(listOf(40L), source.watermarks)
        // Repeated calls use the same observer, rather than one stream per tool.
        assertTrue(live.confirm(owner, 7))
        assertEquals(1, source.readCount)
        assertEquals(1, source.subscriptions.size)
        assertNull(live.answer(owner.copy(runID = UUID.randomUUID()), 7))
        live.stop()
    }

    @Test fun terminalSettlesOnceAndCannotFallBackToStaleChatState() = runBlocking {
        val source = Source(owner)
        var changes = 0
        val live = DeviceRunLiveness(source) { changes++ }
        assertTrue(live.confirm(owner, 7))
        val subscription = source.subscriptions.single()
        subscription.terminal(41)
        subscription.terminal(42)
        subscription.lost()
        assertEquals(false, live.answer(owner, 7))
        assertEquals(1, subscription.closeCount)
        assertEquals(2, changes) // admitted, then settled
        assertEquals(1, source.subscriptions.size)
    }

    @Test fun terminalFromPreviousIncarnationDoesNotEndRetriedRun() = runBlocking {
        val source = Source(owner)
        val live = DeviceRunLiveness(source) {}
        assertTrue(live.confirm(owner, 7))
        val subscription = source.subscriptions.single()
        subscription.terminal(39)
        subscription.terminal(40)
        assertEquals(true, live.answer(owner, 7))
        assertEquals(0, subscription.closeCount)
        subscription.terminal(41)
        assertEquals(false, live.answer(owner, 7))
    }

    @Test fun missingForeignTerminalAndUnownedSnapshotsDoNotAdmitDeviceControl() = runBlocking {
        val source = Source(owner)
        val good = checkNotNull(source.proof)
        val rejected = listOf(null, good.copy(taskID = null),
            good.copy(taskID = UUID.randomUUID().toString()),
            good.copy(runID = UUID.randomUUID().toString()),
            good.copy(terminal = true), good.copy(liveOwner = false),
            good.copy(watermark = -1))
        val live = DeviceRunLiveness(source) {}
        for (proof in rejected) {
            source.proof = proof
            assertFalse(live.confirm(owner, 7))
        }
        assertTrue(source.subscriptions.isEmpty())
        source.proof = good
        assertTrue(live.confirm(owner, 7))
        live.stop()
    }

    @Test fun streamFailureEndsProofWithoutReopeningOrRetryingActions() = runBlocking {
        val source = Source(owner)
        val live = DeviceRunLiveness(source) {}
        assertTrue(live.confirm(owner, 7))
        source.subscriptions.single().lost()
        assertEquals(false, live.answer(owner, 7))
        assertEquals(1, source.subscriptions.size)
        assertEquals(1, source.readCount)
    }

    @Test fun rootReplacementInvalidatesOldProofAndOldCallbacksCannotEndFreshProof() = runBlocking {
        val source = Source(owner)
        val live = DeviceRunLiveness(source) {}
        assertTrue(live.confirm(owner, 7))
        val old = source.subscriptions.single()
        source.epoch = 8
        assertEquals(false, live.answer(owner, 8))
        assertFalse(live.confirm(owner, 7))
        assertTrue(live.confirm(owner, 8))
        old.terminal(100)
        old.lost()
        assertEquals(true, live.answer(owner, 8))
        assertEquals(1, old.closeCount)
        live.stop()
        assertEquals(1, source.subscriptions.last().closeCount)
    }

    @Test fun terminalDuringStreamOpenClosesReturnedHandleWithoutLateAdmission() = runBlocking {
        val source = Source(owner)
        source.whileOpening = { it.terminal(41) }
        val live = DeviceRunLiveness(source) {}
        assertFalse(live.confirm(owner, 7))
        assertEquals(false, live.answer(owner, 7))
        assertEquals(1, source.subscriptions.single().closeCount)
    }

    @Test fun explicitFreshConfirmationCanAdmitSameRunAfterRetry() = runBlocking {
        val source = Source(owner)
        val live = DeviceRunLiveness(source) {}
        assertTrue(live.confirm(owner, 7))
        val old = source.subscriptions.single()
        old.terminal(41)
        assertEquals(false, live.answer(owner, 7))
        source.proof = checkNotNull(source.proof).copy(watermark = 60)
        assertTrue(live.confirm(owner, 7))
        old.terminal(100)
        old.lost()
        assertEquals(true, live.answer(owner, 7))
        assertEquals(listOf(40L, 60L), source.watermarks)
        live.stop()
    }

    @Test fun stopWhileSnapshotPendingFencesLateResponse() = runBlocking {
        val source = Source(owner)
        val release = CompletableDeferred<Unit>()
        source.beforeRead = { release.await() }
        val live = DeviceRunLiveness(source) {}
        var admitted = true
        val reading = launch(start = CoroutineStart.UNDISPATCHED) { admitted = live.confirm(owner, 7) }
        live.stop()
        release.complete(Unit)
        reading.join()
        assertFalse(admitted)
        assertTrue(source.subscriptions.isEmpty())
    }

    @Test fun cancellationOfSnapshotDoesNotBecomeAdmissionOrStartObserver() = runBlocking {
        val source = Source(owner)
        val release = CompletableDeferred<Unit>()
        source.beforeRead = { release.await() }
        val live = DeviceRunLiveness(source) {}
        val reading = launch(start = CoroutineStart.UNDISPATCHED) { live.confirm(owner, 7) }
        reading.cancelAndJoin()
        assertTrue(reading.isCancelled)
        assertTrue(source.subscriptions.isEmpty())
    }

    @Test fun actualSnapshotCarrierRetainsNativeTaskIdentityAndServiceOwnership() {
        val page = ConversationWire.decodeSnapshotPage(Json.parseToJsonElement("""{
            "conversationID":"${owner.taskID}","runID":"${owner.runID}",
            "durableState":"running","isTerminal":false,
            "revision":{"resourceID":"run","version":"1"},
            "liveOwner":true,"durableWatermark":40
        }"""))
        assertNotNull(page)
        assertEquals(owner.taskID.toString(), page!!.conversationID)
        assertEquals(owner.runID.toString(), page.runID)
        assertTrue(page.liveOwner)
        assertFalse(page.isTerminal)
        assertEquals(40L, page.durableWatermark)
    }
}
