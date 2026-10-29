// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the owned-document RETURN admission decision of
 * [OfficePreviewController] (G05-R3 office-return109, 2026-10-28).
 *
 * Mechanism: while an OWNED document is VIEWING, the App publishes a bounded
 * navigation record ([OfficePreviewController.State.ownedReturn] — owner
 * conversation + opaque viewer incarnation + session token) at the real
 * claim, and the owning conversation surface shows one explicit
 * "Back to document" strip. A click decides through the single production
 * predicate [viewerRestoreAdmissible] — the exact arguments
 * [OfficePreviewController.requestOwnedViewerRestore] passes, INCLUDING the
 * established owner fence (op.ownerCurrent(): matching ids alone never
 * prove the current owner) — and the raise's startActivity dispatch runs
 * under the SAME controller lock, so no settle or new-Operation admission
 * (all of which funnel through that lock) can interleave before Android
 * synchronously selects the concrete viewer record (Main platform check,
 * AOSP ActivityStarter REORDER handling). The predicate's own dispatch-
 * under-lock property lives in the controller wiring and is reviewed as
 * such; these tests drive the admission decision itself. The strip returns
 * the user to the document after reviewing an approval WITHOUT closing,
 * retiring or recreating it; nothing here approves, denies, replays or
 * grants anything, and the existing stale-context/owner/epoch guards and
 * the ordinary Back semantics are untouched. If the instance is already
 * gone, the module fails the inert no-request raise closed at launch
 * validation (missing-request finish, no remount) — the pre-existing
 * honest path.
 *
 * Truth-table mirrored from the established approval-notice admission
 * ([approvalNoticeAdmissible]) plus the owner fence and the published-
 * request leg: a live VIEWING owned mount admits its exact captured
 * target; stop, close, settle, replacement, supersede, an owner-closure-
 * invalidated conversation, cross-conversation claims and unowned
 * (provider-pick) operations admit nothing.
 *
 * Authored unrun: Main runs the batch compile/test gate.
 */
class OfficeViewerRestoreAdmissionTest {

    private val token = "session-token-abc"
    private val otherToken = "session-token-xyz"
    private val owner = "convo-1059CCF8-43B8-44B7-AC31-0A21F42EC989"
    private val otherOwner = "convo-00000000-0000-0000-0000-000000000000"

    /** The exact argument shapes requestOwnedViewerRestore passes. */
    private fun admit(
        retired: Boolean = false,
        viewEnded: Boolean = false,
        phaseViewing: Boolean = true,
        ownerCurrent: Boolean = true,
        candidateIncarnation: Long = 42L,
        candidateSessionToken: String? = token,
        candidateOwnerTaskId: String? = owner,
        publishedRequestMatches: Boolean = true,
        claimedIncarnation: Long = 42L,
        claimedSessionToken: String? = token,
        claimedOwnerTaskId: String? = owner,
    ) = viewerRestoreAdmissible(
        retired = retired,
        viewEnded = viewEnded,
        phaseViewing = phaseViewing,
        ownerCurrent = ownerCurrent,
        candidateIncarnation = candidateIncarnation,
        candidateSessionToken = candidateSessionToken,
        candidateOwnerTaskId = candidateOwnerTaskId,
        publishedRequestMatches = publishedRequestMatches,
        claimedIncarnation = claimedIncarnation,
        claimedSessionToken = claimedSessionToken,
        claimedOwnerTaskId = claimedOwnerTaskId,
    )

    @Test
    fun exactCurrentViewingOwnedOperationIsAdmissible() {
        // The strip's captured target for the live mount raises EXACTLY that
        // viewer: same operation, un-retired, not view-ended, VIEWING, owned,
        // published request still naming it, identity matching field-for-
        // field.
        assertTrue(admit())
    }

    @Test
    fun retiredSettledOrUnviewedOperationAdmitsNothing() {
        // A close/settle in any form, an explicit cancel or an operation that
        // never reached the real VIEWING claim withdraws the return route:
        // the document no longer exists to return to and the stale strip's
        // click is a harmless no-op (its published identity was already
        // cleared by the State reset).
        assertFalse(admit(retired = true))
        assertFalse(admit(viewEnded = true))
        assertFalse(admit(phaseViewing = false))
    }

    @Test
    fun wrongIncarnationTokenOrOwnerAdmitsNothing() {
        // Another mount's (or another conversation's) identity can never be
        // raised through this one: replacement and cross-conversation claims
        // fail closed, and an operation that lost its token admits nothing.
        assertFalse(admit(claimedIncarnation = 43L))
        assertFalse(admit(claimedSessionToken = otherToken))
        assertFalse(admit(claimedOwnerTaskId = otherOwner))
        assertFalse(admit(claimedSessionToken = null))
        assertFalse(admit(claimedOwnerTaskId = null))
        assertFalse(admit(candidateSessionToken = null))
    }

    @Test
    fun unownedOperationAdmitsNothing() {
        // The provider-pick route carries no owning conversation: a null
        // candidate owner can never match any claim (honest-absence rule,
        // same as the approval-notice admission).
        assertFalse(admit(candidateOwnerTaskId = null))
    }

    @Test
    fun ownerCurrentClosureInvalidatedAdmitsNothing() {
        // Matching ids alone never prove the current owner: the return lane
        // applies the SAME owner fence current(op) uses for close/notice. A
        // conversation the host no longer owns (deleted/replaced beneath the
        // still-recorded operation) can never be raised back to.
        assertFalse(admit(ownerCurrent = false))
    }

    @Test
    fun replacedPublishedRequestAdmitsNothing() {
        // The published request is the second leg: if State no longer names
        // this exact operation (a replaced/staged mount overwrote the launch
        // record while an old captured target still lingers in a recompos-
        // ing surface), the raise is refused even though the op fields pass.
        assertFalse(admit(publishedRequestMatches = false))
    }
}
