// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.meetingexchange.MeetingDocumentDestinationResult
import com.floe.android.host.meetingexchange.MeetingDocumentExchange
import com.floe.android.host.meetingexchange.MeetingExportFailureCode
import com.floe.android.host.meetingexchange.MeetingExportFormat
import com.floe.android.host.meetingexchange.MeetingExportTestFixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Page seam for meeting export/share. These tests exercise the same admission
 * and identity rules the Compose page uses: one attempt at a time, a target
 * only for the still-selected meeting, and no success from cancellation or a
 * missing write grant. No picker, device, provider or filesystem write is
 * involved.
 */
class MeetingExchangeUiTest {
    private val document = MeetingExportTestFixtures.document(
        MeetingExportTestFixtures.detail(
            title = "Export seam",
            notes = "Saved notes",
            segments = listOf(
                MeetingExportTestFixtures.segment(1_000L, 2_000L, "Saved transcript"),
            ),
        ),
    )
    private val request = MeetingExportTestFixtures.request(document)

    @Test
    fun `export starts only for a selected meeting and never while busy`() {
        assertTrue(meetingExportCanStart(busy = false, meetingId = document.meetingId))
        assertFalse(meetingExportCanStart(busy = true, meetingId = document.meetingId))
        assertFalse(meetingExportCanStart(busy = false, meetingId = null))
        assertFalse(meetingExportCanStart(busy = false, meetingId = "  "))
    }

    @Test
    fun `a result is only shown on the meeting it was prepared for`() {
        assertTrue(meetingExportBelongsToCurrentMeeting(document.meetingId, document.meetingId))
        assertFalse(
            meetingExportBelongsToCurrentMeeting(
                MeetingExportTestFixtures.OTHER_MEETING_ID,
                document.meetingId,
            ),
        )
        assertFalse(meetingExportBelongsToCurrentMeeting(null, document.meetingId))
    }

    @Test
    fun `a picker result for the same meeting becomes one bound target`() {
        val accepted = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = CONTENT_URI,
            hasWriteGrant = true,
            selectedMeetingId = document.meetingId,
        )
        val target = (accepted as MeetingDocumentDestinationResult.Ready).target
        assertEquals(request.requestId, target.requestId)
        assertEquals(document.meetingId, target.meetingId)
        assertEquals(document.format, target.format)
        assertEquals(document.suggestedFileName, target.suggestedFileName)
        assertEquals(document.meetingRevision, target.document.meetingRevision)
    }

    @Test
    fun `a late result for another meeting is rejected before a target exists`() {
        val accepted = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = CONTENT_URI,
            hasWriteGrant = true,
            selectedMeetingId = MeetingExportTestFixtures.OTHER_MEETING_ID,
        )
        assertTrue(accepted is MeetingDocumentDestinationResult.Rejected)
        assertEquals(
            MeetingExportFailureCode.MEETING_CHANGED,
            (accepted as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun `cancelling or returning no document is never success`() {
        assertEquals(
            MeetingDocumentDestinationResult.Cancelled,
            MeetingDocumentExchange.accept(
                request = request,
                resultOk = false,
                uri = null,
                hasWriteGrant = false,
                selectedMeetingId = document.meetingId,
            ),
        )
        assertEquals(
            MeetingDocumentDestinationResult.Cancelled,
            MeetingDocumentExchange.accept(
                request = request,
                resultOk = true,
                uri = null,
                hasWriteGrant = true,
                selectedMeetingId = document.meetingId,
            ),
        )
    }

    @Test
    fun `the returned write grant is required and never assumed`() {
        val accepted = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = CONTENT_URI,
            hasWriteGrant = false,
            selectedMeetingId = document.meetingId,
        )
        assertEquals(
            MeetingExportFailureCode.WRITE_PERMISSION_MISSING,
            (accepted as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun `both offered formats keep their own extension and mime type`() {
        for (format in MeetingExportFormat.entries) {
            val formatDocument = MeetingExportTestFixtures.document(
                MeetingExportTestFixtures.detail(title = "Format ${format.name}"),
                format,
            )
            val formatRequest = MeetingExportTestFixtures.request(formatDocument)
            assertEquals(format, formatRequest.format)
            assertEquals(format.mimeType, formatRequest.mimeType)
            assertTrue(formatRequest.suggestedFileName.endsWith(".${format.extension}"))
        }
    }

    private companion object {
        const val CONTENT_URI = "content://test.provider/document/1"
    }
}
