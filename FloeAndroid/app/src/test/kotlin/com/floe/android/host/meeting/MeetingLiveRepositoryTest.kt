// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import com.floe.android.host.voice.C03Wav
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MeetingLiveRepositoryTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var root: File
    private lateinit var repository: MeetingRepository

    @Before
    fun setUp() {
        root = folder.newFolder("meetings")
        repository = MeetingRepository(root)
    }

    @Test
    fun `confirmed fragments stay durable and promote only after the take is finalized`() = runBlocking {
        val meeting = repository.createMeeting("Live")
        val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(state = MeetingRepository.STATE_RECORDING)
        }
        val sessionId = MeetingIds.newId()
        val live = repository.beginLiveTranscription(meeting.id, draft.id, sessionId, 30)
        val fragment = fragment(live.directory, 0, startMillis = 0L, durationMillis = 1_000L)
        repository.appendLiveFragment(meeting.id, draft.id, sessionId, fragment)
        repository.confirmLiveFragment(
            meetingId = meeting.id,
            recordingId = draft.id,
            sessionId = sessionId,
            fragmentIndex = 0,
            segments = listOf(
                StoredTranscriptSegment(
                    id = "ml-${draft.id.take(8)}-00000-0000",
                    startMillis = 100L,
                    endMillis = 900L,
                    text = "Hello meeting",
                    speaker = "1",
                ),
            ),
            language = "en",
        )

        val durable = repository.detail(meeting.id).liveTranscription
        assertNotNull(durable)
        assertEquals(MeetingLiveTranscriptPhase.RECORDING, durable?.phase)
        assertEquals(1, durable?.confirmedFragments)
        assertEquals(0, durable?.pendingFragments)
        assertEquals("Hello meeting", durable?.segments?.single()?.text)
        assertEquals(100L, durable?.segments?.single()?.startMillis)
        // The canonical transcript is not replaced while the take is live.
        assertEquals(0L, repository.detail(meeting.id).transcription.revision)

        val finalFile = repository.recordingFile(meeting.id, draft.id, final = true)
        writeWav(finalFile, frames = 16_000, amplitude = 1_000)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(
                state = MeetingRepository.STATE_COMPLETED,
                incompleteReason = null,
                durationMillis = 1_000L,
            )
        }

        val promotion = repository.promoteLiveTranscription(meeting.id, draft.id, sessionId)
        assertTrue(promotion is MeetingLivePromotion.Promoted)
        val receipt = (promotion as MeetingLivePromotion.Promoted).receipt
        assertEquals(1, receipt.segmentCount)
        val detail = repository.detail(meeting.id)
        assertEquals(draft.id, detail.transcription.materialId)
        assertEquals("Hello meeting", detail.transcription.segments.single().text)
        assertEquals("1", detail.transcription.segments.single().speaker)
        assertNull(detail.liveTranscription)
        assertFalse(live.directory.exists())
    }

    @Test
    fun `late results from another session are refused without changing the queue`() = runBlocking {
        val meeting = repository.createMeeting("Fence")
        val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(state = MeetingRepository.STATE_RECORDING)
        }
        val sessionId = MeetingIds.newId()
        val live = repository.beginLiveTranscription(meeting.id, draft.id, sessionId, 30)
        val fragment = fragment(live.directory, 0, startMillis = 0L, durationMillis = 1_000L)
        repository.appendLiveFragment(meeting.id, draft.id, sessionId, fragment)

        val failure = assertThrows(MeetingException::class.java) {
            runBlocking {
                repository.confirmLiveFragment(
                    meetingId = meeting.id,
                    recordingId = draft.id,
                    sessionId = MeetingIds.newId(),
                    fragmentIndex = 0,
                    segments = listOf(
                        StoredTranscriptSegment(
                            id = "ml-late",
                            startMillis = 0L,
                            endMillis = 500L,
                            text = "Late result",
                            speaker = null,
                        ),
                    ),
                    language = "en",
                )
            }
        }
        assertEquals(MeetingErrorCode.CONFLICT, failure.code)
        val durable = repository.detail(meeting.id).liveTranscription
        assertEquals(0, durable?.confirmedFragments)
        assertEquals(1, durable?.pendingFragments)
        assertEquals(0, durable?.segments?.size)
    }

    @Test
    fun `discard removes the live manifest and retained fragment files`() = runBlocking {
        val meeting = repository.createMeeting("Discard")
        val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(state = MeetingRepository.STATE_RECORDING)
        }
        val sessionId = MeetingIds.newId()
        val live = repository.beginLiveTranscription(meeting.id, draft.id, sessionId, 30)
        val fragment = fragment(live.directory, 0, startMillis = 0L, durationMillis = 1_000L)
        repository.appendLiveFragment(meeting.id, draft.id, sessionId, fragment)

        repository.deleteRecording(meeting.id, draft.id)

        assertFalse(live.directory.exists())
        assertNull(repository.detail(meeting.id).liveTranscription)
    }

    @Test
    fun `an interrupted live wav is adopted as a completed recording and the manifest is interrupted`() =
        runBlocking {
            val meeting = repository.createMeeting("Restart")
            val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
            repository.updateRecording(meeting.id, draft.id) {
                it.copy(state = MeetingRepository.STATE_RECORDING)
            }
            val sessionId = MeetingIds.newId()
            val live = repository.beginLiveTranscription(meeting.id, draft.id, sessionId, 30)
            val fragment = fragment(live.directory, 0, startMillis = 0L, durationMillis = 1_000L)
            repository.appendLiveFragment(meeting.id, draft.id, sessionId, fragment)
            val part = repository.recordingFile(meeting.id, draft.id, final = false)
            // Header still says zero because the process died before the last
            // patch; recovery must repair it instead of discarding the audio.
            writeStaleWav(part, frames = 16_000, amplitude = 1_000)
            val probe: MediaProbe = {
                ProbedMedia(true, 1_000L, true, false, "audio/wav")
            }

            val report = repository.recoverInterrupted(probe = probe)

            assertEquals(1, report.recoveredCompleted)
            val detail = repository.detail(meeting.id)
            assertTrue(detail.recordings.single().isPlayable)
            assertEquals(MeetingLiveTranscriptPhase.INTERRUPTED, detail.liveTranscription?.phase)
            assertEquals(1, detail.liveTranscription?.pendingFragments)
            assertFalse(part.exists())
            assertTrue(live.directory.exists())
        }

    @Test
    fun `a sidecar written before process death is recovered as pending work`() = runBlocking {
        val meeting = repository.createMeeting("Recover")
        val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(state = MeetingRepository.STATE_RECORDING)
        }
        val sessionId = MeetingIds.newId()
        val live = repository.beginLiveTranscription(meeting.id, draft.id, sessionId, 30)
        val fragment = fragment(live.directory, 0, startMillis = 0L, durationMillis = 1_000L)
        writeMeetingLiveFragmentSidecar(
            File(live.directory, fragment.fileName),
            fragment,
        )

        val reconciled = repository.reconcileLiveTranscription(meeting.id, draft.id)
        assertEquals(1, reconciled?.pendingFragments)
        assertEquals(0, reconciled?.confirmedFragments)
        assertEquals(1, repository.detail(meeting.id).liveTranscription?.pendingFragments)
    }

    private fun fragment(
        directory: File,
        index: Int,
        startMillis: Long,
        durationMillis: Long,
    ): MeetingLiveFragment {
        val fileName = "fragment-%05d.wav".format(index)
        val file = File(directory, fileName)
        val frames = (durationMillis * 16_000L / 1_000L).toInt()
        writeWav(file, frames = frames, amplitude = 1_000)
        return MeetingLiveFragment(
            index = index,
            fileName = fileName,
            startMillis = startMillis,
            durationMillis = durationMillis,
            sampleRate = 16_000,
            channels = 1,
            sizeBytes = file.length(),
        )
    }

    private fun writeStaleWav(file: File, frames: Int, amplitude: Int) {
        val data = ByteArray(frames * 2)
        var offset = 0
        repeat(frames) {
            data[offset] = (amplitude and 0xff).toByte()
            data[offset + 1] = ((amplitude ushr 8) and 0xff).toByte()
            offset += 2
        }
        file.parentFile?.mkdirs()
        file.writeBytes(C03Wav.header(16_000, channels = 1, dataBytes = 0) + data)
    }

    private fun writeWav(file: File, frames: Int, amplitude: Int) {
        val data = ByteArray(frames * 2)
        var offset = 0
        repeat(frames) {
            data[offset] = (amplitude and 0xff).toByte()
            data[offset + 1] = ((amplitude ushr 8) and 0xff).toByte()
            offset += 2
        }
        file.parentFile?.mkdirs()
        file.writeBytes(C03Wav.header(16_000, channels = 1, dataBytes = data.size) + data)
    }
}
