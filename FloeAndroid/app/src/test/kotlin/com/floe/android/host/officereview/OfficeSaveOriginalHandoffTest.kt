// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.core.officeengine.OfficeSaveOriginalHandoffPolicy
import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure JVM tests for the manual original-save handoff policy
 * (OFC-SAVE-REOPEN, job-4c314431dd8348d4; AUTHORED NOTRUN — Main runs the
 * composed batch). Pins the wire shape the App endpoint re-validates: only
 * a real FLUSHED/UNMODIFIED working-copy flush receipt maps to a notice
 * (the mount supplies the format — a flush receipt carries none), every
 * other terminal maps to null so the viewer keeps its honest failure/
 * unknown path, and malformed claims (shape/digest/size/format/token) can
 * never reach the App commit lane.
 */
class OfficeSaveOriginalHandoffTest {

    private fun receipt(
        operation: OfficeSaveOperation = OfficeSaveOperation.WORKING_COPY_FLUSH,
        state: OfficeSaveState = OfficeSaveState.FLUSHED,
        workingCopySha256: String? = "a".repeat(64),
        workingCopyBytes: Long = 128L,
        format: String? = null,
    ): OfficeSaveReceipt = OfficeSaveReceipt(
        opId = "original-9-xyz",
        sessionToken = "sess-abcdef0123456789",
        generation = 42L,
        operation = operation,
        state = state,
        format = format,
        suggestedName = null,
        expectedBaseSha256 = null,
        workingCopySha256 = workingCopySha256,
        workingCopyBytes = workingCopyBytes,
        outputDocumentPath = null,
        outputSha256 = null,
        outputBytes = 0L,
        failure = null,
        message = null,
        cancelRequested = false,
        attestation = "uno-ack+working-copy-digest",
        submittedAtElapsedMs = 0L,
        completedAtElapsedMs = 0L,
    )

    @Test
    fun flushedReceiptMapsToNoticeWithMountFormat() {
        val notice = OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(receipt(), "docx")
        assertNotNull(notice)
        assertEquals("original-9-xyz", notice!!.opId)
        assertEquals("sess-abcdef0123456789", notice.sessionToken)
        assertEquals(42L, notice.generation)
        assertEquals("docx", notice.format)
        assertEquals("a".repeat(64), notice.workingCopySha256)
        assertEquals(128L, notice.workingCopyBytes)
    }

    @Test
    fun unmodifiedReceiptMapsToNoticeToo() {
        val notice = OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
            receipt(state = OfficeSaveState.UNMODIFIED), "xlsx",
        )
        assertNotNull(notice)
    }

    @Test
    fun saveCopyAndFailureTerminalsNeverMapToANotice() {
        // OUTPUT_READY is the Save-Copy lane; FAILED/UNKNOWN/CANCELLED/
        // REJECTED keep the viewer's honest failure path. None of them may
        // ever start an original-save handoff.
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(
                    operation = OfficeSaveOperation.STAGED_EXPORT,
                    state = OfficeSaveState.OUTPUT_READY,
                ),
                "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(state = OfficeSaveState.FAILED), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(state = OfficeSaveState.UNKNOWN), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(state = OfficeSaveState.CANCELLED), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(state = OfficeSaveState.REJECTED), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(
                    operation = OfficeSaveOperation.STAGED_EXPORT,
                    state = OfficeSaveState.FLUSHED,
                ),
                "docx",
            ),
        )
    }

    @Test
    fun flushReceiptWithoutVerifiedFactsRefuses() {
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(workingCopySha256 = null), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(workingCopyBytes = 0L), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(
                receipt(workingCopySha256 = "not-a-digest"), "docx",
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(receipt(), "odt"),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.noticeFromReceipt(receipt(), null),
        )
    }

    @Test
    fun validateSaveOriginalShapeRules() {
        assertNotNull(
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = "op-1", token = "sess", generation = 1L, format = "pptx",
                workingCopySha256 = "b".repeat(64), workingCopyBytes = 1L,
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = "bad op", token = "sess", generation = 1L, format = "docx",
                workingCopySha256 = "b".repeat(64), workingCopyBytes = 1L,
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = "op-1", token = "sess", generation = 0L, format = "docx",
                workingCopySha256 = "b".repeat(64), workingCopyBytes = 1L,
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = "op-1", token = "sess", generation = 1L, format = "docx",
                workingCopySha256 = "B".repeat(64), workingCopyBytes = 1L,
            ),
        )
        assertNull(
            OfficeSaveOriginalHandoffPolicy.validateSaveOriginal(
                opId = "op-1", token = "sess", generation = 1L, format = "docx",
                workingCopySha256 = "b".repeat(64),
                workingCopyBytes = OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED.toLong(),
            ),
        )
    }

    @Test
    fun verdictSpaceIsClosedAndTotal() {
        assertEquals(1, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED)
        assertEquals(2, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED)
        // Receipt follow-up (job-5c864499175b4df1): the four SOURCE_*
        // verdicts correlate an attached provider leg — locally saved (or
        // already current) but the external sync is pending/conflict — and
        // are distinct from the fully-synced ACCEPTED/UNCHANGED.
        assertEquals(3, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_PENDING)
        assertEquals(4, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_PENDING)
        assertEquals(5, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_ACCEPTED_SOURCE_CONFLICT)
        assertEquals(6, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_UNCHANGED_SOURCE_CONFLICT)
        assertEquals(-1, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REJECTED)
        assertEquals(0, OfficeSaveOriginalHandoffPolicy.SAVE_ORIGINAL_REFUSED)
    }
}
