// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.nio.file.Files

class MeetingRepositoryTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var root: File
    private lateinit var repository: MeetingRepository
    private var now = 1_700_000_000_000L

    private fun setUpRepository() {
        root = File(folder.root, "meetings")
        repository = MeetingRepository(root) { now }
    }

    @Test
    fun `strict ids and path confinement refuse traversal and unknown meetings`() = runBlocking {
        setUpRepository()
        expectFailure(MeetingErrorCode.INVALID_IDENTIFIER) { repository.detail("../escape") }
        expectFailure(MeetingErrorCode.INVALID_IDENTIFIER) { repository.detail("NOT-A-UUID") }
        expectFailure(MeetingErrorCode.NOT_FOUND) { repository.detail("11111111-1111-4111-8111-111111111111") }
        assertFalse(File(root, "../escape").exists())
        assertTrue(root.isDirectory)
    }

    @Test
    fun `created meeting is durable and independent of other meetings`() = runBlocking {
        setUpRepository()
        val first = repository.createMeeting("Design review")
        now += 10
        val second = repository.createMeeting("Retro")
        repository.updateNotes(first.id, "First notes", expectedNotesRevision = 0L)

        val firstRead = repository.detail(first.id)
        val secondRead = repository.detail(second.id)
        assertEquals("First notes", firstRead.notes)
        assertEquals("", secondRead.notes)
        assertEquals(1L, firstRead.notesRevision)
        assertEquals(0L, secondRead.notesRevision)
        assertEquals(2, repository.summaries.value.size)
        assertTrue(File(root, first.id).isDirectory)
        assertTrue(File(root, second.id).isDirectory)
        assertNotNull(repository.summaries.value.firstOrNull { it.id == first.id })
    }

    @Test
    fun `notes CAS conflicts and preserves notes and transcription`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Weekly")
        val meta = File(root, "${meeting.id}/meeting.json")
        val current = Json.parseToJsonElement(meta.readText()).jsonObject
        val withTranscription = JsonObject(
            current + (
                "transcription" to buildJsonObject {
                    put("schemaVersion", 1)
                    put("revision", 7)
                    put("language", "en")
                    put("segments", buildJsonArray {
                        add(buildJsonObject {
                            put("id", "segment-1")
                            put("startMillis", 100L)
                            put("endMillis", 900L)
                            put("text", "A durable sentence")
                        })
                    })
                }
                ),
        )
        meta.writeText(withTranscription.toString())

        val edited = repository.updateNotes(meeting.id, "Line one\nLine two", expectedNotesRevision = 0L)
        assertEquals(1L, edited.notesRevision)
        assertEquals(7L, edited.transcription.revision)
        assertEquals("en", edited.transcription.language)
        assertEquals("A durable sentence", edited.transcription.segments.single().text)
        assertEquals(1, edited.transcription.schemaVersion)

        expectFailure(MeetingErrorCode.CONFLICT) {
            repository.updateNotes(meeting.id, "stale overwrite", expectedNotesRevision = 0L)
        }
        val afterConflict = repository.detail(meeting.id)
        assertEquals("Line one\nLine two", afterConflict.notes)
        assertEquals("A durable sentence", afterConflict.transcription.segments.single().text)

        val renamed = repository.renameMeeting(meeting.id, "Weekly sync")
        assertEquals("Weekly sync", renamed.title)
        assertEquals("Line one\nLine two", renamed.notes)
        assertEquals(1L, renamed.notesRevision)
        assertEquals("A durable sentence", renamed.transcription.segments.single().text)
    }

    @Test
    fun `recording materials keep durable ascending order and notes survive edits`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Ordered")
        val first = repository.createRecordingDraft(meeting.id, "Recording 1")
        now += 5
        val second = repository.createRecordingDraft(meeting.id, "Recording 2")
        now += 5

        val staging = repository.importStagingFile(meeting.id, MeetingIds.newId(), "m4a")
        staging.writeBytes(byteArrayOf(1, 2, 3, 4))
        val imported = repository.commitImport(
            meetingId = meeting.id,
            materialId = MeetingIds.newId(),
            stagedFile = staging,
            displayName = "Interview.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 12_000L,
            hasVideo = false,
        )
        assertTrue(imported.isPlayable)
        assertEquals(MeetingMaterialKind.AUDIO_IMPORT, imported.kind)

        val detail = repository.updateNotes(meeting.id, "minutes", expectedNotesRevision = 0L)
        assertEquals(listOf(first.id, second.id, imported.id), detail.recordings.map { it.id } + detail.imports.map { it.id })
        assertEquals(listOf(1L, 2L, 3L), detail.materials.map { it.order })
        assertEquals(12_000L, detail.imports.single().durationMillis)
        assertEquals(MeetingMaterialStatus.RECORDING, detail.recordings.first().status)
        assertFalse(detail.recordings.first().isPlayable)
        assertEquals("minutes", detail.notes)
    }

    @Test
    fun `failed start removes only empty drafts and retains partial audio`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Failure")
        val empty = repository.createRecordingDraft(meeting.id, "Empty")
        val removed = repository.failRecordingStart(meeting.id, empty.id, "denied")
        assertNull(removed)
        assertTrue(repository.detail(meeting.id).recordings.isEmpty())

        val partial = repository.createRecordingDraft(meeting.id, "Partial")
        val part = repository.recordingFile(meeting.id, partial.id, final = false)
        part.writeBytes(ByteArray(2048) { 1 })
        val retained = repository.failRecordingStart(meeting.id, partial.id, "interrupted")
        assertNotNull(retained)
        assertTrue(part.exists())
        val material = repository.material(meeting.id, partial.id)
        assertEquals(MeetingMaterialStatus.INCOMPLETE, material.status)
        assertFalse(material.isPlayable)
        assertEquals(2048L, material.sizeBytes)
        assertEquals("interrupted", material.incompleteReason)
    }

    @Test
    fun `recovery marks unfinalized parts incomplete and adopts finalized audio`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Recovery")
        val partDraft = repository.createRecordingDraft(meeting.id, "Part")
        repository.recordingFile(meeting.id, partDraft.id, final = false)
            .writeBytes(ByteArray(1024) { 7 })
        val finalDraft = repository.createRecordingDraft(meeting.id, "Final")
        repository.recordingFile(meeting.id, finalDraft.id, final = true)
            .writeBytes(ByteArray(4096) { 9 })
        val missingDraft = repository.createRecordingDraft(meeting.id, "Missing")

        val report = repository.recoverInterrupted(probe = { file ->
            if (file.name == "${finalDraft.id}.m4a") {
                ProbedMedia(true, 9_000L, true, false, "audio/mp4")
            } else {
                ProbedMedia(false, 0L, false, false, null)
            }
        })

        assertEquals(1, report.recoveredCompleted)
        assertEquals(1, report.markedIncomplete)
        assertEquals(1, report.missingFiles)
        val detail = repository.detail(meeting.id)
        val partMaterial = detail.recordings.first { it.id == partDraft.id }
        assertEquals(MeetingMaterialStatus.INCOMPLETE, partMaterial.status)
        assertFalse(partMaterial.isPlayable)
        assertTrue(repository.recordingFile(meeting.id, partDraft.id, final = false).exists())

        val finalMaterial = detail.recordings.first { it.id == finalDraft.id }
        assertEquals(MeetingMaterialStatus.COMPLETED, finalMaterial.status)
        assertTrue(finalMaterial.isPlayable)
        assertEquals(9_000L, finalMaterial.durationMillis)

        val missingMaterial = detail.recordings.first { it.id == missingDraft.id }
        assertEquals(MeetingMaterialStatus.MISSING, missingMaterial.status)
        assertFalse(missingMaterial.isPlayable)
    }

    @Test
    fun `active recording blocks delete and safe delete removes only that meeting`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Keep")
        val other = repository.createMeeting("Other")
        repository.createRecordingDraft(meeting.id, "Active")
        expectFailure(MeetingErrorCode.RECORDING_BUSY) { repository.deleteMeeting(meeting.id) }

        // Finish the draft so deletion can proceed.
        val active = repository.detail(meeting.id).recordings.single()
        repository.updateRecording(meeting.id, active.id) {
            it.copy(state = MeetingRepository.STATE_INCOMPLETE, incompleteReason = "test")
        }
        assertTrue(repository.deleteMeeting(meeting.id))
        assertFalse(File(root, meeting.id).exists())
        assertTrue(File(root, other.id).isDirectory)
        assertEquals(listOf(other.id), repository.summaries.value.map { it.id })
    }

    @Test
    fun `corrupt metadata stays discoverable but cannot be presented as content`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Broken")
        File(root, "${meeting.id}/meeting.json").writeText("{not-json")
        repository.refresh()
        val summary = repository.summaries.value.single()
        assertTrue(summary.metadataCorrupt)
        assertEquals(meeting.id, summary.id)
        expectFailure(MeetingErrorCode.INTERRUPTED) { repository.detail(meeting.id) }
        assertTrue(File(root, "${meeting.id}/meeting.json").exists())
    }

    @Test
    fun `symlinked recordings directory cannot redirect material resolution`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Symlink")
        val meetingDir = File(root, meeting.id)
        val recordings = File(meetingDir, "recordings")
        assertTrue(recordings.mkdirs())
        val outside = folder.newFolder("outside")
        Files.delete(recordings.toPath())
        Files.createSymbolicLink(recordings.toPath(), outside.toPath())

        val failure = assertThrows(MeetingException::class.java) {
            runBlocking {
                repository.recordingFile(meeting.id, MeetingIds.newId(), final = false)
            }
        }
        assertTrue(
            failure.code == MeetingErrorCode.INVALID_IDENTIFIER ||
                failure.code == MeetingErrorCode.STORAGE_FAILURE,
        )
        assertFalse(outside.listFiles().orEmpty().isNotEmpty())
    }

    @Test
    fun `bounded copy rejects oversized streams and leaves the destination partial`() {
        val destination = File(folder.root, "copy.part")
        val failure = assertThrows(MeetingException::class.java) {
            copyBounded(ByteArrayInputStream(ByteArray(100) { 1 }), destination, maxBytes = 10L)
        }
        assertEquals(MeetingErrorCode.TOO_LARGE, failure.code)
        assertTrue(destination.exists())
        assertTrue(destination.length() <= 10L)
    }

    @Test
    fun `title and display name sanitization removes path separators and controls`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("  Design\nreview\u0000  ")
        assertEquals("Design review", meeting.title)
        val staging = repository.importStagingFile(meeting.id, MeetingIds.newId(), "m4a")
        staging.writeBytes(byteArrayOf(1, 2, 3))
        val imported = repository.commitImport(
            meetingId = meeting.id,
            materialId = MeetingIds.newId(),
            stagedFile = staging,
            displayName = "../../evil/name\u0000.m4a",
            extension = "m4a",
            mimeType = "audio/mp4",
            durationMillis = 1L,
            hasVideo = false,
        )
        assertFalse(imported.displayName.contains("/"))
        assertFalse(imported.displayName.contains("\\"))
        assertFalse(imported.displayName.contains("\u0000"))
    }


    @Test
    fun `command binding rejects stale or incomplete owners`() {
        val meeting = "11111111-1111-4111-8111-111111111111"
        val recording = "22222222-2222-4222-8222-222222222222"
        val other = "33333333-3333-4333-8333-333333333333"
        assertTrue(
            MeetingRecordingCommandBinding.matches(meeting, recording, meeting, recording, true),
        )
        assertFalse(
            MeetingRecordingCommandBinding.matches(meeting, other, meeting, recording, true),
        )
        assertFalse(
            MeetingRecordingCommandBinding.matches(other, other, meeting, recording, true),
        )
        assertFalse(
            MeetingRecordingCommandBinding.matches(meeting, recording, meeting, recording, false),
        )
        assertFalse(
            MeetingRecordingCommandBinding.matches(null, recording, meeting, recording, true),
        )
        assertFalse(
            MeetingRecordingCommandBinding.matches(meeting, null, meeting, recording, true),
        )
    }

    @Test
    fun `stale cleanup cannot downgrade completed audio or another recording`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Generations")
        val completed = repository.createRecordingDraft(meeting.id, "Completed")
        val finalFile = repository.recordingFile(meeting.id, completed.id, final = true)
        finalFile.writeBytes(ByteArray(4096) { 3 })
        repository.updateRecording(meeting.id, completed.id) {
            it.copy(
                state = MeetingRepository.STATE_COMPLETED,
                durationMillis = 5_000L,
                sizeBytes = 4096L,
                accumulatedMillis = 5_000L,
            )
        }
        val afterStaleCleanup = repository.failRecordingStart(
            meeting.id,
            completed.id,
            "startTimeout",
        )
        assertEquals(MeetingRepository.STATE_COMPLETED, afterStaleCleanup?.state)
        val completedMaterial = repository.material(meeting.id, completed.id)
        assertEquals(MeetingMaterialStatus.COMPLETED, completedMaterial.status)
        assertTrue(completedMaterial.isPlayable)
        assertTrue(finalFile.exists())

        val older = repository.createRecordingDraft(meeting.id, "Older")
        val newer = repository.createRecordingDraft(meeting.id, "Newer")
        repository.recordingFile(meeting.id, older.id, final = false)
            .writeBytes(ByteArray(1024) { 4 })
        repository.failRecordingStart(meeting.id, newer.id, "startRejected")
        val outsideTake = repository.material(meeting.id, older.id)
        assertEquals(MeetingMaterialStatus.RECORDING, outsideTake.status)
        assertTrue(repository.recordingFile(meeting.id, older.id, final = false).exists())
    }


    @Test
    fun `explicit recovery never disturbs the live recording id`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Live")
        val live = repository.createRecordingDraft(meeting.id, "Live")
        repository.recordingFile(meeting.id, live.id, final = false)
            .writeBytes(ByteArray(512) { 5 })
        val report = repository.recoverInterrupted(
            probe = { ProbedMedia(false, 0L, false, false, null) },
            excludedRecordingIds = setOf(live.id),
        )
        assertEquals(0, report.recoveredCompleted)
        assertEquals(0, report.markedIncomplete)
        assertEquals(0, report.missingFiles)
        assertEquals(MeetingMaterialStatus.RECORDING, repository.material(meeting.id, live.id).status)
        assertTrue(repository.recordingFile(meeting.id, live.id, final = false).exists())
    }


    @Test
    fun `failed import commit removes the new file and preserves existing metadata`() = runBlocking {
        setUpRepository()
        val meeting = repository.createMeeting("Atomic import")
        val meta = File(root, "${meeting.id}/meeting.json")
        val materialId = MeetingIds.newId()
        val staging = repository.importStagingFile(meeting.id, materialId, "m4a")
        staging.writeBytes(byteArrayOf(9, 8, 7, 6))
        val originalMetadata = meta.readBytes()
        meta.writeText("{broken")

        expectFailure(MeetingErrorCode.INTERRUPTED) {
            repository.commitImport(
                meetingId = meeting.id,
                materialId = materialId,
                stagedFile = staging,
                displayName = "Import",
                extension = "m4a",
                mimeType = "audio/mp4",
                durationMillis = 1_000L,
                hasVideo = false,
            )
        }
        assertFalse(File(root, "${meeting.id}/imports/$materialId.m4a").exists())
        assertArrayEquals("{broken".toByteArray(), meta.readBytes())
        assertFalse(originalMetadata.isEmpty())
    }

    private fun expectFailure(code: MeetingErrorCode, block: suspend () -> Unit) {
        val failure = assertThrows(MeetingException::class.java) {
            runBlocking { block() }
        }
        assertEquals(code, failure.code)
    }
}

class MeetingRecordingTimelineTest {
    @Test
    fun `pause and resume accumulate without double counting`() {
        val timeline = MeetingRecordingTimeline(startedAtMillis = 1_000L)
        assertEquals(0L, timeline.elapsed(1_000L))
        assertEquals(1_000L, timeline.elapsed(2_000L))
        assertEquals(2_000L, timeline.pause(3_000L))
        assertEquals(2_000L, timeline.elapsed(9_000L))
        assertEquals(2_000L, timeline.pause(10_000L))
        timeline.resume(11_000L)
        assertEquals(3_000L, timeline.elapsed(12_000L))
        assertEquals(4_000L, timeline.stop(13_000L))
        assertEquals(4_000L, timeline.elapsed(99_000L))
        assertFalse(timeline.isRunning)
    }

    @Test
    fun `resume while running does not reset the start`() {
        val timeline = MeetingRecordingTimeline(1_000L)
        timeline.resume(5_000L)
        assertEquals(5_000L, timeline.elapsed(6_000L))
    }
}
