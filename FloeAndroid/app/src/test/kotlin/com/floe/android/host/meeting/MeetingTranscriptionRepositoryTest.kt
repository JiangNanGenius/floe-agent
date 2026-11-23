// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest

class MeetingTranscriptionRepositoryTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var root: File
    private lateinit var repository: MeetingRepository
    private var now = 1_700_000_000_000L

    private val readableProbe: MediaProbe = { _ ->
        ProbedMedia(
            readable = true,
            durationMillis = 60_000L,
            hasAudio = true,
            hasVideo = false,
            mimeType = "audio/mp4",
        )
    }

    private fun setUpRepository(hooks: SnapshotTestHooks = SnapshotTestHooks()) {
        root = File(folder.root, "meetings")
        repository = MeetingRepository(root, snapshotTestHooks = hooks, clock = { now })
    }

    private suspend fun importedAudio(
        meetingId: String,
        bytes: Int = 512,
    ): MeetingMaterial {
        val materialId = MeetingIds.newId()
        val staging = repository.importStagingFile(meetingId, materialId, "m4a")
        staging.writeBytes(ByteArray(bytes) { (it and 0x7f).toByte() })
        return repository.commitImport(
            meetingId = meetingId,
            materialId = materialId,
            stagedFile = staging,
            displayName = "Interview.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 60_000L,
            hasVideo = false,
        )
    }

    private fun sha256Of(file: File): String = sha256Of(file.readBytes())

    private fun sha256Of(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }

    private fun segment(
        index: Int,
        startMillis: Long,
        endMillis: Long,
        text: String,
    ): StoredTranscriptSegment = StoredTranscriptSegment(
        id = "mt-segment-$index",
        startMillis = startMillis,
        endMillis = endMillis,
        text = text,
        speaker = null,
    )

    @Test
    fun `source resolves only playable material by canonical ids`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Weekly")
        val audio = importedAudio(meeting.id)

        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        assertEquals(meeting.id, source.material.meetingId)
        assertEquals(audio.id, source.material.id)
        assertEquals(60_000L, source.durationMillis)
        assertEquals(0L, source.transcriptionRevision)
        assertTrue(source.file.isFile)
        assertTrue(source.file.length() > 0L)

        expectFailure(MeetingErrorCode.INVALID_IDENTIFIER) {
            repository.transcriptionSource("../escape", audio.id, readableProbe)
        }
        expectFailure(MeetingErrorCode.INVALID_IDENTIFIER) {
            repository.transcriptionSource(meeting.id, "../escape", readableProbe)
        }
        expectFailure(MeetingErrorCode.NOT_FOUND) {
            repository.transcriptionSource(
                meeting.id,
                "11111111-1111-4111-8111-111111111111",
                readableProbe,
            )
        }
    }

    @Test
    fun `source refuses missing incomplete and silent material`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Media")
        val audio = importedAudio(meeting.id)
        val missingId = MeetingIds.newId()
        val staging = repository.importStagingFile(meeting.id, missingId, "m4a")
        staging.writeBytes(byteArrayOf(1, 2, 3))
        repository.commitImport(
            meetingId = meeting.id,
            materialId = missingId,
            stagedFile = staging,
            displayName = "Gone.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 1_000L,
            hasVideo = false,
        )
        File(root, "${meeting.id}/imports/$missingId.m4a").delete()
        expectFailure(MeetingErrorCode.MISSING_MEDIA) {
            repository.transcriptionSource(meeting.id, missingId, readableProbe)
        }

        val draft = repository.createRecordingDraft(meeting.id, "Broken take")
        File(root, "${meeting.id}/recordings/${draft.id}.m4a")
            .writeBytes(byteArrayOf(1, 2, 3, 4))
        repository.updateRecording(meeting.id, draft.id) {
            it.copy(
                state = MeetingRepository.STATE_INCOMPLETE,
                sizeBytes = 4,
                incompleteReason = "interrupted",
            )
        }
        expectFailure(MeetingErrorCode.CORRUPT_MEDIA) {
            repository.transcriptionSource(meeting.id, draft.id, readableProbe)
        }

        val silent: MediaProbe = { _ ->
            ProbedMedia(true, 60_000L, false, true, "video/mp4")
        }
        expectFailure(MeetingErrorCode.UNSUPPORTED_MEDIA) {
            repository.transcriptionSource(meeting.id, audio.id, silent)
        }
    }

    @Test
    fun `commit binds material and preserves notes audio and prior transcript`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Durable")
        repository.updateNotes(meeting.id, "Keep these minutes", expectedNotesRevision = 0L)
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        val originalBytes = source.file.readBytes()
        val segments = listOf(
            segment(0, 0L, 1_500L, " Opening line "),
            segment(1, 1_500L, 3_000L, "Second line"),
        )

        val receipt = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
        )
        assertEquals(1L, receipt.transcriptionRevision)
        assertEquals(2, receipt.segmentCount)
        assertFalse(receipt.idempotent)

        val detail = repository.detail(meeting.id)
        assertEquals("Keep these minutes", detail.notes)
        assertEquals(1L, detail.notesRevision)
        assertEquals(1L, detail.transcription.revision)
        assertEquals("en", detail.transcription.language)
        assertEquals(audio.id, detail.transcription.materialId)
        assertEquals(listOf("Opening line", "Second line"),
            detail.transcription.segments.map { it.text })
        assertEquals(0L, detail.transcription.segments[0].startMillis)
        assertEquals(3_000L, detail.transcription.segments[1].endMillis)
        assertArrayEquals(originalBytes, source.file.readBytes())

        val retry = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
        )
        assertEquals(1L, retry.transcriptionRevision)
        assertTrue(retry.idempotent)
        assertEquals(1L, repository.detail(meeting.id).transcription.revision)
        assertEquals("Keep these minutes", repository.detail(meeting.id).notes)
    }

    @Test
    fun `stale revision and changed source never overwrite a newer transcript`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Stale")
        repository.updateNotes(meeting.id, "Minutes", expectedNotesRevision = 0L)
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        val first = listOf(segment(0, 0L, 1_000L, "First result"))
        val second = listOf(segment(0, 0L, 1_000L, "Newer result"))
        repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = first,
        )

        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = audio.id,
                expectedSourceBytes = source.file.length(),
                expectedSourceSha256 = sha256Of(source.file),
                expectedTranscriptionRevision = 0L,
                language = "en",
                segments = second,
            )
        }
        val afterConflict = repository.detail(meeting.id)
        assertEquals("First result", afterConflict.transcription.segments.single().text)
        assertEquals("Minutes", afterConflict.notes)

        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = audio.id,
                expectedSourceBytes = source.file.length() + 1L,
                expectedSourceSha256 = sha256Of(source.file),
                expectedTranscriptionRevision = 1L,
                language = "en",
                segments = second,
            )
        }
        assertEquals("First result", repository.detail(meeting.id).transcription.segments.single().text)
        assertTrue(source.file.isFile)
    }

    @Test
    fun `another material and invalid segments are refused without writes`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Binding")
        val first = importedAudio(meeting.id)
        val second = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, first.id, readableProbe)
        val secondSource = repository.transcriptionSource(meeting.id, second.id, readableProbe)
        repository.commitTranscription(
            meetingId = meeting.id,
            materialId = first.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = listOf(segment(0, 0L, 1_000L, "Bound to first")),
        )

        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = second.id,
                expectedSourceBytes = secondSource.file.length(),
                expectedSourceSha256 = sha256Of(secondSource.file),
                expectedTranscriptionRevision = 1L,
                language = "en",
                segments = listOf(segment(0, 0L, 1_000L, "Bound to second")),
            )
        }
        assertEquals(
            first.id,
            repository.detail(meeting.id).transcription.materialId,
        )
        assertEquals(
            "Bound to first",
            repository.detail(meeting.id).transcription.segments.single().text,
        )
        assertEquals("", repository.detail(meeting.id).notes)

        expectFailure(MeetingErrorCode.INVALID_INPUT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = first.id,
                expectedSourceBytes = source.file.length(),
                expectedSourceSha256 = sha256Of(source.file),
                expectedTranscriptionRevision = 1L,
                language = "en",
                segments = listOf(segment(0, 2_000L, 2_000L, "No duration")),
            )
        }
        expectFailure(MeetingErrorCode.INVALID_INPUT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = first.id,
                expectedSourceBytes = source.file.length(),
                expectedSourceSha256 = sha256Of(source.file),
                expectedTranscriptionRevision = 1L,
                language = "en",
                segments = listOf(segment(0, 0L, 1_000L, "  ")),
            )
        }
        assertEquals(
            "Bound to first",
            repository.detail(meeting.id).transcription.segments.single().text,
        )
    }

    @Test
    fun `concurrent identical commits are idempotent and different results conflict once`() =
        runBlocking {
            setUpRepository()
            val meeting = repository.createMeeting("Concurrent")
            val audio = importedAudio(meeting.id)
            val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
            val same = listOf(segment(0, 0L, 1_000L, "Same"))
            val first = async {
                repository.commitTranscription(
                    meetingId = meeting.id,
                    materialId = audio.id,
                    expectedSourceBytes = source.file.length(),
                    expectedSourceSha256 = sha256Of(source.file),
                    expectedTranscriptionRevision = 0L,
                    language = "en",
                    segments = same,
                )
            }
            val second = async {
                repository.commitTranscription(
                    meetingId = meeting.id,
                    materialId = audio.id,
                    expectedSourceBytes = source.file.length(),
                    expectedSourceSha256 = sha256Of(source.file),
                    expectedTranscriptionRevision = 0L,
                    language = "en",
                    segments = same,
                )
            }
            val receipts = listOf(first.await(), second.await())
            assertEquals(1, receipts.count { !it.idempotent })
            assertEquals(1, receipts.count { it.idempotent })
            assertEquals(1L, repository.detail(meeting.id).transcription.revision)

            val differentA = async {
                runCatching {
                    repository.commitTranscription(
                        meetingId = meeting.id,
                        materialId = audio.id,
                        expectedSourceBytes = source.file.length(),
                        expectedSourceSha256 = sha256Of(source.file),
                        expectedTranscriptionRevision = 1L,
                        language = "en",
                        segments = listOf(segment(0, 0L, 1_000L, "Newer A")),
                    )
                }
            }
            val differentB = async {
                runCatching {
                    repository.commitTranscription(
                        meetingId = meeting.id,
                        materialId = audio.id,
                        expectedSourceBytes = source.file.length(),
                        expectedSourceSha256 = sha256Of(source.file),
                        expectedTranscriptionRevision = 1L,
                        language = "en",
                        segments = listOf(segment(0, 0L, 1_000L, "Newer B")),
                    )
                }
            }
            val outcomes = listOf(differentA.await(), differentB.await())
            assertEquals(1, outcomes.count { it.isSuccess })
            assertEquals(1, outcomes.count { it.isFailure })
            val detail = repository.detail(meeting.id)
            assertEquals(2L, detail.transcription.revision)
            assertTrue(
                detail.transcription.segments.single().text in setOf("Newer A", "Newer B"),
            )
        }

    @Test
    fun `missing audio at commit leaves the previous transcript intact`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Removed")
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = listOf(segment(0, 0L, 1_000L, "Kept")),
        )
        val file = File(root, "${meeting.id}/imports/${audio.id}.m4a")
        val deletedBytes = source.file.length()
        val deletedSha256 = sha256Of(source.file)
        file.delete()
        expectFailure(MeetingErrorCode.MISSING_MEDIA) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = audio.id,
                expectedSourceBytes = deletedBytes,
                expectedSourceSha256 = deletedSha256,
                expectedTranscriptionRevision = 1L,
                language = "en",
                segments = listOf(segment(0, 0L, 1_000L, "Lost")),
            )
        }
        val detail = repository.detail(meeting.id)
        assertEquals("Kept", detail.transcription.segments.single().text)
        assertEquals(1L, detail.transcription.revision)
    }

    @Test
    fun `pre-commit admission gate refuses the write and leaves data untouched`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Admission")
        repository.updateNotes(meeting.id, "Keep my notes", expectedNotesRevision = 0L)
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        val original = source.file.readBytes()
        val segments = listOf(segment(0, 0L, 1_000L, "Blocked result"))
        var calls = 0

        val refused = runCatching {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = audio.id,
                expectedSourceBytes = source.file.length(),
                expectedSourceSha256 = sha256Of(source.file),
                expectedTranscriptionRevision = 0L,
                language = "en",
                segments = segments,
                validateBeforeCommit = {
                    calls += 1
                    throw IllegalStateException("rootRetired")
                },
            )
        }.exceptionOrNull()
        assertEquals("rootRetired", refused?.message)
        assertEquals(1, calls)

        val afterRefusal = repository.detail(meeting.id)
        assertEquals("Keep my notes", afterRefusal.notes)
        assertEquals(0L, afterRefusal.transcription.revision)
        assertTrue(afterRefusal.transcription.segments.isEmpty())
        assertArrayEquals(original, source.file.readBytes())

        val receipt = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
        )
        assertEquals(1L, receipt.transcriptionRevision)

        // An exact retry is an idempotent no-write return and must not run
        // the admission callback.
        var retryCalls = 0
        val retry = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
            validateBeforeCommit = { retryCalls += 1 },
        )
        assertTrue(retry.idempotent)
        assertEquals(0, retryCalls)
        assertEquals(1L, repository.detail(meeting.id).transcription.revision)
    }

    @Test
    fun `snapshot copies exact bytes and releases only its own attempt`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Snapshot")
        val audio = importedAudio(meeting.id)
        val originalFile = File(root, "${meeting.id}/imports/${audio.id}.m4a")
        val original = originalFile.readBytes()

        val first = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        assertArrayEquals(original, first.file.readBytes())
        assertEquals(original.size.toLong(), first.sourceBytes)
        assertEquals(sha256Of(original), first.sourceSha256)
        assertEquals(audio.id, first.material.id)
        assertEquals(meeting.id, first.material.meetingId)
        assertEquals(60_000L, first.durationMillis)
        assertEquals(0L, first.transcriptionRevision)
        assertTrue(
            first.file.path.contains(
                File.separator + MEETING_SNAPSHOTS_DIR + File.separator + first.snapshotId,
            ),
        )

        val second = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        assertNotEquals(first.snapshotId, second.snapshotId)
        assertNotEquals(first.file.path, second.file.path)
        assertArrayEquals(original, second.file.readBytes())

        assertTrue(repository.releaseTranscriptionSource(meeting.id, first.snapshotId))
        assertFalse(first.file.exists())
        assertFalse(first.file.parentFile!!.exists())
        assertTrue(second.file.isFile)
        assertArrayEquals(original, originalFile.readBytes())

        assertFalse(repository.releaseTranscriptionSource(meeting.id, first.snapshotId))
        assertTrue(second.file.isFile)

        val other = repository.createMeeting("Other")
        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.releaseTranscriptionSource(other.id, second.snapshotId)
        }
        assertTrue(second.file.isFile)
        assertTrue(repository.releaseTranscriptionSource(meeting.id, second.snapshotId))
        assertFalse(second.file.exists())
        assertArrayEquals(original, originalFile.readBytes())
    }

    @Test
    fun `same-size source replacement is refused by the commit digest`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Digest")
        val audio = importedAudio(meeting.id)
        val originalFile = File(root, "${meeting.id}/imports/${audio.id}.m4a")
        val snapshot = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        val originalMtime = Files.getLastModifiedTime(originalFile.toPath())
        val replacement = originalFile.readBytes()
        replacement[0] = (replacement[0].toInt() xor 0x5a).toByte()
        originalFile.writeBytes(replacement)
        Files.setLastModifiedTime(originalFile.toPath(), originalMtime)
        assertEquals(snapshot.sourceBytes, originalFile.length())

        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.commitTranscription(
                meetingId = meeting.id,
                materialId = audio.id,
                expectedSourceBytes = snapshot.sourceBytes,
                expectedSourceSha256 = snapshot.sourceSha256,
                expectedTranscriptionRevision = 0L,
                language = "en",
                segments = listOf(segment(0, 0L, 1_000L, "Stale snapshot")),
            )
        }
        assertEquals(0L, repository.detail(meeting.id).transcription.revision)
        assertArrayEquals(replacement, originalFile.readBytes())

        val receipt = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = replacement.size.toLong(),
            expectedSourceSha256 = sha256Of(replacement),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = listOf(segment(0, 0L, 1_000L, "Current bytes")),
        )
        assertEquals(1L, receipt.transcriptionRevision)
        assertEquals(
            "Current bytes",
            repository.detail(meeting.id).transcription.segments.single().text,
        )
        assertTrue(repository.releaseTranscriptionSource(meeting.id, snapshot.snapshotId))
    }

    @Test
    fun `commit refuses a malformed digest before any write`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Digest format")
        val audio = importedAudio(meeting.id)
        val snapshot = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        for (invalid in listOf("A".repeat(64), snapshot.sourceSha256.dropLast(1))) {
            expectFailure(MeetingErrorCode.INVALID_INPUT) {
                repository.commitTranscription(
                    meetingId = meeting.id,
                    materialId = audio.id,
                    expectedSourceBytes = snapshot.sourceBytes,
                    expectedSourceSha256 = invalid,
                    expectedTranscriptionRevision = 0L,
                    language = "en",
                    segments = listOf(segment(0, 0L, 1_000L, "Must not commit")),
                )
            }
        }
        assertEquals(0L, repository.detail(meeting.id).transcription.revision)
        assertTrue(repository.releaseTranscriptionSource(meeting.id, snapshot.snapshotId))
    }

    @Test
    fun `no-space failure before copy leaves no attempt directory`() = runBlocking {
        setUpRepository(SnapshotTestHooks(availableBytes = { 0L }))
        val meeting = repository.createMeeting("No space")
        val audio = importedAudio(meeting.id)
        val sourceFile = File(root, "${meeting.id}/imports/${audio.id}.m4a")
        val original = sourceFile.readBytes()

        expectFailure(MeetingErrorCode.STORAGE_FAILURE) {
            repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        }
        val snapshots = File(root, "${meeting.id}/$MEETING_SNAPSHOTS_DIR")
        assertTrue(!snapshots.exists() || snapshots.listFiles().orEmpty().isEmpty())
        assertArrayEquals(original, sourceFile.readBytes())
    }

    @Test
    fun `cancellation and copy failure remove the partial attempt snapshot`() = runBlocking {
        setUpRepository(
            SnapshotTestHooks(onCopyChunk = { throw CancellationException("copyCancelled") }),
        )
        val meeting = repository.createMeeting("Cancelled copy")
        val audio = importedAudio(meeting.id)
        val sourceFile = File(root, "${meeting.id}/imports/${audio.id}.m4a")
        val original = sourceFile.readBytes()

        val cancelled = runCatching {
            repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        }.exceptionOrNull()
        assertTrue(cancelled is CancellationException)
        val snapshots = File(root, "${meeting.id}/$MEETING_SNAPSHOTS_DIR")
        assertTrue(!snapshots.exists() || snapshots.listFiles().orEmpty().isEmpty())
        assertArrayEquals(original, sourceFile.readBytes())

        repository = MeetingRepository(
            root,
            snapshotTestHooks = SnapshotTestHooks(
                onCopyChunk = { throw IOException("simulated copy failure") },
            ),
            clock = { now },
        )
        expectFailure(MeetingErrorCode.STORAGE_FAILURE) {
            repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        }
        assertTrue(!snapshots.exists() || snapshots.listFiles().orEmpty().isEmpty())
        assertArrayEquals(original, sourceFile.readBytes())

        repository = MeetingRepository(root) { now }
        val retry = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        assertTrue(retry.file.isFile)
        assertArrayEquals(original, retry.file.readBytes())
        assertTrue(repository.releaseTranscriptionSource(meeting.id, retry.snapshotId))
    }

    @Test
    fun `stale recovery removes only old unleased snapshots`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Recovery")
        val audio = importedAudio(meeting.id)
        val active = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        val snapshots = File(root, "${meeting.id}/$MEETING_SNAPSHOTS_DIR")

        val staleId = MeetingIds.newId()
        val stale = File(snapshots, staleId)
        assertTrue(stale.mkdirs())
        File(stale, "$MEETING_SNAPSHOT_AUDIO_FILE.part-dead").writeBytes(ByteArray(128) { 3 })

        now += MEETING_SNAPSHOT_STALE_MILLIS + 60_000L
        assertTrue(stale.setLastModified(now - MEETING_SNAPSHOT_STALE_MILLIS - 1_000L))

        val newer = repository.createTranscriptionSnapshot(meeting.id, audio.id, readableProbe)
        assertFalse(stale.exists())
        assertTrue(active.file.isFile)
        assertTrue(newer.file.isFile)
        assertEquals(
            listOf(active.snapshotId, newer.snapshotId).sorted(),
            snapshots.listFiles().orEmpty().map { it.name }.sorted(),
        )
        assertTrue(repository.releaseTranscriptionSource(meeting.id, active.snapshotId))
        assertTrue(repository.releaseTranscriptionSource(meeting.id, newer.snapshotId))
    }

    @Test
    fun `attempt checkpoint round-trips through durable storage`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Checkpoint")
        val audio = importedAudio(meeting.id)
        val checkpoint = MeetingTranscriptionLastAttempt(
            materialId = audio.id,
            expectedTranscriptionRevision = 0L,
            phase = MeetingTranscriptionLastAttemptPhase.RUNNING,
            failureCode = null,
            failureReason = null,
            retryable = false,
            updatedAtMillis = now,
        )
        repository.recordTranscriptionAttempt(meeting.id, checkpoint)
        assertEquals(checkpoint, repository.detail(meeting.id).transcription.lastAttempt)

        // A fresh repository over the same bytes sees the same record, which
        // is what makes a retry offer possible after a process restart.
        val reopened = MeetingRepository(root, clock = { now })
        assertEquals(checkpoint, reopened.detail(meeting.id).transcription.lastAttempt)

        // Terminal update replaces it.
        val failed = checkpoint.copy(
            phase = MeetingTranscriptionLastAttemptPhase.FAILED,
            failureCode = "NETWORK",
            failureReason = "chunkTransportFailed",
            retryable = true,
        )
        repository.recordTranscriptionAttempt(meeting.id, failed)
        assertEquals(failed, reopened.detail(meeting.id).transcription.lastAttempt)

        // Clearing works and is idempotent.
        repository.recordTranscriptionAttempt(meeting.id, null)
        assertEquals(null, repository.detail(meeting.id).transcription.lastAttempt)
        repository.recordTranscriptionAttempt(meeting.id, null)
    }

    @Test
    fun `commit clears the checkpoint and idempotent commit clears a stale one`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Commit clears")
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        val segments = listOf(segment(0, 0L, 1_500L, "Hello"))
        val checkpoint = MeetingTranscriptionLastAttempt(
            materialId = audio.id,
            expectedTranscriptionRevision = 0L,
            phase = MeetingTranscriptionLastAttemptPhase.FAILED,
            failureCode = "NETWORK",
            failureReason = "chunkTransportFailed",
            retryable = true,
            updatedAtMillis = now,
        )
        repository.recordTranscriptionAttempt(meeting.id, checkpoint)
        assertNotEquals(null, repository.detail(meeting.id).transcription.lastAttempt)

        val receipt = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
        )
        assertFalse(receipt.idempotent)
        assertEquals(null, repository.detail(meeting.id).transcription.lastAttempt)

        // A failed retry after the commit leaves a stale marker; the exact
        // idempotent re-commit must clear it instead of leaving a phantom
        // retry prompt over an existing transcript.
        repository.recordTranscriptionAttempt(meeting.id, checkpoint)
        val idempotent = repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = segments,
        )
        assertTrue(idempotent.idempotent)
        assertEquals(null, repository.detail(meeting.id).transcription.lastAttempt)
        assertEquals(1L, repository.detail(meeting.id).transcription.revision)
    }

    @Test
    fun `malformed checkpoint shapes are ignored on read`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Corrupt checkpoint")
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = listOf(segment(0, 0L, 1_500L, "Hello")),
        )

        // Hand-corrupt the checkpoint inside meeting.json: unknown phase,
        // invalid material id and a non-object shape must never fail the
        // whole meeting read nor touch the committed transcript.
        val meta = File(root, "${meeting.id}/$MEETING_META_FILE")
        val corrupted = listOf(
            meta.readText().replace(
                "\"lastAttempt\":null",
                """"lastAttempt":{"materialId":"${audio.id}",""" +
                    """"expectedTranscriptionRevision":0,"phase":"paused"}""",
            ),
            meta.readText().replace(
                "\"lastAttempt\":null",
                """"lastAttempt":{"materialId":"not-a-valid-id",""" +
                    """"expectedTranscriptionRevision":0,"phase":"running"}""",
            ),
            meta.readText().replace(
                "\"lastAttempt\":null",
                """"lastAttempt":"running"""",
            ),
        )
        for ((index, text) in corrupted.withIndex()) {
            meta.writeText(text)
            val reopened = MeetingRepository(root, clock = { now })
            val detail = reopened.detail(meeting.id)
            assertEquals("corrupt checkpoint $index must not break the read", 1L, detail.transcription.revision)
            assertEquals(null, detail.transcription.lastAttempt)
        }
    }

    @Test
    fun `speaker labels survive the durable round trip`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Speakers")
        val audio = importedAudio(meeting.id)
        val source = repository.transcriptionSource(meeting.id, audio.id, readableProbe)
        repository.commitTranscription(
            meetingId = meeting.id,
            materialId = audio.id,
            expectedSourceBytes = source.file.length(),
            expectedSourceSha256 = sha256Of(source.file),
            expectedTranscriptionRevision = 0L,
            language = "en",
            segments = listOf(
                StoredTranscriptSegment("s-0", 0L, 1_000L, "Hi", "Alice"),
                StoredTranscriptSegment("s-1", 1_000L, 2_000L, "Hello", null),
            ),
        )
        val reopened = MeetingRepository(root, clock = { now })
        val segments = reopened.detail(meeting.id).transcription.segments
        assertEquals("Alice", segments[0].speaker)
        assertEquals(null, segments[1].speaker)
    }

    private fun expectFailure(code: MeetingErrorCode, block: suspend () -> Unit) {
        val failure = assertThrows(MeetingException::class.java) {
            runBlocking { block() }
        }
        assertEquals(code, failure.code)
    }
}
