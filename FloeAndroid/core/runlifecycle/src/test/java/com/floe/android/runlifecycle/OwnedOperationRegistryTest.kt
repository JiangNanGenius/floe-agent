// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for the transient ownership ledger. These drive the
 * EXACT hardened decision core (atomic stop snapshot/fence with acquire,
 * refcounted same-kind attach, owner conflict refusal, stale-generation
 * release) without any android dependency; the Binder/Parcel transport
 * stays with Main's instrumentation cohort.
 */
class OwnedOperationRegistryTest {

    private fun uuid() = UUID.randomUUID().toString()

    private fun attached(registry: OwnedOperationRegistry<Unit>, id: String,
                         kind: OperationKind = OperationKind.AGENT_RUN,
                         stop: RunStopHandler? = null): OwnedOperationRegistry.Entry<Unit> {
        val pair = registry.acquire(id, kind, stop) { _, _ -> Unit }
        assertNotNullPair(pair)
        return pair!!.first
    }

    private fun assertNotNullPair(pair: Pair<OwnedOperationRegistry.Entry<Unit>, Boolean>?) {
        assertTrue("acquire must succeed", pair != null)
    }

    @Test
    fun idempotentSameKindAttachKeepsEntryUntilLastLeaseCloses() {
        val registry = OwnedOperationRegistry<Unit>()
        val first = attached(registry, uuid())
        val stampAfterCreate = registry.currentStamp
        val pair = registry.acquire(first.operationID, first.kind, null) { _, _ -> Unit }
        assertNotNullPair(pair)
        assertFalse("second attach is not a new registration", pair!!.second)
        assertSame(first, pair.first)
        // Attach is NOT a set change: the stop fence stamp stays put.
        assertEquals(stampAfterCreate, registry.currentStamp)
        assertEquals(2, registry.leaseCount(first.operationID, first.ownerGeneration))

        assertFalse(registry.release(first.operationID, first.ownerGeneration))
        assertEquals(1, registry.leaseCount(first.operationID, first.ownerGeneration))
        assertTrue(registry.isActive(first.operationID, first.ownerGeneration, true))
        assertFalse("one lease closed while another still owns", registry.isEmpty())

        assertTrue(registry.release(first.operationID, first.ownerGeneration))
        assertTrue(registry.isEmpty())
        assertEquals(stampAfterCreate + 1, registry.currentStamp)
    }

    @Test
    fun sameIdDifferentKindIsRefusedAndMutatesNothing() {
        val registry = OwnedOperationRegistry<Unit>()
        val id = uuid()
        val install = attached(registry, id, OperationKind.ENVIRONMENT_INSTALL)
        val stampBefore = registry.currentStamp
        val refused = registry.acquire(id, OperationKind.AGENT_RUN, null) { _, _ -> Unit }
        assertTrue("kind conflict must be refused", refused == null)
        assertEquals(OperationKind.ENVIRONMENT_INSTALL, registry.kindOf(id))
        assertEquals("refusal changed nothing", stampBefore, registry.currentStamp)
        assertEquals(1, registry.leaseCount(install.operationID, install.ownerGeneration))
        assertSame(OperationKind.ENVIRONMENT_INSTALL, registry.snapshotForTesting().single().third)
    }

    @Test
    fun staleGenerationReleaseNeverTouchesNewerRegistration() {
        val registry = OwnedOperationRegistry<Unit>()
        val id = uuid()
        val first = attached(registry, id)
        assertTrue(registry.release(id, first.ownerGeneration))
        val second = attached(registry, id)
        assertEquals(1, second.ownerGeneration - first.ownerGeneration)

        // A stale close from the finished first registration must be
        // refused and must not decrement or remove the newer entry.
        assertFalse(registry.release(id, first.ownerGeneration))
        assertTrue(registry.isActive(id, second.ownerGeneration, true))
        assertEquals(1, registry.leaseCount(id, second.ownerGeneration))

        // And a stale-generation permit answer is inert.
        assertFalse(registry.isActive(id, first.ownerGeneration, true))
        assertTrue(registry.release(id, second.ownerGeneration))
    }

    @Test
    fun stopPressCannotCancelAnOperationAcquiredAfterTheSnapshot() {
        val registry = OwnedOperationRegistry<Unit>()
        val idA = uuid()
        val idB = uuid()
        var bFired = false
        val stopB = RunStopHandler { bFired = true }
        // A's own handler races a NEW acquisition mid-route (the exact
        // stamp-change race from review): B is created AFTER the atomic
        // snapshot was captured, so the current press must not reach it.
        val stopA = RunStopHandler { attached(registry, idB, OperationKind.LOCAL_EXECUTION, stopB) }
        attached(registry, idA, OperationKind.AGENT_RUN, stopA)
        val pressStamp = registry.currentStamp

        assertTrue(registry.routeStop(pressStamp))
        assertFalse("a new operation joined after the snapshot was NOT cancelled", bFired)
        val bGeneration = registry.snapshotForTesting().first { it.first == idB }.second
        assertEquals(1, registry.leaseCount(idB, bGeneration))

        // B is live and owned; a FRESH press at the new stamp does reach it.
        assertTrue(registry.routeStop(registry.currentStamp))
        assertTrue("the current press reaches current owners", bFired)
        assertFalse(registry.isEmpty())
    }

    @Test
    fun stalePressAfterSetChangeIsRefusedAndCancelsNothing() {
        val registry = OwnedOperationRegistry<Unit>()
        var fired = 0
        val id = uuid()
        attached(registry, id, OperationKind.AGENT_RUN, RunStopHandler { fired += 1 })
        val oldStamp = registry.currentStamp
        attached(registry, uuid(), OperationKind.DURABLE_JOB, RunStopHandler { fired += 1 })

        assertFalse(registry.routeStop(oldStamp))
        assertEquals("stale press routed nothing", 0, fired)
        assertTrue(registry.routeStop(registry.currentStamp))
        assertEquals("live press routed both owners once", 2, fired)
        assertEquals("stop never closes leases", 2, registry.size())
    }

    @Test
    fun replacementAfterReleaseIsInvisibleToTheOldPress() {
        val registry = OwnedOperationRegistry<Unit>()
        val id = uuid()
        val first = attached(registry, id, OperationKind.AGENT_RUN)
        val oldPress = registry.currentStamp
        assertTrue(registry.release(id, first.ownerGeneration))
        var newFired = 0
        attached(registry, id, OperationKind.AGENT_RUN, RunStopHandler { newFired = 1 })
        assertFalse(registry.routeStop(oldPress))
        assertEquals("new unrelated owner was not cancelled by the old press", 0, newFired)
    }

    @Test
    fun permitActiveRequiresExactGenerationAndConfirmedForeground() {
        val registry = OwnedOperationRegistry<Unit>()
        val entry = attached(registry, uuid())
        assertFalse(registry.isActive(entry.operationID, entry.ownerGeneration, false))
        assertTrue(registry.isActive(entry.operationID, entry.ownerGeneration, true))
        assertFalse(registry.isActive(entry.operationID, entry.ownerGeneration + 99, true))
        assertFalse(registry.isActive(uuid(), entry.ownerGeneration, true))
    }
}
