// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G07.3A AUTHORED-NOT-RUN regressions for the runtime's role admission and
 * target-scoped cancellation grammar.
 *
 * The executable half of multi-session admission is the real process/PTY path
 * (Main's device batch); these pure decisions are where a wrong answer could
 * silently stop ANOTHER session or over-admit a role, so they are pinned here
 * against the actual production functions.
 */
class WorkloadRoleAdmissionTest {

    @Test
    fun `roles map from the closed wire vocabulary and keep the approved caps`() {
        assertEquals(WorkloadRole.INTERACTIVE, WorkloadRole.fromWire("interactive"))
        assertEquals(WorkloadRole.AGENT, WorkloadRole.fromWire("agent"))
        assertEquals(WorkloadRole.RUN, WorkloadRole.fromWire("run"))
        assertNull(WorkloadRole.fromWire("root"))
        assertNull(WorkloadRole.fromWire(""))

        assertEquals(2, WorkloadRole.INTERACTIVE.maximumConcurrent)
        assertEquals(1, WorkloadRole.AGENT.maximumConcurrent)
        assertEquals(1, WorkloadRole.RUN.maximumConcurrent)
        // Approved default: TWO interactive + ONE shared Agent/run execution
        // slot. The per-role maxima do NOT sum to the ceiling because the
        // execution slot is shared, never doubled.
        assertEquals(3, LinuxRuntimeOperations.MAX_CONCURRENT_WORKLOADS)
        assertTrue(WorkloadRole.AGENT.isExecution)
        assertTrue(WorkloadRole.RUN.isExecution)
        assertFalse(WorkloadRole.INTERACTIVE.isExecution)
        assertEquals(2, WorkloadRole.entries.count { it.isExecution })
        assertTrue(WorkloadRole.entries.filter { it.isExecution }
            .all { it.maximumConcurrent == 1 })
    }

    @Test
    fun `cancel scope addresses exactly one live session among many`() {
        val held = listOf("lease-a", "lease-b", "lease-c")
        assertEquals("session", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-b", requestID = null,
            heldLeaseIDs = held, pendingStartIDs = emptyList()))
        assertNull("an unknown session id is never a broad cancel", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-z", requestID = null,
            heldLeaseIDs = held, pendingStartIDs = emptyList()))
        assertNull("a mixed shape is refused", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID", "requestID"), sessionID = "lease-b", requestID = "start-1",
            heldLeaseIDs = held, pendingStartIDs = listOf("start-1")))
        assertNull("a session id is not a pending-start id", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "lease-b",
            heldLeaseIDs = held, pendingStartIDs = listOf("start-1")))
    }

    @Test
    fun `pending start cancel addresses only the exact in-flight request`() {
        val pending = listOf("start-a", "start-b")
        assertEquals("pendingStart", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "start-b",
            heldLeaseIDs = emptyList(), pendingStartIDs = pending))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("requestID"), sessionID = null, requestID = "start-z",
            heldLeaseIDs = emptyList(), pendingStartIDs = pending))
    }

    @Test
    fun `legacy single-id overload stays truthful`() {
        assertEquals("session", LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-a", requestID = null,
            heldLeaseID = "lease-a", pendingStartID = null))
        assertNull(LinuxRuntimeOperations.shellCancelScope(
            keys = setOf("sessionID"), sessionID = "lease-b", requestID = null,
            heldLeaseID = "lease-a", pendingStartID = null))
    }

    @Test
    fun `export status vocabulary is closed`() {
        // The runtime exposes these literal states to the host; a typo would
        // make the pump wait forever for a deferred shared export.
        val closed = setOf("synced", "conflict", "aborted", "error", "deferred", "unknown", "pending")
        for (value in closed) {
            assertTrue(value, value.isNotEmpty() && value.all { it in 'a'..'z' })
        }
    }
}
