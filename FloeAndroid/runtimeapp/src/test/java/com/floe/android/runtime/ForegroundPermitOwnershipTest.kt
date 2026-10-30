// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * AUTHORED NOT RUN lifecycle regressions for the actual Samsung two-TTY
 * close failure (device evidence: `a18r-A-closed-B-live.xml` /
 * `A_CLOSED_B_PROCESS_PROOF.txt`; A's pump stopped, `OPS_FINISH_RETURNED`,
 * then B's still live session was stopped although Core never requested B's
 * close).
 *
 * These drive the PRODUCTION retirement policy used by
 * `LinuxRuntimeService`. Main's settled ruling is pinned:
 *
 *  * a permit is pruned ONLY after its exact admitted request is absent from
 *    the runtime's positive ownership set, so a normal A close cannot
 *    masquerade as permission loss and stop B;
 *  * an inactive/dead permit whose exact request is STILL owned keeps the
 *    ORIGINAL GLOBAL fail-closed stop (shared UID/deferred exports);
 *  * unknown owned ids neither retire a token nor fabricate a loss; there is
 *    no elapsed-time prune and no per-permit cancel-routing authority.
 */
class ForegroundPermitOwnershipTest {

    private fun view(token: String, ids: Set<String>, active: Boolean) =
        ForegroundPermitOwnership.PermitView(token = token, requestIDs = ids, active = active)

    @Test
    fun settledParticipantRetiresWithoutGlobalStop() {
        // Actual Samsung order: A settled (its Core foreground permit released)
        // while B is still live under its own active permit.
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = false),
                view("permit-B", setOf("start-B"), active = true)),
            ownedRequestIDs = setOf("start-B"),
        )
        assertEquals(listOf<Any>("permit-A"), plan.retire)
        assertFalse("a retired participant must never stop the surviving session",
            plan.activePermitLoss)
    }

    @Test
    fun repeatedSettledTargetNeverBecomesLoss() {
        // First tick retires A by real settlement...
        val first = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = false),
                view("permit-B", setOf("start-B"), active = true)),
            ownedRequestIDs = setOf("start-B"),
        )
        assertEquals(listOf<Any>("permit-A"), first.retire)
        // ...and a later lifecycle notification for the already-settled
        // target sees only B; there is no residual A loss.
        val second = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-B", setOf("start-B"), active = true)),
            ownedRequestIDs = setOf("start-B"),
        )
        assertTrue(second.retire.isEmpty())
        assertFalse(second.activePermitLoss)
    }

    @Test
    fun inactivePermitWithStillOwnedWorkKeepsOriginalGlobalFailClosed() {
        // A's permit is not active but A's exact request is still owned: this
        // is an ACTIVE permit loss, not a settled participant. The ORIGINAL
        // global response is deliberately preserved (no narrow per-permit
        // cancellation routing), even while B's permit is active.
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = false),
                view("permit-B", setOf("start-B"), active = true)),
            ownedRequestIDs = setOf("start-A", "start-B"),
        )
        assertTrue(plan.retire.isEmpty())
        assertTrue(plan.activePermitLoss)
    }

    @Test
    fun activePermitsKeepTheirAssociations() {
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = true),
                view("permit-B", setOf("start-B"), active = true)),
            ownedRequestIDs = setOf("start-A", "start-B"),
        )
        assertTrue(plan.retire.isEmpty())
        assertFalse(plan.activePermitLoss)
    }

    @Test
    fun stopBFirstLeavesAUsable() {
        // Reverse order of the device run: B is the settled participant.
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = true),
                view("permit-B", setOf("start-B"), active = false)),
            ownedRequestIDs = setOf("start-A"),
        )
        assertEquals(listOf<Any>("permit-B"), plan.retire)
        assertFalse(plan.activePermitLoss)
    }

    @Test
    fun unknownOwnedIdWithoutAssociationNeitherRetiresNorFabricatesLoss() {
        // The admission -> retain window (or a retain failure) leaves an
        // owned id with no association. Unknown ownership is refused as
        // settlement; it is not a global loss by itself. A retain failure is
        // already handled by the ORIGINAL global stop at its own boundary.
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = true)),
            ownedRequestIDs = setOf("start-A", "start-B"),
        )
        assertTrue(plan.retire.isEmpty())
        assertFalse(plan.activePermitLoss)
    }

    @Test
    fun emptyAssociationsDuringAdmissionRetainWindowRefuseLoss() {
        val plan = ForegroundPermitOwnership.plan(
            permits = emptyList(),
            ownedRequestIDs = setOf("start-B"),
        )
        assertTrue(plan.retire.isEmpty())
        assertFalse(plan.activePermitLoss)
    }

    @Test
    fun deferredOwnerAssociationRetiresOnlyAfterItsObligationSettles() {
        // A deferred export is still real owned work: while its OWNER start id
        // remains in the positive ownership set the association is retained,
        // even after the owner's process/permit settled.
        val retainedPlan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-owner", setOf("start-owner"), active = false)),
            ownedRequestIDs = setOf("start-owner", "start-B"),
        )
        assertTrue(retainedPlan.retire.isEmpty())
        // Inactive while its exact obligation is still owned = ORIGINAL
        // global fail-closed (shared UID); this is the settled ruling.
        assertTrue(retainedPlan.activePermitLoss)
        // Once the last real workload has serviced the export, the exact id
        // leaves the ownership set and ONLY then does the association retire.
        val settledPlan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-owner", setOf("start-owner"), active = false)),
            ownedRequestIDs = emptySet(),
        )
        assertEquals(listOf<Any>("permit-owner"), settledPlan.retire)
        assertFalse(settledPlan.activePermitLoss)
    }

    @Test
    fun mixedSettledIdOfAReusedPermitKeepsTheLiveAssociation() {
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-shared", setOf("start-old", "start-live"), active = true)),
            ownedRequestIDs = setOf("start-live"),
        )
        assertTrue(plan.retire.isEmpty())
        assertFalse(plan.activePermitLoss)
    }

    @Test
    fun allSettledAssociationsRetireWithoutAnyStop() {
        val plan = ForegroundPermitOwnership.plan(
            permits = listOf(view("permit-A", setOf("start-A"), active = true),
                view("permit-B", setOf("start-B"), active = false)),
            ownedRequestIDs = emptySet(),
        )
        assertEquals(listOf<Any>("permit-A", "permit-B"), plan.retire)
        assertFalse(plan.activePermitLoss)
    }
}
