// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.PlatformLaunchOwnership
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the viewer-lane launch ownership of [OfficePreviewEffect].
 *
 * Mechanism: the platform ActivityResult callback carries NO request
 * identity of its own, so the composition registers ONE launcher per
 * immutable (namespace, incarnation) viewer launch identity in a keyed
 * child slot. A delivery at a slot may dispatch ONLY that slot's captured
 * incarnation while the lane still holds the slot's own exact key — never
 * the controller's current pending viewer — and unmounting a retired slot
 * unregisters its launcher so the next open registers a distinct one.
 * These tests drive the SAME pure decisions the slots make
 * ([viewerSlotIdentity], [viewerSlotAction], [viewerCallbackOwnsLaunch]);
 * the shared picker/permission ledger semantics (PlatformLaunchOwnership)
 * are intentionally untouched.
 *
 * Authored unrun: Main runs the batch compile/test gate.
 */
class OfficeViewerLaunchLaneTest {

    private val ns = "namespace-current"
    private val dead = "namespace-dead-process"

    private fun key(namespace: String, incarnation: Long) =
        PlatformLaunchOwnership.LaunchKey(namespace, incarnation).encode()

    @Test
    fun freeLaneLaunchesCurrentPendingExactlyOnceThenHolds() {
        assertEquals(ViewerSlotAction.Launch, viewerSlotAction(ns, null, 5L, 5L))
        // Once this slot's own key is recorded the same pending must NEVER
        // relaunch (recomposition, restored state or re-observation).
        assertEquals(ViewerSlotAction.Hold, viewerSlotAction(ns, key(ns, 5L), 5L, 5L))
        // Free lane with the pending elsewhere: this slot does nothing.
        assertEquals(ViewerSlotAction.Idle, viewerSlotAction(ns, null, 6L, 5L))
    }

    @Test
    fun lateResultOnOldSlotCannotDispatchToNextDocument() {
        // The critical race: op1 retired, op2 launched and the lane holds
        // (ns,2); a late (possibly null) result for the OLD launch physically
        // lands at the still-mounted identity-1 slot. The binding is the
        // slot's OWN captured identity: holding op2's key never authorizes
        // slot 1 (the old code looked up the CURRENT pending here and settled
        // the new document with the old result), and anything slot 1 does
        // dispatch names incarnation 1 — which the controller's
        // exact-operation fence drops.
        assertFalse(viewerCallbackOwnsLaunch(ns, key(ns, 2L), 1L))
        assertTrue(viewerCallbackOwnsLaunch(ns, key(ns, 2L), 2L))
        // A delivery after the lane already settled dispatches nothing.
        assertFalse(viewerCallbackOwnsLaunch(ns, null, 2L))
    }

    @Test
    fun retiredLaunchReleasesLaneButNeverRebindsOrRelaunches() {
        // op1 settled without a callback (the fatal native close exit bypasses
        // the result): the composition must release the held key so the next
        // open registers a DISTINCT launcher — releasing only, never a
        // dispatch and never a relaunch of the old identity.
        assertEquals(ViewerSlotAction.Release, viewerSlotAction(ns, key(ns, 1L), null, 1L))
        // Replacement pending 2 while key (ns,1) is still held: same rule —
        // the stale slot releases; the new identity gets its own slot next.
        assertEquals(ViewerSlotAction.Release, viewerSlotAction(ns, key(ns, 1L), 2L, 1L))
        // Until it settles, the held same-namespace identity owns the slot.
        assertEquals(1L, viewerSlotIdentity(ns, key(ns, 1L), 2L))
    }

    @Test
    fun nextOpenMountsFreshIdentityAndLaunchesAfterRelease() {
        assertNull(viewerSlotIdentity(ns, null, null))
        assertEquals(2L, viewerSlotIdentity(ns, null, 2L))
        assertEquals(ViewerSlotAction.Launch, viewerSlotAction(ns, null, 2L, 2L))
        // The fresh launch gets its own key; slot 1 can no longer dispatch.
        assertTrue(viewerCallbackOwnsLaunch(ns, key(ns, 2L), 2L))
        assertFalse(viewerCallbackOwnsLaunch(ns, key(ns, 2L), 1L))
    }

    @Test
    fun restoredPreDeathKeyCannotHoldOrRebindTheNewGeneration() {
        // Process A issued (dead,1) and died; the new controller minted ns and
        // its incarnation counter RESTARTS, so its first viewer is ALSO
        // incarnation 1 — the namespace/counter collision case.
        // The foreign key is never mounted and never authorizes anything.
        assertNull(viewerSlotIdentity(ns, key(dead, 1L), null))
        assertEquals(1L, viewerSlotIdentity(ns, key(dead, 1L), 1L))
        // Its first effect pass RELEASES the foreign key instead of launching
        // under it; a restored result delivered into the registration can
        // never dispatch under the foreign identity.
        assertEquals(ViewerSlotAction.Release, viewerSlotAction(ns, key(dead, 1L), 1L, 1L))
        assertFalse(viewerCallbackOwnsLaunch(ns, key(dead, 1L), 1L))
        // Only after that release does the new generation launch its own key.
        assertEquals(ViewerSlotAction.Launch, viewerSlotAction(ns, null, 1L, 1L))
        assertTrue(viewerCallbackOwnsLaunch(ns, key(ns, 1L), 1L))
    }

    @Test
    fun sameGenerationCallbackDispatchIsExactIdentityOnly() {
        // Normal in-flight launch: the slot's own key authorizes ONLY its own
        // incarnation, never a neighbor.
        assertTrue(viewerCallbackOwnsLaunch(ns, key(ns, 3L), 3L))
        assertFalse(viewerCallbackOwnsLaunch(ns, key(ns, 3L), 4L))
        assertFalse(viewerCallbackOwnsLaunch(ns, key(ns, 4L), 3L))
    }

    @Test
    fun malformedHeldKeyReleasesLane() {
        assertEquals(ViewerSlotAction.Release, viewerSlotAction(ns, "not-a-key", 1L, 1L))
        assertEquals(1L, viewerSlotIdentity(ns, "not-a-key", 1L))
        // A malformed key authorizes no dispatch at all.
        assertFalse(viewerCallbackOwnsLaunch(ns, "not-a-key", 1L))
    }
    @Test
    fun lateOldResultCannotClearTheNewHeldLaunch() {
        val oldKey = key(ns, 1L)
        val newKey = key(ns, 2L)
        assertEquals(newKey, viewerKeyAfterRelease(newKey, oldKey))
        assertFalse(viewerCallbackOwnsLaunch(ns, newKey, 1L))
        assertTrue(viewerCallbackOwnsLaunch(ns, newKey, 2L))
    }

    @Test
    fun ownedAndForeignKeyReleaseUseExactParentCompare() {
        val own = key(ns, 3L)
        val foreign = key(dead, 3L)
        assertNull(viewerKeyAfterRelease(own, own))
        assertNull(viewerKeyAfterRelease(foreign, foreign))
        assertEquals(own, viewerKeyAfterRelease(own, foreign))
        assertNull(viewerKeyAfterRelease(null, foreign))
    }
}
