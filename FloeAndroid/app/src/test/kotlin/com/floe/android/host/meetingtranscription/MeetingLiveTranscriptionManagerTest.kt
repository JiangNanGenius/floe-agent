// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MeetingIds
import com.floe.android.host.meeting.MeetingLiveFragment
import com.floe.android.host.meeting.MeetingLiveTranscriptPhase
import com.floe.android.host.meeting.MeetingRepository
import com.floe.android.host.voice.C03CloudVoiceSelection
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import com.floe.android.host.voice.C03Wav
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MeetingLiveTranscriptionManagerTest {
    @get:Rule
    val folder = TemporaryFolder()

    private suspend fun fixture(): Triple<MeetingRepository, String, String> {
        val root = folder.newFolder("meetings")
        val repository = MeetingRepository(root)
        val meeting = repository.createMeeting("Live")
        val draft = repository.createRecordingDraft(meeting.id, "Take", liveAudio = true)
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(state = MeetingRepository.STATE_RECORDING)
        }
        return Triple(repository, meeting.id, draft.id)
    }

    private fun manager(
        repository: MeetingRepository,
        backend: MeetingTranscriptionBackend,
    ): MeetingLiveTranscriptionManager = MeetingLiveTranscriptionManager(
        repository = repository,
        currentEpoch = { 7L },
        ioDispatcher = Dispatchers.Unconfined,
        backend = backend,
        retryDelay = {},
    )

    @Test
    fun `confirmed fragments are emitted before stop and promoted with absolute offsets`() = runBlocking {
        val (repository, meetingId, recordingId) = fixture()
        val backend = FakeBackend()
        val manager = manager(repository, backend)
        val started = manager.start(
            meetingId = meetingId,
            recordingId = recordingId,
            sessionId = MeetingIds.newId(),
            chunkSeconds = 30,
        ) as MeetingLiveStartOutcome.Started
        val fragment = fragment(started.session.directory, index = 0, startMillis = 1_000L)

        manager.fragmentReady(fragment)
        val confirmed = withTimeout(5_000) {
            manager.state.first { it.confirmedFragments == 1 }
        }
        assertEquals(MeetingLiveTranscriptPhase.RECORDING, confirmed.phase)
        assertEquals(0, confirmed.pendingFragments)
        assertEquals("Fragment 0", confirmed.segments.single().text)
        assertEquals(1_100L, confirmed.segments.single().startMillis)
        // Promotion must not write the canonical transcript before stop.
        assertEquals(0L, repository.detail(meetingId).transcription.revision)

        completeTake(repository, meetingId, recordingId)
        manager.captureStopped(completed = true)
        val completed = withTimeout(5_000) {
            manager.state.first { it.phase == MeetingLiveTranscriptPhase.COMPLETED }
        }
        assertEquals(0, completed.pendingFragments)
        assertEquals(0, completed.failedFragments)
        val detail = repository.detail(meetingId)
        assertEquals(recordingId, detail.transcription.materialId)
        assertEquals(1, detail.transcription.segments.size)
        assertEquals("Fragment 0", detail.transcription.segments.single().text)
        assertEquals(1_100L, detail.transcription.segments.single().startMillis)
    }

    @Test
    fun `stop drains only fragments that were not yet confirmed`() = runBlocking {
        val (repository, meetingId, recordingId) = fixture()
        val backend = FakeBackend()
        val manager = manager(repository, backend)
        val started = manager.start(
            meetingId = meetingId,
            recordingId = recordingId,
            sessionId = MeetingIds.newId(),
            chunkSeconds = 30,
        ) as MeetingLiveStartOutcome.Started
        manager.fragmentReady(fragment(started.session.directory, 0, startMillis = 0L))
        withTimeout(5_000) { manager.state.first { it.confirmedFragments == 1 } }
        val firstUpload = backend.applied.toList()
        assertEquals(listOf(0), firstUpload)

        manager.fragmentReady(fragment(started.session.directory, 1, startMillis = 1_000L))
        completeTake(repository, meetingId, recordingId)
        manager.captureStopped(completed = true)
        withTimeout(5_000) {
            manager.state.first { it.phase == MeetingLiveTranscriptPhase.COMPLETED }
        }

        // Fragment 0 was already confirmed and is never sent again.
        assertEquals(2, backend.applied.size)
        val segments = repository.detail(meetingId).transcription.segments
        assertEquals(2, segments.size)
        assertEquals(listOf(100L, 1_100L), segments.map { it.startMillis })
    }

    @Test
    fun `a failed fragment keeps the take and an explicit retry finishes it`() = runBlocking {
        val (repository, meetingId, recordingId) = fixture()
        val failing = manager(
            repository,
            FakeBackend(failChunk = true),
        )
        val started = failing.start(
            meetingId = meetingId,
            recordingId = recordingId,
            sessionId = MeetingIds.newId(),
            chunkSeconds = 30,
        ) as MeetingLiveStartOutcome.Started
        failing.fragmentReady(fragment(started.session.directory, 0, startMillis = 0L))
        withTimeout(5_000) {
            failing.state.first { it.phase == MeetingLiveTranscriptPhase.FAILED }
        }
        assertEquals(1, failing.state.value.failedFragments)
        val saved = checkNotNull(repository.liveTranscription(meetingId, recordingId))
        assertEquals(MeetingLiveTranscriptPhase.FAILED, saved.phase)
        assertEquals(1, saved.failedFragments)
        assertEquals(0L, repository.detail(meetingId).transcription.revision)

        completeTake(repository, meetingId, recordingId)
        // A fresh owner represents the explicit user retry after the failure.
        val retry = manager(repository, FakeBackend())
        retry.retry(meetingId, recordingId)
        withTimeout(5_000) {
            retry.state.first { it.phase == MeetingLiveTranscriptPhase.COMPLETED }
        }
        val segments = repository.detail(meetingId).transcription.segments
        assertEquals(1, segments.size)
        assertEquals("Fragment 0", segments.single().text)
    }

    private suspend fun completeTake(
        repository: MeetingRepository,
        meetingId: String,
        recordingId: String,
    ) {
        val finalFile = repository.recordingFile(meetingId, recordingId, final = true)
        writeWav(finalFile, frames = 32_000)
        repository.updateRecording(meetingId, recordingId) {
            it.copy(
                state = MeetingRepository.STATE_COMPLETED,
                incompleteReason = null,
                durationMillis = 2_000L,
            )
        }
    }

    private fun fragment(directory: File, index: Int, startMillis: Long): MeetingLiveFragment {
        val fileName = "fragment-%05d.wav".format(index)
        val file = File(directory, fileName)
        writeWav(file, frames = 16_000)
        return MeetingLiveFragment(
            index = index,
            fileName = fileName,
            startMillis = startMillis,
            durationMillis = 1_000L,
            sampleRate = 16_000,
            channels = 1,
            sizeBytes = file.length(),
        )
    }

    private fun writeWav(file: File, frames: Int) {
        val data = ByteArray(frames * 2)
        var offset = 0
        repeat(frames) {
            data[offset] = 0xe8.toByte()
            data[offset + 1] = 0x03.toByte()
            offset += 2
        }
        file.parentFile?.mkdirs()
        file.writeBytes(C03Wav.header(16_000, channels = 1, dataBytes = data.size) + data)
    }

    private class FakeBackend(
        private val failChunk: Boolean = false,
    ) : MeetingTranscriptionBackend {
        val applied = mutableListOf<Int>()
        private val operations = mutableMapOf<String, MutableList<C03TimedSegment>>()
        private var segmentText = 0
        private var stagingIndex = 0

        override suspend fun configuration(epoch: Long): MeetingTranscriptionConfiguration =
            MeetingTranscriptionConfiguration(
                selection = C03CloudVoiceSelection(
                    providerID = "provider-1",
                    modelID = "model-1",
                ),
                language = "en",
                providerName = "Fixture provider",
            )

        override suspend fun plan(
            epoch: Long,
            meetingId: String,
            materialId: String,
            sourceBytes: Long,
            durationSeconds: Double,
            configuration: MeetingTranscriptionConfiguration,
        ): MeetingTranscriptionCloudPlan {
            stagingIndex += 1
            val staging = File(System.getProperty("java.io.tmpdir"), "live-asr-$stagingIndex")
            staging.mkdirs()
            return MeetingTranscriptionCloudPlan(
                operationId = "operation-$stagingIndex",
                stagingPath = staging.absolutePath,
                chunkLimitBytes = 20L * 1024L * 1024L,
                estimatedChunks = 1,
                sourceBytes = sourceBytes,
                durationSeconds = durationSeconds,
            )
        }

        override suspend fun applyChunk(
            meetingId: String,
            materialId: String,
            operationId: String,
            chunkIndex: Int,
            sourceStartSeconds: Double,
            sourceDurationSeconds: Double,
            sampleRate: Int,
            channels: Int,
        ): Int {
            applied += chunkIndex
            if (failChunk) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.PROVIDER_REJECTED,
                    "providerRejectedFixture",
                    retryable = false,
                )
            }
            val items = operations.getOrPut(operationId) { mutableListOf() }
            items += C03TimedSegment(
                start = 0.1,
                end = 0.9,
                text = "Fragment $segmentText",
                speaker = "1",
            )
            segmentText += 1
            return items.size
        }

        override suspend fun finish(
            meetingId: String,
            materialId: String,
            operationId: String,
            totalChunks: Int,
            sourceDurationSeconds: Double,
        ): Int = operations[operationId]?.size ?: 0

        override suspend fun page(
            meetingId: String,
            materialId: String,
            operationId: String,
            offset: Int,
            limit: Int,
        ): MeetingTranscriptionPage {
            val items = operations[operationId].orEmpty()
            return MeetingTranscriptionPage(
                segments = items.drop(offset).take(limit),
                total = items.size,
            )
        }

        override suspend fun cancel(
            meetingId: String,
            materialId: String,
            operationId: String,
        ) = Unit
    }
}
