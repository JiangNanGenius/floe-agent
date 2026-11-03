// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.*
import org.junit.Test

class LinuxSessionPollTest {
    @Test fun settlementCannotCloseTheConnectionDuringAnInFlightPoll() = runBlocking {
        val lock = Mutex()
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var closed = false
        val poll = async(start = CoroutineStart.UNDISPATCHED) {
            pollWithSettlement(lock, { closed }, live = {
                entered.complete(Unit)
                release.await()
                assertFalse("Live IPC must remain owned until its reply", closed)
                "actual output"
            }, retired = { error("Not retired yet") })
        }
        entered.await()
        val finish = async(start = CoroutineStart.UNDISPATCHED) { lock.withLock { closed = true } }
        assertFalse(finish.isCompleted)
        release.complete(Unit)
        assertEquals("actual output", poll.await())
        finish.await()
        assertTrue(closed)
    }

    @Test fun ownerLookedUpBeforeSettlementUsesRetiredReaderAfterSettlement() = runBlocking {
        val lock = Mutex(locked = true)
        var settled = false
        val request = async(start = CoroutineStart.UNDISPATCHED) {
            pollWithSettlement(lock, { settled }, live = { error("Closed live connection") },
                retired = { "actual retained runtime page at requested cursor" })
        }
        settled = true
        lock.unlock()
        assertEquals("actual retained runtime page at requested cursor", request.await())
    }

    @Test fun retiredReaderFailureNeverBecomesFabricatedOutput() = runBlocking {
        val failure = IllegalStateException("runtime unavailable")
        try {
            pollWithSettlement(Mutex(), { true }, live = { "wrong" }, retired = { throw failure })
            fail("The actual read failure must propagate")
        } catch (actual: IllegalStateException) { assertSame(failure, actual) }
    }
}
