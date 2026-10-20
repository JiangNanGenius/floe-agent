// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Focused JVM contract tests for the append-only v2 envelope. These exercise
 * construction-time authority shape only: no binder, task, provider or
 * credential operation is registered or executed.
 */
class BridgeEnvelopeV2ContractTest {
    private val task = UUID.randomUUID()
    private val run = UUID.randomUUID()
    private val environment = UUID.randomUUID()
    private val job = UUID.randomUUID()

    private fun envelope(
        owner: ExecutionOwner = ExecutionOwner(task, run, environment, job),
        command: String = "chat.send",
        stateful: Boolean = false,
        revision: Revision? = null,
        cursor: EventCursor? = null,
        grantID: UUID? = null,
        correlationID: String = "c-1",
        scope: EnvelopeScope = EnvelopeScope.TaskExecution(owner),
    ) = CommandEnvelope(
        scope = scope,
        command = command,
        stateful = stateful,
        revision = revision,
        cursor = cursor,
        grantID = grantID,
        correlationID = correlationID,
    )

    @Test
    fun aliasedRoleIDsRemainExplicitStructuredFields() {
        // A root jobID may equal its runID. Removing the invented
        // `distinct().size == 4` rule must not weaken the all-zero guard, and
        // this shape alone grants no authority (there is no binder here).
        val aliased = ExecutionOwner(task, run, environment, run)
        val value = envelope(owner = aliased, cursor = EventCursor(run, 0))
        val scoped = value.scope as EnvelopeScope.TaskExecution
        assertEquals(run, scoped.owner.runID)
        assertEquals(run, scoped.owner.jobID)
        assertEquals(task, scoped.owner.taskID)
        assertEquals(environment, scoped.owner.environmentID)
    }

    @Test
    fun nilUUIDIdentityIsStillRejected() {
        val nil = UUID(0, 0)
        assertThrows(IllegalArgumentException::class.java) {
            envelope(owner = ExecutionOwner(nil, run, environment, job))
        }
    }

    @Test
    fun cursorMustAgreeWithOwnerRun() {
        assertThrows(IllegalArgumentException::class.java) {
            envelope(cursor = EventCursor(UUID.randomUUID(), 0))
        }
    }

    @Test
    fun blankRevisionAndCorrelationAreRejected() {
        assertThrows(IllegalArgumentException::class.java) { Revision("   ", "1") }
        assertThrows(IllegalArgumentException::class.java) { Revision("r", "\t\n") }
        assertThrows(IllegalArgumentException::class.java) { envelope(correlationID = " \t ") }
    }

    @Test
    fun statefulCommandStillRequiresRevision() {
        assertThrows(IllegalArgumentException::class.java) { envelope(stateful = true) }
    }

    @Test
    fun applicationConfigurationStillRequiresHostOwnedScope() {
        assertThrows(IllegalArgumentException::class.java) {
            envelope(scope = EnvelopeScope.ApplicationConfiguration("   "))
        }
    }

    @Test
    fun commandSurfaceGuardsAreUnchanged() {
        assertThrows(IllegalArgumentException::class.java) { envelope(command = "") }
        assertThrows(IllegalArgumentException::class.java) { envelope(command = "chat send") }
        assertThrows(IllegalArgumentException::class.java) { envelope(command = "a".repeat(129)) }
    }
}
