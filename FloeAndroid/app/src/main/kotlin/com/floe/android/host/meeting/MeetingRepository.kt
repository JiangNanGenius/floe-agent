// SPDX-License-Identifier: MPL-2.0
//
// File-backed meeting store.
//
// Every meeting owns `filesDir/meetings/<uuid>/meeting.json` plus
// `recordings/` and `imports/`. There is no task id, workspace id or shared
// project database. All metadata writes go to a same-directory temporary file,
// are fsynced and then renamed over `meeting.json`, so a failed write leaves
// the previous notes, transcription and material list intact.
//
// Ids are strict canonical UUIDs and every derived path is canonicalized and
// checked against its meeting directory. Import names are metadata only; the
// on-disk name is always a generated UUID plus a validated short extension.
// Recursive deletion never follows symlinks.
package com.floe.android.host.meeting

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.channels.FileChannel
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID

internal const val MEETING_SCHEMA_VERSION = 1
internal const val MEETING_META_FILE = "meeting.json"
internal const val MEETING_RECORDINGS_DIR = "recordings"
internal const val MEETING_IMPORTS_DIR = "imports"
internal const val MEETING_TRASH_DIR = ".trash"
internal const val MEETING_MAX_NOTES_CHARS = 1_000_000
internal const val MEETING_MAX_TITLE_CHARS = 120
internal const val MEETING_MAX_NAME_CHARS = 120
internal const val MEETING_MAX_IMPORT_BYTES = 2L * 1024L * 1024L * 1024L
internal const val MEETING_RECORDING_EXTENSION = "m4a"
internal const val MEETING_RECORDING_MIME = "audio/mp4"

internal object MeetingIds {
    private val canonical = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    fun newId(): String = UUID.randomUUID().toString()

    fun isValid(raw: String): Boolean {
        if (!canonical.matches(raw)) return false
        val parsed = runCatching { UUID.fromString(raw) }.getOrNull() ?: return false
        return parsed.toString() == raw
    }

    fun require(raw: String): String {
        if (!isValid(raw)) throw invalidIdentifier(raw)
        return raw
    }
}

internal object MeetingText {
    private val whitespace = Regex("\\s+")

    fun title(raw: String, fallback: String): String {
        val cleaned = raw
            .map { if (it.isISOControl()) ' ' else it }
            .joinToString("")
            .trim()
            .replace(whitespace, " ")
            .take(MEETING_MAX_TITLE_CHARS)
        if (cleaned.isNotBlank()) return cleaned
        return fallback
            .map { if (it.isISOControl()) ' ' else it }
            .joinToString("")
            .trim()
            .replace(whitespace, " ")
            .take(MEETING_MAX_TITLE_CHARS)
            .ifBlank { "Untitled meeting" }
    }

    fun displayName(raw: String?, fallback: String): String {
        if (raw == null) return fallback
        val cleaned = raw
            .map { if (it.isISOControl() || it == '/' || it == '\\') ' ' else it }
            .joinToString("")
            .trim()
            .replace(whitespace, " ")
            .take(MEETING_MAX_NAME_CHARS)
        return cleaned.ifBlank { fallback }
    }

    fun notes(raw: String): String {
        if (raw.length > MEETING_MAX_NOTES_CHARS) {
            throw meetingError(
                MeetingErrorCode.TOO_LARGE,
                "Notes are too large to store.",
                detail = "characters=${raw.length}",
            )
        }
        return raw
    }

    fun preview(notes: String): String =
        notes.trim().replace(whitespace, " ").take(140)
}

internal data class ProbedMedia(
    val readable: Boolean,
    val durationMillis: Long,
    val hasAudio: Boolean,
    val hasVideo: Boolean,
    val mimeType: String?,
)

internal typealias MediaProbe = (File) -> ProbedMedia

internal data class StoredTranscription(
    val schemaVersion: Int = MEETING_SCHEMA_VERSION,
    val revision: Long = 0L,
    val language: String? = null,
    val updatedAtMillis: Long? = null,
    val segments: List<StoredTranscriptSegment> = emptyList(),
)

internal data class StoredTranscriptSegment(
    val id: String,
    val startMillis: Long,
    val endMillis: Long,
    val text: String,
    val speaker: String?,
)

internal data class StoredRecording(
    val id: String,
    val order: Long,
    val displayName: String,
    val createdAtMillis: Long,
    val startedAtMillis: Long?,
    val accumulatedMillis: Long,
    val durationMillis: Long,
    val sizeBytes: Long,
    val state: String,
    val mimeType: String,
    val incompleteReason: String?,
)

internal data class StoredImport(
    val id: String,
    val order: Long,
    val displayName: String,
    val createdAtMillis: Long,
    val durationMillis: Long,
    val sizeBytes: Long,
    val mimeType: String,
    val extension: String,
    val kind: MeetingMaterialKind,
)

internal data class StoredMeeting(
    val id: String,
    val title: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val notes: String,
    val notesRevision: Long,
    val revision: Long,
    val transcription: StoredTranscription,
    val recordings: List<StoredRecording>,
    val imports: List<StoredImport>,
)

/**
 * Testable, Android-free durable store. Production code constructs one through
 * [MeetingStoreRegistry]; JVM tests construct it directly with a temp root.
 */
internal class MeetingRepository(
    root: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private val rootDir: File = try {
        root.canonicalFile
    } catch (error: IOException) {
        throw storageFailure(error, "meetingRoot")
    }

    private val _summaries = MutableStateFlow<List<MeetingSummary>>(emptyList())
    val summaries: StateFlow<List<MeetingSummary>> = _summaries.asStateFlow()

    internal val rootPath: String get() = rootDir.path

    init {
        ensureRootLocked()
    }

    suspend fun refresh(): List<MeetingSummary> = mutex.withLock {
        refreshLocked()
        _summaries.value
    }

    suspend fun detail(meetingId: String): MeetingDetail = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        toDetailLocked(readMeetingLocked(dir, id), dir)
    }

    suspend fun createMeeting(title: String, now: Long = clock()): MeetingDetail = mutex.withLock {
        ensureRootLocked()
        val id = MeetingIds.newId()
        val dir = meetingDirLocked(id)
        if (!dir.mkdirs()) {
            if (!dir.isDirectory) throw storageFailure(IOException("mkdirs"), "createMeeting")
        }
        if (Files.isSymbolicLink(dir.toPath())) throw storageFailure(IOException("symlink"), "createMeeting")
        val stored = StoredMeeting(
            id = id,
            title = MeetingText.title(title, "Untitled meeting"),
            createdAtMillis = now,
            updatedAtMillis = now,
            notes = "",
            notesRevision = 0L,
            revision = 1L,
            transcription = StoredTranscription(),
            recordings = emptyList(),
            imports = emptyList(),
        )
        try {
            writeMeetingLocked(dir, stored)
        } catch (error: Exception) {
            runCatching { deleteTreeNoFollow(dir.toPath(), rootDir.toPath()) }
            throw error
        }
        refreshLocked()
        toDetailLocked(stored, dir)
    }

    suspend fun renameMeeting(meetingId: String, title: String, now: Long = clock()): MeetingDetail =
        mutex.withLock {
            val id = MeetingIds.require(meetingId)
            val dir = existingMeetingDirLocked(id)
            val stored = readMeetingLocked(dir, id)
            val updated = stored.copy(
                title = MeetingText.title(title, stored.title),
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1,
            )
            writeMeetingLocked(dir, updated)
            refreshLocked()
            toDetailLocked(updated, dir)
        }

    suspend fun updateNotes(
        meetingId: String,
        notes: String,
        expectedNotesRevision: Long?,
        now: Long = clock(),
    ): MeetingDetail = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        if (expectedNotesRevision != null && expectedNotesRevision != stored.notesRevision) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "Notes changed in another edit.",
                retryable = true,
                detail = "expected=$expectedNotesRevision actual=${stored.notesRevision}",
            )
        }
        val cleaned = MeetingText.notes(notes)
        val updated = stored.copy(
            notes = cleaned,
            notesRevision = stored.notesRevision + 1,
            updatedAtMillis = maxOf(now, stored.updatedAtMillis),
            revision = stored.revision + 1,
        )
        writeMeetingLocked(dir, updated)
        refreshLocked()
        toDetailLocked(updated, dir)
    }

    /**
     * Deletes only after the whole directory is atomically moved out of the
     * live namespace. Recursive removal does not follow symlinks. A live or
     * stale active recording blocks deletion rather than discarding audio.
     */
    suspend fun deleteMeeting(meetingId: String, now: Long = clock()): Boolean = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        if (stored.recordings.any { it.state in ACTIVE_RECORDING_STATES }) {
            throw meetingError(
                MeetingErrorCode.RECORDING_BUSY,
                "A recording is still active for this meeting.",
                retryable = true,
                detail = id,
            )
        }
        val trash = File(rootDir, MEETING_TRASH_DIR)
        if (!trash.isDirectory && !trash.mkdirs()) {
            throw storageFailure(IOException("mkdirs"), "trash")
        }
        if (Files.isSymbolicLink(trash.toPath())) {
            throw storageFailure(IOException("symlink"), "trash")
        }
        val destination = File(trash, "$id-$now")
        try {
            moveAtomically(dir, destination)
        } catch (error: Exception) {
            throw storageFailure(error, "deleteMeeting")
        }
        runCatching { deleteTreeNoFollow(destination.toPath(), rootDir.toPath()) }
        refreshLocked()
        true
    }

    suspend fun recordingFile(meetingId: String, recordingId: String, final: Boolean): File =
        mutex.withLock {
            val id = MeetingIds.require(meetingId)
            val materialId = MeetingIds.require(recordingId)
            val dir = existingMeetingDirLocked(id)
            recordingFileLocked(dir, materialId, final)
        }

    suspend fun importDirectory(meetingId: String): File = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        importDirLocked(existingMeetingDirLocked(id))
    }

    suspend fun createRecordingDraft(
        meetingId: String,
        displayName: String,
        now: Long = clock(),
    ): StoredRecording = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recordingId = MeetingIds.newId()
        val draft = StoredRecording(
            id = recordingId,
            order = nextOrder(stored),
            displayName = MeetingText.displayName(displayName, "Recording"),
            createdAtMillis = now,
            startedAtMillis = null,
            accumulatedMillis = 0L,
            durationMillis = 0L,
            sizeBytes = 0L,
            state = RECORDING_STARTING,
            mimeType = MEETING_RECORDING_MIME,
            incompleteReason = null,
        )
        val updated = stored.copy(
            recordings = stored.recordings + draft,
            updatedAtMillis = maxOf(now, stored.updatedAtMillis),
            revision = stored.revision + 1,
        )
        writeMeetingLocked(dir, updated)
        refreshLocked()
        draft
    }

    suspend fun updateRecording(
        meetingId: String,
        recordingId: String,
        now: Long = clock(),
        mutate: (StoredRecording) -> StoredRecording,
    ): StoredRecording = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val index = stored.recordings.indexOfFirst { it.id == materialId }
        if (index < 0) throw notFound(materialId)
        val mutated = mutate(stored.recordings[index])
        if (mutated.id != materialId) throw invalidIdentifier(mutated.id)
        val recordings = stored.recordings.toMutableList()
        recordings[index] = mutated
        val updated = stored.copy(
            recordings = recordings,
            updatedAtMillis = maxOf(now, stored.updatedAtMillis),
            revision = stored.revision + 1,
        )
        writeMeetingLocked(dir, updated)
        refreshLocked()
        mutated
    }

    /**
     * Failure receiver for a start that never produced audio. Zero-byte or
     * absent files are removed from metadata and disk; any retained bytes are
     * marked INCOMPLETE and kept. Returns null only when nothing was retained.
     */
    suspend fun failRecordingStart(
        meetingId: String,
        recordingId: String,
        reason: String,
        now: Long = clock(),
    ): StoredRecording? = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val index = stored.recordings.indexOfFirst { it.id == materialId }
        if (index < 0) return@withLock null
        // A delayed cleanup from an old start must never downgrade a take
        // that already finalized successfully.
        if (stored.recordings[index].state == RECORDING_COMPLETED) {
            return@withLock stored.recordings[index]
        }
        val part = recordingFileLocked(dir, materialId, final = false)
        val final = recordingFileLocked(dir, materialId, final = true)
        val existing = when {
            final.isFile && final.length() > 0 -> final
            part.isFile && part.length() > 0 -> part
            else -> null
        }
        if (existing == null) {
            val updated = stored.copy(
                recordings = stored.recordings.filterNot { it.id == materialId },
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1,
            )
            writeMeetingLocked(dir, updated)
            runCatching { part.delete() }
            runCatching { final.delete() }
            refreshLocked()
            return@withLock null
        }
        val failed = stored.recordings[index].copy(
            state = RECORDING_INCOMPLETE,
            sizeBytes = existing.length(),
            incompleteReason = reason.take(160),
        )
        val recordings = stored.recordings.toMutableList()
        recordings[index] = failed
        val updated = stored.copy(
            recordings = recordings,
            updatedAtMillis = maxOf(now, stored.updatedAtMillis),
            revision = stored.revision + 1,
        )
        writeMeetingLocked(dir, updated)
        refreshLocked()
        failed
    }

    /** Explicit discard of one take/material. The caller must have consented. */
    suspend fun deleteRecording(meetingId: String, recordingId: String, now: Long = clock()): Boolean =
        mutex.withLock {
            val id = MeetingIds.require(meetingId)
            val materialId = MeetingIds.require(recordingId)
            val dir = existingMeetingDirLocked(id)
            val stored = readMeetingLocked(dir, id)
            if (stored.recordings.none { it.id == materialId }) throw notFound(materialId)
            val updated = stored.copy(
                recordings = stored.recordings.filterNot { it.id == materialId },
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1,
            )
            writeMeetingLocked(dir, updated)
            runCatching { recordingFileLocked(dir, materialId, final = false).delete() }
            runCatching { recordingFileLocked(dir, materialId, final = true).delete() }
            refreshLocked()
            true
        }

    /** Existing recording material, including an INCOMPLETE one. */
    suspend fun material(meetingId: String, materialId: String): MeetingMaterial = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
        if (recording != null) return@withLock recordingMaterialLocked(dir, id, recording)
        val imported = stored.imports.firstOrNull { it.id == materialId }
        if (imported != null) return@withLock importMaterialLocked(dir, id, imported)
        throw notFound(materialId)
    }

    suspend fun resolvedMaterial(meetingId: String, materialId: String): ResolvedMaterial = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialIdChecked = MeetingIds.require(materialId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialIdChecked }
        if (recording != null) {
            val material = recordingMaterialLocked(dir, id, recording)
            if (!material.isPlayable) {
                throw meetingError(
                    if (material.status == MeetingMaterialStatus.MISSING) {
                        MeetingErrorCode.MISSING_MEDIA
                    } else {
                        MeetingErrorCode.CORRUPT_MEDIA
                    },
                    if (material.status == MeetingMaterialStatus.MISSING) {
                        "The recording file is no longer available."
                    } else {
                        "This recording has no finalized audio."
                    },
                    detail = recording.incompleteReason,
                )
            }
            val file = recordingFileLocked(dir, materialIdChecked, final = true)
            return@withLock ResolvedMaterial(material, file)
        }
        val imported = stored.imports.firstOrNull { it.id == materialIdChecked }
            ?: throw notFound(materialIdChecked)
        val material = importMaterialLocked(dir, id, imported)
        if (!material.isPlayable) {
            throw meetingError(
                MeetingErrorCode.MISSING_MEDIA,
                "The imported file is no longer available.",
                detail = materialIdChecked,
            )
        }
        val file = importFileLocked(dir, imported)
        return@withLock ResolvedMaterial(material, file)
    }

    suspend fun importStagingFile(
        meetingId: String,
        materialId: String,
        extension: String,
    ): File = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val material = MeetingIds.require(materialId)
        val ext = requireExtension(extension)
        val dir = existingMeetingDirLocked(id)
        val imports = importDirLocked(dir)
        // Every component is generated (validated UUID + random nonce +
        // validated extension) and is created inside the canonical imports
        // directory; no caller text participates in the path.
        File(imports, "$material.staging.${UUID.randomUUID().toString().replace("-", "")}.$ext")
    }

    /**
     * Atomically promotes a fully streamed staging file and appends its
     * metadata. Existing notes/transcription/materials are untouched. If the
     * metadata write fails the newly imported file is removed and the original
     * meeting.json remains authoritative.
     */
    suspend fun commitImport(
        meetingId: String,
        materialId: String,
        stagedFile: File,
        displayName: String,
        extension: String,
        mimeType: String?,
        durationMillis: Long,
        hasVideo: Boolean,
        now: Long = clock(),
    ): MeetingMaterial = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val material = MeetingIds.require(materialId)
        val ext = requireExtension(extension)
        val dir = existingMeetingDirLocked(id)
        val imports = importDirLocked(dir)
        val staged = stagedFile.canonicalFile
        if (staged.parentFile?.path != imports.canonicalPath) {
            throw meetingError(MeetingErrorCode.INVALID_INPUT, "Import staging path is invalid.")
        }
        if (!staged.isFile) throw meetingError(MeetingErrorCode.SOURCE_UNAVAILABLE, "The selected media is unavailable.")
        val size = staged.length()
        if (size <= 0L) throw meetingError(MeetingErrorCode.UNSUPPORTED_MEDIA, "The selected media is empty.")
        if (size > MEETING_MAX_IMPORT_BYTES) {
            throw meetingError(MeetingErrorCode.TOO_LARGE, "The selected media is too large.")
        }
        val destination = File(imports, "$material.$ext")
        if (destination.exists()) {
            throw meetingError(MeetingErrorCode.STORAGE_FAILURE, "Import destination already exists.", retryable = true)
        }
        try {
            moveAtomically(staged, destination)
        } catch (error: Exception) {
            throw storageFailure(error, "importMove")
        }
        val import = try {
            val stored = readMeetingLocked(dir, id)
            val added = StoredImport(
                id = material,
                order = nextOrder(stored),
                displayName = MeetingText.displayName(displayName, "Imported media"),
                createdAtMillis = now,
                durationMillis = durationMillis.coerceAtLeast(0L),
                sizeBytes = size,
                mimeType = (mimeType ?: "application/octet-stream").take(160),
                extension = ext,
                kind = if (hasVideo) MeetingMaterialKind.VIDEO_IMPORT else MeetingMaterialKind.AUDIO_IMPORT,
            )
            writeMeetingLocked(
                dir,
                stored.copy(
                    imports = stored.imports + added,
                    updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                    revision = stored.revision + 1,
                ),
            )
            added
        } catch (error: Exception) {
            // The destination is new and unreferenced on every failure path;
            // the previous meeting.json and all existing materials stay intact.
            runCatching { destination.delete() }
            throw error
        }
        refreshLocked()
        importMaterialLocked(dir, id, import)
    }

    /**
     * Marks stale active recordings after a crash/process death. A finalized
     * `.m4a` is accepted only when the platform probe can read it; a `.part`
     * file is retained but never claimed playable.
     */
    suspend fun recoverInterrupted(
        probe: MediaProbe,
        excludedRecordingIds: Set<String> = emptySet(),
        now: Long = clock(),
    ): MeetingRecoveryReport = mutex.withLock {
        ensureRootLocked()
        var recovered = 0
        var incomplete = 0
        var missing = 0
        for (dir in meetingDirectoriesLocked()) {
            val id = dir.name
            val stored = try {
                readMeetingLocked(dir, id)
            } catch (_: Exception) {
                continue
            }
            var changed = false
            var meetingRecovered = 0
            var meetingIncomplete = 0
            var meetingMissing = 0
            val recordings = stored.recordings.map { recording ->
                if (recording.id in excludedRecordingIds || recording.state !in ACTIVE_RECORDING_STATES) {
                    return@map recording
                }
                val final = recordingFileLocked(dir, recording.id, final = true)
                val part = recordingFileLocked(dir, recording.id, final = false)
                changed = true
                when {
                    final.isFile && final.length() > 0 -> {
                        val probed = runCatching { probe(final) }.getOrNull()
                        if (probed != null && probed.readable && (probed.hasAudio || probed.hasVideo)) {
                            meetingRecovered++
                            recording.copy(
                                state = RECORDING_COMPLETED,
                                durationMillis = if (probed.durationMillis > 0) {
                                    probed.durationMillis
                                } else {
                                    recording.accumulatedMillis
                                },
                                sizeBytes = final.length(),
                                incompleteReason = null,
                            )
                        } else {
                            meetingIncomplete++
                            recording.copy(
                                state = RECORDING_INCOMPLETE,
                                sizeBytes = final.length(),
                                durationMillis = maxOf(recording.durationMillis, recording.accumulatedMillis),
                                incompleteReason = "interruptedUnreadable",
                            )
                        }
                    }
                    part.isFile -> {
                        meetingIncomplete++
                        recording.copy(
                            state = RECORDING_INCOMPLETE,
                            sizeBytes = part.length(),
                            durationMillis = maxOf(recording.durationMillis, recording.accumulatedMillis),
                            incompleteReason = "interrupted",
                        )
                    }
                    else -> {
                        meetingMissing++
                        recording.copy(
                            state = RECORDING_INCOMPLETE,
                            sizeBytes = 0L,
                            durationMillis = maxOf(recording.durationMillis, recording.accumulatedMillis),
                            incompleteReason = "missingFile",
                        )
                    }
                }
            }
            if (!changed) continue
            try {
                writeMeetingLocked(
                    dir,
                    stored.copy(
                        recordings = recordings,
                        updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                        revision = stored.revision + 1,
                    ),
                )
            } catch (_: Exception) {
                // The retained files are unchanged; a later recovery can
                // retry the metadata write. Do not report it as recovered.
                continue
            }
            recovered += meetingRecovered
            incomplete += meetingIncomplete
            missing += meetingMissing
        }
        refreshLocked()
        MeetingRecoveryReport(
            recoveredCompleted = recovered,
            markedIncomplete = incomplete,
            missingFiles = missing,
        )
    }

    // ------------------------------------------------------------------
    // Paths
    // ------------------------------------------------------------------

    private fun ensureRootLocked() {
        if (rootDir.isDirectory) {
            if (Files.isSymbolicLink(rootDir.toPath())) {
                throw storageFailure(IOException("symlink"), "meetingRoot")
            }
            return
        }
        if (!rootDir.mkdirs() && !rootDir.isDirectory) {
            throw storageFailure(IOException("mkdirs"), "meetingRoot")
        }
    }

    private fun meetingDirLocked(id: String): File {
        val dir = File(rootDir, id).canonicalFile
        if (dir.parentFile?.path != rootDir.path) throw invalidIdentifier(id)
        if (Files.isSymbolicLink(dir.toPath())) throw invalidIdentifier(id)
        return dir
    }

    private fun existingMeetingDirLocked(id: String): File {
        val dir = meetingDirLocked(id)
        if (!dir.isDirectory) throw notFound(id)
        return dir
    }

    private fun meetingDirectoriesLocked(): List<File> {
        val children = rootDir.listFiles() ?: return emptyList()
        return children
            .asSequence()
            .filter { it.isDirectory && MeetingIds.isValid(it.name) }
            .sortedWith(compareByDescending<File> { it.name })
            .toList()
    }

    private fun recordingsDirLocked(meetingDir: File): File {
        val dir = File(meetingDir, MEETING_RECORDINGS_DIR).canonicalFile
        if (!dir.path.startsWith(meetingDir.canonicalPath + File.separator)) {
            throw MeetingException(MeetingError(MeetingErrorCode.INVALID_IDENTIFIER, "Invalid recordings path.", false))
        }
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) {
            throw storageFailure(IOException("mkdirs"), "recordings")
        }
        if (Files.isSymbolicLink(dir.toPath())) {
            throw storageFailure(IOException("symlink"), "recordings")
        }
        return dir
    }

    private fun importDirLocked(meetingDir: File): File {
        val dir = File(meetingDir, MEETING_IMPORTS_DIR).canonicalFile
        if (!dir.path.startsWith(meetingDir.canonicalPath + File.separator)) {
            throw MeetingException(MeetingError(MeetingErrorCode.INVALID_IDENTIFIER, "Invalid imports path.", false))
        }
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) {
            throw storageFailure(IOException("mkdirs"), "imports")
        }
        if (Files.isSymbolicLink(dir.toPath())) {
            throw storageFailure(IOException("symlink"), "imports")
        }
        return dir
    }

    internal fun recordingFileLocked(meetingDir: File, recordingId: String, final: Boolean): File {
        val dir = recordingsDirLocked(meetingDir)
        val name = if (final) {
            "$recordingId.$MEETING_RECORDING_EXTENSION"
        } else {
            "$recordingId.$MEETING_RECORDING_EXTENSION.part"
        }
        val file = File(dir, name).canonicalFile
        if (!file.path.startsWith(dir.canonicalPath + File.separator)) throw invalidIdentifier(recordingId)
        return file
    }

    internal fun importFileLocked(meetingDir: File, imported: StoredImport): File {
        val dir = importDirLocked(meetingDir)
        val file = File(dir, "${imported.id}.${imported.extension}").canonicalFile
        if (!file.path.startsWith(dir.canonicalPath + File.separator)) throw invalidIdentifier(imported.id)
        return file
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    private fun readMeetingLocked(dir: File, expectedId: String): StoredMeeting {
        val file = File(dir, MEETING_META_FILE)
        if (!file.isFile) throw notFound(expectedId)
        val text = try {
            if (file.length() > MAX_METADATA_BYTES) {
                throw MeetingException(
                    MeetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata is unreadable.", false, "oversized"),
                )
            }
            file.readText(Charsets.UTF_8)
        } catch (error: MeetingException) {
            throw error
        } catch (error: Exception) {
            throw storageFailure(error, "readMeeting")
        }
        val parsed = try {
            Json.parseToJsonElement(text).jsonObject
        } catch (error: Exception) {
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "Meeting metadata is unreadable.",
                detail = "parse",
                cause = error,
            )
        }
        val stored = try {
            decodeMeeting(parsed)
        } catch (error: MeetingException) {
            throw error
        } catch (error: Exception) {
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "Meeting metadata is unreadable.",
                detail = "schema",
                cause = error,
            )
        }
        if (stored.id != expectedId) {
            throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata is unreadable.", detail = "idMismatch")
        }
        return stored
    }

    private fun writeMeetingLocked(dir: File, stored: StoredMeeting) {
        val target = File(dir, MEETING_META_FILE)
        val temp = File(dir, "$MEETING_META_FILE.tmp-${UUID.randomUUID()}")
        try {
            val bytes = encodeMeeting(stored).toString().toByteArray(Charsets.UTF_8)
            FileOutputStream(temp).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            moveAtomically(temp, target)
            fsyncDirectory(dir)
        } catch (error: Exception) {
            runCatching { temp.delete() }
            throw storageFailure(error, "writeMeeting")
        } finally {
            if (temp.exists()) runCatching { temp.delete() }
        }
    }

    private fun refreshLocked() {
        val summaries = meetingDirectoriesLocked().mapNotNull { dir ->
            val id = dir.name
            try {
                val stored = readMeetingLocked(dir, id)
                toSummaryLocked(stored, dir)
            } catch (_: Exception) {
                val meta = File(dir, MEETING_META_FILE)
                MeetingSummary(
                    id = id,
                    title = "Unreadable meeting",
                    createdAtMillis = meta.lastModified().coerceAtLeast(0L),
                    updatedAtMillis = meta.lastModified().coerceAtLeast(0L),
                    notesPreview = "",
                    materialCount = 0,
                    recordingCount = 0,
                    totalDurationMillis = 0L,
                    hasIncompleteMedia = true,
                    revision = 0L,
                    metadataCorrupt = true,
                )
            }
        }.sortedWith(
            compareByDescending<MeetingSummary> { it.createdAtMillis }
                .thenByDescending { it.updatedAtMillis }
                .thenByDescending { it.id },
        )
        _summaries.value = summaries
    }

    private fun toSummaryLocked(stored: StoredMeeting, dir: File): MeetingSummary {
        val materials = stored.recordings.map { recordingMaterialLocked(dir, stored.id, it) } +
            stored.imports.map { importMaterialLocked(dir, stored.id, it) }
        return MeetingSummary(
            id = stored.id,
            title = stored.title,
            createdAtMillis = stored.createdAtMillis,
            updatedAtMillis = stored.updatedAtMillis,
            notesPreview = MeetingText.preview(stored.notes),
            materialCount = materials.size,
            recordingCount = stored.recordings.size,
            totalDurationMillis = materials.sumOf { it.durationMillis },
            hasIncompleteMedia = materials.any {
                it.status == MeetingMaterialStatus.INCOMPLETE || it.status == MeetingMaterialStatus.MISSING
            },
            revision = stored.revision,
            metadataCorrupt = false,
        )
    }

    private fun toDetailLocked(stored: StoredMeeting, dir: File): MeetingDetail {
        val materials = (
            stored.recordings.map { recordingMaterialLocked(dir, stored.id, it) } +
                stored.imports.map { importMaterialLocked(dir, stored.id, it) }
            ).sortedWith(compareBy({ it.order }, { it.createdAtMillis }, { it.id }))
        return MeetingDetail(
            id = stored.id,
            title = stored.title,
            createdAtMillis = stored.createdAtMillis,
            updatedAtMillis = stored.updatedAtMillis,
            notes = stored.notes,
            notesRevision = stored.notesRevision,
            revision = stored.revision,
            transcription = stored.transcription.toPublic(),
            materials = materials,
            recordings = materials.filter { it.kind == MeetingMaterialKind.RECORDING },
            imports = materials.filter { it.kind != MeetingMaterialKind.RECORDING },
        )
    }

    private fun recordingMaterialLocked(
        dir: File,
        meetingId: String,
        recording: StoredRecording,
    ): MeetingMaterial {
        val finalFile = recordingFileLocked(dir, recording.id, final = true)
        val partFile = recordingFileLocked(dir, recording.id, final = false)
        val existing = when {
            finalFile.isFile && finalFile.length() > 0 -> finalFile
            partFile.isFile && partFile.length() > 0 -> partFile
            else -> null
        }
        val status = when (recording.state) {
            RECORDING_STARTING, RECORDING_ACTIVE -> MeetingMaterialStatus.RECORDING
            RECORDING_PAUSED -> MeetingMaterialStatus.PAUSED
            RECORDING_STOPPING -> MeetingMaterialStatus.FINALIZING
            RECORDING_COMPLETED -> if (existing != null) {
                MeetingMaterialStatus.COMPLETED
            } else {
                MeetingMaterialStatus.MISSING
            }
            else -> if (existing != null) MeetingMaterialStatus.INCOMPLETE else MeetingMaterialStatus.MISSING
        }
        val playable = recording.state == RECORDING_COMPLETED &&
            recording.incompleteReason == null &&
            finalFile.isFile &&
            finalFile.length() > 0
        val reason = when {
            recording.incompleteReason != null -> recording.incompleteReason
            status == MeetingMaterialStatus.MISSING -> "missingFile"
            else -> null
        }
        return MeetingMaterial(
            id = recording.id,
            meetingId = meetingId,
            kind = MeetingMaterialKind.RECORDING,
            displayName = recording.displayName,
            order = recording.order,
            createdAtMillis = recording.createdAtMillis,
            durationMillis = maxOf(recording.durationMillis, recording.accumulatedMillis),
            sizeBytes = existing?.length() ?: recording.sizeBytes,
            status = status,
            isPlayable = playable,
            mimeType = recording.mimeType,
            incompleteReason = reason,
        )
    }

    private fun importMaterialLocked(
        dir: File,
        meetingId: String,
        imported: StoredImport,
    ): MeetingMaterial {
        val file = importFileLocked(dir, imported)
        val exists = file.isFile && file.length() > 0
        return MeetingMaterial(
            id = imported.id,
            meetingId = meetingId,
            kind = imported.kind,
            displayName = imported.displayName,
            order = imported.order,
            createdAtMillis = imported.createdAtMillis,
            durationMillis = imported.durationMillis,
            sizeBytes = if (exists) file.length() else imported.sizeBytes,
            status = if (exists) MeetingMaterialStatus.COMPLETED else MeetingMaterialStatus.MISSING,
            isPlayable = exists,
            mimeType = imported.mimeType,
            incompleteReason = if (exists) null else "missingFile",
        )
    }

    private fun nextOrder(stored: StoredMeeting): Long {
        val maxRecording = stored.recordings.maxOfOrNull { it.order } ?: 0L
        val maxImport = stored.imports.maxOfOrNull { it.order } ?: 0L
        return maxOf(maxRecording, maxImport) + 1L
    }

    // ------------------------------------------------------------------
    // JSON codec
    // ------------------------------------------------------------------

    private fun encodeMeeting(stored: StoredMeeting): JsonObject = buildJsonObject {
        put("schemaVersion", MEETING_SCHEMA_VERSION)
        put("id", stored.id)
        put("title", stored.title)
        put("createdAtMillis", stored.createdAtMillis)
        put("updatedAtMillis", stored.updatedAtMillis)
        put("notes", stored.notes)
        put("notesRevision", stored.notesRevision)
        put("revision", stored.revision)
        put("transcription", buildJsonObject {
            put("schemaVersion", stored.transcription.schemaVersion)
            put("revision", stored.transcription.revision)
            putNullable("language", stored.transcription.language)
            putNullable("updatedAtMillis", stored.transcription.updatedAtMillis)
            put("segments", buildJsonArray {
                stored.transcription.segments.forEach { segment ->
                    add(buildJsonObject {
                        put("id", segment.id)
                        put("startMillis", segment.startMillis)
                        put("endMillis", segment.endMillis)
                        put("text", segment.text)
                        putNullable("speaker", segment.speaker)
                    })
                }
            })
        })
        put("recordings", buildJsonArray {
            stored.recordings.forEach { recording ->
                add(buildJsonObject {
                    put("id", recording.id)
                    put("order", recording.order)
                    put("displayName", recording.displayName)
                    put("createdAtMillis", recording.createdAtMillis)
                    putNullable("startedAtMillis", recording.startedAtMillis)
                    put("accumulatedMillis", recording.accumulatedMillis)
                    put("durationMillis", recording.durationMillis)
                    put("sizeBytes", recording.sizeBytes)
                    put("state", recording.state)
                    put("mimeType", recording.mimeType)
                    putNullable("incompleteReason", recording.incompleteReason)
                })
            }
        })
        put("imports", buildJsonArray {
            stored.imports.forEach { imported ->
                add(buildJsonObject {
                    put("id", imported.id)
                    put("order", imported.order)
                    put("displayName", imported.displayName)
                    put("createdAtMillis", imported.createdAtMillis)
                    put("durationMillis", imported.durationMillis)
                    put("sizeBytes", imported.sizeBytes)
                    put("mimeType", imported.mimeType)
                    put("extension", imported.extension)
                    put("kind", imported.kind.name)
                })
            }
        })
    }

    private fun decodeMeeting(obj: JsonObject): StoredMeeting {
        val schema = obj.intOrNull("schemaVersion") ?: MEETING_SCHEMA_VERSION
        if (schema !in 1..MEETING_SCHEMA_VERSION) {
            throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an unsupported version.")
        }
        val id = obj.requiredString("id")
        if (!MeetingIds.isValid(id)) throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid id.")
        val title = MeetingText.title(obj.requiredString("title"), "Untitled meeting")
        val createdAt = obj.requiredLong("createdAtMillis").coerceAtLeast(0L)
        val updatedAt = obj.longOrNull("updatedAtMillis")?.coerceAtLeast(0L) ?: createdAt
        val notes = obj.stringOrNull("notes") ?: ""
        if (notes.length > MEETING_MAX_NOTES_CHARS) {
            throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting notes exceed the supported size.")
        }
        val notesRevision = obj.longOrNull("notesRevision")?.coerceAtLeast(0L) ?: 0L
        val revision = obj.longOrNull("revision")?.coerceAtLeast(0L) ?: 1L
        val transcription = decodeTranscription(obj["transcription"] as? JsonObject)
        val recordings = (obj["recordings"] as? JsonArray)?.mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val recordingId = value.stringOrNull("id") ?: return@mapNotNull null
            if (!MeetingIds.isValid(recordingId)) {
                throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid recording id.")
            }
            val state = value.stringOrNull("state") ?: RECORDING_INCOMPLETE
            if (state !in ALL_RECORDING_STATES) {
                throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid recording state.")
            }
            StoredRecording(
                id = recordingId,
                order = value.longOrNull("order")?.coerceAtLeast(0L) ?: 0L,
                displayName = MeetingText.displayName(value.stringOrNull("displayName"), "Recording"),
                createdAtMillis = value.longOrNull("createdAtMillis")?.coerceAtLeast(0L) ?: createdAt,
                startedAtMillis = value.longOrNull("startedAtMillis")?.coerceAtLeast(0L),
                accumulatedMillis = value.longOrNull("accumulatedMillis")?.coerceAtLeast(0L) ?: 0L,
                durationMillis = value.longOrNull("durationMillis")?.coerceAtLeast(0L) ?: 0L,
                sizeBytes = value.longOrNull("sizeBytes")?.coerceAtLeast(0L) ?: 0L,
                state = state,
                mimeType = value.stringOrNull("mimeType") ?: MEETING_RECORDING_MIME,
                incompleteReason = value.stringOrNull("incompleteReason")?.take(160),
            )
        } ?: emptyList()
        val imports = (obj["imports"] as? JsonArray)?.mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val importId = value.stringOrNull("id") ?: return@mapNotNull null
            if (!MeetingIds.isValid(importId)) {
                throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid import id.")
            }
            val extension = value.stringOrNull("extension") ?: "media"
            if (!EXTENSION_PATTERN.matches(extension)) {
                throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid import extension.")
            }
            val rawKind = value.stringOrNull("kind") ?: MeetingMaterialKind.AUDIO_IMPORT.name
            val kind = runCatching { MeetingMaterialKind.valueOf(rawKind) }.getOrNull()
                ?: throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid import kind.")
            if (kind == MeetingMaterialKind.RECORDING) {
                throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata has an invalid import kind.")
            }
            StoredImport(
                id = importId,
                order = value.longOrNull("order")?.coerceAtLeast(0L) ?: 0L,
                displayName = MeetingText.displayName(value.stringOrNull("displayName"), "Imported media"),
                createdAtMillis = value.longOrNull("createdAtMillis")?.coerceAtLeast(0L) ?: createdAt,
                durationMillis = value.longOrNull("durationMillis")?.coerceAtLeast(0L) ?: 0L,
                sizeBytes = value.longOrNull("sizeBytes")?.coerceAtLeast(0L) ?: 0L,
                mimeType = value.stringOrNull("mimeType") ?: "application/octet-stream",
                extension = extension,
                kind = kind,
            )
        } ?: emptyList()
        val materialIds = recordings.map { it.id } + imports.map { it.id }
        if (materialIds.toSet().size != materialIds.size) {
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "Meeting metadata contains duplicate material ids.",
            )
        }
        return StoredMeeting(
            id = id,
            title = title,
            createdAtMillis = createdAt,
            updatedAtMillis = updatedAt,
            notes = notes,
            notesRevision = notesRevision,
            revision = revision,
            transcription = transcription,
            recordings = recordings,
            imports = imports,
        )
    }

    private fun decodeTranscription(obj: JsonObject?): StoredTranscription {
        if (obj == null) return StoredTranscription()
        val segments = (obj["segments"] as? JsonArray)?.mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val id = value.stringOrNull("id") ?: return@mapNotNull null
            StoredTranscriptSegment(
                id = id.take(160),
                startMillis = value.longOrNull("startMillis")?.coerceAtLeast(0L) ?: 0L,
                endMillis = value.longOrNull("endMillis")?.coerceAtLeast(0L) ?: 0L,
                text = value.stringOrNull("text") ?: "",
                speaker = value.stringOrNull("speaker")?.take(120),
            )
        } ?: emptyList()
        return StoredTranscription(
            schemaVersion = obj.intOrNull("schemaVersion")?.coerceIn(1, 1000) ?: MEETING_SCHEMA_VERSION,
            revision = obj.longOrNull("revision")?.coerceAtLeast(0L) ?: 0L,
            language = obj.stringOrNull("language")?.take(40),
            updatedAtMillis = obj.longOrNull("updatedAtMillis")?.coerceAtLeast(0L),
            segments = segments,
        )
    }

    private fun StoredTranscription.toPublic(): MeetingTranscription = MeetingTranscription(
        schemaVersion = schemaVersion,
        revision = revision,
        language = language,
        updatedAtMillis = updatedAtMillis,
        segments = segments.map {
            MeetingTranscriptSegment(
                id = it.id,
                startMillis = it.startMillis,
                endMillis = it.endMillis,
                text = it.text,
                speaker = it.speaker,
            )
        },
    )

    companion object {
        private const val MAX_METADATA_BYTES = 8L * 1024L * 1024L
        private val EXTENSION_PATTERN = Regex("^[a-z0-9]{1,8}$")

        private const val RECORDING_STARTING = "STARTING"
        private const val RECORDING_ACTIVE = "RECORDING"
        private const val RECORDING_PAUSED = "PAUSED"
        private const val RECORDING_STOPPING = "STOPPING"
        private const val RECORDING_COMPLETED = "COMPLETED"
        private const val RECORDING_INCOMPLETE = "INCOMPLETE"
        private const val RECORDING_FAILED = "FAILED"

        private val ALL_RECORDING_STATES = setOf(
            RECORDING_STARTING,
            RECORDING_ACTIVE,
            RECORDING_PAUSED,
            RECORDING_STOPPING,
            RECORDING_COMPLETED,
            RECORDING_INCOMPLETE,
            RECORDING_FAILED,
        )
        private val ACTIVE_RECORDING_STATES = setOf(
            RECORDING_STARTING,
            RECORDING_ACTIVE,
            RECORDING_PAUSED,
            RECORDING_STOPPING,
        )

        internal const val STATE_STARTING = RECORDING_STARTING
        internal const val STATE_RECORDING = RECORDING_ACTIVE
        internal const val STATE_PAUSED = RECORDING_PAUSED
        internal const val STATE_STOPPING = RECORDING_STOPPING
        internal const val STATE_COMPLETED = RECORDING_COMPLETED
        internal const val STATE_INCOMPLETE = RECORDING_INCOMPLETE
        internal const val STATE_FAILED = RECORDING_FAILED

        internal fun requireExtension(raw: String?): String {
            val value = raw?.lowercase()?.takeIf { EXTENSION_PATTERN.matches(it) }
                ?: throw meetingError(MeetingErrorCode.INVALID_INPUT, "Unsupported media extension.")
            return value
        }

        internal fun isActiveState(state: String): Boolean = state in ACTIVE_RECORDING_STATES
    }
}

// ----------------------------------------------------------------------
// Shared file helpers
// ----------------------------------------------------------------------

internal fun moveAtomically(source: File, destination: File) {
    try {
        Files.move(
            source.toPath(),
            destination.toPath(),
            StandardCopyOption.ATOMIC_MOVE,
            StandardCopyOption.REPLACE_EXISTING,
        )
    } catch (_: AtomicMoveNotSupportedException) {
        Files.move(source.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
}

private fun fsyncDirectory(directory: File) {
    runCatching {
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
    }
}

internal fun deleteTreeNoFollow(path: Path, root: Path) {
    val canonicalRoot = root.toRealPath()
    val canonicalPath = if (Files.exists(path)) path.toRealPath() else path.toAbsolutePath().normalize()
    if (!canonicalPath.startsWith(canonicalRoot)) {
        throw IOException("Refusing to delete outside the meeting root.")
    }
    Files.walkFileTree(path, object : SimpleFileVisitor<Path>() {
        override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
            Files.deleteIfExists(file)
            return FileVisitResult.CONTINUE
        }

        override fun postVisitDirectory(dir: Path, error: IOException?): FileVisitResult {
            if (error != null) throw error
            Files.deleteIfExists(dir)
            return FileVisitResult.CONTINUE
        }
    })
}

/**
 * Bounded streaming copy used by imports. The destination is fsynced before
 * returning; an overflow or read failure leaves the partial staging file for
 * the caller to delete.
 */
internal fun copyBounded(input: InputStream, destination: File, maxBytes: Long): Long {
    var total = 0L
    FileOutputStream(destination).use { output ->
        val buffer = ByteArray(64 * 1024)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            total += read.toLong()
            if (total > maxBytes) {
                throw meetingError(
                    MeetingErrorCode.TOO_LARGE,
                    "The selected media is too large.",
                    detail = "limit=$maxBytes",
                )
            }
            output.write(buffer, 0, read)
        }
        output.fd.sync()
    }
    return total
}

internal fun fileLengthOrZero(file: File): Long =
    runCatching { if (file.isFile) file.length() else 0L }.getOrDefault(0L)

private fun JsonObjectBuilder.putNullable(key: String, value: String?) {
    put(key, value?.let(::JsonPrimitive) ?: JsonNull)
}

private fun JsonObjectBuilder.putNullable(key: String, value: Long?) {
    put(key, value?.let { JsonPrimitive(it) } ?: JsonNull)
}

private fun JsonObject.stringOrNull(key: String): String? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull
}

private fun JsonObject.requiredString(key: String): String =
    stringOrNull(key) ?: throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata is missing $key.")

private fun JsonObject.longOrNull(key: String): Long? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
}

private fun JsonObject.requiredLong(key: String): Long =
    longOrNull(key) ?: throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata is missing $key.")

private fun JsonObject.intOrNull(key: String): Int? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
}
