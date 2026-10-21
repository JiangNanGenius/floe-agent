// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MAIN_ANDROID_PLATFORM_LAUNCH_OWNERSHIP_20261021 — deferred ownership
 * state-machine tests for the shared picker/permission launch ledger.
 * AUTHORED, NOTRUN: Main executes them in the composed batch.
 *
 * These tests drive [PlatformLaunchOwnership] directly on the JVM: the
 * launch/settle/supersede/restored-key-collision behavior of the three
 * composition lanes (attachment GetContent, Skills OpenDocumentTree, API 37
 * local-network permission dialog) is modeled here without any Android
 * framework, launcher, or controller. No production fake service is added.
 */
class PlatformLaunchOwnershipTest {

    private fun newLane(): PlatformLaunchOwnership.LaneLedger =
        PlatformLaunchOwnership.LaneLedger(PlatformLaunchOwnership.mintNamespace())

    // ------------------------------------------------------------- encoding

    @Test
    fun launchKeyRoundTripsThroughEncodedForm() {
        val key = PlatformLaunchOwnership.LaunchKey("ns-abc", 42L)
        val decoded = PlatformLaunchOwnership.LaunchKey.decode(key.encode())
        assertEquals(key, decoded)
    }

    @Test
    fun malformedPersistedKeysDecodeToFreeLane() {
        assertNull(PlatformLaunchOwnership.LaunchKey.decode(null))
        assertNull(PlatformLaunchOwnership.LaunchKey.decode(""))
        assertNull(PlatformLaunchOwnership.LaunchKey.decode("no-separator"))
        assertNull(PlatformLaunchOwnership.LaunchKey.decode("ns:"))
        assertNull(PlatformLaunchOwnership.LaunchKey.decode("ns:not-a-long"))
    }

    // ------------------------------------------------- happy path (settle)

    @Test
    fun pendingLaunchesAndCallbackDispatchesToSameOwner() {
        val lane = newLane()
        val launch = lane.onPending(1L)
        assertTrue(launch is PlatformLaunchOwnership.PendingDecision.Launch)
        assertEquals(1L, (launch as PlatformLaunchOwnership.PendingDecision.Launch).savedKey.incarnation)

        val callback = lane.onCallback(1L)
        assertTrue(callback is PlatformLaunchOwnership.CallbackDecision.Dispatch)
        assertEquals(1L, (callback as PlatformLaunchOwnership.CallbackDecision.Dispatch).incarnation)
        // The lane settled: it may launch a future request.
        assertNull(lane.savedKey)
    }

    @Test
    fun noPendingMeansHoldAndKeepsLaneFree() {
        val lane = newLane()
        assertEquals(
            PlatformLaunchOwnership.PendingDecision.Hold,
            lane.onPending(null),
        )
        assertNull(lane.savedKey)
    }

    @Test
    fun nullPendingReobservationDoesNotDiscardInflightOwner() {
        val lane = newLane()
        lane.onPending(1L)
        // A null re-read of the pending flow (host refresh/recomposition)
        // must NOT free the lane while the picker may still be showing.
        assertEquals(
            PlatformLaunchOwnership.PendingDecision.Hold,
            lane.onPending(null),
        )
        assertEquals(1L, lane.savedKey?.incarnation)
    }

    // ---------------------------------------------- supersede (same lane)

    @Test
    fun replacementRequestHoldsWhileOldPickerIsShowing() {
        val lane = newLane()
        lane.onPending(1L)
        // A newer request replaced the pending flow value; the old picker is
        // still out, so no second picker may launch.
        val second = lane.onPending(2L)
        assertEquals(PlatformLaunchOwnership.PendingDecision.Hold, second)
        assertEquals(1L, lane.savedKey?.incarnation)
    }

    @Test
    fun staleCallbackForSupersededRequestDropsThenReplacementLaunches() {
        val lane = newLane()
        lane.onPending(1L)
        // The user finishes the OLD picker after a replacement request 2 is
        // pending: the old result must drop, never bind to request 2.
        val stale = lane.onCallback(2L)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, stale)
        assertNull(lane.savedKey)
        // The lane is free, so the current pending request 2 may now launch.
        val relaunch = lane.onPending(2L)
        assertTrue(relaunch is PlatformLaunchOwnership.PendingDecision.Launch)
        assertEquals(2L, (relaunch as PlatformLaunchOwnership.PendingDecision.Launch).savedKey.incarnation)
        val current = lane.onCallback(2L)
        assertTrue(current is PlatformLaunchOwnership.CallbackDecision.Dispatch)
        assertEquals(2L, (current as PlatformLaunchOwnership.CallbackDecision.Dispatch).incarnation)
    }

    @Test
    fun sameNamespaceWithMismatchedIncarnationDrops() {
        // Namespace equality alone is NOT sufficient: a same-process request
        // superseded while its picker was showing must not receive the old
        // result even though the namespace matches.
        val lane = newLane()
        lane.onPending(1L)
        val stale = lane.onCallback(7L)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, stale)
    }

    // --------------------------------- process recreation (namespace reset)

    @Test
    fun restoredPreDeathKeyHoldsCollidingNewRequestUntilStaleCallbackSettles() {
        // Process A issued launch (nsA, 1) and died; the saved bundle carries
        // that key. Process B's controller restarted its counter, so the new
        // request ALSO has incarnation 1: the exact counter-reset collision.
        val nsA = "namespace-process-a"
        val lane = PlatformLaunchOwnership.LaneLedger(PlatformLaunchOwnership.mintNamespace())
        // Rehydrate the ledger from the restored bundle key, exactly as the
        // composition re-enters evaluation after process death.
        lane.restore(PlatformLaunchOwnership.LaunchKey(nsA, 1L))

        // The new request (incarnation 1, colliding) must NOT launch while
        // the restored pre-death launch may still own a live platform picker.
        val hold = lane.onPending(1L)
        assertEquals(PlatformLaunchOwnership.PendingDecision.Hold, hold)

        // The restored pre-death picker finally settles: dropped because the
        // namespace belongs to the dead process — never dispatched to the new
        // request despite the incarnation collision.
        val stale = lane.onCallback(1L)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, stale)
        assertNull(lane.savedKey)

        // NOW the new process's pending request may launch under the new
        // namespace, and its own callback dispatches normally.
        val launch = lane.onPending(1L)
        assertTrue(launch is PlatformLaunchOwnership.PendingDecision.Launch)
        val newKey = (launch as PlatformLaunchOwnership.PendingDecision.Launch).savedKey
        assertEquals(lane.namespace, newKey.namespace)
        assertEquals(1L, newKey.incarnation)
        val dispatch = lane.onCallback(1L)
        assertTrue(dispatch is PlatformLaunchOwnership.CallbackDecision.Dispatch)
    }

    @Test
    fun restoredPreDeathCallbackWithNewHostNamespaceNeverDispatches() {
        // Direct rule check: the saved key is from the dead process; even a
        // current pending request with the SAME incarnation is not a match.
        val nsA = "namespace-process-a"
        val nsB = "namespace-process-b"
        val decision = PlatformLaunchOwnership.evaluateCallback(
            PlatformLaunchOwnership.LaunchKey(nsA, 1L),
            1L,
            nsB,
        )
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, decision)
    }

    @Test
    fun sameNamespaceAcrossRecreationDispatchesNormally() {
        // Activity rotation keeps the SAME Application host: the namespace is
        // unchanged, so the restored key still matches and the pending pick
        // settles normally instead of being mistaken for a stale result.
        val lane = newLane()
        lane.onPending(3L)
        // Same Application host survived: rotation only recreates the
        // composition, which re-adopts the SAME key it saved.
        val recreated = PlatformLaunchOwnership.LaneLedger(lane.namespace)
        recreated.restore(lane.savedKey)
        val decision = recreated.onCallback(3L)
        assertTrue(decision is PlatformLaunchOwnership.CallbackDecision.Dispatch)
        assertEquals(3L, (decision as PlatformLaunchOwnership.CallbackDecision.Dispatch).incarnation)
    }

    // -------------------------------------------------------- cancel paths

    @Test
    fun callbackAfterHostCancelDropsAndFreesLaneForNextRequest() {
        val lane = newLane()
        lane.onPending(1L)
        // The host cancelled/invalidate()d the pending flow: nothing is
        // current when the (late) platform callback lands.
        val stale = lane.onCallback(null)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, stale)
        assertNull(lane.savedKey)
        // The next explicit user request launches cleanly.
        assertTrue(lane.onPending(2L) is PlatformLaunchOwnership.PendingDecision.Launch)
    }

    @Test
    fun callbackWithoutAnySavedKeyDrops() {
        val lane = newLane()
        val decision = lane.onCallback(1L)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, decision)
        assertNull(lane.savedKey)
    }

    @Test
    fun releaseFreesLaneForImmediateRelaunch() {
        val lane = newLane()
        lane.onPending(1L)
        lane.release()
        assertNull(lane.savedKey)
        assertTrue(lane.onPending(2L) is PlatformLaunchOwnership.PendingDecision.Launch)
    }

    // ------------------------------------------------------- lane isolation

    @Test
    fun unrelatedLanesDoNotShareOwnership() {
        // The three effects own one ledger each; a stale callback on one
        // lane must never disturb another lane's issued identity.
        val attachment = newLane()
        val skills = newLane()
        val permission = newLane()
        attachment.onPending(1L)
        skills.onPending(1L)
        permission.onPending(1L)

        // The attachment lane's stale callback settles (dropped); skills and
        // permission lanes keep their in-flight ownership untouched.
        val stale = attachment.onCallback(null)
        assertEquals(PlatformLaunchOwnership.CallbackDecision.Drop, stale)
        assertEquals(1L, skills.savedKey?.incarnation)
        assertEquals(1L, permission.savedKey?.incarnation)
        assertTrue(skills.onCallback(1L) is PlatformLaunchOwnership.CallbackDecision.Dispatch)
        assertTrue(permission.onCallback(1L) is PlatformLaunchOwnership.CallbackDecision.Dispatch)
    }

    @Test
    fun eachLaneClaimsItsOwnNamespace() {
        val first = newLane()
        val second = newLane()
        assertFalse(first.namespace == second.namespace)
    }
}
