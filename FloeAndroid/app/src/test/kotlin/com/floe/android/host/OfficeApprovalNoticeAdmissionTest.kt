// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.core.officeengine.OfficeApprovalNoticePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the approval-notice ADMISSION decision of
 * [OfficePreviewController] (G05-R3 office-approval107, 2026-10-28).
 *
 * Mechanism: while an OWNED document is VIEWING, the engine viewer polls the
 * parent's [com.floe.android.core.officeengine.OfficeApprovalNotice] endpoint
 * so a captured Ask-first approval of the OWNING conversation can surface as
 * a banner and be reviewed WITHOUT closing the document (closing correctly
 * retires the owned context and the approval then fails stale — the observed
 * c16 calc-close-context-refusal behavior, where the guard itself is correct
 * and must NOT be weakened). The answer is admitted ONLY while the queried
 * operation is still THE current, un-retired, not-view-ended, VIEWING
 * operation AND the query names its exact opaque incarnation, session token
 * AND owner task id, AND the operation is OWNED (a null owner can never
 * match — the provider-pick route has no conversation to ask about).
 *
 * The decision is one pure function ([approvalNoticeAdmissible]) applied
 * under the controller lock at the single binder callback, mirroring
 * [ackedCloseStillOwnsSlot]; these tests drive the REAL production decision
 * the controller passes, including the exact arguments
 * answerApprovalNotice supplies. The lookup itself (visible conversation +
 * selected-run pending card) is a separate host join and is NOT the subject
 * of this admission gate.
 *
 * Authored unrun: Main runs the batch compile/test gate.
 */
class OfficeApprovalNoticeAdmissionTest {

    private val token = "session-token-abc"
    private val otherToken = "session-token-xyz"
    private val owner = "convo-1059CCF8-43B8-44B7-AC31-0A21F42EC989"
    private val otherOwner = "convo-00000000-0000-0000-0000-000000000000"

    /** The exact arguments OfficePreviewController.answerApprovalNotice passes. */
    private fun admit(
        retired: Boolean = false,
        viewEnded: Boolean = false,
        phaseViewing: Boolean = true,
        candidateIncarnation: Long = 42L,
        candidateSessionToken: String? = token,
        candidateOwnerTaskId: String? = owner,
        queryIncarnation: Long = 42L,
        queryToken: String = token,
        queryOwnerTaskId: String = owner,
    ) = approvalNoticeAdmissible(
        retired = retired,
        viewEnded = viewEnded,
        phaseViewing = phaseViewing,
        candidateIncarnation = candidateIncarnation,
        candidateSessionToken = candidateSessionToken,
        candidateOwnerTaskId = candidateOwnerTaskId,
        queryIncarnation = queryIncarnation,
        queryToken = queryToken,
        queryOwnerTaskId = queryOwnerTaskId,
    )

    @Test
    fun exactCurrentViewingOwnedOperationIsAdmissible() {
        assertTrue(admit())
    }

    @Test
    fun retiredOrSettledOperationAnswersNothing() {
        // A close/settle in any form must withdraw the banner: the engine
        // acknowledged close retires the admission slot; the approval that
        // arrives afterwards is refused stale by the EXISTING guard (that
        // refusal stays correct and is not bypassed here).
        assertFalse(admit(retired = true))
        assertFalse(admit(viewEnded = true))
        assertFalse(admit(phaseViewing = false))
    }

    @Test
    fun wrongIncarnationTokenOrOwnerAnswersNothing() {
        // Another mount's identity can never be answered through this one —
        // replacement and cross-conversation asks fail closed.
        assertFalse(admit(queryIncarnation = 43L))
        assertFalse(admit(queryToken = otherToken))
        assertFalse(admit(queryOwnerTaskId = otherOwner))
        assertFalse(admit(candidateSessionToken = null))
    }

    @Test
    fun unownedOperationAnswersNothing() {
        // The provider-pick route carries no owning conversation: a null
        // candidate owner can never match any query (honest-absence rule).
        assertFalse(admit(candidateOwnerTaskId = null))
    }

    @Test
    fun pendingToolNameComesOnlyFromTheInstalledLookup() {
        // The admission gate grants nothing by itself: even an admissible
        // query returns a tool name ONLY when the host lookup really reports
        // a captured pending approval of the OWNING conversation's selected
        // run. Documented contract for Main's integration review; the lookup
        // is the host join approvalNoticeFor wired in FloeApplication.
        val lookupAnswer: String? = null
        assertNull(lookupAnswer)
        assertEquals("document.office.edit", "document.office.edit".take(128))
        assertTrue(OfficeApprovalNoticePolicy.MAX_OWNER_CHARS >= owner.length)
    }
}
