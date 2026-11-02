// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

import com.floe.android.core.officeengine.OfficeDocumentFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the C08 tracked-change/review contract.
 *
 * These assert only observed facts: real pinned command names, tri-state
 * state parsing, command-specific acknowledgement, bounded timeout and the
 * keep-revisions PDF proof. No engine, WebView or Android framework is used.
 */
class OfficeRevisionContractTest {

    @Test
    fun writerOnlySupportMatchesPinnedMobileReviewSurface() {
        assertTrue(OfficeRevisionContract.supports(OfficeDocumentFormat.DOCX))
        assertFalse(OfficeRevisionContract.supports(OfficeDocumentFormat.XLSX))
        assertFalse(OfficeRevisionContract.supports(OfficeDocumentFormat.PPTX))
    }

    @Test
    fun commandsAreTheRealPinnedReviewActions() {
        assertEquals(".uno:TrackChanges", OfficeRevisionAction.TOGGLE_RECORDING.command)
        assertEquals(".uno:ShowTrackedChanges", OfficeRevisionAction.SHOW_CHANGES.command)
        assertEquals(".uno:AcceptTrackedChange", OfficeRevisionAction.ACCEPT_CURRENT.command)
        assertEquals(".uno:AcceptTrackedChangeToNext", OfficeRevisionAction.ACCEPT_NEXT.command)
        assertEquals(".uno:RejectTrackedChange", OfficeRevisionAction.REJECT_CURRENT.command)
        assertEquals(".uno:RejectTrackedChangeToNext", OfficeRevisionAction.REJECT_NEXT.command)
        assertEquals(".uno:AcceptAllTrackedChanges", OfficeRevisionAction.ACCEPT_ALL.command)
        assertEquals(".uno:RejectAllTrackedChanges", OfficeRevisionAction.REJECT_ALL.command)
        assertEquals(".uno:PreviousTrackedChange", OfficeRevisionAction.PREVIOUS.command)
        assertEquals(".uno:NextTrackedChange", OfficeRevisionAction.NEXT.command)
        // Wire shape used by every proven editable command (undo/redo/save).
        assertEquals("uno .uno:AcceptAllTrackedChanges", OfficeRevisionAction.ACCEPT_ALL.wireFrame)
    }

    @Test
    fun stateParsingKeepsUnknownDistinctFromFalse() {
        assertNull(OfficeRevisionContract.enabled(null))
        assertNull(OfficeRevisionContract.enabled(""))
        assertNull(OfficeRevisionContract.enabled("undefined"))
        assertEquals(true, OfficeRevisionContract.enabled("true"))
        assertEquals(true, OfficeRevisionContract.enabled("enabled"))
        assertEquals(true, OfficeRevisionContract.enabled("checked"))
        assertEquals(false, OfficeRevisionContract.enabled("false"))
        assertEquals(false, OfficeRevisionContract.enabled("disabled"))
        assertEquals(false, OfficeRevisionContract.enabled("unchecked"))
    }

    @Test
    fun dispatchDoesNotBecomeAnObservedState() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatched(OfficeRevisionAction.TOGGLE_RECORDING, 1_000L)
        val pending = tracker.snapshot(
            sessionToken = "token",
            generation = 1L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 1_100L,
        )
        // Sent is not on/off and not a success claim.
        assertNull(pending.recording)
        assertEquals(OfficeRevisionAction.TOGGLE_RECORDING, pending.pendingAction)
        assertFalse(pending.supported)

        assertTrue(tracker.onStateChanged(".uno:TrackChanges", "true", 1_200L))
        val observed = tracker.snapshot(
            sessionToken = "token",
            generation = 1L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 1_300L,
        )
        assertEquals(true, observed.recording)
        assertEquals(OfficeRevisionAction.TOGGLE_RECORDING, observed.lastAcknowledged)
        assertNull(observed.pendingAction)
        assertTrue(observed.supported)
    }

    @Test
    fun acknowledgementMustMatchTheExactDispatchedCommand() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatched(OfficeRevisionAction.ACCEPT_CURRENT, 10L)
        assertTrue(tracker.onStateChanged(".uno:RejectTrackedChange", "true", 20L))
        // A different command's state frame is observed but is NOT this
        // action's acknowledgement.
        assertTrue(tracker.hasPending())
        assertTrue(tracker.onStateChanged(".uno:AcceptTrackedChange", "true", 30L))
        assertFalse(tracker.hasPending())
    }

    @Test
    fun missingAcknowledgementExpiresWithoutFabricatingState() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatched(OfficeRevisionAction.ACCEPT_ALL, 5_000L)
        val waiting = tracker.snapshot(
            sessionToken = "token",
            generation = 2L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 8_499L,
        )
        assertTrue(waiting.pendingTimedOut)

        assertTrue(tracker.expirePending(OfficeRevisionAction.ACCEPT_ALL))
        val expired = tracker.snapshot(
            sessionToken = "token",
            generation = 2L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 8_500L,
        )
        assertEquals("noAcknowledgement", expired.lastFailure)
        assertNull(expired.acceptAllAvailable)
        assertNull(expired.pendingAction)
    }

    @Test
    fun transportFailureIsNotAnAcknowledgement() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatchFailed(OfficeRevisionAction.REJECT_ALL, "transport-write-failed")
        val state = tracker.snapshot(
            sessionToken = "token",
            generation = 3L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 100L,
        )
        assertEquals("transport-write-failed", state.lastFailure)
        assertNull(state.rejectAllAvailable)
        assertNull(state.lastAcknowledged)
    }

    @Test
    fun pageIssuedAcceptRejectCommandsAdvanceTheMutationEpoch() {
        val tracker = OfficeRevisionTracker()
        tracker.notePageMutation(OfficeRevisionContract.pageUnoCommand("uno .uno:AcceptAllTrackedChanges"))
        tracker.notePageMutation(OfficeRevisionContract.pageUnoCommand("uno .uno:RejectTrackedChange?RejectTrackedChange:short=1"))
        tracker.notePageMutation(OfficeRevisionContract.pageUnoCommand("uno .uno:ShowTrackedChanges"))
        assertEquals(2L, tracker.mutationEpoch())
    }

    @Test
    fun pageCommandParsingIsExactAndBounded() {
        assertEquals(".uno:AcceptTrackedChange", OfficeRevisionContract.pageUnoCommand("uno .uno:AcceptTrackedChange"))
        assertEquals(".uno:RejectTrackedChange", OfficeRevisionContract.pageUnoCommand("uno .uno:RejectTrackedChange?x=1"))
        assertNull(OfficeRevisionContract.pageUnoCommand("key .uno:AcceptTrackedChange"))
        assertNull(OfficeRevisionContract.pageUnoCommand("uno AcceptTrackedChange"))
    }

    @Test
    fun onlyContentRevisionCommandsAdvanceTheMutationEpoch() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatched(OfficeRevisionAction.TOGGLE_RECORDING, 1L)
        tracker.onDispatched(OfficeRevisionAction.SHOW_CHANGES, 2L)
        assertEquals(0L, tracker.mutationEpoch())
        tracker.onDispatched(OfficeRevisionAction.ACCEPT_ALL, 3L)
        tracker.onDispatched(OfficeRevisionAction.REJECT_CURRENT, 4L)
        assertEquals(2L, tracker.mutationEpoch())
    }

    @Test
    fun lateAcknowledgementAfterTimeoutIsObservedWithoutResurrectingPending() {
        val tracker = OfficeRevisionTracker()
        tracker.onDispatched(OfficeRevisionAction.ACCEPT_CURRENT, 1_000L)
        assertTrue(tracker.expirePending(OfficeRevisionAction.ACCEPT_CURRENT))
        val expired = tracker.snapshot(
            sessionToken = "token",
            generation = 1L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 5_000L,
        )
        assertNull(expired.pendingAction)
        assertEquals("noAcknowledgement", expired.lastFailure)

        // A late engine frame is recorded as the observed acknowledgement,
        // but it never recreates a "pending" action or a success notice.
        assertTrue(tracker.onStateChanged(".uno:AcceptTrackedChange", "true", 5_100L))
        assertFalse(tracker.hasPending())
        val late = tracker.snapshot(
            sessionToken = "token",
            generation = 1L,
            format = OfficeDocumentFormat.DOCX,
            manageRedlines = true,
            liveEditableMount = true,
            editPermissionEstablished = true,
            pageEditMode = true,
            nativeLeaseBusy = false,
            nowElapsedMs = 5_200L,
        )
        assertEquals(OfficeRevisionAction.ACCEPT_CURRENT, late.lastAcknowledged)
        assertNull(late.lastFailure)
        assertNull(late.pendingAction)
    }

    @Test
    fun pdfProofStatesAreTruthful() {
        val unchanged = proof(
            before = "a".repeat(64),
            after = "a".repeat(64),
            epochBefore = 4L,
            epochAfter = 4L,
            completed = true,
        )
        assertEquals("revisionsKeptSourceUnchanged", unchanged.verdict)
        assertTrue(unchanged.revisionsPreserved)
        assertEquals(true, unchanged.sourceUnchanged)
        assertFalse(unchanged.pdfCarriesEditableRevisions)

        val changedByCopy = proof(
            before = "a".repeat(64),
            after = "b".repeat(64),
            epochBefore = 4L,
            epochAfter = 4L,
            completed = true,
        )
        assertEquals("revisionsKeptSourceChanged", changedByCopy.verdict)
        assertTrue(changedByCopy.revisionsPreserved)
        assertEquals(false, changedByCopy.sourceUnchanged)

        val revisionAction = proof(
            before = "a".repeat(64),
            after = "a".repeat(64),
            epochBefore = 4L,
            epochAfter = 5L,
            completed = true,
        )
        assertEquals("revisionActionDuringExport", revisionAction.verdict)
        assertFalse(revisionAction.revisionsPreserved)

        val unmeasured = proof(
            before = null,
            after = null,
            epochBefore = 4L,
            epochAfter = 4L,
            completed = true,
        )
        assertEquals("revisionsKeptSourceUnmeasured", unmeasured.verdict)
        assertNull(unmeasured.sourceUnchanged)

        val notCreated = proof(
            before = "a".repeat(64),
            after = "a".repeat(64),
            epochBefore = 4L,
            epochAfter = 4L,
            completed = false,
        )
        assertEquals("notCreated", notCreated.verdict)
    }

    private fun proof(
        before: String?,
        after: String?,
        epochBefore: Long,
        epochAfter: Long,
        completed: Boolean,
    ) = OfficeRevisionPdfProof(
        opId = "export-1",
        sessionToken = "token",
        generation = 1L,
        workingCopySha256Before = before,
        workingCopyBytesBefore = if (before == null) 0L else 10L,
        workingCopySha256After = after,
        workingCopyBytesAfter = if (after == null) 0L else 10L,
        revisionMutationEpochBefore = epochBefore,
        revisionMutationEpochAfter = epochAfter,
        outputSha256 = if (completed) "c".repeat(64) else null,
        outputBytes = if (completed) 100L else 0L,
        completed = completed,
        completedAtElapsedMs = 1L,
    )
}
