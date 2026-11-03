// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.remote

import java.util.Collections
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class C05RemoteInputLaneTest {

    @Test
    fun preservesOrderAndCoalescesAdjacentSmallFrames() = runBlocking {
        val received = Collections.synchronizedList(mutableListOf<String>())
        val lane = C05RemoteInputLane(sink = { received += String(it) }, onIssue = {})
        assertNull(lane.offer("a".toByteArray()))
        assertNull(lane.offer("b".toByteArray()))
        val job = launch { lane.run() }
        while (received.isEmpty()) yield()
        lane.close()
        job.join()
        assertEquals(listOf("ab"), received)
    }

    @Test
    fun refusesOverflowWithoutGrowingUnbounded() = runBlocking {
        val issues = Collections.synchronizedList(mutableListOf<String>())
        val received = Collections.synchronizedList(mutableListOf<String>())
        val lane = C05RemoteInputLane(
            sink = { received += String(it) },
            onIssue = { issues += it },
            capacityPackets = 2,
            capacityBytes = 10,
        )
        assertNull(lane.offer("123456".toByteArray()))
        assertNull(lane.offer("7890".toByteArray()))
        assertEquals("inputFull", lane.offer("x".toByteArray()))
        val job = launch { lane.run() }
        while (received.isEmpty()) yield()
        lane.close()
        job.join()
        assertTrue(issues.isEmpty())
    }

    @Test
    fun closeRefusesNewInputAndEndsTheDrain() = runBlocking {
        val lane = C05RemoteInputLane(sink = {}, onIssue = {})
        val job = launch { lane.run() }
        lane.close()
        assertEquals("hostClosed", lane.offer("x".toByteArray()))
        job.join()
    }

    @Test
    fun sinkFailureReportsTransportAndCloses() = runBlocking {
        val issues = Collections.synchronizedList(mutableListOf<String>())
        val lane = C05RemoteInputLane(
            sink = { error("boom") },
            onIssue = { issues += it },
        )
        assertNull(lane.offer("x".toByteArray()))
        val job = launch { lane.run() }
        job.join()
        assertEquals(listOf("transport"), issues)
        assertEquals("hostClosed", lane.offer("y".toByteArray()))
    }
}
