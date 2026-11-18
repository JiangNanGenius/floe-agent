// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meetingtranscription

import com.floe.android.host.meeting.MediaProbe
import com.floe.android.host.meeting.MeetingIds
import com.floe.android.host.meeting.MeetingMaterial
import com.floe.android.host.meeting.MeetingRepository
import com.floe.android.host.meeting.ProbedMedia
import com.floe.android.host.voice.C03AudioChunk
import com.floe.android.host.voice.C03CloudVoiceSelection
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.CoroutineContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Ownership, cancellation and durable-commit boundaries for the process-wide
 * meeting transcription attempt.
 *
 * These are JVM tests with a fake cloud backend and a temporary meeting store.
 * They never call a provider, decode real media or touch a device.
 */
class MeetingTranscriptionOwnershipTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val probe: MediaProbe = { _ ->
        ProbedMedia(true, 60_000L, true, false, "audio/mp4")
    }

    private fun repository(): MeetingRepository = MeetingRepository(File(folder.root, "meetings"))

    private suspend fun addMeeting(
        repository: MeetingRepository,
        title: String,
    ): Pair<MeetingMaterial, File> {
        val meeting = repository.createMeeting(title)
        val materialId = MeetingIds.newId()
        val staging = repository.importStagingFile(meeting.id, materialId, "m4a")
        staging.writeBytes(ByteArray(256) { (it and 0x7f).toByte() })
        val material = repository.commitImport(
            meetingId = meeting.id,
            materialId = materialId,
            stagedFile = staging,
            displayName = "$title.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 60_000L,
            hasVideo = false,
        )
        return material to File(repository.rootPath, "${meeting.id}/imports/$materialId.m4a")
    }

    private fun manager(
        repository: MeetingRepository,
        backend: MeetingTranscriptionBackendFake,
        factory: () -> MeetingAudioExtractor = { TwoChunkExtractor() },
        epoch: () -> Long? = { 7L },
        dispatcher: CoroutineDispatcher = Dispatchers.Unconfined,
    ): MeetingTranscriptionManager = MeetingTranscriptionManager(
        repository = repository,
        currentEpoch = epoch,
        ioDispatcher = dispatcher,
        backend = backend,
        extractorFactory = factory,
        probe = probe,
    )

    @Test
    fun `a second start is busy without replacing the running session and the first still cancels`() =
        runBlocking {
            val repository = repository()
            val (first, _) = addMeeting(repository, "First")
            val (second, _) = addMeeting(repository, "Second")
            val backend = MeetingTranscriptionBackendFake()
            val blocking = BlockingExtractor()
            val manager = manager(repository, backend, factory = { blocking })

            val started = manager.start(first.meetingId, first.id)
            assertTrue(started is MeetingTranscriptionStart.Started)
            withTimeout(5_000) { blocking.entered.await() }
            assertEquals(MeetingTranscriptionPhase.TRANSCRIBING, manager.state.value.phase)
            assertEquals(first.meetingId, manager.state.value.session?.meetingId)

            val rejected = manager.start(second.meetingId, second.id)
            assertTrue(rejected is MeetingTranscriptionStart.Busy)
            assertEquals(
                MeetingTranscriptionFailureCode.BUSY,
                (rejected as MeetingTranscriptionStart.Busy).failure.code,
            )
            // The rejected second caller must not poison the first session.
            assertEquals(MeetingTranscriptionPhase.TRANSCRIBING, manager.state.value.phase)
            assertNull(manager.state.value.failure)
            assertEquals(first.meetingId, manager.state.value.session?.meetingId)

            assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())
            awaitPhase(manager, MeetingTranscriptionPhase.CANCELLED)
            assertTrue(backend.cancelCalls >= 1)
            assertEquals(0L, repository.detail(second.meetingId).transcription.revision)
            awaitNoSnapshotDirectories(repository, first.meetingId)
        }

    @Test
    fun `an immediate cancel settles even if the background job never starts`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "ImmediateCancel")
        val backend = MeetingTranscriptionBackendFake()
        val blocking = BlockingExtractor()
        val manager = manager(
            repository = repository,
            backend = backend,
            factory = { blocking },
            dispatcher = Dispatchers.Default,
        )

        assertTrue(manager.start(material.meetingId, material.id) is MeetingTranscriptionStart.Started)
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())

        awaitPhase(manager, MeetingTranscriptionPhase.CANCELLED)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `an immediate cancel settles a queued job that never started`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "QueuedCancel")
        val backend = MeetingTranscriptionBackendFake()
        val dispatcher = ManualDispatcher()
        val manager = manager(
            repository = repository,
            backend = backend,
            dispatcher = dispatcher,
        )

        assertTrue(manager.start(material.meetingId, material.id) is MeetingTranscriptionStart.Started)
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())
        dispatcher.runAll()

        assertEquals(MeetingTranscriptionPhase.CANCELLED, manager.state.value.phase)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `cancelling a caller coroutine does not cancel the process-owned attempt`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Caller")
        val backend = MeetingTranscriptionBackendFake()
        val blocking = BlockingExtractor()
        val manager = manager(repository, backend, factory = { blocking })

        val caller = launch(Dispatchers.Default) {
            runCatching { manager.transcribe(material.meetingId, material.id) }
        }
        withTimeout(5_000) { blocking.entered.await() }
        caller.cancel()
        caller.join()

        assertEquals(MeetingTranscriptionPhase.TRANSCRIBING, manager.state.value.phase)
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())
        awaitPhase(manager, MeetingTranscriptionPhase.CANCELLED)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `the repository pre-write gate rechecks the root epoch under its mutex`() = runBlocking {
        var armClock = false
        var epoch = 7L
        val repository = MeetingRepository(
            root = File(folder.root, "epoch-gated-meetings"),
            clock = {
                if (armClock) epoch = 8L
                System.currentTimeMillis()
            },
        )
        val (material, _) = addMeeting(repository, "EpochGate")
        val backend = MeetingTranscriptionBackendFake()
        backend.pageOverride = { _, _ ->
            // The manager's own check has already passed by pagination time;
            // the repository's clock now retires the root before it reaches
            // its pre-write admission callback.
            armClock = true
            MeetingTranscriptionPage(timedSegments(2), 2)
        }
        val manager = manager(repository, backend, epoch = { epoch })

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals(MeetingTranscriptionFailureCode.CORE_UNAVAILABLE, failure.failure.code)
        assertEquals("rootEpochChanged", failure.failure.reason)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        assertEquals(MeetingTranscriptionPhase.FAILED, manager.state.value.phase)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `cancel during pagination stops before the durable commit`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "PageCancel")
        val backend = MeetingTranscriptionBackendFake()
        backend.pageGate = CompletableDeferred()
        val manager = manager(repository, backend)

        val caller = launch(Dispatchers.Default) {
            runCatching { manager.transcribe(material.meetingId, material.id) }
        }
        withTimeout(5_000) { backend.pageEntered.await() }
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())
        awaitPhase(manager, MeetingTranscriptionPhase.CANCELLED)
        caller.join()
        awaitNoSnapshotDirectories(repository, material.meetingId)

        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
    }

    @Test
    fun `a root epoch change before commit rejects the write`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Epoch")
        var epoch = 7L
        val backend = MeetingTranscriptionBackendFake()
        backend.onFinish = { epoch = 8L }
        val manager = manager(repository, backend, epoch = { epoch })

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals(MeetingTranscriptionFailureCode.CORE_UNAVAILABLE, failure.failure.code)
        assertEquals("rootEpochChanged", failure.failure.reason)
        assertTrue(failure.failure.retryable)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
        assertEquals(MeetingTranscriptionPhase.FAILED, manager.state.value.phase)
    }

    @Test
    fun `cancel after a completed commit is idle and keeps the completed state`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Complete")
        val manager = manager(repository, MeetingTranscriptionBackendFake())

        val receipt = manager.transcribe(material.meetingId, material.id)

        assertEquals(2, receipt.segmentCount)
        assertEquals(MeetingTranscriptionCancelResult.IDLE, manager.cancel())
        assertEquals(MeetingTranscriptionPhase.COMPLETED, manager.state.value.phase)
        assertNotNull(manager.state.value.receipt)
        assertEquals(1L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
        assertNull(manager.cleanupFailure.value)
    }

    @Test
    fun `a failed attempt releases its temporary source snapshot`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "SnapshotFailure")
        val backend = MeetingTranscriptionBackendFake()
        backend.configurationFailure = C03VoiceFailure(
            C03VoiceErrorCode.UNCONFIGURED,
            "transcriptionNotConfigured",
        )
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals(MeetingTranscriptionFailureCode.NOT_CONFIGURED, failure.failure.code)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
        assertNull(manager.cleanupFailure.value)
    }

    @Test
    fun `an unchanged page total is read fully and committed`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Pages")
        val backend = MeetingTranscriptionBackendFake()
        backend.finishedCount = 5
        backend.pageOverride = { call, _ ->
            val all = timedSegments(5)
            when (call) {
                1 -> MeetingTranscriptionPage(all.take(2), 5)
                2 -> MeetingTranscriptionPage(all.drop(2).take(2), 5)
                3 -> MeetingTranscriptionPage(all.drop(4).take(1), 5)
                else -> MeetingTranscriptionPage(emptyList(), 5)
            }
        }
        val manager = manager(repository, backend)

        val receipt = manager.transcribe(material.meetingId, material.id)

        assertEquals(5, receipt.segmentCount)
        assertEquals(3, backend.pageCalls)
        assertEquals(5, repository.detail(material.meetingId).transcription.segments.size)
    }

    @Test
    fun `a changing page total fails without a write`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Changing")
        val backend = MeetingTranscriptionBackendFake()
        backend.finishedCount = 3
        backend.pageOverride = { call, _ ->
            if (call == 1) {
                MeetingTranscriptionPage(timedSegments(3).take(2), 3)
            } else {
                MeetingTranscriptionPage(timedSegments(3).drop(2), 4)
            }
        }
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals(MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT, failure.failure.code)
        assertEquals("transcriptPageInconsistent", failure.failure.reason)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `a finish count that disagrees with the pages fails without a write`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "CountMismatch")
        val backend = MeetingTranscriptionBackendFake()
        backend.finishedCount = 3
        backend.pageOverride = { _, _ -> MeetingTranscriptionPage(timedSegments(2), 2) }
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals("transcriptCountMismatch", failure.failure.reason)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `an empty page before the reported total fails without a write`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "EmptyPage")
        val backend = MeetingTranscriptionBackendFake()
        backend.finishedCount = 3
        backend.pageOverride = { call, _ ->
            if (call == 1) {
                MeetingTranscriptionPage(timedSegments(3).take(2), 3)
            } else {
                MeetingTranscriptionPage(emptyList(), 3)
            }
        }
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals("transcriptPageEmpty", failure.failure.reason)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `a transcript above the segment ceiling is rejected rather than truncated`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "TooMany")
        val backend = MeetingTranscriptionBackendFake()
        backend.finishedCount = 2_001
        backend.pageOverride = { _, _ -> MeetingTranscriptionPage(timedSegments(1), 2_001) }
        val manager = manager(repository, backend)

        val failure = assertThrows(MeetingTranscriptionException::class.java) {
            runBlocking { manager.transcribe(material.meetingId, material.id) }
        }

        assertEquals("transcriptTooLong", failure.failure.reason)
        assertEquals(0L, repository.detail(material.meetingId).transcription.revision)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `retrying after cancel creates a fresh extractor`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Retry")
        val backend = MeetingTranscriptionBackendFake()
        val blocking = BlockingExtractor()
        var extractorCalls = 0
        val manager = manager(repository, backend, factory = {
            extractorCalls += 1
            if (extractorCalls == 1) blocking else TwoChunkExtractor()
        })

        assertTrue(manager.start(material.meetingId, material.id) is MeetingTranscriptionStart.Started)
        withTimeout(5_000) { blocking.entered.await() }
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, manager.cancel())
        awaitPhase(manager, MeetingTranscriptionPhase.CANCELLED)
        awaitNoSnapshotDirectories(repository, material.meetingId)
        assertEquals(1, extractorCalls)

        val receipt = manager.transcribe(material.meetingId, material.id)

        assertEquals(2, receipt.segmentCount)
        assertEquals(2, extractorCalls)
    }

    @Test
    fun `commit admission and cancellation are decided in one fence`() {
        val commitFirst = MeetingTranscriptionAttemptFence()
        assertEquals(
            MeetingTranscriptionCommitAdmission.ADMITTED,
            commitFirst.tryBeginCommit(expectedEpoch = 7L, liveEpoch = 7L),
        )
        assertFalse("a started commit cannot be cancelled", commitFirst.tryCancel())

        val cancelFirst = MeetingTranscriptionAttemptFence()
        assertTrue(cancelFirst.tryCancel())
        assertEquals(
            MeetingTranscriptionCommitAdmission.CANCELLED,
            cancelFirst.tryBeginCommit(expectedEpoch = 7L, liveEpoch = 7L),
        )
    }

    @Test
    fun `a stale root generation cannot be admitted and cannot later commit`() {
        val fence = MeetingTranscriptionAttemptFence()
        assertEquals(
            MeetingTranscriptionCommitAdmission.EPOCH_CHANGED,
            fence.tryBeginCommit(expectedEpoch = 7L, liveEpoch = 8L),
        )
        assertFalse(fence.tryCancel())
        assertEquals(
            MeetingTranscriptionCommitAdmission.CANCELLED,
            fence.tryBeginCommit(expectedEpoch = 7L, liveEpoch = 8L),
        )

        val missing = MeetingTranscriptionAttemptFence()
        assertEquals(
            MeetingTranscriptionCommitAdmission.EPOCH_CHANGED,
            missing.tryBeginCommit(expectedEpoch = 7L, liveEpoch = null),
        )
    }

    @Test
    fun `a recreated page surface observes and can cancel the same running attempt`() = runBlocking {
        val repository = repository()
        val (material, _) = addMeeting(repository, "Reenter")
        val backend = MeetingTranscriptionBackendFake()
        val blocking = BlockingExtractor()
        val owner = MeetingTranscriptionOwner(
            repositoryProvider = { repository },
            epochProvider = { 7L },
            ioDispatcher = Dispatchers.Unconfined,
            backend = backend,
            extractorFactory = { blocking },
            probe = probe,
        )
        val firstSurface = MeetingTranscriptionManager(owner)
        val recreatedSurface = MeetingTranscriptionManager(owner)

        assertTrue(
            firstSurface.start(material.meetingId, material.id) is
                MeetingTranscriptionStart.Started,
        )
        withTimeout(5_000) { blocking.entered.await() }

        assertEquals(
            MeetingTranscriptionPhase.TRANSCRIBING,
            recreatedSurface.state.value.phase,
        )
        assertEquals(material.meetingId, recreatedSurface.state.value.session?.meetingId)
        assertEquals(material.id, recreatedSurface.state.value.session?.materialId)
        assertEquals(MeetingTranscriptionCancelResult.REQUESTED, recreatedSurface.cancel())
        awaitPhase(firstSurface, MeetingTranscriptionPhase.CANCELLED)
        awaitNoSnapshotDirectories(repository, material.meetingId)
    }

    @Test
    fun `a rejected start leaves the observable state untouched`() {
        val manager = manager(repository(), MeetingTranscriptionBackendFake())

        val rejected = manager.start("not a meeting id", "also bad")

        assertTrue(rejected is MeetingTranscriptionStart.Rejected)
        assertEquals(MeetingTranscriptionPhase.IDLE, manager.state.value.phase)
        assertNull(manager.state.value.failure)
    }

    private suspend fun awaitNoSnapshotDirectories(
        repository: MeetingRepository,
        meetingId: String,
    ) {
        val directory = File(repository.rootPath, "$meetingId/.transcription")
        withTimeout(5_000) {
            while (true) {
                val entries = directory.listFiles()?.filter { it.isDirectory }.orEmpty()
                if (entries.isEmpty()) return@withTimeout
                delay(10)
            }
        }
    }

    private suspend fun awaitPhase(
        manager: MeetingTranscriptionManager,
        phase: MeetingTranscriptionPhase,
    ) {
        withTimeout(5_000) {
            while (manager.state.value.phase != phase) delay(10)
        }
    }

    private fun timedSegments(count: Int): List<C03TimedSegment> = List(count) { index ->
        C03TimedSegment(
            start = index * 1.0 + 0.1,
            end = index * 1.0 + 0.8,
            text = "Segment $index",
        )
    }

    private class MeetingTranscriptionBackendFake : MeetingTranscriptionBackend {
        var planCalls = 0
        var finishCalls = 0
        var cancelCalls = 0
        var pageCalls = 0
        val pageEntered = CompletableDeferred<Unit>()
        var pageGate: CompletableDeferred<Unit>? = null
        var finishedCount = -1
        var configurationFailure: C03VoiceFailure? = null
        var onFinish: () -> Unit = {}
        var pageOverride: ((Int, Int) -> MeetingTranscriptionPage)? = null
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
            segments += C03TimedSegment(
                start = sourceStartSeconds + 0.5,
                end = sourceStartSeconds + 1.5,
                text = if (chunkIndex == 0) "First part" else "Second part",
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
            onFinish()
            return if (finishedCount >= 0) finishedCount else segments.size
        }

        override suspend fun page(
            meetingId: String,
            materialId: String,
            operationId: String,
            offset: Int,
            limit: Int,
        ): MeetingTranscriptionPage {
            pageCalls += 1
            pageEntered.complete(Unit)
            pageGate?.await()
            pageOverride?.let { return it(pageCalls, offset) }
            return MeetingTranscriptionPage(
                segments = segments.drop(offset).take(limit),
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

    private class ManualDispatcher : CoroutineDispatcher() {
        private val tasks = mutableListOf<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            synchronized(tasks) { tasks += block }
        }

        fun runAll() {
            while (true) {
                val task = synchronized(tasks) {
                    if (tasks.isEmpty()) null else tasks.removeAt(0)
                } ?: return
                task.run()
            }
        }
    }

    private class TwoChunkExtractor : MeetingAudioExtractor {
        override suspend fun extract(
            sourcePath: String,
            stagingPath: String,
            chunkLimitBytes: Long,
            onChunk: suspend (C03AudioChunk) -> Unit,
        ) {
            onChunk(
                C03AudioChunk(
                    index = 0,
                    file = chunkFile(stagingPath, 0),
                    sourceStartSeconds = 0.0,
                    durationSeconds = 30.0,
                    sampleRate = 16_000,
                    channels = 1,
                ),
            )
            onChunk(
                C03AudioChunk(
                    index = 1,
                    file = chunkFile(stagingPath, 1),
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
