// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import java.util.concurrent.ConcurrentHashMap
import org.junit.Assert.*
import org.junit.Test

class RuntimeSessionReadIndexTest {
    private class Session(val output: String, var leaseReleased: Boolean = false)

    @Test fun outputStaysReadableDuringTheWholeWorkspaceExportGap() {
        val running = ConcurrentHashMap<String, Session>()
        val completed = ConcurrentHashMap<String, Session>()
        val reads = RuntimeSessionReadIndex(running, completed)
        val owner = Session("actual output")
        running["session"] = owner
        reads.beginSettlement("session", owner)
        running.remove("session", owner)

        // The old active-or-completed lookup loses this exact interval.
        assertTrue(running.isEmpty())
        assertTrue(completed.isEmpty())
        assertSame(owner, reads.find("session"))
        assertEquals("actual output", reads.find("session")!!.output)
        assertFalse("An output snapshot must not invent native release", owner.leaseReleased)

        owner.leaseReleased = true
        completed["session"] = owner
        reads.endSettlement("session", owner)
        assertSame(owner, reads.find("session"))
        assertTrue(reads.find("session")!!.leaseReleased)
    }

    @Test fun unknownOrForeignSessionCannotAcquireAReadEntry() {
        val running = ConcurrentHashMap<String, Session>()
        val reads = RuntimeSessionReadIndex(running, emptyMap())
        running["session"] = Session("owned")
        assertNull(reads.find("foreign"))
        try {
            reads.beginSettlement("session", Session("foreign"))
            fail("A different owner cannot be retained")
        } catch (_: IllegalStateException) { }
        assertSame(running["session"], reads.find("session"))
    }

    @Test fun staleReleaseCannotRemoveAnotherRetainedOwner() {
        val running = ConcurrentHashMap<String, Session>()
        val reads = RuntimeSessionReadIndex(running, emptyMap())
        val owner = Session("retained after failed release")
        running["session"] = owner
        reads.beginSettlement("session", owner)
        running.remove("session")
        reads.endSettlement("session", Session("stale"))
        assertSame(owner, reads.find("session"))
        assertFalse(owner.leaseReleased)
    }
}
