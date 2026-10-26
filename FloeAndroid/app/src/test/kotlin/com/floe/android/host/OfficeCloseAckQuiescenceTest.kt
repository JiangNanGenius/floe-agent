// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.OfficeCloseAckPolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the acknowledged-close retirement path of
 * [OfficePreviewController].
 *
 * Mechanism: the engine acknowledges one exact current user close BEFORE
 * posting the native BYE that ends the viewer process inside the call;
 * that exit bypasses every Java Activity-result path, so the real result —
 * the only other consumer of the recorded acknowledgement — may never
 * arrive. Arming the bounded retirement and its expiry share ONE pure
 * identity guard ([ackedCloseStillOwnsSlot], applied under the controller
 * lock at both call sites): a stale, settled or replaced operation can
 * never cancel/replace the current operation's single global job nor settle
 * through it, and the expiry releases ONLY the admission slot under honest
 * uncertainty through the same [OfficeCloseAckPolicy.resolveViewerResult]
 * decision a missing-result onViewerResult applies — no error report, never
 * closedCleanly, staged inputs retained. It is NOT a claim that engine or
 * IO work completed.
 *
 * Authored unrun: Main runs the batch compile/test gate.
 */
class OfficeCloseAckQuiescenceTest {

    /** The exact arguments OfficePreviewController.settleAcknowledgedCloseIfUnclaimed passes. */
    private fun quiescenceResolution(ackedUserClose: Boolean, ownerCurrent: Boolean = true) =
        OfficeCloseAckPolicy.resolveViewerResult(
            ownerCurrent = ownerCurrent,
            outcomePresent = false,
            exactToken = false,
            failureName = null,
            closedCleanly = false,
            ackedUserClose = ackedUserClose,
        )

    @Test
    fun acknowledgedUserCloseWithoutResultRetiresAdmissionHonestly() {
        val resolution = quiescenceResolution(ackedUserClose = true)
        // OWNED_CLOSE_UNCERTAIN: the close was requested; the native exit
        // bypassed the result. The App may release the admission slot, but
        // must show no error, must never claim a clean close, and must retain
        // the staged snapshot / working copy.
        assertEquals(OfficeCloseAckPolicy.Interpretation.OWNED_CLOSE_UNCERTAIN, resolution.interpretation)
        assertNull(resolution.errorKey)
        assertFalse(resolution.removeInput)
    }

    @Test
    fun missingResultWithoutAcknowledgementStaysFailureAndKeepsAdmissionPolicy() {
        // An unexpected viewer death with NO recorded close-intent must not be
        // retired by the expiry path: it keeps the pre-existing REFUSED
        // semantics (honest "viewer" failure, input retained).
        val resolution = quiescenceResolution(ackedUserClose = false)
        assertEquals(OfficeCloseAckPolicy.Interpretation.REFUSED, resolution.interpretation)
        assertEquals("viewer", resolution.errorKey)
        assertFalse(resolution.removeInput)
    }

    @Test
    fun staleOwnerSettlesExactlyLikeTheRealResultPath() {
        // If the owning workspace/task went stale while viewing, the
        // expiry path must mirror onViewerResult's NOT_CURRENT handling
        // (silent settle, no input removal) instead of wedging the slot.
        val resolution = quiescenceResolution(ackedUserClose = true, ownerCurrent = false)
        assertEquals(OfficeCloseAckPolicy.Interpretation.NOT_CURRENT, resolution.interpretation)
        assertNull(resolution.errorKey)
        assertFalse(resolution.removeInput)
    }

    @Test
    fun quiescenceExpiryMatchesMissingResultViewerCallbackDecision() {
        // Convergence proof: settling directly at expiry must equal what
        // onViewerResult computes for a null-data (RESULT_CANCELED-shaped)
        // callback after consuming the exact acknowledgement. If these ever
        // diverge, one of the two retirement paths invents state the other
        // would not.
        val viaQuiescence = quiescenceResolution(ackedUserClose = true)
        val viaMissingResultCallback = OfficeCloseAckPolicy.resolveViewerResult(
            ownerCurrent = true,
            outcomePresent = false,
            exactToken = false,
            failureName = null,
            closedCleanly = false,
            ackedUserClose = true,
        )
        assertEquals(viaMissingResultCallback.interpretation, viaQuiescence.interpretation)
        assertEquals(viaMissingResultCallback.errorKey, viaQuiescence.errorKey)
        assertEquals(viaMissingResultCallback.removeInput, viaQuiescence.removeInput)
    }

    @Test
    fun internalTeardownReasonsNeverProduceAnAcknowledgement() {
        // Only genuine user closes reach the parent's acknowledgement (and so
        // can arm the retirement). Internal teardowns — transport failure,
        // presentation replacement, reclamation — stay un-acknowledged and
        // therefore can never retire the admission through this path.
        for (reason in listOf("user-back", "page-close")) {
            val request = OfficeCloseAckPolicy.validateShape(
                token = "token-1",
                generation = 1L,
                incarnation = 1L,
                reason = reason,
            )
            assertTrue("user close reason $reason must validate", request != null)
        }
        for (reason in listOf("presentation-replaced", "transport-failure", "reclaimed", null)) {
            val request = OfficeCloseAckPolicy.validateShape(
                token = "token-1",
                generation = 1L,
                incarnation = 1L,
                reason = reason,
            )
            assertTrue("internal reason $reason must never validate", request == null)
        }
    }

    @Test
    fun malformedAcknowledgementNeverValidates() {
        // Fail-closed shape rules keep a malformed engine payload from ever
        // arming the retirement for the wrong operation.
        assertNull(OfficeCloseAckPolicy.validateShape(null, 1L, 1L, "user-back"))
        assertNull(OfficeCloseAckPolicy.validateShape("", 1L, 1L, "user-back"))
        assertNull(OfficeCloseAckPolicy.validateShape("token-1", 0L, 1L, "user-back"))
        assertNull(OfficeCloseAckPolicy.validateShape("token-1", 1L, 0L, "user-back"))
        assertNull(OfficeCloseAckPolicy.validateShape("token-1", 1L, 1L, "USER-BACK"))
    }

    // ------------------------------------------- shared identity guard facts

    private val ackInc1 = OfficeCloseAckPolicy.AckRequest(
        sessionToken = "token-1", generation = 1L, viewerIncarnation = 1L, reason = "user-back",
    )
    private val ackInc2 = OfficeCloseAckPolicy.AckRequest(
        sessionToken = "token-2", generation = 1L, viewerIncarnation = 2L, reason = "page-close",
    )

    private fun guard(
        activeIsCandidate: Boolean = true,
        retired: Boolean = false,
        viewEnded: Boolean = false,
        phaseViewing: Boolean = true,
        candidateIncarnation: Long = 1L,
        candidateSessionToken: String? = "token-1",
        ack: OfficeCloseAckPolicy.AckRequest? = ackInc1,
    ) = ackedCloseStillOwnsSlot(
        activeIsCandidate, retired, viewEnded, phaseViewing,
        candidateIncarnation, candidateSessionToken, ack,
    )

    @Test
    fun currentAcknowledgedClosePassesTheSharedGuard() {
        assertTrue(guard())
    }

    @Test
    fun staleArmAfterRealResultSettledCannotReplaceNewerOperationJob() {
        // The race this repair closes: op1's ack was accepted, then a real
        // Activity result settled op1 and a NEW op2 close recorded its own
        // ack — all before op1's accepted call reached the arming step. The
        // global job now belongs to op2; op1's facts must fail the guard so
        // the stale arm never cancels/replaces op2's job and leaves only its
        // own expiry no-op (which would wedge the new close).
        assertFalse(guard(activeIsCandidate = false, viewEnded = true, ack = ackInc2))
        // The SAME guard still authorizes op2's own arm and expiry.
        assertTrue(guard(candidateIncarnation = 2L, candidateSessionToken = "token-2", ack = ackInc2))
    }

    @Test
    fun everyRetirementOrForeignFactFailsTheGuard() {
        // Each fence term independently: retired, view-ended, no longer
        // VIEWING, ack consumed, or an ack naming a different
        // incarnation/token may never touch the job slot.
        assertFalse(guard(retired = true))
        assertFalse(guard(viewEnded = true))
        assertFalse(guard(phaseViewing = false))
        assertFalse(guard(ack = null))
        assertFalse(guard(ack = ackInc2))
        assertFalse(guard(candidateSessionToken = "token-2"))
        assertFalse(guard(candidateIncarnation = 7L))
        assertFalse(guard(activeIsCandidate = false))
    }

    @Test
    fun duplicateAcknowledgementIsIdempotentForTheCurrentOwner() {
        // A second acknowledgement of the same still-current operation re-arms
        // its OWN single job slot (replaced by its exact owner — the expiry
        // decision is unchanged), so duplicate engine acks converge instead of
        // arming competing jobs.
        assertTrue(guard())
        assertTrue(guard(ack = OfficeCloseAckPolicy.AckRequest("token-1", 2L, 1L, "page-close")))
    }
}
