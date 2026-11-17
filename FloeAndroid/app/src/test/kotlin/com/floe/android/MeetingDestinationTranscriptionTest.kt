// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingMaterialKind
import com.floe.android.host.meeting.MeetingMaterialStatus
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import com.floe.android.host.meetingtranscription.MeetingTranscriptionFailure
import com.floe.android.host.meetingtranscription.MeetingTranscriptionFailureCode
import com.floe.android.host.meetingtranscription.MeetingTranscriptionPhase
import com.floe.android.host.meetingtranscription.MeetingTranscriptionReadiness
import com.floe.android.host.meetingtranscription.MeetingTranscriptionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure page policy for the meeting transcription surface.
 *
 * These tests do not start a cloud call, decode audio, copy a source file or
 * boot a device. They pin source selection, start gating, running phases and
 * the user-visible failure mapping used by the Compose section.
 */
class MeetingDestinationTranscriptionTest {

    @Test
    fun `only playable materials can be transcription sources`() {
        val detail = detail(
            materials = listOf(
                material("ready", playable = true),
                material("incomplete", playable = false),
                material("imported", playable = true),
            ),
        )

        assertEquals(
            listOf("ready", "imported"),
            meetingTranscriptionPlayableMaterials(detail).map { it.id },
        )
    }

    @Test
    fun `an explicit playable choice survives a detail refresh`() {
        val detail = detail(
            materials = listOf(material("a", playable = true), material("b", playable = true)),
        )

        assertEquals("a", meetingTranscriptionDefaultMaterial(detail, "a"))
    }

    @Test
    fun `a transcript material is preferred over the newest file`() {
        val detail = detail(
            materials = listOf(material("older", playable = true), material("newer", playable = true)),
            transcription = MeetingTranscription(
                revision = 2L,
                materialId = "older",
                segments = listOf(segment("hello")),
            ),
        )

        assertEquals("older", meetingTranscriptionDefaultMaterial(detail, null))
    }

    @Test
    fun `missing or unplayable choices fall back to the newest playable file`() {
        val detail = detail(
            materials = listOf(
                material("first", playable = true),
                material("second", playable = true),
                material("gone", playable = false),
            ),
        )

        assertEquals("second", meetingTranscriptionDefaultMaterial(detail, "gone"))
        assertNull(meetingTranscriptionDefaultMaterial(detail.copy(materials = emptyList()), "first"))
    }

    @Test
    fun `start requires a ready selection for the selected material`() {
        val detail = detail(materials = listOf(material("a", playable = true)))
        val ready = readiness("a")

        assertTrue(
            meetingTranscriptionCanStart(
                detail = detail,
                selectedMaterialId = "a",
                readiness = ready,
                state = MeetingTranscriptionState(),
            ),
        )
        assertFalse(
            meetingTranscriptionCanStart(
                detail = detail,
                selectedMaterialId = "b",
                readiness = ready,
                state = MeetingTranscriptionState(),
            ),
        )
        assertFalse(
            meetingTranscriptionCanStart(
                detail = detail,
                selectedMaterialId = "a",
                readiness = MeetingTranscriptionReadiness.Unavailable(
                    MeetingTranscriptionFailure(MeetingTranscriptionFailureCode.NOT_CONFIGURED),
                ),
                state = MeetingTranscriptionState(),
            ),
        )
        assertFalse(
            meetingTranscriptionCanStart(
                detail = detail,
                selectedMaterialId = null,
                readiness = ready,
                state = MeetingTranscriptionState(),
            ),
        )
    }

    @Test
    fun `no start is offered while any process-wide attempt is running`() {
        val detail = detail(materials = listOf(material("a", playable = true)))
        val phases = listOf(
            MeetingTranscriptionPhase.PREPARING,
            MeetingTranscriptionPhase.TRANSCRIBING,
            MeetingTranscriptionPhase.FINALIZING,
            MeetingTranscriptionPhase.CANCELLING,
        )

        phases.forEach { phase ->
            assertTrue("$phase must be running", meetingTranscriptionIsRunning(phase))
            assertFalse(
                "start must be blocked during $phase",
                meetingTranscriptionCanStart(
                    detail = detail,
                    selectedMaterialId = "a",
                    readiness = readiness("a"),
                    state = MeetingTranscriptionState(phase = phase),
                ),
            )
        }
        assertFalse(meetingTranscriptionIsRunning(MeetingTranscriptionPhase.COMPLETED))
        assertFalse(meetingTranscriptionIsRunning(MeetingTranscriptionPhase.CANCELLED))
        assertFalse(meetingTranscriptionIsRunning(MeetingTranscriptionPhase.FAILED))
    }

    @Test
    fun `a transcript bound to another material is never replaced from this page`() {
        val detail = detail(
            materials = listOf(material("original", playable = true), material("other", playable = true)),
            transcription = MeetingTranscription(
                revision = 1L,
                materialId = "original",
                segments = listOf(segment("already committed")),
            ),
        )

        assertFalse(
            meetingTranscriptionCanStart(
                detail = detail,
                selectedMaterialId = "other",
                readiness = readiness("other"),
                state = MeetingTranscriptionState(),
            ),
        )
    }

    @Test
    fun `every typed failure maps to visible copy`() {
        MeetingTranscriptionFailureCode.entries.forEach { code ->
            assertNotEquals(
                "Missing string for $code",
                0,
                meetingTranscriptionFailureTextRes(MeetingTranscriptionFailure(code)),
            )
        }
    }

    @Test
    fun `partial pagination says nothing was saved instead of no speech`() {
        val incomplete = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                "transcriptPageIncomplete",
            ),
        )
        val tooLong = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                "transcriptTooLong",
            ),
        )
        val countMismatch = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                "transcriptCountMismatch",
            ),
        )
        val noSpeech = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                "providerReturnedNoTiming",
            ),
        )

        assertNotEquals(0, tooLong)
        assertNotEquals(incomplete, tooLong)
        assertEquals(incomplete, countMismatch)
        assertNotEquals(incomplete, noSpeech)
    }

    @Test
    fun `unconfirmed provider cancellation is called out`() {
        val unconfirmed = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.CANCELLED,
                "cancelUnconfirmed",
                retryable = true,
            ),
        )
        val plain = meetingTranscriptionFailureTextRes(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.CANCELLED,
                "meetingTranscriptionCancelled",
            ),
        )

        assertNotEquals(unconfirmed, plain)
    }

    private fun detail(
        materials: List<MeetingMaterial>,
        transcription: MeetingTranscription = MeetingTranscription.EMPTY,
    ): MeetingDetail = MeetingDetail(
        id = "meeting-1",
        title = "Meeting",
        createdAtMillis = 1_000L,
        updatedAtMillis = 2_000L,
        notes = "Notes",
        notesRevision = 0L,
        revision = 3L,
        transcription = transcription,
        materials = materials,
        recordings = materials.filter { it.kind == MeetingMaterialKind.RECORDING },
        imports = materials.filter { it.kind != MeetingMaterialKind.RECORDING },
    )

    private fun material(id: String, playable: Boolean): MeetingMaterial = MeetingMaterial(
        id = id,
        meetingId = "meeting-1",
        kind = MeetingMaterialKind.AUDIO_IMPORT,
        displayName = "$id.m4a",
        order = 1L,
        createdAtMillis = 1_000L,
        durationMillis = 60_000L,
        sizeBytes = 256L,
        status = if (playable) MeetingMaterialStatus.COMPLETED else MeetingMaterialStatus.INCOMPLETE,
        isPlayable = playable,
        mimeType = "audio/mp4",
        incompleteReason = if (playable) null else "unfinalized",
    )

    private fun readiness(materialId: String): MeetingTranscriptionReadiness.Ready =
        MeetingTranscriptionReadiness.Ready(
            meetingId = "meeting-1",
            materialId = materialId,
            providerName = "Fixture provider",
            durationMillis = 60_000L,
            transcriptionRevision = 0L,
        )

    private fun segment(text: String): MeetingTranscriptSegment = MeetingTranscriptSegment(
        id = "segment-$text",
        startMillis = 0L,
        endMillis = 1_000L,
        text = text,
        speaker = null,
    )
}
