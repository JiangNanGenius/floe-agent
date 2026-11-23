// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MeetingDetail
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingMaterialKind
import com.floe.android.host.meeting.MeetingMaterialStatus
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscription
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure drain policy for the stop -> transcription -> minutes pipeline.
 *
 * These tests never copy a source file, call the cloud route or read storage.
 * They pin the follow-up decision, restart reconciliation, the final-minutes
 * gate and the deleted-meeting fence.
 */
class MeetingTranscriptionFollowupTest {
    private val meetingId = "meeting-1"

    // ---------------------------------------------------------- stop decision

    @Test
    fun `a playable completed stop with auto-transcribe on produces a request`() {
        val followup = MeetingTranscriptionFollowup()
        val detail = detail(materials = listOf(material("take-1")))
        val request = followup.onStoppedMaterial(detail, material("take-1"), autoTranscribe = true)

        assertEquals(
            MeetingTranscriptionFollowupRequest(
                meetingId = meetingId,
                materialId = "take-1",
                expectedTranscriptionRevision = 0L,
            ),
            request,
        )
    }

    @Test
    fun `auto-transcribe off never produces a request`() {
        val followup = MeetingTranscriptionFollowup()
        val detail = detail(materials = listOf(material("take-1")))
        assertNull(followup.onStoppedMaterial(detail, material("take-1"), autoTranscribe = false))
    }

    @Test
    fun `an incomplete or unplayable take is never transcribed`() {
        val followup = MeetingTranscriptionFollowup()
        val incomplete = material("take-1").copy(
            status = MeetingMaterialStatus.INCOMPLETE,
            isPlayable = false,
        )
        val detail = detail(materials = listOf(incomplete))
        assertNull(followup.onStoppedMaterial(detail, incomplete, autoTranscribe = true))
    }

    @Test
    fun `a take that already has a committed transcript is not re-requested`() {
        val followup = MeetingTranscriptionFollowup()
        val detail = detail(
            materials = listOf(material("take-1")),
            transcription = MeetingTranscription(
                revision = 3L,
                materialId = "take-1",
                segments = listOf(segment("already transcribed")),
            ),
        )
        assertNull(followup.onStoppedMaterial(detail, material("take-1"), autoTranscribe = true))
    }

    @Test
    fun `a transcript bound to an older material does not block a new take`() {
        val followup = MeetingTranscriptionFollowup()
        val detail = detail(
            materials = listOf(material("take-1"), material("take-2")),
            transcription = MeetingTranscription(
                revision = 3L,
                materialId = "take-1",
                segments = listOf(segment("older take")),
            ),
        )
        val request = followup.onStoppedMaterial(detail, material("take-2"), autoTranscribe = true)
        assertEquals("take-2", request?.materialId)
        assertEquals(3L, request?.expectedTranscriptionRevision)
    }

    @Test
    fun `a material from another meeting is never requested`() {
        val followup = MeetingTranscriptionFollowup()
        val foreign = material("take-1").copy(meetingId = "other-meeting")
        val detail = detail(materials = listOf(material("take-1")))
        assertNull(followup.onStoppedMaterial(detail, foreign, autoTranscribe = true))
    }

    // ------------------------------------------------- restart reconciliation

    @Test
    fun `a busy start queues and the next settle returns it exactly once`() {
        val followup = MeetingTranscriptionFollowup()
        val detail = detail(materials = listOf(material("take-1")))
        val request = followup.onStoppedMaterial(detail, material("take-1"), autoTranscribe = true)
        checkNotNull(request)

        // The manager still owns the process slot, so the start was refused as
        // Busy; the page queues it. nextAfterSettle runs only after a terminal
        // receipt, returns the request once, and never loops it silently.
        followup.enqueue(request)
        assertEquals(request, followup.nextAfterSettle())
        assertNull(followup.nextAfterSettle())
    }

    @Test
    fun `a newer stop for the same meeting replaces its queued follow-up`() {
        val followup = MeetingTranscriptionFollowup()
        val first = detail(materials = listOf(material("take-1")))
        val second = detail(materials = listOf(material("take-1"), material("take-2")))
        val r1 = followup.onStoppedMaterial(first, material("take-1"), autoTranscribe = true)
        val r2 = followup.onStoppedMaterial(second, material("take-2"), autoTranscribe = true)
        checkNotNull(r1)
        checkNotNull(r2)

        followup.enqueue(r1)
        followup.enqueue(r2)
        val next = followup.nextAfterSettle()
        assertEquals("take-2", next?.materialId)
        assertNull(followup.nextAfterSettle())
    }

    @Test
    fun `queued follow-ups for different meetings drain in FIFO order`() {
        val followup = MeetingTranscriptionFollowup()
        val a1 = MeetingTranscriptionFollowupRequest("meeting-a", "take-a1", 0L)
        val b1 = MeetingTranscriptionFollowupRequest("meeting-b", "take-b1", 0L)
        followup.enqueue(a1)
        followup.enqueue(b1)

        assertEquals(a1, followup.nextAfterSettle())
        assertEquals(b1, followup.nextAfterSettle())
        assertNull(followup.nextAfterSettle())
    }

    @Test
    fun `a direct start supersedes the still-queued take for the same meeting`() {
        val followup = MeetingTranscriptionFollowup()
        val stale = MeetingTranscriptionFollowupRequest(meetingId, "take-1", 0L)
        followup.enqueue(stale)
        followup.onStarted(meetingId)
        assertNull(followup.nextAfterSettle())
    }

    @Test
    fun `drop meeting removes exactly its queued follow-up`() {
        val followup = MeetingTranscriptionFollowup()
        val mine = MeetingTranscriptionFollowupRequest(meetingId, "take-1", 0L)
        val other = MeetingTranscriptionFollowupRequest("meeting-b", "take-b1", 0L)
        followup.enqueue(mine)
        followup.enqueue(other)

        followup.dropMeeting(meetingId)
        assertEquals(other, followup.nextAfterSettle())
        assertNull(followup.nextAfterSettle())
    }

    // ------------------------------------------------------------ minutes gate

    @Test
    fun `minutes wait only for this meeting's running transcription`() {
        val followup = MeetingTranscriptionFollowup()
        val running = MeetingTranscriptionState(
            phase = MeetingTranscriptionPhase.TRANSCRIBING,
            session = session(meetingId, "take-1"),
        )
        assertTrue(followup.shouldAwaitMinutes(meetingId, running))
        assertFalse(followup.shouldAwaitMinutes("other-meeting", running))
        assertFalse(
            followup.shouldAwaitMinutes(
                meetingId,
                running.copy(phase = MeetingTranscriptionPhase.COMPLETED),
            ),
        )
        assertFalse(
            followup.shouldAwaitMinutes(
                meetingId,
                running.copy(
                    phase = MeetingTranscriptionPhase.FAILED,
                    session = null,
                ),
            ),
        )
    }

    @Test
    fun `every running phase gates minutes and every terminal phase releases it`() {
        val followup = MeetingTranscriptionFollowup()
        listOf(
            MeetingTranscriptionPhase.PREPARING,
            MeetingTranscriptionPhase.TRANSCRIBING,
            MeetingTranscriptionPhase.FINALIZING,
            MeetingTranscriptionPhase.CANCELLING,
        ).forEach { phase ->
            assertTrue(
                "$phase must gate minutes",
                followup.shouldAwaitMinutes(
                    meetingId,
                    MeetingTranscriptionState(phase = phase, session = session(meetingId, "take-1")),
                ),
            )
        }
        listOf(
            MeetingTranscriptionPhase.IDLE,
            MeetingTranscriptionPhase.COMPLETED,
            MeetingTranscriptionPhase.FAILED,
            MeetingTranscriptionPhase.CANCELLED,
        ).forEach { phase ->
            assertFalse(
                "$phase must release minutes",
                followup.shouldAwaitMinutes(
                    meetingId,
                    MeetingTranscriptionState(phase = phase, session = session(meetingId, "take-1")),
                ),
            )
        }
    }

    // -------------------------------------------------------------- fixtures

    private fun detail(
        materials: List<MeetingMaterial>,
        transcription: MeetingTranscription = MeetingTranscription.EMPTY,
    ): MeetingDetail = MeetingDetail(
        id = meetingId,
        title = "Weekly review",
        createdAtMillis = 1_000L,
        updatedAtMillis = 2_000L,
        notes = "Notes",
        notesRevision = 0L,
        revision = 3L,
        transcription = transcription,
        materials = materials,
        recordings = materials,
        imports = emptyList(),
    )

    private fun material(id: String): MeetingMaterial = MeetingMaterial(
        id = id,
        meetingId = meetingId,
        kind = MeetingMaterialKind.RECORDING,
        displayName = "$id.m4a",
        order = 1L,
        createdAtMillis = 1_000L,
        durationMillis = 60_000L,
        sizeBytes = 256L,
        status = MeetingMaterialStatus.COMPLETED,
        isPlayable = true,
        mimeType = "audio/mp4",
        incompleteReason = null,
    )

    private fun segment(text: String): MeetingTranscriptSegment = MeetingTranscriptSegment(
        id = "segment-$text",
        startMillis = 0L,
        endMillis = 1_000L,
        text = text,
        speaker = null,
    )

    private fun session(meetingId: String, materialId: String) = MeetingTranscriptionSession(
        meetingId = meetingId,
        materialId = materialId,
        startedAtMillis = 5_000L,
        completedChunks = 1,
        totalChunks = 4,
        progress = 0.25,
    )
}
