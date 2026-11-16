// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.design.FloeBadgeTone
import com.floe.android.host.meeting.MeetingErrorCode
import com.floe.android.host.meeting.MeetingMaterialStatus
import com.floe.android.host.meeting.MeetingRecordingPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure page policy for the Android meeting workspace.
 *
 * These tests do not start a recording, read media or boot a device. They pin
 * the optimistic notes revision rules (a conflict must never replace the
 * user's draft), the recording leave guard, and the user-visible formatting
 * and error mapping used by the Compose surface.
 */
class MeetingDestinationLogicTest {

    @Test
    fun `initial notes load adopts the server text and revision`() {
        val loaded = MeetingNotesUiState().afterLoad("Server notes", 7L)
        assertEquals("Server notes", loaded.draft)
        assertEquals("Server notes", loaded.base)
        assertEquals(7L, loaded.revision)
        assertFalse(loaded.dirty)
        assertFalse(loaded.conflict)
    }

    @Test
    fun `dirty draft survives a refresh at the same notes revision`() {
        val editing = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")

        val refreshed = editing.afterLoad("Server notes", 3L)

        assertEquals("My unsaved draft", refreshed.draft)
        assertEquals("Server notes", refreshed.base)
        assertEquals(3L, refreshed.revision)
        assertTrue(refreshed.dirty)
        assertFalse(refreshed.conflict)
        assertTrue(refreshed.canSave)
    }

    @Test
    fun `external revision while dirty keeps the draft and marks a conflict`() {
        val editing = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")

        val refreshed = editing.afterLoad("Other editor", 4L)

        assertEquals("My unsaved draft", refreshed.draft)
        assertEquals("Server notes", refreshed.base)
        assertEquals(3L, refreshed.revision)
        assertEquals("My unsaved draft", refreshed.recovery)
        assertEquals("Other editor", refreshed.latestNotes)
        assertEquals(4L, refreshed.latestRevision)
        assertTrue(refreshed.dirty)
        assertTrue(refreshed.conflict)
        assertFalse(refreshed.canSave)
    }

    @Test
    fun `save conflict records recovery without touching the local draft`() {
        val editing = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")

        val conflicted = editing.afterConflict("Other editor", 4L)

        assertEquals("My unsaved draft", conflicted.draft)
        assertEquals("My unsaved draft", conflicted.recovery)
        assertEquals(3L, conflicted.revision)
        assertEquals(4L, conflicted.latestRevision)
        assertTrue(conflicted.conflict)
    }

    @Test
    fun `reload latest replaces the draft and keeps a restore entry`() {
        val conflicted = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")
            .afterConflict("Other editor", 4L)

        val reloaded = conflicted.reloadLatest("Other editor", 4L)

        assertEquals("Other editor", reloaded.draft)
        assertEquals("Other editor", reloaded.base)
        assertEquals(4L, reloaded.revision)
        assertFalse(reloaded.conflict)
        assertFalse(reloaded.dirty)
        assertEquals("My unsaved draft", reloaded.recovery)
        assertTrue(reloaded.canRestore)
    }

    @Test
    fun `restore brings the saved recovery back over the latest revision`() {
        val reloaded = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")
            .afterConflict("Other editor", 4L)
            .reloadLatest("Other editor", 4L)

        val restored = reloaded.restore("Other editor", 4L)

        assertEquals("My unsaved draft", restored.draft)
        assertEquals("Other editor", restored.base)
        assertEquals(4L, restored.revision)
        assertTrue(restored.dirty)
        assertFalse(restored.conflict)
        assertTrue(restored.canSave)
        assertFalse(restored.canRestore)
    }

    @Test
    fun `successful save adopts cleaned server text and clears revision state`() {
        val saved = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("  My note  ")
            .afterSave("My note", 4L)

        assertEquals("My note", saved.draft)
        assertEquals("My note", saved.base)
        assertEquals(4L, saved.revision)
        assertFalse(saved.dirty)
        assertFalse(saved.conflict)
        assertNull(saved.recovery)
        assertNull(saved.latestNotes)
    }

    @Test
    fun `discard returns to the last known server text`() {
        val discarded = MeetingNotesUiState()
            .afterLoad("Server notes", 3L)
            .edited("My unsaved draft")
            .discarded()

        assertEquals("Server notes", discarded.draft)
        assertEquals("Server notes", discarded.base)
        assertFalse(discarded.dirty)
        assertFalse(discarded.conflict)
    }

    @Test
    fun `active recording phases are exactly the process-wide owner phases`() {
        assertTrue(meetingRecordingActive(MeetingRecordingPhase.STARTING))
        assertTrue(meetingRecordingActive(MeetingRecordingPhase.RECORDING))
        assertTrue(meetingRecordingActive(MeetingRecordingPhase.PAUSED))
        assertTrue(meetingRecordingActive(MeetingRecordingPhase.STOPPING))
        assertFalse(meetingRecordingActive(MeetingRecordingPhase.IDLE))
        assertFalse(meetingRecordingActive(MeetingRecordingPhase.COMPLETED))
        assertFalse(meetingRecordingActive(MeetingRecordingPhase.FAILED))
    }

    @Test
    fun `recording start requires the microphone and no active take`() {
        assertTrue(meetingCanStartRecording(MeetingRecordingPhase.IDLE, microphoneGranted = true))
        assertTrue(meetingCanStartRecording(MeetingRecordingPhase.COMPLETED, microphoneGranted = true))
        assertFalse(meetingCanStartRecording(MeetingRecordingPhase.IDLE, microphoneGranted = false))
        assertFalse(meetingCanStartRecording(MeetingRecordingPhase.RECORDING, microphoneGranted = true))
        assertFalse(meetingCanStartRecording(MeetingRecordingPhase.STARTING, microphoneGranted = true))
    }

    @Test
    fun `leave prompt appears only when the page leaves the active owner`() {
        assertTrue(
            meetingLeaveNeedsRecordingPrompt(
                phase = MeetingRecordingPhase.RECORDING,
                activeMeetingId = "meeting-a",
                leavingMeetingId = "meeting-a",
                leavingPage = false,
            ),
        )
        assertFalse(
            meetingLeaveNeedsRecordingPrompt(
                phase = MeetingRecordingPhase.RECORDING,
                activeMeetingId = "meeting-a",
                leavingMeetingId = "meeting-b",
                leavingPage = false,
            ),
        )
        assertTrue(
            meetingLeaveNeedsRecordingPrompt(
                phase = MeetingRecordingPhase.PAUSED,
                activeMeetingId = "meeting-a",
                leavingMeetingId = null,
                leavingPage = true,
            ),
        )
        assertFalse(
            meetingLeaveNeedsRecordingPrompt(
                phase = MeetingRecordingPhase.COMPLETED,
                activeMeetingId = "meeting-a",
                leavingMeetingId = "meeting-a",
                leavingPage = true,
            ),
        )
    }

    @Test
    fun `duration labels stay stable from seconds through hours`() {
        assertEquals("0:00", meetingDurationLabel(0L))
        assertEquals("0:00", meetingDurationLabel(-1_000L))
        assertEquals("0:09", meetingDurationLabel(9_999L))
        assertEquals("1:05", meetingDurationLabel(65_000L))
        assertEquals("1:01:05", meetingDurationLabel(3_665_000L))
    }

    @Test
    fun `every typed meeting error maps to visible copy`() {
        MeetingErrorCode.entries.forEach { code ->
            assertNotEquals("Missing string for $code", 0, meetingErrorResource(code))
        }
        assertNotEquals(
            meetingErrorResource(MeetingErrorCode.CONFLICT),
            meetingErrorResource(MeetingErrorCode.STORAGE_FAILURE),
        )
    }

    @Test
    fun `only a finalized playable material counts as a successful stop`() {
        assertTrue(meetingStopSucceeded(MeetingMaterialStatus.COMPLETED, isPlayable = true))
        assertFalse(meetingStopSucceeded(MeetingMaterialStatus.COMPLETED, isPlayable = false))
        assertFalse(meetingStopSucceeded(MeetingMaterialStatus.INCOMPLETE, isPlayable = false))
        assertFalse(meetingStopSucceeded(MeetingMaterialStatus.MISSING, isPlayable = false))
        assertFalse(meetingStopSucceeded(MeetingMaterialStatus.PAUSED, isPlayable = false))
    }

    @Test
    fun `material status tone never presents an unfinished take as success`() {
        assertEquals(
            FloeBadgeTone.SUCCESS,
            meetingMaterialTone(MeetingMaterialStatus.COMPLETED),
        )
        assertNotEquals(
            FloeBadgeTone.SUCCESS,
            meetingMaterialTone(MeetingMaterialStatus.INCOMPLETE),
        )
        assertEquals(
            FloeBadgeTone.DESTRUCTIVE,
            meetingMaterialTone(MeetingMaterialStatus.MISSING),
        )
    }
}
