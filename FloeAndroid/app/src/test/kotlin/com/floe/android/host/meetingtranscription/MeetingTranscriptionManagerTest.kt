// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MediaProbe
import com.floe.android.host.meeting.MeetingIds
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingRepository
import com.floe.android.host.meeting.MeetingTranscriptionLastAttempt
import com.floe.android.host.meeting.MeetingTranscriptionLastAttemptPhase
import com.floe.android.host.meeting.ProbedMedia
import com.floe.android.host.voice.C03AudioChunk
import com.floe.android.host.voice.C03CloudVoiceSelection
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MeetingTranscriptionManagerTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val probe: MediaProbe = { _ ->
        ProbedMedia(true, 60_000L, true, false, "audio/mp4")
    }

    private suspend fun fixture(
        notes: String = "",
    ): Triple<MeetingRepository, MeetingMaterial, File> {
        val root = File(folder.root, "meetings")
        val repository = MeetingRepository(root)
        val meeting = repository.createMeeting("Cloud meeting")
        if (notes.isNotEmpty()) {
            repository.updateNotes(meeting.id, notes, expectedNotesRevision = 0L)
        }
        val materialId = MeetingIds.newId()
        val staging = repository.importStagingFile(meeting.id, materialId, "m4a")
        staging.writeBytes(ByteArray(256) { (it and 0x7f).toByte() })
        val material = repository.commitImport(
            meetingId = meeting.id,
            materialId = materialId,
            stagedFile = staging,
            displayName = "Weekly.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 60_000L,
            hasVideo = false,
        )
        return Triple(repository, material, File(root, "${meeting.id}/imports/$materialId.m4a"))
    }

    private fun manager(
        repository: MeetingRepository,
        backend: MeetingTranscriptionBackend,
        extractor: MeetingAudioExtractor = TwoChunkExtractor(),
        epoch: Long = 7L,
    ): MeetingTranscriptionManager = MeetingTranscriptionManager(
        repository = repository,
        currentEpoch = { epoch },
        ioDispatcher = Dispatchers.Unconfined,
        backend = backend,
        extractor = extractor,
        probe = probe,
    )

    @Test
    fun `transcription uses resolved material offsets and commits atomically`() = runBlocking {
        val (repository, material, audioFile) = fixture("Keep my notes")
        val original = audioFile.readBytes()
        val backend = FakeBackend()
        val manager = manager(repository, backend)

        val receipt = manager.transcribe(material.meetingId, material.id)

        assertFalse(receipt.idempotent)
        assertEquals(1L, receipt.transcriptionRevision)
        assertEquals(2, receipt.segmentCount)
        assertEquals(listOf(0, 1), backend.appliedChunks)
        assertEquals(2, backend.finishedTotalChunks)
        val detail = repository.detail(material.meetingId)
        assertEquals("Keep my notes", detail.notes)
        assertEquals(material.id, detail.transcription.materialId)
        assertEquals(
            listOf("First part", "Second part"),
            detail.transcription.segments.map { it.text },
        )
        assertEquals(500L, detail.transcription.segments[0].startMillis)
        assertEquals(1_500L, detail.transcription.segments[0].endMillis)
        assertEquals(30_500L, detail.transcription.segments[1].startMillis)
        assertEquals(31_500L, detail.transcription.segments[1].endMillis)
        assertArrayEquals(original, audioFile.readBytes())
        assertEquals(MeetingTranscriptionPhase.COMPLETED, manager.state.value.phase)
        assertNotNull(manager.state.value.receipt)
        assertEquals(0, backend.cancelCalls)
    }

    @Test
    fun `missing configuration is a typed failure with no transcript write`() = runBlocking {
        val (repository, material, _) = fixture()
        val backend = FakeBackend(
            configurationFailure = C03VoiceFailure(
                C03VoiceErrorCode.UNCONFIGURED,
                "transcriptionNotConfigured",
            ),
        )
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }
        assertEquals(MeetingTranscriptionFailureCode.NOT_CONFIGURED, failure.failure.code)
        assertEquals(0, backend.planCalls)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        assertEquals(
            MeetingTranscriptionPhase.FAILED,
            manager.state.value.phase,
        )
        assertEquals(
            MeetingTranscriptionFailureCode.NOT_CONFIGURED,
            manager.state.value.failure?.code,
        )
    }

    @Test
    fun `provider failure mid chunk leaves audio and prior transcript intact`() = runBlocking {
        val (repository, material, audioFile) = fixture("Minutes")
        val original = audioFile.readBytes()
        val backend = FakeBackend(failChunkIndex = 1)
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }
        assertEquals(
            MeetingTranscriptionFailureCode.PROVIDER_REJECTED,
            failure.failure.code,
        )
        assertTrue(failure.failure.retryable)
        assertTrue(backend.cancelCalls >= 1)
        val detail = repository.detail(material.meetingId)
        assertEquals(0L, detail.transcription.revision)
        assertEquals("Minutes", detail.notes)
        assertArrayEquals(original, audioFile.readBytes())
        assertEquals(MeetingTranscriptionPhase.FAILED, manager.state.value.phase)
    }

    @Test
    fun `stale expected revision is refused before any cloud plan`() = runBlocking {
        val (repository, material, _) = fixture()
        val backend = FakeBackend()
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking {
                manager.transcribe(
                    meetingId = material.meetingId,
                    materialId = material.id,
                    expectedTranscriptionRevision = 3L,
                )
            }
        }
        assertEquals(MeetingTranscriptionFailureCode.STALE_REVISION, failure.failure.code)
        assertEquals(0, backend.planCalls)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `empty provider result is not written`() = runBlocking {
        val (repository, material, _) = fixture()
        val backend = FakeBackend(emptyTranscript = true)
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }
        assertEquals(MeetingTranscriptionFailureCode.EMPTY_TRANSCRIPT, failure.failure.code)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `cancel stops chunking without committing`() = runBlocking {
        val (repository, material, audioFile) = fixture("Cancel notes")
        val original = audioFile.readBytes()
        val backend = FakeBackend()
        val extractor = BlockingExtractor()
        val manager = manager(repository, backend, extractor)

        val job = launch(Dispatchers.Default) {
            runCatching {
                manager.transcribe(material.meetingId, material.id)
            }
        }
        withTimeout(5_000) { extractor.entered.await() }
        manager.cancel()
        withTimeout(5_000) { job.join() }

        assertEquals(MeetingTranscriptionPhase.CANCELLED, manager.state.value.phase)
        assertEquals(0, backend.finishCalls)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        assertEquals("Cancel notes", repository.detail(material.meetingId).notes)
        assertArrayEquals(original, audioFile.readBytes())
        assertTrue(backend.cancelCalls >= 1)
    }

    @Test
    fun `readiness reports configuration and source failures without starting a plan`() =
        runBlocking {
            val (repository, material, audioFile) = fixture()
            val ready = manager(repository, FakeBackend())
            val result = ready.readiness(material.meetingId, material.id)
            assertTrue(result is MeetingTranscriptionReadiness.Ready)
            assertEquals("Fixture provider", (result as MeetingTranscriptionReadiness.Ready).providerName)

            val unconfigured = manager(
                repository,
                FakeBackend(
                    configurationFailure = C03VoiceFailure(
                        C03VoiceErrorCode.UNCONFIGURED,
                        "transcriptionNotConfigured",
                    ),
                ),
            )
            val unavailable = unconfigured.readiness(material.meetingId, material.id)
            assertTrue(unavailable is MeetingTranscriptionReadiness.Unavailable)
            assertEquals(
                MeetingTranscriptionFailureCode.NOT_CONFIGURED,
                (unavailable as MeetingTranscriptionReadiness.Unavailable).failure.code,
            )

            audioFile.delete()
            val missing = ready.readiness(material.meetingId, material.id)
            assertTrue(missing is MeetingTranscriptionReadiness.Unavailable)
            assertEquals(
                MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE,
                (missing as MeetingTranscriptionReadiness.Unavailable).failure.code,
            )
        }

    @Test
    fun `provider speaker labels are committed verbatim and absent stays null`() = runBlocking {
        val (repository, material, _) = fixture()
        val backend = FakeBackend(speaker = "Alice")
        val manager = manager(repository, backend)

        manager.transcribe(material.meetingId, material.id)

        val segments = repository.detail(material.meetingId).transcription.segments
        assertEquals(2, segments.size)
        assertEquals("Alice", segments[0].speaker)
        assertEquals("Alice", segments[1].speaker)

        val noSpeaker = manager(repository, FakeBackend())
        val second = repository.createMeeting("No speaker")
        val secondMaterialId = MeetingIds.newId()
        val staging = repository.importStagingFile(second.id, secondMaterialId, "m4a")
        staging.writeBytes(ByteArray(256) { (it and 0x7f).toByte() })
        val plain = repository.commitImport(
            meetingId = second.id,
            materialId = secondMaterialId,
            stagedFile = staging,
            displayName = "Plain.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 60_000L,
            hasVideo = false,
        )
        noSpeaker.transcribe(plain.meetingId, plain.id)
        assertEquals(
            listOf(null, null),
            repository.detail(plain.meetingId).transcription.segments.map { it.speaker },
        )
    }

    @Test
    fun `failed attempt leaves a durable retry checkpoint with original identifiers`() =
        runBlocking {
            val (repository, material, audioFile) = fixture("Checkpoint")
            val original = audioFile.readBytes()
            val backend = FakeBackend(failChunkIndex = 1)
            val manager = manager(repository, backend)

            val failure = assertThrows(MeetingTranscriptionException::class.java) {
                runBlocking { manager.transcribe(material.meetingId, material.id) }
            }
            assertEquals(MeetingTranscriptionFailureCode.PROVIDER_REJECTED, failure.failure.code)

            val attempt = awaitLastAttempt(repository, material.meetingId) {
                it.phase == MeetingTranscriptionLastAttemptPhase.FAILED
            }
            assertEquals(material.id, attempt.materialId)
            assertEquals(0L, attempt.expectedTranscriptionRevision)
            assertEquals(MeetingTranscriptionFailureCode.PROVIDER_REJECTED.name, attempt.failureCode)
            assertEquals("providerRejectedFixture", attempt.failureReason)
            assertTrue(attempt.retryable)
            // Nothing was committed and the audio is untouched.
            assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
            assertArrayEquals(original, audioFile.readBytes())
        }

    @Test
    fun `cancelled attempt records a cancelled checkpoint`() = runBlocking {
        val (repository, material, _) = fixture()
        val backend = FakeBackend()
        val extractor = BlockingExtractor()
        val manager = manager(repository, backend, extractor)

        val job = launch(Dispatchers.Default) {
            runCatching { manager.transcribe(material.meetingId, material.id) }
        }
        withTimeout(5_000) { extractor.entered.await() }
        manager.cancel()
        withTimeout(5_000) { job.join() }

        val attempt = awaitLastAttempt(repository, material.meetingId) {
            it.phase == MeetingTranscriptionLastAttemptPhase.CANCELLED
        }
        assertEquals(material.id, attempt.materialId)
        assertTrue(attempt.retryable)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `retry from the durable checkpoint completes and clears it`() = runBlocking {
        val (repository, material, _) = fixture()
        val failing = manager(repository, FakeBackend(failChunkIndex = 1))
        assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { failing.transcribe(material.meetingId, material.id) }
        }
        val checkpoint = awaitLastAttempt(repository, material.meetingId) {
            it.phase == MeetingTranscriptionLastAttemptPhase.FAILED
        }

        // Reopening the meeting: a fresh manager (process restart) starts from
        // exactly the recorded meeting/material/checkpoint.
        val reopened = manager(repository, FakeBackend())
        val receipt = reopened.transcribe(
            meetingId = material.meetingId,
            materialId = checkpoint.materialId,
            expectedTranscriptionRevision = checkpoint.expectedTranscriptionRevision,
        )
        assertFalse(receipt.idempotent)
        assertEquals(1L, receipt.transcriptionRevision)
        assertEquals(
            null,
            repository.detail(material.meetingId).transcription.lastAttempt,
        )
    }

    @Test
    fun `successful transcription clears a stale interrupted checkpoint`() = runBlocking {
        val (repository, material, _) = fixture()
        repository.recordTranscriptionAttempt(
            meetingId = material.meetingId,
            attempt = MeetingTranscriptionLastAttempt(
                materialId = material.id,
                expectedTranscriptionRevision = 0L,
                phase = MeetingTranscriptionLastAttemptPhase.RUNNING,
                failureCode = null,
                failureReason = null,
                retryable = true,
                updatedAtMillis = System.currentTimeMillis(),
            ),
        )
        assertNotNull(repository.detail(material.meetingId).transcription.lastAttempt)

        manager(repository, FakeBackend()).transcribe(material.meetingId, material.id)

        assertEquals(
            null,
            repository.detail(material.meetingId).transcription.lastAttempt,
        )
    }

    private suspend fun awaitLastAttempt(
        repository: MeetingRepository,
        meetingId: String,
        predicate: (MeetingTranscriptionLastAttempt) -> Boolean,
    ): MeetingTranscriptionLastAttempt {
        val deadline = System.currentTimeMillis() + 5_000
        while (true) {
            val attempt = repository.detail(meetingId).transcription.lastAttempt
            if (attempt != null && predicate(attempt)) return attempt
            check(System.currentTimeMillis() <= deadline) {
                "timed out waiting for the durable transcription attempt record"
            }
            kotlinx.coroutines.delay(10)
        }
    }

    private class FakeBackend(
        private val configurationFailure: C03VoiceFailure? = null,
        private val failChunkIndex: Int? = null,
        private val emptyTranscript: Boolean = false,
        private val speaker: String? = null,
    ) : MeetingTranscriptionBackend {
        var planCalls = 0
        var finishCalls = 0
        var cancelCalls = 0
        var appliedChunks = mutableListOf<Int>()
        var finishedTotalChunks = 0
        private val segments = mutableListOf<C03TimedSegment>()

        override suspend fun configuration(epoch: Long): MeetingTranscriptionConfiguration {
            configurationFailure?.let { throw it }
            return MeetingTranscriptionConfiguration(
                selection = C03CloudVoiceSelection(
                    providerID = "provider-1",
                    modelID = "model-1",
                ),
                language = "en",
                providerName = "Fixture provider",
            )
        }

        override suspend fun plan(
            epoch: Long,
            meetingId: String,
            materialId: String,
            sourceBytes: Long,
            durationSeconds: Double,
            configuration: MeetingTranscriptionConfiguration,
        ): MeetingTranscriptionCloudPlan {
            planCalls += 1
            return MeetingTranscriptionCloudPlan(
                operationId = "operation-fixture",
                stagingPath = File(System.getProperty("java.io.tmpdir"), "mt-$meetingId-$materialId")
                    .absolutePath,
                chunkLimitBytes = 20L * 1024L * 1024L,
                estimatedChunks = 2,
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
            appliedChunks += chunkIndex
            if (chunkIndex == failChunkIndex) {
                throw C03VoiceFailure(
                    C03VoiceErrorCode.PROVIDER_REJECTED,
                    "providerRejectedFixture",
                    retryable = true,
                )
            }
            val text = if (chunkIndex == 0) "First part" else "Second part"
            segments += C03TimedSegment(
                start = sourceStartSeconds + 0.5,
                end = sourceStartSeconds + 1.5,
                text = text,
                speaker = speaker,
            )
            return segments.size
        }

        override suspend fun finish(
            meetingId: String,
            materialId: String,
            operationId: String,
            totalChunks: Int,
            sourceDurationSeconds: Double,
        ): Int {
            finishCalls += 1
            finishedTotalChunks = totalChunks
            return if (emptyTranscript) 0 else segments.size
        }

        override suspend fun page(
            meetingId: String,
            materialId: String,
            operationId: String,
            offset: Int,
            limit: Int,
        ): MeetingTranscriptionPage {
            val page = segments.drop(offset).take(limit)
            return MeetingTranscriptionPage(
                segments = page,
                total = segments.size,
            )
        }

        override suspend fun cancel(
            meetingId: String,
            materialId: String,
            operationId: String,
        ) {
            cancelCalls += 1
        }
    }

    private class TwoChunkExtractor : MeetingAudioExtractor {
        override suspend fun extract(
            sourcePath: String,
            stagingPath: String,
            chunkLimitBytes: Long,
            onChunk: suspend (C03AudioChunk) -> Unit,
        ) {
            val first = chunkFile(stagingPath, 0)
            onChunk(
                C03AudioChunk(
                    index = 0,
                    file = first,
                    sourceStartSeconds = 0.0,
                    durationSeconds = 30.0,
                    sampleRate = 16_000,
                    channels = 1,
                ),
            )
            val second = chunkFile(stagingPath, 1)
            onChunk(
                C03AudioChunk(
                    index = 1,
                    file = second,
                    sourceStartSeconds = 30.0,
                    durationSeconds = 30.0,
                    sampleRate = 16_000,
                    channels = 1,
                ),
            )
        }

        override fun cancel() = Unit

        private fun chunkFile(stagingPath: String, index: Int): File {
            val directory = File(stagingPath)
            if (!directory.isDirectory) directory.mkdirs()
            return File(directory, "chunk-$index.wav").apply {
                writeBytes(ByteArray(64) { index.toByte() })
            }
        }
    }

    private class BlockingExtractor : MeetingAudioExtractor {
        val entered = CompletableDeferred<Unit>()
        private val gate = CompletableDeferred<Unit>()
        @Volatile
        private var cancelled = false

        override suspend fun extract(
            sourcePath: String,
            stagingPath: String,
            chunkLimitBytes: Long,
            onChunk: suspend (C03AudioChunk) -> Unit,
        ) {
            entered.complete(Unit)
            try {
                gate.await()
            } catch (cancelled: CancellationException) {
                throw cancelled
            }
            if (cancelled) throw CancellationException("cancelled")
        }

        override fun cancel() {
            cancelled = true
            gate.cancel(CancellationException("cancelled"))
        }
    }
}
