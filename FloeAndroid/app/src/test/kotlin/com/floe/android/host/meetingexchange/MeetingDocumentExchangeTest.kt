// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeetingDocumentExchangeTest {
    private val document = MeetingExportTestFixtures.document(
        MeetingExportTestFixtures.detail(
            title = "Document exchange",
            notes = "Private meeting notes",
            segments = listOf(
                MeetingExportTestFixtures.segment(1_000L, 2_000L, "Private transcript"),
            ),
        ),
    )
    private val request = MeetingExportTestFixtures.request(document)

    @Test
    fun aResultForTheSameMeetingBecomesAWriteTarget() {
        val result = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = "content://test.provider/document/1",
            hasWriteGrant = true,
            selectedMeetingId = document.meetingId,
        )
        assertTrue(result is MeetingDocumentDestinationResult.Ready)
        val target = (result as MeetingDocumentDestinationResult.Ready).target
        assertEquals(request.requestId, target.requestId)
        assertEquals(document.meetingId, target.meetingId)
        assertEquals("content://test.provider/document/1", target.uri)
        assertEquals(document.suggestedFileName, target.suggestedFileName)
    }

    @Test
    fun aLateResultCannotExportTheNewlySelectedMeeting() {
        val result = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = "content://test.provider/document/1",
            hasWriteGrant = true,
            selectedMeetingId = MeetingExportTestFixtures.OTHER_MEETING_ID,
        )
        assertEquals(
            MeetingExportFailureCode.MEETING_CHANGED,
            (result as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun aNullMeetingSelectionIsRejected() {
        val result = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = "content://test.provider/document/1",
            hasWriteGrant = true,
            selectedMeetingId = null,
        )
        assertEquals(
            MeetingExportFailureCode.MEETING_CHANGED,
            (result as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun pickerCancellationAndMissingUriProduceCancelled() {
        assertEquals(
            MeetingDocumentDestinationResult.Cancelled,
            MeetingDocumentExchange.accept(
                request, resultOk = false, uri = null, hasWriteGrant = false,
                selectedMeetingId = document.meetingId,
            ),
        )
        assertEquals(
            MeetingDocumentDestinationResult.Cancelled,
            MeetingDocumentExchange.accept(
                request, resultOk = true, uri = null, hasWriteGrant = true,
                selectedMeetingId = document.meetingId,
            ),
        )
        assertEquals(
            MeetingDocumentDestinationResult.Cancelled,
            MeetingDocumentExchange.accept(
                request, resultOk = true, uri = "", hasWriteGrant = true,
                selectedMeetingId = document.meetingId,
            ),
        )
    }

    @Test
    fun nonContentDestinationsAreRejectedBeforeAnyWrite() {
        for (uri in listOf("file:///tmp/export.txt", "https://example.com/export.txt")) {
            val result = MeetingDocumentExchange.accept(
                request = request,
                resultOk = true,
                uri = uri,
                hasWriteGrant = true,
                selectedMeetingId = document.meetingId,
            )
            assertEquals(
                MeetingExportFailureCode.INVALID_DESTINATION,
                (result as MeetingDocumentDestinationResult.Rejected).failure.code,
            )
        }
    }

    @Test
    fun aMissingWriteGrantIsTyped() {
        val result = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = "content://test.provider/document/1",
            hasWriteGrant = false,
            selectedMeetingId = document.meetingId,
        )
        assertEquals(
            MeetingExportFailureCode.WRITE_PERMISSION_MISSING,
            (result as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun identityIsCheckedBeforeDestinationShape() {
        val result = MeetingDocumentExchange.accept(
            request = request,
            resultOk = true,
            uri = "file:///tmp/stale.txt",
            hasWriteGrant = false,
            selectedMeetingId = MeetingExportTestFixtures.OTHER_MEETING_ID,
        )
        assertEquals(
            MeetingExportFailureCode.MEETING_CHANGED,
            (result as MeetingDocumentDestinationResult.Rejected).failure.code,
        )
    }

    @Test
    fun requestKeepsThePreparedSnapshotAndDoesNotExposeContentInToString() {
        assertEquals(document.meetingId, request.meetingId)
        assertEquals(document.format, request.format)
        assertEquals(document.suggestedFileName, request.suggestedFileName)
        assertEquals(MeetingExportFormat.TXT.mimeType, request.mimeType)
        assertEquals(document, request.document)
        assertFalse(request.toString().contains("Private meeting notes"))
        assertFalse(request.toString().contains("Private transcript"))
    }

    @Test
    fun targetToStringDoesNotExposeTheUserUri() {
        val target = MeetingExportTestFixtures.target(document)
        val text = target.toString()
        assertFalse(text.contains("content://"))
        assertFalse(text.contains("Private meeting notes"))
        assertTrue(text.contains(document.meetingId))
    }
}
