// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingexchange

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingError
import com.floe.android.host.meeting.MeetingErrorCode
import com.floe.android.host.meeting.MeetingException
import com.floe.android.host.meeting.MeetingMaterialKind
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MeetingExportServiceTest {
    private fun prepare(
        detail: MeetingDetail,
        format: MeetingExportFormat = MeetingExportFormat.TXT,
        read: (suspend (String) -> MeetingDetail)? = null,
    ): MeetingExportPreparationResult = runBlocking {
        MeetingExportService(
            readMeeting = read ?: { detail },
            labels = MeetingExportTestFixtures.LABELS,
            zoneId = MeetingExportTestFixtures.UTC,
        ).prepare(detail.id, format)
    }

    private fun document(
        detail: MeetingDetail,
        format: MeetingExportFormat = MeetingExportFormat.TXT,
    ): MeetingExportDocument {
        val result = prepare(detail, format)
        assertTrue("expected ready but was $result", result is MeetingExportPreparationResult.Ready)
        return (result as MeetingExportPreparationResult.Ready).document
    }

    @Test
    fun onlyTheSelectedMeetingContentIsRendered() {
        val detail = MeetingExportTestFixtures.detail(
            title = "Selected meeting",
            notes = "Only this meeting's notes.",
            segments = listOf(
                MeetingExportTestFixtures.segment(
                    startMillis = 5_000L,
                    endMillis = 9_000L,
                    text = "Only this meeting's transcript.",
                    speaker = "Alex",
                ),
            ),
            materials = listOf(
                MeetingExportTestFixtures.material("material-1"),
            ),
        )
        val rendered = document(detail)
        assertEquals(detail.id, rendered.meetingId)
        assertTrue(rendered.text.contains("Selected meeting"))
        assertTrue(rendered.text.contains("Only this meeting's notes."))
        assertTrue(rendered.text.contains("Only this meeting's transcript."))
        assertTrue(rendered.text.contains("Alex"))
        assertTrue(rendered.text.contains("[00:00:05 – 00:00:09]"))
        assertFalse(rendered.text.contains("Unrelated"))
        assertFalse(rendered.text.contains(MeetingExportTestFixtures.OTHER_MEETING_ID))
    }

    @Test
    fun missingMeetingIsAUsableNotFoundFailure() {
        val detail = MeetingExportTestFixtures.detail()
        val result = prepare(detail) { throw MeetingException(
            MeetingError(MeetingErrorCode.NOT_FOUND, "missing", retryable = false),
        ) }
        assertTrue(result is MeetingExportPreparationResult.Failed)
        assertEquals(
            MeetingExportFailureCode.NOT_FOUND,
            (result as MeetingExportPreparationResult.Failed).failure.code,
        )
    }

    @Test
    fun storageFailureIsRetryableReadFailure() {
        val detail = MeetingExportTestFixtures.detail()
        val result = prepare(detail) { throw MeetingException(
            MeetingError(MeetingErrorCode.STORAGE_FAILURE, "unreadable", retryable = true),
        ) }
        val failure = (result as MeetingExportPreparationResult.Failed).failure
        assertEquals(MeetingExportFailureCode.READ_FAILED, failure.code)
        assertTrue(failure.retryable)
    }

    @Test
    fun unexpectedReadFailureIsReportedWithoutThrowing() {
        val detail = MeetingExportTestFixtures.detail()
        val result = prepare(detail) { throw IllegalStateException("unexpected") }
        assertEquals(
            MeetingExportFailureCode.READ_FAILED,
            (result as MeetingExportPreparationResult.Failed).failure.code,
        )
    }

    @Test
    fun invalidIdentifierIsRejectedBeforeAnyRead() {
        var read = false
        val result = runBlocking {
            MeetingExportService(
                readMeeting = { read = true; MeetingExportTestFixtures.detail() },
                labels = MeetingExportTestFixtures.LABELS,
                zoneId = MeetingExportTestFixtures.UTC,
            ).prepare("../../not-a-meeting", MeetingExportFormat.TXT)
        }
        assertEquals(
            MeetingExportFailureCode.INVALID_IDENTIFIER,
            (result as MeetingExportPreparationResult.Failed).failure.code,
        )
        assertFalse(read)
    }

    @Test
    fun aSourceThatReturnsAnotherMeetingFailsClosed() {
        val requested = MeetingExportTestFixtures.detail(id = MeetingExportTestFixtures.MEETING_ID)
        val other = MeetingExportTestFixtures.detail(
            id = MeetingExportTestFixtures.OTHER_MEETING_ID,
            title = "Other meeting",
            notes = "Unrelated notes",
        )
        val result = prepare(requested) { other }
        assertEquals(
            MeetingExportFailureCode.IDENTITY_MISMATCH,
            (result as MeetingExportPreparationResult.Failed).failure.code,
        )
    }

    @Test
    fun emptyNotesAndTranscriptRemainExplicitAndUnfabricated() {
        val rendered = document(MeetingExportTestFixtures.detail(notes = "", segments = emptyList()))
        assertFalse(rendered.hasNotes)
        assertFalse(rendered.hasTranscript)
        assertTrue(rendered.text.contains(MeetingExportTestFixtures.LABELS.noNotes))
        assertTrue(rendered.text.contains(MeetingExportTestFixtures.LABELS.noTranscript))
        assertFalse(rendered.text.contains("[00:"))
    }

    @Test
    fun blankTranscriptSegmentsAreNotTreatedAsATranscript() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                notes = "",
                segments = listOf(
                    MeetingExportTestFixtures.segment(0L, 1_000L, ""),
                    MeetingExportTestFixtures.segment(1_000L, 2_000L, "   "),
                ),
            ),
        )
        assertFalse(rendered.hasNotes)
        assertFalse(rendered.hasTranscript)
        assertTrue(rendered.text.contains(MeetingExportTestFixtures.LABELS.noTranscript))
        assertFalse(rendered.text.contains("[00:00:"))
    }

    @Test
    fun notesWithoutTranscriptDoNotPretendTheMeetingWasTranscribed() {
        val rendered = document(
            MeetingExportTestFixtures.detail(notes = "Remember the decision."),
        )
        assertTrue(rendered.hasNotes)
        assertFalse(rendered.hasTranscript)
        assertTrue(rendered.text.contains("Remember the decision."))
        assertTrue(rendered.text.contains(MeetingExportTestFixtures.LABELS.noTranscript))
    }

    @Test
    fun transcriptWithoutNotesKeepsTheMissingNotesState() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                notes = "",
                segments = listOf(
                    MeetingExportTestFixtures.segment(0L, 1_000L, "Short transcript."),
                ),
            ),
        )
        assertFalse(rendered.hasNotes)
        assertTrue(rendered.hasTranscript)
        assertTrue(rendered.text.contains(MeetingExportTestFixtures.LABELS.noNotes))
        assertTrue(rendered.text.contains("Short transcript."))
    }

    @Test
    fun unicodeAndTimestampsSurviveUtf8Rendering() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                title = "周会 😀",
                notes = "决定：继续。",
                segments = listOf(
                    MeetingExportTestFixtures.segment(
                        startMillis = 65_000L,
                        endMillis = 70_000L,
                        text = "你好 👋",
                        speaker = "张三",
                    ),
                ),
            ),
        )
        assertTrue(rendered.text.contains("周会 😀"))
        assertTrue(rendered.text.contains("决定：继续。"))
        assertTrue(rendered.text.contains("你好 👋"))
        assertTrue(rendered.text.contains("张三"))
        assertTrue(rendered.text.contains("[00:01:05 – 00:01:10]"))
        assertEquals(
            rendered.text.toByteArray(Charsets.UTF_8).size.toLong(),
            rendered.byteCount,
        )
        assertEquals(MeetingExportFormat.TXT.mimeType, rendered.format.mimeType)
        assertTrue(rendered.suggestedFileName.endsWith(".txt"))
    }

    @Test
    fun markdownHasStableSectionsAndARealExtension() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                title = "Review",
                notes = "A note",
                segments = listOf(
                    MeetingExportTestFixtures.segment(65_000L, 70_000L, "Spoken text", "Alex"),
                ),
            ),
            MeetingExportFormat.MARKDOWN,
        )
        assertTrue(rendered.text.startsWith("# Review\n"))
        assertTrue(rendered.text.contains("## Notes"))
        assertTrue(rendered.text.contains("## Transcript"))
        assertTrue(rendered.text.contains("- `[00:01:05 – 00:01:10]` **Alex:** Spoken text"))
        assertEquals("text/markdown", rendered.format.mimeType)
        assertTrue(rendered.suggestedFileName.endsWith(".md"))
    }

    @Test
    fun plainTextHasStableSectionsAndARealExtension() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                title = "Review",
                notes = "A note",
                segments = listOf(
                    MeetingExportTestFixtures.segment(65_000L, 70_000L, "Spoken text", "Alex"),
                ),
            ),
        )
        assertTrue(rendered.text.contains("Review"))
        assertTrue(rendered.text.contains("Notes"))
        assertTrue(rendered.text.contains("Transcript"))
        assertTrue(rendered.text.contains("[00:01:05 – 00:01:10] Alex: Spoken text"))
        assertEquals("text/plain", rendered.format.mimeType)
        assertTrue(rendered.suggestedFileName.endsWith(".txt"))
    }

    @Test
    fun unsafeTitleCannotCreateAPathOrControlTheSuggestedName() {
        val rendered = document(
            MeetingExportTestFixtures.detail(
                title = "../../evil:report<script>\nnext",
            ),
        )
        val name = rendered.suggestedFileName
        assertEquals(File(name).name, name)
        assertFalse(name.contains('/'))
        assertFalse(name.contains('\\'))
        assertFalse(name.contains(':'))
        assertFalse(name.contains('<'))
        assertFalse(name.contains('>'))
        assertFalse(name.contains('\n'))
        assertFalse(name.startsWith("."))
        assertTrue(name.endsWith(".txt"))
    }

    @Test
    fun longEmojiTitleIsBoundedToAReasonableFileName() {
        val rendered = document(
            MeetingExportTestFixtures.detail(title = "😀".repeat(200)),
        )
        val bytes = rendered.suggestedFileName.toByteArray(Charsets.UTF_8).size
        assertTrue("filename was $bytes bytes", bytes <= 140)
        assertTrue(rendered.suggestedFileName.endsWith(".txt"))
        assertFalse(rendered.suggestedFileName.contains('\u0000'))
    }

    @Test
    fun oversizedMeetingIsRejectedInsteadOfTruncated() {
        val rendered = prepare(
            MeetingExportTestFixtures.detail(notes = "a".repeat(MeetingExportFormatter.MAX_EXPORT_CHARS + 1)),
        )
        assertEquals(
            MeetingExportFailureCode.TOO_LARGE,
            (rendered as MeetingExportPreparationResult.Failed).failure.code,
        )
    }

    @Test
    fun renderingIsDeterministicForTheSameMeetingSnapshot() {
        val detail = MeetingExportTestFixtures.detail(
            title = "Deterministic",
            notes = "same input",
            segments = listOf(
                MeetingExportTestFixtures.segment(1_000L, 2_000L, "same transcript"),
            ),
        )
        val first = document(detail, MeetingExportFormat.MARKDOWN)
        val second = document(detail, MeetingExportFormat.MARKDOWN)
        assertEquals(first.text, second.text)
        assertEquals(first.suggestedFileName, second.suggestedFileName)
        assertEquals(first.byteCount, second.byteCount)
    }

    @Test
    fun metadataCountsUseOnlyTheSelectedMeetingMaterials() {
        val recording = MeetingExportTestFixtures.material(
            id = "recording-1",
            kind = MeetingMaterialKind.RECORDING,
        )
        val imported = MeetingExportTestFixtures.material(
            id = "import-1",
            kind = MeetingMaterialKind.AUDIO_IMPORT,
        )
        val rendered = document(
            MeetingExportTestFixtures.detail(
                materials = listOf(recording, imported),
                recordings = listOf(recording),
                imports = listOf(imported),
            ),
        )
        assertTrue(rendered.text.contains("Materials: 2"))
        assertTrue(rendered.text.contains("Recordings: 1"))
        assertTrue(rendered.text.contains("Imports: 1"))
    }
}
