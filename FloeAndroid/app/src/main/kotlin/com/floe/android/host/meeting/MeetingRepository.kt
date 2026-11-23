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

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
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
internal const val MEETING_RECORDING_MIME = "audio/mp4"
internal const val MEETING_MAX_TRANSCRIPT_SEGMENTS = 2_000
internal const val MEETING_MAX_TRANSCRIPT_TEXT_CHARS = 2_000
internal const val MEETING_MAX_TRANSCRIPT_MILLIS = 12L * 60L * 60L * 1_000L
internal const val MEETING_SNAPSHOTS_DIR = ".transcription"
internal const val MEETING_LIVE_DIR = ".live"
internal const val MEETING_LIVE_META_FILE = "live.json"
internal const val MEETING_LIVE_SCHEMA_VERSION = 1
internal const val MEETING_MAX_LIVE_META_BYTES = 8L * 1024L * 1024L
internal const val MEETING_MAX_LIVE_FRAGMENTS = 4_000
internal const val MEETING_RECORDING_WAV_MIME = "audio/wav"
internal const val MEETING_SNAPSHOT_META_FILE = "snapshot.json"
internal const val MEETING_SNAPSHOT_AUDIO_FILE = "source.audio"
internal const val MEETING_MAX_SNAPSHOT_BYTES = MEETING_MAX_IMPORT_BYTES
internal const val MEETING_SNAPSHOT_STALE_MILLIS = 24L * 60L * 60L * 1_000L

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
    /** Exact material that produced this transcript; null for legacy rows. */
    val materialId: String? = null,
    val segments: List<StoredTranscriptSegment> = emptyList(),
    /** Trace of the latest unfinished attempt; never a transcript body. */
    val lastAttempt: StoredTranscriptionAttempt? = null,
)

/**
 * Durable, bounded checkpoint of one transcription attempt. The strings are
 * the lane-authored vocabulary only — no provider body, URL or credential.
 */
internal data class StoredTranscriptionAttempt(
    val materialId: String,
    val expectedTranscriptionRevision: Long,
    val phase: String,
    val failureCode: String?,
    val failureReason: String?,
    val retryable: Boolean,
    val updatedAtMillis: Long,
) {
    companion object {
        const val PHASE_RUNNING = "running"
        const val PHASE_FAILED = "failed"
        const val PHASE_CANCELLED = "cancelled"
        val ALL_PHASES = setOf(PHASE_RUNNING, PHASE_FAILED, PHASE_CANCELLED)
    }
}

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

/** One finalized local fragment queued for live cloud transcription. */
internal data class MeetingLiveFragment(
    val index: Int,
    val fileName: String,
    val startMillis: Long,
    val durationMillis: Long,
    val sampleRate: Int,
    val channels: Int,
    val sizeBytes: Long,
) {
    val endMillis: Long get() = startMillis + durationMillis
}

internal data class StoredLiveFragment(
    val index: Int,
    val fileName: String,
    val startMillis: Long,
    val durationMillis: Long,
    val sampleRate: Int,
    val channels: Int,
    val sizeBytes: Long,
    val state: String,
    val segments: List<StoredTranscriptSegment>,
    val failureCode: String?,
    val failureReason: String?,
    val retryable: Boolean,
    val attempts: Int,
    val updatedAtMillis: Long,
)

internal data class StoredLiveTranscription(
    val schemaVersion: Int,
    val meetingId: String,
    val recordingId: String,
    val sessionId: String,
    val baseTranscriptionRevision: Long,
    val language: String?,
    val state: String,
    val failureCode: String?,
    val failureReason: String?,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val fragments: List<StoredLiveFragment>,
)

/** One live session's manifest plus its trusted fragment directory. */
internal data class MeetingLiveSession(
    val transcript: MeetingLiveTranscript,
    val directory: File,
    val chunkSeconds: Int,
    val recordingActive: Boolean,
    val recordingCompleted: Boolean,
)

internal sealed interface MeetingLivePromotion {
    data class Promoted(val receipt: MeetingTranscriptionReceipt) : MeetingLivePromotion
    data object NoSpeech : MeetingLivePromotion
}

/** Verified playable source for one meeting transcription attempt. */
internal data class MeetingTranscriptionSource(
    val material: MeetingMaterial,
    val file: File,
    val durationMillis: Long,
    val transcriptionRevision: Long,
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
 * Deterministic seams for storage and cancellation tests. Production uses the
 * platform implementations by leaving every field at its default.
 */
internal data class SnapshotTestHooks(
    /** Overrides the usable-space reading; null means "use the real file store". */
    val availableBytes: ((File) -> Long?)? = null,
    /** Runs after each bounded copy chunk; may throw to simulate cancellation. */
    val onCopyChunk: () -> Unit = {},
)

/**
 * Testable, Android-free durable store. Production code constructs one through
 * [MeetingStoreRegistry]; JVM tests construct it directly with a temp root.
 */
internal class MeetingRepository(
    root: File,
    private val snapshotTestHooks: SnapshotTestHooks = SnapshotTestHooks(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val mutex = Mutex()
    private val rawRoot: File = root.absoluteFile
    private val rootDir: File = try {
        rawRoot.canonicalFile
    } catch (error: IOException) {
        throw storageFailure(error, "meetingRoot")
    }

    /**
     * Snapshot leases owned by this process. Guarded by [mutex]. A lease keeps
     * stale recovery from deleting a snapshot another live attempt is using.
     */
    private val activeSnapshots = LinkedHashMap<String, ActiveSnapshot>()

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
        if (activeSnapshots.values.any { it.meetingId == id }) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "Cloud transcription is using this meeting.",
                retryable = true,
                detail = "transcriptionActive",
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
            val stored = readMeetingLocked(dir, id)
            val extension = stored.recordings
                .firstOrNull { it.id == materialId }
                ?.let { recordingExtension(it.mimeType) }
                ?: "m4a"
            recordingFileLocked(dir, materialId, final, extension)
        }

    suspend fun importDirectory(meetingId: String): File = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        importDirLocked(existingMeetingDirLocked(id))
    }

    suspend fun createRecordingDraft(
        meetingId: String,
        displayName: String,
        liveAudio: Boolean = false,
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
            mimeType = if (liveAudio) MEETING_RECORDING_WAV_MIME else MEETING_RECORDING_MIME,
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
        val part = recordingFileLocked(
            dir,
            materialId,
            final = false,
            recordingExtension(stored.recordings[index].mimeType),
        )
        val final = recordingFileLocked(
            dir,
            materialId,
            final = true,
            recordingExtension(stored.recordings[index].mimeType),
        )
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
            val recording = stored.recordings.firstOrNull { it.id == materialId }
                ?: throw notFound(materialId)
            if (activeSnapshots.values.any { it.meetingId == id && it.materialId == materialId }) {
                throw meetingError(
                    MeetingErrorCode.CONFLICT,
                    "Cloud transcription is using this recording.",
                    retryable = true,
                    detail = "transcriptionActive",
                )
            }
            val updated = stored.copy(
                recordings = stored.recordings.filterNot { it.id == materialId },
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1,
            )
            writeMeetingLocked(dir, updated)
            val extension = recordingExtension(recording.mimeType)
            runCatching { recordingFileLocked(dir, materialId, final = false, extension).delete() }
            runCatching { recordingFileLocked(dir, materialId, final = true, extension).delete() }
            runCatching { deleteLiveDirectoryLocked(dir, materialId) }
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
        resolvedMaterialLocked(dir, id, materialIdChecked, stored)
    }

    private fun resolvedMaterialLocked(
        dir: File,
        meetingId: String,
        materialId: String,
        stored: StoredMeeting,
    ): ResolvedMaterial {
        val recording = stored.recordings.firstOrNull { it.id == materialId }
        if (recording != null) {
            val material = recordingMaterialLocked(dir, meetingId, recording)
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
            val file = recordingFileLocked(
                dir,
                materialId,
                final = true,
                recordingExtension(recording.mimeType),
            )
            return ResolvedMaterial(material, file)
        }
        val imported = stored.imports.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val material = importMaterialLocked(dir, meetingId, imported)
        if (!material.isPlayable) {
            throw meetingError(
                MeetingErrorCode.MISSING_MEDIA,
                "The imported file is no longer available.",
                detail = materialId,
            )
        }
        val file = importFileLocked(dir, imported)
        return ResolvedMaterial(material, file)
    }

    /**
     * Resolves exactly one playable material for cloud transcription.
     *
     * The caller supplies only canonical meeting/material ids. The returned
     * file is the repository's canonical app-owned path, never a caller path,
     * and its real duration comes from the platform probe. Recording/import
     * metadata and bytes are not modified.
     */
    suspend fun transcriptionSource(
        meetingId: String,
        materialId: String,
        probe: MediaProbe,
    ): MeetingTranscriptionSource = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialKey = MeetingIds.require(materialId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        requireTranscriptMaterialLocked(stored, materialKey)
        val resolved = resolvedMaterialLocked(dir, id, materialKey, stored)
        val file = resolved.file
        assertNoSymlinkAncestry(dir, file, "transcriptionSource")
        if (!file.isFile || file.length() <= 0L) {
            throw meetingError(
                MeetingErrorCode.MISSING_MEDIA,
                "The selected material is no longer available.",
                detail = materialKey,
            )
        }
        val probed = probe(file)
        if (!probed.readable) {
            throw meetingError(
                MeetingErrorCode.CORRUPT_MEDIA,
                "The selected material could not be decoded.",
                detail = "probe",
            )
        }
        if (!probed.hasAudio) {
            throw meetingError(
                MeetingErrorCode.UNSUPPORTED_MEDIA,
                "The selected material has no audio track.",
                detail = "audioTrackMissing",
            )
        }
        val duration = maxOf(probed.durationMillis, resolved.material.durationMillis)
        if (duration <= 0L) {
            throw meetingError(
                MeetingErrorCode.UNSUPPORTED_MEDIA,
                "The selected material has no usable duration.",
                detail = "durationUnavailable",
            )
        }
        MeetingTranscriptionSource(
            material = resolved.material,
            file = file,
            durationMillis = duration,
            transcriptionRevision = stored.transcription.revision,
        )
    }

    /**
     * Creates one private, bounded, immutable-for-one-attempt copy of the
     * exactly resolved source.
     *
     * The original material is never modified. The copy lives under
     * `<meeting>/.transcription/<snapshotId>/` and is removed only by
     * [releaseTranscriptionSource] or bounded stale recovery. The copied bytes
     * are identified by [MeetingTranscriptionSnapshot.sourceBytes] and
     * [MeetingTranscriptionSnapshot.sourceSha256]; [commitTranscription] later
     * re-hashes the original and refuses any mismatch.
     *
     * Cancellation or any failure before handoff removes the partial snapshot.
     * A source or directory symlink, a source that changes while it is being
     * copied, low storage space and an unreadable source all fail closed.
     */
    suspend fun createTranscriptionSnapshot(
        meetingId: String,
        materialId: String,
        probe: MediaProbe,
    ): MeetingTranscriptionSnapshot {
        val id = MeetingIds.require(meetingId)
        val materialKey = MeetingIds.require(materialId)
        val prepared = mutex.withLock {
            val dir = existingMeetingDirLocked(id)
            val stored = readMeetingLocked(dir, id)
            requireTranscriptMaterialLocked(stored, materialKey)
            recoverStaleSnapshotsLocked(dir, id, clock())
            val resolved = resolvedMaterialLocked(dir, id, materialKey, stored)
            val file = resolved.file
            assertNoSymlinkAncestry(dir, file, "snapshotSource")
            if (!file.isFile || file.length() <= 0L) {
                throw meetingError(
                    MeetingErrorCode.MISSING_MEDIA,
                    "The selected material is no longer available.",
                    detail = materialKey,
                )
            }
            if (file.length() > MEETING_MAX_SNAPSHOT_BYTES) {
                throw meetingError(
                    MeetingErrorCode.TOO_LARGE,
                    "The selected media is too large.",
                    detail = "limit=$MEETING_MAX_SNAPSHOT_BYTES",
                )
            }
            val probed = probe(file)
            if (!probed.readable) {
                throw meetingError(
                    MeetingErrorCode.CORRUPT_MEDIA,
                    "The selected material could not be decoded.",
                    detail = "probe",
                )
            }
            if (!probed.hasAudio) {
                throw meetingError(
                    MeetingErrorCode.UNSUPPORTED_MEDIA,
                    "The selected material has no audio track.",
                    detail = "audioTrackMissing",
                )
            }
            val duration = maxOf(probed.durationMillis, resolved.material.durationMillis)
            if (duration <= 0L) {
                throw meetingError(
                    MeetingErrorCode.UNSUPPORTED_MEDIA,
                    "The selected material has no usable duration.",
                    detail = "durationUnavailable",
                )
            }
            val identity = sourceIdentityLocked(file)
            val snapshotId = MeetingIds.newId()
            val snapshots = snapshotsDirLocked(dir)
            // Check space before creating the per-attempt directory, so a
            // full or unavailable volume cannot leave an empty snapshot dir.
            requireSnapshotSpace(snapshots, identity.size)
            var createdDir: File? = null
            try {
                val snapshotDir = snapshotDirLocked(snapshots, snapshotId, create = true)
                createdDir = snapshotDir
                activeSnapshots[snapshotId] = ActiveSnapshot(id, materialKey)
                PreparedSnapshot(
                    meetingId = id,
                    materialId = materialKey,
                    snapshotId = snapshotId,
                    directory = snapshotDir,
                    source = file,
                    identity = identity,
                    durationMillis = duration,
                )
            } catch (error: Throwable) {
                activeSnapshots.remove(snapshotId)
                val cleanupError = createdDir?.let { deleteSnapshotDirectoryLocked(it) }
                if (cleanupError != null) throw snapshotCleanupFailure(cleanupError, error)
                throw error
            }
        }
        val part = File(
            prepared.directory,
            "$MEETING_SNAPSHOT_AUDIO_FILE.part-${UUID.randomUUID()}",
        )
        try {
            val copied = copySourceWithDigest(prepared.source, part)
            return mutex.withLock { finishSnapshotLocked(prepared, part, copied) }
        } catch (cancelled: CancellationException) {
            val cleanupError = discardSnapshot(prepared)
            if (cleanupError != null) cancelled.addSuppressed(cleanupError)
            throw cancelled
        } catch (error: Throwable) {
            val cleanupError = discardSnapshot(prepared)
            if (cleanupError != null) throw snapshotCleanupFailure(cleanupError, error)
            throw error
        }
    }

    /**
     * Deletes exactly one snapshot owned by this meeting.
     *
     * Returns true only when this call removed a snapshot whose on-disk
     * metadata matches the meeting and snapshot ids. A missing snapshot
     * returns false, which is an explicit "nothing deleted" answer rather than
     * a silent success. Invalid identifiers, another meeting's snapshot or
     * unknown on-disk ownership fail without destructive cleanup.
     */
    suspend fun releaseTranscriptionSource(meetingId: String, snapshotId: String): Boolean =
        mutex.withLock {
            val id = MeetingIds.require(meetingId)
            val snapshotKey = MeetingIds.require(snapshotId)
            val lease = activeSnapshots[snapshotKey]
            if (lease != null && lease.meetingId != id) {
                throw meetingError(
                    MeetingErrorCode.CONFLICT,
                    "The transcription snapshot belongs to another meeting.",
                    detail = "snapshotOwnership",
                )
            }
            // The attempt has asked for release. Stop protecting it from stale
            // recovery immediately, even if the delete below fails; a later
            // bounded recovery can then remove an orphan safely.
            activeSnapshots.remove(snapshotKey)
            val dir = existingMeetingDirLocked(id)
            val snapshots = existingSnapshotsDirLocked(dir)
            if (snapshots == null) {
                return@withLock false
            }
            val snapshotDir = File(snapshots, snapshotKey)
            if (Files.isSymbolicLink(snapshotDir.toPath())) {
                throw storageFailure(IOException("symlink"), "snapshotRelease")
            }
            if (!Files.exists(snapshotDir.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                return@withLock false
            }
            if (!snapshotDir.isDirectory) {
                throw storageFailure(IOException("notDirectory"), "snapshotOwnership")
            }
            val meta = readSnapshotMetaLocked(snapshotDir)
                ?: throw storageFailure(IOException("missingMeta"), "snapshotOwnership")
            if (meta.snapshotId != snapshotKey || meta.meetingId != id) {
                throw storageFailure(IOException("metaMismatch"), "snapshotOwnership")
            }
            try {
                deleteTreeNoFollow(snapshotDir.toPath(), rootDir.toPath())
                fsyncDirectory(snapshots)
            } catch (error: Exception) {
                throw storageFailure(error, "snapshotRelease")
            }
            true
        }

    /**
     * Atomically commits timed transcript segments for exactly one material.
     *
     * All checks and the metadata write happen under the repository lock:
     *  * the material must still exist and be playable;
     *  * the actual original bytes and SHA-256 must match the snapshot;
     *  * [expectedTranscriptionRevision] must match the current transcript;
     *  * an existing transcript bound to another material is never replaced;
     *  * segments must carry real, bounded provider timing.
     *
     * An exact retry of the immediately previous result is idempotent and does
     * not write twice. Any conflict leaves notes, materials, audio and the
     * previous transcript untouched.
     *
     * [validateBeforeCommit] is an optional, non-suspending admission check
     * invoked under the repository mutex immediately before the one actual
     * metadata write (never on an idempotent no-write return). It exists so a
     * caller can shrink the window between its own lifecycle/epoch check and
     * this durable write. The callback must not block, suspend or call back
     * into this repository; its failure propagates unchanged and nothing is
     * written. It is not, and must not be described as, a global linearization
     * protocol for an external runtime root.
     */
    suspend fun commitTranscription(
        meetingId: String,
        materialId: String,
        expectedSourceBytes: Long,
        expectedSourceSha256: String,
        expectedTranscriptionRevision: Long,
        language: String?,
        segments: List<StoredTranscriptSegment>,
        validateBeforeCommit: () -> Unit = {},
        now: Long = clock(),
    ): MeetingTranscriptionReceipt = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialKey = MeetingIds.require(materialId)
        val expectedSha = requireSha256Hex(expectedSourceSha256)
        if (expectedSourceBytes <= 0L || expectedSourceBytes > MEETING_MAX_SNAPSHOT_BYTES) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "The transcription source size is invalid.",
                detail = "sourceBytes",
            )
        }
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        requireTranscriptMaterialLocked(stored, materialKey)
        val resolved = resolvedMaterialLocked(dir, id, materialKey, stored)
        if (!resolved.file.isFile || resolved.file.length() <= 0L ||
            resolved.file.length() != expectedSourceBytes
        ) {
            throw sourceChanged()
        }
        assertNoSymlinkAncestry(dir, resolved.file, "commitSource")
        val actual = hashSourceWithDigest(resolved.file)
        if (actual.bytes != expectedSourceBytes || actual.sha256 != expectedSha) {
            throw sourceChanged()
        }
        val cleanSegments = normalizedTranscriptSegments(segments)
        if (cleanSegments.isEmpty()) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "The transcription contains no timed text.",
                detail = "emptyTranscript",
            )
        }
        val existing = stored.transcription
        if (existing.revision != expectedTranscriptionRevision) {
            // A retry after a successful commit is safe only when the exact
            // material, revision and segment set already exist.
            if (expectedTranscriptionRevision + 1L == existing.revision &&
                existing.materialId == materialKey &&
                sameTranscriptSegments(existing.segments, cleanSegments)
            ) {
                return@withLock clearStaleAttemptAndReturnIdempotentLocked(
                    dir, stored, existing, now,
                )
            }
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "The transcript changed in another edit.",
                retryable = true,
                detail = "expected=$expectedTranscriptionRevision actual=${existing.revision}",
            )
        }
        if (existing.materialId == materialKey &&
            sameTranscriptSegments(existing.segments, cleanSegments)
        ) {
            return@withLock clearStaleAttemptAndReturnIdempotentLocked(
                dir, stored, existing, now,
            )
        }
        val committedAt = maxOf(now, existing.updatedAtMillis ?: now)
        val transcription = StoredTranscription(
            schemaVersion = existing.schemaVersion.coerceIn(1, MEETING_SCHEMA_VERSION),
            revision = existing.revision + 1L,
            language = language?.trim()?.takeIf { it.isNotEmpty() }?.take(40),
            updatedAtMillis = committedAt,
            materialId = materialKey,
            segments = cleanSegments,
            // A real transcript now exists; the unfinished-attempt trace is
            // no longer actionable and must not outlive its own recovery.
            lastAttempt = null,
        )
        // Called exactly once, under the repository lock, immediately before
        // the only metadata write. A throw leaves every durable byte intact.
        validateBeforeCommit()
        writeMeetingLocked(
            dir,
            stored.copy(
                transcription = transcription,
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1L,
            ),
        )
        refreshLocked()
        MeetingTranscriptionReceipt(
            meetingId = id,
            materialId = materialKey,
            transcriptionRevision = transcription.revision,
            segmentCount = cleanSegments.size,
            updatedAtMillis = committedAt,
            idempotent = false,
        )
    }

    /**
     * Idempotent commit receipt. The transcript write is genuinely skipped;
     * the only write that can still happen is clearing a stale unfinished
     * attempt marker left by a failed retry after this transcript was
     * already committed (otherwise the page would keep offering a retry for
     * material that now has a transcript).
     */
    private fun clearStaleAttemptAndReturnIdempotentLocked(
        dir: File,
        stored: StoredMeeting,
        existing: StoredTranscription,
        now: Long,
    ): MeetingTranscriptionReceipt {
        if (stored.transcription.lastAttempt != null) {
            writeMeetingLocked(
                dir,
                stored.copy(
                    transcription = stored.transcription.copy(lastAttempt = null),
                    updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                    revision = stored.revision + 1L,
                ),
            )
            refreshLocked()
        }
        return MeetingTranscriptionReceipt(
            meetingId = stored.id,
            materialId = existing.materialId ?: stored.transcription.materialId ?: stored.id,
            transcriptionRevision = existing.revision,
            segmentCount = existing.segments.size,
            updatedAtMillis = existing.updatedAtMillis ?: now,
            idempotent = true,
        )
    }

    /**
     * Records (or clears) the durable trace of the most recent unfinished
     * transcription attempt for this meeting.
     *
     * The record is advisory recovery metadata only: it never touches the
     * transcript body, never bumps the transcription revision and never
     * carries provider content. It exists so that an attempt that was
     * interrupted by process death, failure or cancellation can be honestly
     * retried from the exact material and revision checkpoint it started
     * with, instead of silently vanishing. Supplying a null [attempt]
     * clears the record.
     */
    suspend fun recordTranscriptionAttempt(
        meetingId: String,
        attempt: MeetingTranscriptionLastAttempt?,
        now: Long = clock(),
    ) = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val next = attempt?.let { toStoredAttempt(it, now) }
        val cleared = stored.transcription.lastAttempt == null
        if (cleared && next == null) return@withLock
        if (!cleared && next != null && sameAttempt(stored.transcription.lastAttempt, next)) {
            return@withLock
        }
        writeMeetingLocked(
            dir,
            stored.copy(
                transcription = stored.transcription.copy(lastAttempt = next),
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1L,
            ),
        )
        refreshLocked()
    }

    // ------------------------------------------------------------------
    // While-recording live cloud transcription
    // ------------------------------------------------------------------

    /**
     * Reads the newest durable live-transcript manifest for one meeting. A
     * manifest whose recording no longer exists is ignored; it is never
     * projected as a transcript for another take.
     */
    suspend fun liveTranscription(
        meetingId: String,
        recordingId: String? = null,
    ): MeetingLiveTranscript? = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        if (recordingId != null) {
            val key = MeetingIds.require(recordingId)
            return@withLock readLiveTranscriptionLocked(dir, stored, key)
        }
        val root = existingLiveRootLocked(dir) ?: return@withLock null
        val candidates = (root.listFiles() ?: emptyArray())
            .asSequence()
            .filter { it.isDirectory && MeetingIds.isValid(it.name) }
            .filter { child -> !Files.isSymbolicLink(child.toPath()) }
            .sortedByDescending { it.lastModified() }
        for (child in candidates) {
            val live = readLiveTranscriptionLocked(dir, stored, child.name) ?: continue
            return@withLock live
        }
        null
    }

    /**
     * Creates or reattaches the durable live manifest for one take. A new
     * [sessionId] fences late results from an earlier process/session while
     * preserving already-confirmed fragments and their real text.
     */
    internal suspend fun beginLiveTranscription(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        chunkSeconds: Int,
        now: Long = clock(),
    ): MeetingLiveSession = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        require(chunkSeconds in MIN_LIVE_CHUNK_SECONDS..MAX_LIVE_CHUNK_SECONDS) {
            "invalidLiveChunkSeconds"
        }
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        if (recording.state !in setOf(RECORDING_STARTING, RECORDING_ACTIVE, RECORDING_PAUSED)) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "Live transcription can only start with an active recording.",
                detail = recording.state,
            )
        }
        val liveDir = liveRecordingDirLocked(dir, materialId, create = true)
        val existing = readLiveManifestLocked(liveDir, id, materialId)
        val baseRevision = existing?.baseTranscriptionRevision ?: stored.transcription.revision
        val fragments = existing?.fragments ?: emptyList()
        val next = StoredLiveTranscription(
            schemaVersion = MEETING_LIVE_SCHEMA_VERSION,
            meetingId = id,
            recordingId = materialId,
            sessionId = session,
            baseTranscriptionRevision = baseRevision,
            language = existing?.language,
            state = LIVE_RECORDING,
            failureCode = null,
            failureReason = null,
            createdAtMillis = existing?.createdAtMillis ?: now,
            updatedAtMillis = now,
            fragments = fragments,
        )
        writeLiveManifestLocked(liveDir, next)
        MeetingLiveSession(
            transcript = toPublicLive(next, recordingState = recording.state),
            directory = liveDir,
            chunkSeconds = chunkSeconds,
            recordingActive = true,
            recordingCompleted = false,
        )
    }

    /**
     * Appends one finalized local fragment. The fragment file must already be
     * closed under [liveDirectory] and match the supplied measured timing.
     * Repeating the same index is idempotent; a conflicting reuse is refused.
     */
    internal suspend fun appendLiveFragment(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        fragment: MeetingLiveFragment,
        now: Long = clock(),
    ): MeetingLiveTranscript = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId)
            ?: throw meetingError(
                MeetingErrorCode.NOT_FOUND,
                "Live transcription is not prepared for this recording.",
            )
        if (live.sessionId != session) throw liveSessionChanged()
        if (live.state == LIVE_CANCELLED || live.state == LIVE_COMPLETED) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "Live transcription is not accepting fragments.",
                retryable = false,
                detail = live.state,
            )
        }
        validateLiveFragment(liveDir, live, fragment)
        val previous = live.fragments.firstOrNull { it.index == fragment.index }
        if (previous != null) {
            if (previous.fileName != fragment.fileName ||
                previous.startMillis != fragment.startMillis ||
                previous.durationMillis != fragment.durationMillis ||
                previous.sizeBytes != fragment.sizeBytes
            ) {
                throw meetingError(
                    MeetingErrorCode.CONFLICT,
                    "A different live fragment already uses this index.",
                    retryable = false,
                    detail = "fragmentIndex",
                )
            }
            return@withLock toPublicLive(live, recording.state)
        }
        if (live.fragments.size >= MEETING_MAX_LIVE_FRAGMENTS) {
            throw meetingError(
                MeetingErrorCode.TOO_LARGE,
                "The live transcript has too many fragments.",
                retryable = false,
                detail = "liveFragments",
            )
        }
        val entry = StoredLiveFragment(
            index = fragment.index,
            fileName = fragment.fileName,
            startMillis = fragment.startMillis,
            durationMillis = fragment.durationMillis,
            sampleRate = fragment.sampleRate,
            channels = fragment.channels,
            sizeBytes = fragment.sizeBytes,
            state = LIVE_FRAGMENT_PENDING,
            segments = emptyList(),
            failureCode = null,
            failureReason = null,
            retryable = false,
            attempts = 0,
            updatedAtMillis = now,
        )
        val updated = live.copy(
            fragments = (live.fragments + entry).sortedBy { it.index },
            state = if (live.state == LIVE_INTERRUPTED) LIVE_RECORDING else live.state,
            updatedAtMillis = now,
        )
        writeLiveManifestLocked(liveDir, updated)
        toPublicLive(updated, recording.state)
    }

    /** Confirms one fragment with real provider-timed segments (or none). */
    internal suspend fun confirmLiveFragment(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        fragmentIndex: Int,
        segments: List<StoredTranscriptSegment>,
        language: String?,
        now: Long = clock(),
    ): MeetingLiveTranscript = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId)
            ?: throw meetingError(MeetingErrorCode.NOT_FOUND, "Live transcription is not prepared.")
        if (live.sessionId != session) throw liveSessionChanged()
        if (live.state == LIVE_CANCELLED || live.state == LIVE_COMPLETED) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "Live transcription is not accepting results.",
                retryable = false,
                detail = live.state,
            )
        }
        val index = live.fragments.indexOfFirst { it.index == fragmentIndex }
        if (index < 0) throw notFound("liveFragment:$fragmentIndex")
        val current = live.fragments[index]
        if (current.state == LIVE_FRAGMENT_CONFIRMED) {
            return@withLock toPublicLive(live, recording.state)
        }
        val clean = normalizedTranscriptSegments(segments)
        val confirmedSegments = live.fragments
            .asSequence()
            .filter { it.state == LIVE_FRAGMENT_CONFIRMED }
            .sumOf { it.segments.size }
        if (confirmedSegments + clean.size > MEETING_MAX_TRANSCRIPT_SEGMENTS) {
            throw meetingError(
                MeetingErrorCode.TOO_LARGE,
                "The live transcript is too long.",
                detail = "liveTranscriptSegments",
            )
        }
        val fragments = live.fragments.toMutableList()
        fragments[index] = current.copy(
            state = LIVE_FRAGMENT_CONFIRMED,
            segments = clean,
            failureCode = null,
            failureReason = null,
            retryable = false,
            attempts = current.attempts + 1,
            updatedAtMillis = now,
        )
        val updated = live.copy(
            fragments = fragments,
            language = language?.trim()?.takeIf { it.isNotEmpty() }?.take(40) ?: live.language,
            updatedAtMillis = now,
        )
        writeLiveManifestLocked(liveDir, updated)
        toPublicLive(updated, recording.state)
    }

    internal suspend fun failLiveFragment(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        fragmentIndex: Int,
        failureCode: String?,
        failureReason: String?,
        retryable: Boolean,
        now: Long = clock(),
    ): MeetingLiveTranscript = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId)
            ?: throw meetingError(MeetingErrorCode.NOT_FOUND, "Live transcription is not prepared.")
        if (live.sessionId != session) throw liveSessionChanged()
        if (live.state == LIVE_CANCELLED || live.state == LIVE_COMPLETED) {
            return@withLock toPublicLive(live, recording.state)
        }
        val index = live.fragments.indexOfFirst { it.index == fragmentIndex }
        if (index < 0) throw notFound("liveFragment:$fragmentIndex")
        val current = live.fragments[index]
        if (current.state == LIVE_FRAGMENT_CONFIRMED) {
            return@withLock toPublicLive(live, recording.state)
        }
        val fragments = live.fragments.toMutableList()
        fragments[index] = current.copy(
            state = LIVE_FRAGMENT_FAILED,
            failureCode = failureCode?.take(64),
            failureReason = failureReason?.take(160),
            retryable = retryable,
            attempts = current.attempts + 1,
            updatedAtMillis = now,
        )
        val updated = live.copy(
            state = LIVE_FAILED,
            fragments = fragments,
            failureCode = fragments[index].failureCode,
            failureReason = fragments[index].failureReason,
            updatedAtMillis = now,
        )
        writeLiveManifestLocked(liveDir, updated)
        toPublicLive(updated, recording.state)
    }

    internal suspend fun setLiveTranscriptionState(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        phase: MeetingLiveTranscriptPhase,
        failureCode: String? = null,
        failureReason: String? = null,
        now: Long = clock(),
    ): MeetingLiveTranscript = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId)
            ?: throw meetingError(MeetingErrorCode.NOT_FOUND, "Live transcription is not prepared.")
        if (live.sessionId != session) throw liveSessionChanged()
        val state = liveStateName(phase)
        if (live.state == state && live.failureCode == failureCode &&
            live.failureReason == failureReason
        ) {
            return@withLock toPublicLive(live, recording.state)
        }
        if (live.state in setOf(LIVE_CANCELLED, LIVE_COMPLETED)) {
            return@withLock toPublicLive(live, recording.state)
        }
        val updated = live.copy(
            state = state,
            failureCode = failureCode?.take(64),
            failureReason = failureReason?.take(160),
            updatedAtMillis = now,
        )
        writeLiveManifestLocked(liveDir, updated)
        toPublicLive(updated, recording.state)
    }

    /**
     * Reconciles capture-written fragment sidecars after a process death.
     * Missing sidecars are not invented: a fragment without measured timing
     * cannot be aligned and is left out of the cloud queue.
     */
    internal suspend fun reconcileLiveTranscription(
        meetingId: String,
        recordingId: String,
        now: Long = clock(),
    ): MeetingLiveTranscript? = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: return@withLock null
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId) ?: return@withLock null
        val known = live.fragments.map { it.index }.toHashSet()
        val additions = ArrayList<StoredLiveFragment>()
        (liveDir.listFiles() ?: emptyArray()).forEach { file ->
            if (!file.isFile || Files.isSymbolicLink(file.toPath())) return@forEach
            if (!LIVE_FRAGMENT_SIDECAR_PATTERN.matches(file.name)) return@forEach
            val sidecar = runCatching { readMeetingLiveFragmentSidecar(file) }.getOrNull()
                ?: return@forEach
            if (sidecar.index >= MEETING_MAX_LIVE_FRAGMENTS) return@forEach
            val wav = File(liveDir, sidecar.fileName)
            val existing = live.fragments.firstOrNull { it.index == sidecar.index }
            if (existing != null) {
                if (existing.state == LIVE_FRAGMENT_CONFIRMED) {
                    // The durable text is already committed; never resend or
                    // retain the confirmed audio again.
                    runCatching { wav.delete() }
                    runCatching { file.delete() }
                }
                return@forEach
            }
            if (!wav.isFile || Files.isSymbolicLink(wav.toPath()) ||
                wav.length() != sidecar.sizeBytes || wav.length() <= 44L
            ) {
                return@forEach
            }
            try {
                validateLiveFragment(liveDir, live, sidecar)
            } catch (_: Exception) {
                return@forEach
            }
            known += sidecar.index
            additions += StoredLiveFragment(
                index = sidecar.index,
                fileName = sidecar.fileName,
                startMillis = sidecar.startMillis,
                durationMillis = sidecar.durationMillis,
                sampleRate = sidecar.sampleRate,
                channels = sidecar.channels,
                sizeBytes = sidecar.sizeBytes,
                state = LIVE_FRAGMENT_PENDING,
                segments = emptyList(),
                failureCode = null,
                failureReason = null,
                retryable = false,
                attempts = 0,
                updatedAtMillis = now,
            )
        }
        var updated = live
        if (additions.isNotEmpty()) {
            updated = live.copy(
                fragments = (live.fragments + additions).sortedBy { it.index },
                updatedAtMillis = now,
            )
        }
        val missing = updated.fragments.map { entry ->
            if (entry.state == LIVE_FRAGMENT_CONFIRMED) return@map entry
            val file = File(liveDir, entry.fileName)
            if (file.isFile && !Files.isSymbolicLink(file.toPath())) return@map entry
            entry.copy(
                state = LIVE_FRAGMENT_FAILED,
                failureCode = "SOURCE_UNAVAILABLE",
                failureReason = "fragmentMissing",
                retryable = false,
                updatedAtMillis = now,
            )
        }
        if (missing != updated.fragments) updated = updated.copy(fragments = missing)
        if (updated != live) writeLiveManifestLocked(liveDir, updated)
        toPublicLive(updated, recording.state)
    }

    /**
     * Reattaches an explicit retry to the existing manifest under a fresh
     * session id. Confirmed fragments and their text are preserved; only
     * failed fragments whose real audio file still exists become pending.
     * This is never called automatically after a process restart.
     */
    internal suspend fun retryLiveTranscription(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        chunkSeconds: Int,
        now: Long = clock(),
    ): MeetingLiveSession? = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        require(chunkSeconds in MIN_LIVE_CHUNK_SECONDS..MAX_LIVE_CHUNK_SECONDS) {
            "invalidLiveChunkSeconds"
        }
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: return@withLock null
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId) ?: return@withLock null
        if (live.state == LIVE_COMPLETED) return@withLock null
        val fragments = live.fragments.map { fragment ->
            if (fragment.state != LIVE_FRAGMENT_FAILED ||
                !File(liveDir, fragment.fileName).isFile
            ) {
                fragment
            } else {
                fragment.copy(
                    state = LIVE_FRAGMENT_PENDING,
                    failureCode = null,
                    failureReason = null,
                    updatedAtMillis = now,
                )
            }
        }
        val recordingActive = recording.state in ACTIVE_RECORDING_STATES
        val next = live.copy(
            sessionId = session,
            state = if (recordingActive) LIVE_RECORDING else LIVE_DRAINING,
            failureCode = null,
            failureReason = null,
            updatedAtMillis = now,
            fragments = fragments,
        )
        writeLiveManifestLocked(liveDir, next)
        MeetingLiveSession(
            transcript = toPublicLive(next, recording.state),
            directory = liveDir,
            chunkSeconds = chunkSeconds,
            recordingActive = recordingActive,
            recordingCompleted = recording.state == RECORDING_COMPLETED,
        )
    }

    /** Lowest ordered pending fragment for one live session. */
    internal suspend fun nextPendingLiveFragment(
        meetingId: String,
        recordingId: String,
        sessionId: String,
    ): MeetingLiveFragment? = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId) ?: return@withLock null
        if (live.sessionId != session) throw liveSessionChanged()
        val fragment = live.fragments
            .asSequence()
            .filter { it.state == LIVE_FRAGMENT_PENDING }
            .sortedBy { it.index }
            .firstOrNull() ?: return@withLock null
        MeetingLiveFragment(
            index = fragment.index,
            fileName = fragment.fileName,
            startMillis = fragment.startMillis,
            durationMillis = fragment.durationMillis,
            sampleRate = fragment.sampleRate,
            channels = fragment.channels,
            sizeBytes = fragment.sizeBytes,
        )
    }

    internal suspend fun deleteLiveTranscription(
        meetingId: String,
        recordingId: String,
    ) = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val dir = existingMeetingDirLocked(id)
        runCatching { deleteLiveDirectoryLocked(dir, materialId) }
    }

    /**
     * Atomically promotes every confirmed live fragment into the canonical
     * meeting transcript. The canonical revision is a compare-and-swap: a
     * transcript edited elsewhere is never overwritten and the live manifest
     * is retained for an explicit retry. A recording that is not finalized
     * and playable is never presented as a committed source.
     */
    internal suspend fun promoteLiveTranscription(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        now: Long = clock(),
    ): MeetingLivePromotion = mutex.withLock {
        val id = MeetingIds.require(meetingId)
        val materialId = MeetingIds.require(recordingId)
        val session = MeetingIds.require(sessionId)
        val dir = existingMeetingDirLocked(id)
        val stored = readMeetingLocked(dir, id)
        val recording = stored.recordings.firstOrNull { it.id == materialId }
            ?: throw notFound(materialId)
        val extension = recordingExtension(recording.mimeType)
        val finalFile = recordingFileLocked(dir, materialId, final = true, extension)
        val liveDir = liveRecordingDirLocked(dir, materialId, create = false)
        val live = readLiveManifestLocked(liveDir, id, materialId)
            ?: throw meetingError(MeetingErrorCode.NOT_FOUND, "Live transcription is not prepared.")
        if (live.sessionId != session) throw liveSessionChanged()
        if (live.fragments.any {
                it.state == LIVE_FRAGMENT_PENDING || it.state == LIVE_FRAGMENT_FAILED
            }
        ) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "Unconfirmed live fragments remain.",
                retryable = true,
                detail = "liveFragmentsUnconfirmed",
            )
        }
        if (recording.state != RECORDING_COMPLETED || recording.incompleteReason != null ||
            !finalFile.isFile || finalFile.length() <= 0L
        ) {
            throw meetingError(
                MeetingErrorCode.SOURCE_UNAVAILABLE,
                "The recording is not finalized.",
                retryable = true,
                detail = recording.incompleteReason ?: recording.state,
            )
        }
        val seen = HashSet<String>()
        val deduplicated = live.fragments
            .sortedBy { it.index }
            .flatMap { it.segments }
            .filter { segment ->
                seen.add(
                    "${segment.startMillis}|${segment.endMillis}|${segment.text}|${segment.speaker}",
                )
            }
        val segments = normalizedTranscriptSegments(deduplicated)
        if (segments.isEmpty()) {
            markLiveCompletedLocked(liveDir, live, now)
            runCatching { deleteLiveDirectoryLocked(dir, materialId) }
            return@withLock MeetingLivePromotion.NoSpeech
        }
        val existing = stored.transcription
        if (existing.revision != live.baseTranscriptionRevision) {
            if (existing.materialId == materialId &&
                sameTranscriptSegments(existing.segments, segments)
            ) {
                markLiveCompletedLocked(liveDir, live, now)
                runCatching { deleteLiveDirectoryLocked(dir, materialId) }
                return@withLock MeetingLivePromotion.Promoted(
                    MeetingTranscriptionReceipt(
                        meetingId = id,
                        materialId = materialId,
                        transcriptionRevision = existing.revision,
                        segmentCount = existing.segments.size,
                        updatedAtMillis = existing.updatedAtMillis ?: now,
                        idempotent = true,
                    ),
                )
            }
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "The transcript changed in another edit.",
                retryable = true,
                detail = "expected=${live.baseTranscriptionRevision} actual=${existing.revision}",
            )
        }
        if (existing.materialId == materialId &&
            sameTranscriptSegments(existing.segments, segments)
        ) {
            markLiveCompletedLocked(liveDir, live, now)
            runCatching { deleteLiveDirectoryLocked(dir, materialId) }
            return@withLock MeetingLivePromotion.Promoted(
                MeetingTranscriptionReceipt(
                    meetingId = id,
                    materialId = materialId,
                    transcriptionRevision = existing.revision,
                    segmentCount = existing.segments.size,
                    updatedAtMillis = existing.updatedAtMillis ?: now,
                    idempotent = true,
                ),
            )
        }
        val committedAt = maxOf(now, existing.updatedAtMillis ?: now)
        val transcription = StoredTranscription(
            schemaVersion = existing.schemaVersion.coerceIn(1, MEETING_SCHEMA_VERSION),
            revision = existing.revision + 1L,
            language = live.language?.take(40),
            updatedAtMillis = committedAt,
            materialId = materialId,
            segments = segments,
            lastAttempt = null,
        )
        writeMeetingLocked(
            dir,
            stored.copy(
                transcription = transcription,
                updatedAtMillis = maxOf(now, stored.updatedAtMillis),
                revision = stored.revision + 1L,
            ),
        )
        markLiveCompletedLocked(liveDir, live.copy(
            baseTranscriptionRevision = existing.revision,
        ), now)
        runCatching { deleteLiveDirectoryLocked(dir, materialId) }
        refreshLocked()
        MeetingLivePromotion.Promoted(
            MeetingTranscriptionReceipt(
                meetingId = id,
                materialId = materialId,
                transcriptionRevision = transcription.revision,
                segmentCount = segments.size,
                updatedAtMillis = committedAt,
                idempotent = false,
            ),
        )
    }

    private fun markLiveCompletedLocked(
        liveDir: File,
        live: StoredLiveTranscription,
        now: Long,
    ) {
        runCatching {
            writeLiveManifestLocked(
                liveDir,
                live.copy(state = LIVE_COMPLETED, updatedAtMillis = now),
            )
        }
    }

    private fun markLiveInterruptedLocked(meetingDir: File, recordingId: String, now: Long) {
        val liveDir = liveRecordingDirLocked(meetingDir, recordingId, create = false)
        if (!liveDir.isDirectory) return
        val live = readLiveManifestLocked(liveDir, meetingDir.name, recordingId) ?: return
        if (live.state != LIVE_RECORDING && live.state != LIVE_DRAINING) return
        writeLiveManifestLocked(
            liveDir,
            live.copy(
                state = LIVE_INTERRUPTED,
                failureCode = "INTERRUPTED",
                failureReason = "processInterrupted",
                updatedAtMillis = now,
            ),
        )
    }

    private fun liveSessionChanged(): MeetingException = meetingError(
        MeetingErrorCode.CONFLICT,
        "The live transcription session changed.",
        retryable = false,
        detail = "liveSession",
    )

    private fun validateLiveFragment(
        liveDir: File,
        live: StoredLiveTranscription,
        fragment: MeetingLiveFragment,
    ) {
        if (fragment.index !in 0 until MEETING_MAX_LIVE_FRAGMENTS) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "Invalid live fragment index.",
                detail = fragment.index.toString(),
            )
        }
        if (!LIVE_FRAGMENT_FILE_PATTERN.matches(fragment.fileName)) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "Invalid live fragment file.",
                detail = fragment.fileName.take(80),
            )
        }
        if (fragment.startMillis < 0L ||
            fragment.durationMillis <= 0L ||
            fragment.endMillis > MEETING_MAX_TRANSCRIPT_MILLIS
        ) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "Invalid live fragment timing.",
                detail = "fragmentTiming",
            )
        }
        if (fragment.sampleRate !in 8_000..192_000 ||
            fragment.channels !in 1..8
        ) {
            throw meetingError(
                MeetingErrorCode.INVALID_INPUT,
                "Invalid live fragment audio format.",
                detail = "fragmentFormat",
            )
        }
        val file = childFileLocked(liveDir, fragment.fileName, "liveFragment")
        if (!file.isFile || Files.isSymbolicLink(file.toPath())) {
            throw meetingError(
                MeetingErrorCode.SOURCE_UNAVAILABLE,
                "The live fragment file is unavailable.",
                detail = fragment.fileName,
            )
        }
        if (file.length() <= 44L || file.length() != fragment.sizeBytes) {
            throw meetingError(
                MeetingErrorCode.STORAGE_FAILURE,
                "The live fragment file is incomplete.",
                retryable = true,
                detail = fragment.fileName,
            )
        }
    }

    private fun readLiveTranscriptionLocked(
        meetingDir: File,
        stored: StoredMeeting,
        recordingId: String,
    ): MeetingLiveTranscript? {
        if (stored.recordings.none { it.id == recordingId }) return null
        val recording = stored.recordings.firstOrNull { it.id == recordingId } ?: return null
        val liveDir = liveRecordingDirLocked(meetingDir, recordingId, create = false)
        val live = readLiveManifestLocked(liveDir, stored.id, recordingId) ?: return null
        return toPublicLive(live, recording.state)
    }

    private fun readLiveManifestLocked(
        liveDir: File,
        expectedMeetingId: String,
        expectedRecordingId: String,
    ): StoredLiveTranscription? {
        if (Files.isSymbolicLink(liveDir.toPath()) || !liveDir.isDirectory) return null
        val file = File(liveDir, MEETING_LIVE_META_FILE)
        if (Files.isSymbolicLink(file.toPath()) || !file.isFile) return null
        if (file.length() <= 0L || file.length() > MEETING_MAX_LIVE_META_BYTES) return null
        val obj = runCatching {
            Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
        }.getOrNull() ?: return null
        return decodeLiveManifest(obj, expectedMeetingId, expectedRecordingId)
    }

    private fun writeLiveManifestLocked(liveDir: File, live: StoredLiveTranscription) {
        val target = childFileLocked(liveDir, MEETING_LIVE_META_FILE, "liveMeta")
        val temp = File(liveDir, "$MEETING_LIVE_META_FILE.tmp-${UUID.randomUUID()}")
        try {
            val bytes = encodeLiveManifest(live).toString().toByteArray(Charsets.UTF_8)
            if (bytes.size > MEETING_MAX_LIVE_META_BYTES) {
                throw meetingError(
                    MeetingErrorCode.TOO_LARGE,
                    "The live transcript is too large.",
                    detail = "liveMeta",
                )
            }
            FileOutputStream(temp).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            moveAtomically(temp, target)
            fsyncDirectory(liveDir)
        } catch (error: Exception) {
            runCatching { temp.delete() }
            if (error is MeetingException) throw error
            throw storageFailure(error, "writeLive")
        } finally {
            if (temp.exists()) runCatching { temp.delete() }
        }
    }

    private fun liveRootLocked(meetingDir: File, create: Boolean): File =
        if (create) {
            childDirectoryLocked(meetingDir, MEETING_LIVE_DIR, "liveRoot")
        } else {
            existingChildDirectoryLocked(meetingDir, MEETING_LIVE_DIR, "liveRoot")
                ?: throw meetingError(MeetingErrorCode.NOT_FOUND, "Live transcription is not prepared.")
        }

    private fun existingLiveRootLocked(meetingDir: File): File? =
        existingChildDirectoryLocked(meetingDir, MEETING_LIVE_DIR, "liveRoot")

    private fun liveRecordingDirLocked(
        meetingDir: File,
        recordingId: String,
        create: Boolean,
    ): File {
        val root = liveRootLocked(meetingDir, create = create)
        if (create) return childDirectoryLocked(root, recordingId, "liveRecording")
        existingChildDirectoryLocked(root, recordingId, "liveRecording")?.let { return it }
        val unresolved = File(root, recordingId)
        if (Files.isSymbolicLink(unresolved.toPath())) {
            throw storageFailure(IOException("symlink"), "liveRecording")
        }
        return unresolved
    }

    private fun deleteLiveDirectoryLocked(meetingDir: File, recordingId: String) {
        val root = existingLiveRootLocked(meetingDir) ?: return
        val dir = existingChildDirectoryLocked(root, recordingId, "liveRecording") ?: return
        deleteTreeNoFollow(dir.toPath(), rootDir.toPath())
        runCatching { fsyncDirectory(root) }
        if ((root.listFiles() ?: emptyArray()).isEmpty()) {
            runCatching { root.delete() }
        }
    }

    private fun liveStateName(phase: MeetingLiveTranscriptPhase): String = when (phase) {
        MeetingLiveTranscriptPhase.RECORDING -> LIVE_RECORDING
        MeetingLiveTranscriptPhase.DRAINING -> LIVE_DRAINING
        MeetingLiveTranscriptPhase.COMPLETED -> LIVE_COMPLETED
        MeetingLiveTranscriptPhase.FAILED -> LIVE_FAILED
        MeetingLiveTranscriptPhase.CANCELLED -> LIVE_CANCELLED
        MeetingLiveTranscriptPhase.INTERRUPTED -> LIVE_INTERRUPTED
    }

    private fun toPublicLive(
        live: StoredLiveTranscription,
        recordingState: String,
    ): MeetingLiveTranscript {        val confirmed = live.fragments.count { it.state == LIVE_FRAGMENT_CONFIRMED }
        val pending = live.fragments.count { it.state == LIVE_FRAGMENT_PENDING }
        val failed = live.fragments.count { it.state == LIVE_FRAGMENT_FAILED }
        val phase = when (live.state) {
            LIVE_RECORDING ->
                if (recordingState in ACTIVE_RECORDING_STATES) {
                    MeetingLiveTranscriptPhase.RECORDING
                } else {
                    MeetingLiveTranscriptPhase.INTERRUPTED
                }
            LIVE_DRAINING -> MeetingLiveTranscriptPhase.DRAINING
            LIVE_COMPLETED -> MeetingLiveTranscriptPhase.COMPLETED
            LIVE_FAILED -> MeetingLiveTranscriptPhase.FAILED
            LIVE_CANCELLED -> MeetingLiveTranscriptPhase.CANCELLED
            else -> MeetingLiveTranscriptPhase.INTERRUPTED
        }
        val segments = live.fragments
            .asSequence()
            .filter { it.state == LIVE_FRAGMENT_CONFIRMED }
            .sortedBy { it.index }
            .flatMap { it.segments.asSequence() }
            .map { segment ->
                MeetingTranscriptSegment(
                    id = segment.id,
                    startMillis = segment.startMillis,
                    endMillis = segment.endMillis,
                    text = segment.text,
                    speaker = segment.speaker,
                )
            }
            .toList()
        return MeetingLiveTranscript(
            meetingId = live.meetingId,
            recordingId = live.recordingId,
            sessionId = live.sessionId,
            phase = phase,
            segments = segments,
            confirmedFragments = confirmed,
            pendingFragments = pending,
            failedFragments = failed,
            errorCode = live.failureCode,
            errorReason = live.failureReason,
            updatedAtMillis = live.updatedAtMillis,
        )
    }

    private fun encodeLiveManifest(live: StoredLiveTranscription): JsonObject = buildJsonObject {
        put("schemaVersion", live.schemaVersion)
        put("meetingId", live.meetingId)
        put("recordingId", live.recordingId)
        put("sessionId", live.sessionId)
        put("baseTranscriptionRevision", live.baseTranscriptionRevision)
        putNullable("language", live.language)
        put("state", live.state)
        putNullable("failureCode", live.failureCode)
        putNullable("failureReason", live.failureReason)
        put("createdAtMillis", live.createdAtMillis)
        put("updatedAtMillis", live.updatedAtMillis)
        put("fragments", buildJsonArray {
            live.fragments.forEach { fragment ->
                add(buildJsonObject {
                    put("index", fragment.index)
                    put("fileName", fragment.fileName)
                    put("startMillis", fragment.startMillis)
                    put("durationMillis", fragment.durationMillis)
                    put("sampleRate", fragment.sampleRate)
                    put("channels", fragment.channels)
                    put("sizeBytes", fragment.sizeBytes)
                    put("state", fragment.state)
                    putNullable("failureCode", fragment.failureCode)
                    putNullable("failureReason", fragment.failureReason)
                    put("retryable", fragment.retryable)
                    put("attempts", fragment.attempts)
                    put("updatedAtMillis", fragment.updatedAtMillis)
                    put("segments", encodeStoredSegments(fragment.segments))
                })
            }
        })
    }

    private fun decodeLiveManifest(
        obj: JsonObject,
        expectedMeetingId: String,
        expectedRecordingId: String,
    ): StoredLiveTranscription? {
        if (obj.intOrNull("schemaVersion") != MEETING_LIVE_SCHEMA_VERSION) return null
        if (obj.stringOrNull("meetingId") != expectedMeetingId) return null
        if (obj.stringOrNull("recordingId") != expectedRecordingId) return null
        val session = obj.stringOrNull("sessionId")?.takeIf { MeetingIds.isValid(it) } ?: return null
        val state = obj.stringOrNull("state")?.takeIf { it in LIVE_STATES } ?: return null
        val fragments = (obj["fragments"] as? JsonArray)?.mapNotNull { element ->
            val value = element as? JsonObject ?: return@mapNotNull null
            val index = value.intOrNull("index") ?: return@mapNotNull null
            if (index !in 0 until MEETING_MAX_LIVE_FRAGMENTS) return@mapNotNull null
            val fileName = value.stringOrNull("fileName") ?: return@mapNotNull null
            if (!LIVE_FRAGMENT_FILE_PATTERN.matches(fileName)) return@mapNotNull null
            val fragmentState = value.stringOrNull("state")
                ?.takeIf { it in LIVE_FRAGMENT_STATES } ?: return@mapNotNull null
            StoredLiveFragment(
                index = index,
                fileName = fileName,
                startMillis = value.longOrNull("startMillis")?.coerceAtLeast(0L) ?: 0L,
                durationMillis = value.longOrNull("durationMillis")?.coerceAtLeast(0L) ?: 0L,
                sampleRate = value.intOrNull("sampleRate")?.coerceIn(1, 192_000) ?: 16_000,
                channels = value.intOrNull("channels")?.coerceIn(1, 8) ?: 1,
                sizeBytes = value.longOrNull("sizeBytes")?.coerceAtLeast(0L) ?: 0L,
                state = fragmentState,
                segments = decodeStoredSegments(value["segments"]),
                failureCode = value.stringOrNull("failureCode")?.take(64),
                failureReason = value.stringOrNull("failureReason")?.take(160),
                retryable = value.booleanOrNull("retryable") == true,
                attempts = value.intOrNull("attempts")?.coerceAtLeast(0) ?: 0,
                updatedAtMillis = value.longOrNull("updatedAtMillis")?.coerceAtLeast(0L) ?: 0L,
            )
        } ?: emptyList()
        if (fragments.map { it.index }.toSet().size != fragments.size) return null
        return StoredLiveTranscription(
            schemaVersion = MEETING_LIVE_SCHEMA_VERSION,
            meetingId = expectedMeetingId,
            recordingId = expectedRecordingId,
            sessionId = session,
            baseTranscriptionRevision = obj.longOrNull("baseTranscriptionRevision")
                ?.coerceAtLeast(0L) ?: 0L,
            language = obj.stringOrNull("language")?.take(40),
            state = state,
            failureCode = obj.stringOrNull("failureCode")?.take(64),
            failureReason = obj.stringOrNull("failureReason")?.take(160),
            createdAtMillis = obj.longOrNull("createdAtMillis")?.coerceAtLeast(0L) ?: 0L,
            updatedAtMillis = obj.longOrNull("updatedAtMillis")?.coerceAtLeast(0L) ?: 0L,
            fragments = fragments.sortedBy { it.index },
        )
    }

    private fun encodeStoredSegments(segments: List<StoredTranscriptSegment>): JsonArray =
        buildJsonArray {
            segments.forEach { segment ->
                add(buildJsonObject {
                    put("id", segment.id)
                    put("startMillis", segment.startMillis)
                    put("endMillis", segment.endMillis)
                    put("text", segment.text)
                    putNullable("speaker", segment.speaker)
                })
            }
        }

    private fun decodeStoredSegments(element: kotlinx.serialization.json.JsonElement?): List<StoredTranscriptSegment> =
        (element as? JsonArray)?.mapNotNull { item ->
            val value = item as? JsonObject ?: return@mapNotNull null
            val id = value.stringOrNull("id") ?: return@mapNotNull null
            StoredTranscriptSegment(
                id = id.take(160),
                startMillis = value.longOrNull("startMillis")?.coerceAtLeast(0L) ?: 0L,
                endMillis = value.longOrNull("endMillis")?.coerceAtLeast(0L) ?: 0L,
                text = value.stringOrNull("text") ?: "",
                speaker = value.stringOrNull("speaker")?.take(120),
            )
        } ?: emptyList()

    private fun toStoredAttempt(
        attempt: MeetingTranscriptionLastAttempt,
        now: Long,
    ): StoredTranscriptionAttempt = StoredTranscriptionAttempt(
        materialId = attempt.materialId,
        expectedTranscriptionRevision = attempt.expectedTranscriptionRevision,
        phase = when (attempt.phase) {
            MeetingTranscriptionLastAttemptPhase.RUNNING -> StoredTranscriptionAttempt.PHASE_RUNNING
            MeetingTranscriptionLastAttemptPhase.CANCELLED ->
                StoredTranscriptionAttempt.PHASE_CANCELLED
            MeetingTranscriptionLastAttemptPhase.FAILED -> StoredTranscriptionAttempt.PHASE_FAILED
        },
        failureCode = attempt.failureCode?.take(64),
        failureReason = attempt.failureReason?.take(160),
        retryable = attempt.retryable,
        updatedAtMillis = maxOf(attempt.updatedAtMillis, now),
    )

    private fun sameAttempt(
        left: StoredTranscriptionAttempt?,
        right: StoredTranscriptionAttempt,
    ): Boolean = left != null &&
        left.materialId == right.materialId &&
        left.expectedTranscriptionRevision == right.expectedTranscriptionRevision &&
        left.phase == right.phase &&
        left.failureCode == right.failureCode &&
        left.failureReason == right.failureReason &&
        left.retryable == right.retryable

    private fun normalizedTranscriptSegments(
        segments: List<StoredTranscriptSegment>,
    ): List<StoredTranscriptSegment> {
        if (segments.isEmpty()) return emptyList()
        if (segments.size > MEETING_MAX_TRANSCRIPT_SEGMENTS) {
            throw meetingError(
                MeetingErrorCode.TOO_LARGE,
                "The transcription has too many segments.",
                detail = "segments=${segments.size}",
            )
        }
        val seenIds = HashSet<String>(segments.size)
        val clean = ArrayList<StoredTranscriptSegment>(segments.size)
        for (segment in segments) {
            val id = segment.id.trim().takeIf { it.isNotEmpty() && it.length <= 160 }
                ?: throw meetingError(
                    MeetingErrorCode.INVALID_INPUT,
                    "The transcription contains an invalid segment id.",
                )
            if (!seenIds.add(id)) {
                throw meetingError(
                    MeetingErrorCode.INVALID_INPUT,
                    "The transcription contains duplicate segment ids.",
                )
            }
            val text = segment.text
                .replace(Regex("\\s+"), " ")
                .trim()
            if (text.isEmpty() || text.length > MEETING_MAX_TRANSCRIPT_TEXT_CHARS) {
                throw meetingError(
                    MeetingErrorCode.INVALID_INPUT,
                    "The transcription contains invalid segment text.",
                )
            }
            if (segment.startMillis < 0L ||
                segment.endMillis <= segment.startMillis ||
                segment.endMillis > MEETING_MAX_TRANSCRIPT_MILLIS
            ) {
                throw meetingError(
                    MeetingErrorCode.INVALID_INPUT,
                    "The transcription contains invalid segment timing.",
                )
            }
            clean.add(
                StoredTranscriptSegment(
                    id = id,
                    startMillis = segment.startMillis,
                    endMillis = segment.endMillis,
                    text = text,
                    speaker = segment.speaker?.trim()?.takeIf { it.isNotEmpty() }?.take(120),
                ),
            )
        }
        return clean.sortedWith(
            compareBy<StoredTranscriptSegment> { it.startMillis }
                .thenBy { it.endMillis }
                .thenBy { it.id },
        )
    }

    private fun sameTranscriptSegments(
        left: List<StoredTranscriptSegment>,
        right: List<StoredTranscriptSegment>,
    ): Boolean {
        if (left.size != right.size) return false
        for (index in left.indices) {
            val a = left[index]
            val b = right[index]
            if (a.id != b.id || a.startMillis != b.startMillis ||
                a.endMillis != b.endMillis || a.text != b.text ||
                a.speaker != b.speaker
            ) {
                return false
            }
        }
        return true
    }

    private fun requireTranscriptMaterialLocked(stored: StoredMeeting, materialKey: String) {
        if (stored.transcription.segments.isNotEmpty() &&
            stored.transcription.materialId != null &&
            stored.transcription.materialId != materialKey
        ) {
            throw meetingError(
                MeetingErrorCode.CONFLICT,
                "The meeting transcript belongs to another material.",
                retryable = true,
                detail = "materialMismatch",
            )
        }
    }

    private fun sourceChanged(): MeetingException = meetingError(
        MeetingErrorCode.CONFLICT,
        "The source material changed during transcription.",
        retryable = true,
        detail = "sourceChanged",
    )

    private fun sourceIdentityLocked(file: File): SourceIdentity {
        val attrs = try {
            Files.readAttributes(
                file.toPath(),
                BasicFileAttributes::class.java,
                LinkOption.NOFOLLOW_LINKS,
            )
        } catch (error: IOException) {
            throw storageFailure(error, "sourceIdentity")
        }
        if (attrs.isSymbolicLink || !attrs.isRegularFile) {
            throw meetingError(
                MeetingErrorCode.CORRUPT_MEDIA,
                "The selected material is not a regular file.",
            )
        }
        return SourceIdentity(
            fileKey = attrs.fileKey(),
            size = attrs.size(),
            modifiedMillis = attrs.lastModifiedTime().toMillis(),
        )
    }

    private fun requireSnapshotSpace(directory: File, bytes: Long) {
        val usable = snapshotTestHooks.availableBytes?.invoke(directory)
            ?: runCatching { Files.getFileStore(directory.toPath()).usableSpace }.getOrNull()
            ?: return
        val required = bytes + 64L * 1024L
        if (required > 0L && usable < required) {
            throw storageFailure(IOException("capacity"), "snapshotSpace")
        }
    }

    private suspend fun copySourceWithDigest(source: File, destination: File): CopiedSource {
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            Files.newInputStream(
                source.toPath(),
                StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS,
            ).use { input ->
                FileOutputStream(destination).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val read = input.read(buffer)
                        if (read < 0) break
                        if (read == 0) continue
                        total += read.toLong()
                        if (total > MEETING_MAX_SNAPSHOT_BYTES) {
                            throw meetingError(
                                MeetingErrorCode.TOO_LARGE,
                                "The selected media is too large.",
                                detail = "limit=$MEETING_MAX_SNAPSHOT_BYTES",
                            )
                        }
                        digest.update(buffer, 0, read)
                        output.write(buffer, 0, read)
                        snapshotTestHooks.onCopyChunk()
                    }
                    output.fd.sync()
                }
            }
        } catch (error: MeetingException) {
            throw error
        } catch (error: NoSuchFileException) {
            throw meetingError(
                MeetingErrorCode.MISSING_MEDIA,
                "The selected material is no longer available.",
                detail = "snapshotSource",
                cause = error,
            )
        } catch (error: IOException) {
            throw snapshotCopyFailure(error)
        }
        return CopiedSource(total, sha256Hex(digest.digest()))
    }

    private suspend fun hashSourceWithDigest(source: File): CopiedSource {
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        try {
            Files.newInputStream(
                source.toPath(),
                StandardOpenOption.READ,
                LinkOption.NOFOLLOW_LINKS,
            ).use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    total += read.toLong()
                    if (total > MEETING_MAX_SNAPSHOT_BYTES) {
                        throw meetingError(
                            MeetingErrorCode.TOO_LARGE,
                            "The selected media is too large.",
                            detail = "limit=$MEETING_MAX_SNAPSHOT_BYTES",
                        )
                    }
                    digest.update(buffer, 0, read)
                }
            }
        } catch (error: MeetingException) {
            throw error
        } catch (error: NoSuchFileException) {
            throw meetingError(
                MeetingErrorCode.MISSING_MEDIA,
                "The selected material is no longer available.",
                detail = "commitSource",
                cause = error,
            )
        } catch (error: IOException) {
            throw storageFailure(error, "sourceHash")
        }
        return CopiedSource(total, sha256Hex(digest.digest()))
    }

    private fun finishSnapshotLocked(
        prepared: PreparedSnapshot,
        part: File,
        copied: CopiedSource,
    ): MeetingTranscriptionSnapshot {
        val dir = existingMeetingDirLocked(prepared.meetingId)
        val stored = readMeetingLocked(dir, prepared.meetingId)
        requireTranscriptMaterialLocked(stored, prepared.materialId)
        val resolved = resolvedMaterialLocked(dir, prepared.meetingId, prepared.materialId, stored)
        if (resolved.file.path != prepared.source.path) throw sourceChanged()
        assertNoSymlinkAncestry(dir, resolved.file, "snapshotSource")
        val currentIdentity = sourceIdentityLocked(resolved.file)
        if (currentIdentity != prepared.identity ||
            currentIdentity.size != copied.bytes ||
            copied.bytes != prepared.identity.size
        ) {
            throw sourceChanged()
        }
        val snapshots = existingSnapshotsDirLocked(dir)
            ?: throw storageFailure(IOException("snapshotMissing"), "snapshotFinalize")
        val snapshotDir = snapshotDirLocked(snapshots, prepared.snapshotId, create = false)
        if (snapshotDir.path != prepared.directory.path) {
            throw storageFailure(IOException("snapshotMoved"), "snapshotFinalize")
        }
        val audio = childFileLocked(snapshotDir, MEETING_SNAPSHOT_AUDIO_FILE, "snapshotAudio")
        moveAtomically(part, audio)
        fsyncDirectory(snapshotDir)
        val createdAt = clock()
        writeSnapshotMetaLocked(
            snapshotDir,
            SnapshotMetadata(
                snapshotId = prepared.snapshotId,
                meetingId = prepared.meetingId,
                materialId = prepared.materialId,
                sourceBytes = copied.bytes,
                sourceSha256 = copied.sha256,
                durationMillis = prepared.durationMillis,
                transcriptionRevision = stored.transcription.revision,
                createdAtMillis = createdAt,
            ),
        )
        activeSnapshots[prepared.snapshotId] =
            ActiveSnapshot(prepared.meetingId, prepared.materialId)
        return MeetingTranscriptionSnapshot(
            material = resolved.material,
            file = audio,
            durationMillis = prepared.durationMillis,
            transcriptionRevision = stored.transcription.revision,
            sourceBytes = copied.bytes,
            sourceSha256 = copied.sha256,
            snapshotId = prepared.snapshotId,
        )
    }

    /**
     * Removes one unhanded snapshot. Runs in [NonCancellable] so cancellation
     * cannot skip cleanup; returns a cleanup error instead of pretending the
     * directory was removed.
     */
    private suspend fun discardSnapshot(prepared: PreparedSnapshot): Throwable? =
        withContext(NonCancellable) {
            mutex.withLock {
                activeSnapshots.remove(prepared.snapshotId)
                deleteSnapshotDirectoryLocked(prepared.directory)
            }
        }

    private fun deleteSnapshotDirectoryLocked(directory: File): Throwable? {
        if (Files.isSymbolicLink(directory.toPath())) {
            return IOException("Refusing to delete a symlinked snapshot directory.")
        }
        return runCatching {
            if (Files.exists(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                deleteTreeNoFollow(directory.toPath(), rootDir.toPath())
            }
        }.exceptionOrNull()
    }

    private fun snapshotCleanupFailure(cleanup: Throwable, original: Throwable): MeetingException {
        val failure = storageFailure(cleanup, "snapshotCleanup")
        failure.addSuppressed(original)
        return failure
    }

    private fun snapshotCopyFailure(error: IOException): MeetingException {
        val message = error.message.orEmpty()
        val noSpace = message.contains("ENOSPC", ignoreCase = true) ||
            message.contains("No space left", ignoreCase = true)
        return storageFailure(error, if (noSpace) "snapshotNoSpace" else "snapshotCopy")
    }

    /**
     * Bounded recovery of snapshot directories left by a dead process.
     *
     * Only UUID-named directories under this meeting's snapshot namespace are
     * considered. A directory with a live in-process lease is never touched.
     * A directory whose metadata names a different owner is left alone (its
     * ownership is unknown). Missing metadata is accepted only for an old
     * directory, which can only be an interrupted copy created by this store.
     */
    private fun recoverStaleSnapshotsLocked(meetingDir: File, meetingId: String, now: Long) {
        val root = existingSnapshotsDirLocked(meetingDir) ?: return
        val children = root.listFiles() ?: return
        for (child in children) {
            if (!MeetingIds.isValid(child.name)) continue
            if (activeSnapshots.containsKey(child.name)) continue
            if (Files.isSymbolicLink(child.toPath())) continue
            if (!child.isDirectory) continue
            val meta = runCatching { readSnapshotMetaLocked(child) }.getOrNull()
            if (meta != null &&
                (meta.snapshotId != child.name || meta.meetingId != meetingId)
            ) {
                continue
            }
            val created = meta?.createdAtMillis ?: child.lastModified()
            if (created <= 0L || created > now) continue
            if (now - created < MEETING_SNAPSHOT_STALE_MILLIS) continue
            runCatching { deleteTreeNoFollow(child.toPath(), rootDir.toPath()) }
        }
    }

    private fun writeSnapshotMetaLocked(directory: File, meta: SnapshotMetadata) {
        val target = childFileLocked(directory, MEETING_SNAPSHOT_META_FILE, "snapshotMeta")
        val temp = File(directory, "$MEETING_SNAPSHOT_META_FILE.tmp-${UUID.randomUUID()}")
        try {
            val bytes = buildJsonObject {
                put("schemaVersion", 1)
                put("snapshotId", meta.snapshotId)
                put("meetingId", meta.meetingId)
                put("materialId", meta.materialId)
                put("sourceBytes", meta.sourceBytes)
                put("sourceSha256", meta.sourceSha256)
                put("durationMillis", meta.durationMillis)
                put("transcriptionRevision", meta.transcriptionRevision)
                put("createdAtMillis", meta.createdAtMillis)
            }.toString().toByteArray(Charsets.UTF_8)
            FileOutputStream(temp).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            moveAtomically(temp, target)
            fsyncDirectory(directory)
        } catch (error: Exception) {
            runCatching { temp.delete() }
            throw storageFailure(error, "snapshotMeta")
        } finally {
            if (temp.exists()) runCatching { temp.delete() }
        }
    }

    private fun readSnapshotMetaLocked(directory: File): SnapshotMetadata? {
        val file = File(directory, MEETING_SNAPSHOT_META_FILE)
        if (Files.isSymbolicLink(file.toPath())) return null
        if (!file.isFile) return null
        if (file.length() <= 0L || file.length() > MAX_SNAPSHOT_META_BYTES) return null
        val obj = try {
            Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
        } catch (_: Exception) {
            return null
        }
        val snapshotId = obj.stringOrNull("snapshotId") ?: return null
        val meetingId = obj.stringOrNull("meetingId") ?: return null
        val materialId = obj.stringOrNull("materialId") ?: return null
        val sha256 = obj.stringOrNull("sourceSha256") ?: return null
        if (!MeetingIds.isValid(snapshotId) ||
            !MeetingIds.isValid(meetingId) ||
            !MeetingIds.isValid(materialId) ||
            !SHA256_PATTERN.matches(sha256)
        ) {
            return null
        }
        val sourceBytes = obj.longOrNull("sourceBytes") ?: return null
        val durationMillis = obj.longOrNull("durationMillis") ?: return null
        val transcriptionRevision = obj.longOrNull("transcriptionRevision") ?: return null
        val createdAtMillis = obj.longOrNull("createdAtMillis") ?: return null
        if (sourceBytes <= 0L || sourceBytes > MEETING_MAX_SNAPSHOT_BYTES) return null
        if (durationMillis <= 0L || createdAtMillis <= 0L) return null
        if (transcriptionRevision < 0L) return null
        return SnapshotMetadata(
            snapshotId = snapshotId,
            meetingId = meetingId,
            materialId = materialId,
            sourceBytes = sourceBytes,
            sourceSha256 = sha256,
            durationMillis = durationMillis,
            transcriptionRevision = transcriptionRevision,
            createdAtMillis = createdAtMillis,
        )
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
        val stagedUnresolved = stagedFile.absoluteFile
        val staged = if (stagedUnresolved.parentFile?.path == imports.path) {
            childFileLocked(imports, stagedUnresolved.name, "importStaging")
        } else {
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
            val interruptedLive = ArrayList<String>()
            val recordings = stored.recordings.map { recording ->
                if (recording.id in excludedRecordingIds || recording.state !in ACTIVE_RECORDING_STATES) {
                    return@map recording
                }
                val extension = recordingExtension(recording.mimeType)
                val final = recordingFileLocked(dir, recording.id, final = true, extension)
                val part = recordingFileLocked(dir, recording.id, final = false, extension)
                changed = true
                val recovered = when {
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
                        // A PCM WAV written by the live-capture path has no
                        // unfinalized container index: repairing its header
                        // makes the retained capture playable, so adopt it
                        // instead of discarding a valid interrupted take.
                        val adopted = extension == "wav" &&
                            repairPcmWavHeader(part) &&
                            runCatching { moveAtomically(part, final) }.isSuccess &&
                            final.isFile && final.length() > 44
                        if (adopted) {
                            val probed = runCatching { probe(final) }.getOrNull()
                            if (probed != null && probed.readable && probed.hasAudio) {
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
                        } else {
                            meetingIncomplete++
                            recording.copy(
                                state = RECORDING_INCOMPLETE,
                                sizeBytes = part.length(),
                                durationMillis = maxOf(recording.durationMillis, recording.accumulatedMillis),
                                incompleteReason = "interrupted",
                            )
                        }
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
                interruptedLive += recording.id
                recovered
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
            interruptedLive.forEach { recordingId ->
                runCatching { markLiveInterruptedLocked(dir, recordingId, now) }
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
        if (Files.isSymbolicLink(rawRoot.toPath())) {
            throw storageFailure(IOException("symlink"), "meetingRoot")
        }
        if (rootDir.isDirectory) return
        if (!rootDir.mkdirs() && !rootDir.isDirectory) {
            throw storageFailure(IOException("mkdirs"), "meetingRoot")
        }
    }

    private fun meetingDirLocked(id: String): File {
        val unresolved = File(rootDir, id)
        if (Files.isSymbolicLink(unresolved.toPath())) throw invalidIdentifier(id)
        val dir = try {
            unresolved.canonicalFile
        } catch (error: IOException) {
            throw storageFailure(error, "meetingDir")
        }
        if (dir.parentFile?.path != rootDir.path || dir.name != id) throw invalidIdentifier(id)
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

    /**
     * Resolves one owned child directory whose unresolved leaf and canonical
     * parent must both be exactly what the caller expects. A symlink is never
     * followed, even when it points back inside the meeting root.
     */
    private fun existingChildDirectoryLocked(parent: File, name: String, detail: String): File? {
        val unresolved = File(parent, name)
        if (Files.isSymbolicLink(unresolved.toPath())) {
            throw storageFailure(IOException("symlink"), detail)
        }
        if (!unresolved.exists()) return null
        if (!unresolved.isDirectory) {
            throw storageFailure(IOException("notDirectory"), detail)
        }
        val dir = try {
            unresolved.canonicalFile
        } catch (error: IOException) {
            throw storageFailure(error, detail)
        }
        if (dir.parentFile?.path != parent.path || dir.name != name) {
            throw storageFailure(IOException("alias"), detail)
        }
        return dir
    }

    private fun childDirectoryLocked(parent: File, name: String, detail: String): File {
        existingChildDirectoryLocked(parent, name, detail)?.let { return it }
        val unresolved = File(parent, name)
        var created = false
        try {
            created = unresolved.mkdirs()
            if (!created && !unresolved.isDirectory) {
                throw storageFailure(IOException("mkdirs"), detail)
            }
            return existingChildDirectoryLocked(parent, name, detail)
                ?: throw storageFailure(IOException("mkdirs"), detail)
        } catch (error: Throwable) {
            // A directory this call created is empty and unreferenced; never
            // leave it behind when the following validation fails. Never
            // delete through a path that has since become a symlink.
            if (created && !Files.isSymbolicLink(unresolved.toPath())) {
                val cleanup = runCatching {
                    deleteTreeNoFollow(unresolved.toPath(), rootDir.toPath())
                }.exceptionOrNull()
                if (cleanup != null) error.addSuppressed(cleanup)
            }
            throw error
        }
    }

    /** Resolves a file leaf without ever following a final-component symlink. */
    private fun childFileLocked(parent: File, name: String, detail: String): File {
        val unresolved = File(parent, name)
        if (Files.isSymbolicLink(unresolved.toPath())) {
            throw storageFailure(IOException("symlink"), detail)
        }
        val file = try {
            unresolved.canonicalFile
        } catch (error: IOException) {
            throw storageFailure(error, detail)
        }
        if (file.parentFile?.path != parent.path || file.name != name) {
            throw storageFailure(IOException("alias"), detail)
        }
        return file
    }

    private fun recordingsDirLocked(meetingDir: File): File =
        childDirectoryLocked(meetingDir, MEETING_RECORDINGS_DIR, "recordings")

    private fun importDirLocked(meetingDir: File): File =
        childDirectoryLocked(meetingDir, MEETING_IMPORTS_DIR, "imports")

    private fun snapshotsDirLocked(meetingDir: File): File =
        childDirectoryLocked(meetingDir, MEETING_SNAPSHOTS_DIR, "snapshots")

    private fun existingSnapshotsDirLocked(meetingDir: File): File? =
        existingChildDirectoryLocked(meetingDir, MEETING_SNAPSHOTS_DIR, "snapshots")

    private fun snapshotDirLocked(snapshots: File, snapshotId: String, create: Boolean): File {
        if (create) return childDirectoryLocked(snapshots, snapshotId, "snapshot")
        return existingChildDirectoryLocked(snapshots, snapshotId, "snapshot")
            ?: throw storageFailure(IOException("missing"), "snapshot")
    }

    internal fun recordingFileLocked(
        meetingDir: File,
        recordingId: String,
        final: Boolean,
        extension: String = "m4a",
    ): File {
        val dir = recordingsDirLocked(meetingDir)
        val safeExtension = if (extension == "wav") "wav" else "m4a"
        val name = if (final) {
            "$recordingId.$safeExtension"
        } else {
            "$recordingId.$safeExtension.part"
        }
        return childFileLocked(dir, name, "recordingFile")
    }

    internal fun importFileLocked(meetingDir: File, imported: StoredImport): File {
        val dir = importDirLocked(meetingDir)
        return childFileLocked(dir, "${imported.id}.${imported.extension}", "importFile")
    }

    /**
     * Verifies the already-canonical file and every meeting-owned ancestor up
     * to [meetingDir] is still not a symlink. This is a fail-closed check
     * immediately before a read/open, not a replacement for the per-leaf
     * checks performed while resolving each path component.
     */
    private fun assertNoSymlinkAncestry(meetingDir: File, file: File, detail: String) {
        if (Files.isSymbolicLink(meetingDir.toPath())) {
            throw storageFailure(IOException("symlink"), detail)
        }
        if (!file.path.startsWith(meetingDir.path + File.separator)) {
            throw storageFailure(IOException("outside"), detail)
        }
        var current: File? = file
        while (current != null) {
            if (Files.isSymbolicLink(current.toPath())) {
                throw storageFailure(IOException("symlink"), detail)
            }
            if (current.path == meetingDir.path) return
            current = current.parentFile
        }
        throw storageFailure(IOException("outside"), detail)
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    private fun readMeetingLocked(dir: File, expectedId: String): StoredMeeting {
        val file = childFileLocked(dir, MEETING_META_FILE, "meetingMeta")
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
        val target = childFileLocked(dir, MEETING_META_FILE, "meetingMeta")
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
            liveTranscription = runCatching {
                val root = existingLiveRootLocked(dir) ?: return@runCatching null
                root.listFiles()
                    ?.asSequence()
                    ?.filter { it.isDirectory && MeetingIds.isValid(it.name) }
                    ?.filter { child -> !Files.isSymbolicLink(child.toPath()) }
                    ?.sortedByDescending { it.lastModified() }
                    ?.mapNotNull { child -> readLiveTranscriptionLocked(dir, stored, child.name) }
                    ?.firstOrNull()
            }.getOrNull(),
        )
    }

    private fun recordingMaterialLocked(
        dir: File,
        meetingId: String,
        recording: StoredRecording,
    ): MeetingMaterial {
        val extension = recordingExtension(recording.mimeType)
        val finalFile = recordingFileLocked(dir, recording.id, final = true, extension)
        val partFile = recordingFileLocked(dir, recording.id, final = false, extension)
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
            putNullable("materialId", stored.transcription.materialId)
            val attempt = stored.transcription.lastAttempt
            if (attempt != null) {
                put("lastAttempt", buildJsonObject {
                    put("materialId", attempt.materialId)
                    put("expectedTranscriptionRevision", attempt.expectedTranscriptionRevision)
                    put("phase", attempt.phase)
                    putNullable("failureCode", attempt.failureCode)
                    putNullable("failureReason", attempt.failureReason)
                    put("retryable", attempt.retryable)
                    put("updatedAtMillis", attempt.updatedAtMillis)
                })
            } else {
                put("lastAttempt", JsonNull)
            }
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
            materialId = obj.stringOrNull("materialId")
                ?.takeIf { MeetingIds.isValid(it) },
            segments = segments,
            lastAttempt = decodeTranscriptionAttempt(obj["lastAttempt"] as? JsonObject),
        )
    }

    /**
     * Reads one attempt checkpoint. Unknown/absent shapes are ignored rather
     * than failing the whole meeting read: the record is advisory recovery
     * metadata, never transcript content.
     */
    private fun decodeTranscriptionAttempt(obj: JsonObject?): StoredTranscriptionAttempt? {
        if (obj == null) return null
        val materialId = obj.stringOrNull("materialId")?.takeIf { MeetingIds.isValid(it) } ?: return null
        val phase = obj.stringOrNull("phase")?.takeIf { it in StoredTranscriptionAttempt.ALL_PHASES }
            ?: return null
        return StoredTranscriptionAttempt(
            materialId = materialId,
            expectedTranscriptionRevision = obj.longOrNull("expectedTranscriptionRevision")?.coerceAtLeast(0L) ?: 0L,
            phase = phase,
            failureCode = obj.stringOrNull("failureCode")?.take(64),
            failureReason = obj.stringOrNull("failureReason")?.take(160),
            retryable = obj.booleanOrNull("retryable") == true,
            updatedAtMillis = obj.longOrNull("updatedAtMillis")?.coerceAtLeast(0L) ?: 0L,
        )
    }

    private fun StoredTranscription.toPublic(): MeetingTranscription = MeetingTranscription(
        schemaVersion = schemaVersion,
        revision = revision,
        language = language,
        updatedAtMillis = updatedAtMillis,
        materialId = materialId,
        segments = segments.map {
            MeetingTranscriptSegment(
                id = it.id,
                startMillis = it.startMillis,
                endMillis = it.endMillis,
                text = it.text,
                speaker = it.speaker,
            )
        },
        lastAttempt = lastAttempt?.let {
            MeetingTranscriptionLastAttempt(
                materialId = it.materialId,
                expectedTranscriptionRevision = it.expectedTranscriptionRevision,
                phase = when (it.phase) {
                    StoredTranscriptionAttempt.PHASE_RUNNING ->
                        MeetingTranscriptionLastAttemptPhase.RUNNING
                    StoredTranscriptionAttempt.PHASE_CANCELLED ->
                        MeetingTranscriptionLastAttemptPhase.CANCELLED
                    else -> MeetingTranscriptionLastAttemptPhase.FAILED
                },
                failureCode = it.failureCode,
                failureReason = it.failureReason,
                retryable = it.retryable,
                updatedAtMillis = it.updatedAtMillis,
            )
        },
    )

    private data class ActiveSnapshot(
        val meetingId: String,
        val materialId: String,
    )

    private data class SourceIdentity(
        val fileKey: Any?,
        val size: Long,
        val modifiedMillis: Long,
    )

    private data class PreparedSnapshot(
        val meetingId: String,
        val materialId: String,
        val snapshotId: String,
        val directory: File,
        val source: File,
        val identity: SourceIdentity,
        val durationMillis: Long,
    )

    private data class CopiedSource(
        val bytes: Long,
        val sha256: String,
    )

    private data class SnapshotMetadata(
        val snapshotId: String,
        val meetingId: String,
        val materialId: String,
        val sourceBytes: Long,
        val sourceSha256: String,
        val durationMillis: Long,
        val transcriptionRevision: Long,
        val createdAtMillis: Long,
    )

    companion object {
        private const val MAX_METADATA_BYTES = 8L * 1024L * 1024L
        private const val MAX_SNAPSHOT_META_BYTES = 64L * 1024L
        private val EXTENSION_PATTERN = Regex("^[a-z0-9]{1,8}$")

        private const val MIN_LIVE_CHUNK_SECONDS = 10
        private const val MAX_LIVE_CHUNK_SECONDS = 60

        private const val LIVE_RECORDING = "RECORDING"
        private const val LIVE_DRAINING = "DRAINING"
        private const val LIVE_COMPLETED = "COMPLETED"
        private const val LIVE_FAILED = "FAILED"
        private const val LIVE_CANCELLED = "CANCELLED"
        private const val LIVE_INTERRUPTED = "INTERRUPTED"

        private const val LIVE_FRAGMENT_PENDING = "PENDING"
        private const val LIVE_FRAGMENT_CONFIRMED = "CONFIRMED"
        private const val LIVE_FRAGMENT_FAILED = "FAILED"

        private val LIVE_STATES = setOf(
            LIVE_RECORDING,
            LIVE_DRAINING,
            LIVE_COMPLETED,
            LIVE_FAILED,
            LIVE_CANCELLED,
            LIVE_INTERRUPTED,
        )
        private val LIVE_FRAGMENT_STATES = setOf(
            LIVE_FRAGMENT_PENDING,
            LIVE_FRAGMENT_CONFIRMED,
            LIVE_FRAGMENT_FAILED,
        )
        private val LIVE_FRAGMENT_FILE_PATTERN = Regex("^fragment-[0-9]{5}\\.wav$")
        private val LIVE_FRAGMENT_SIDECAR_PATTERN = Regex("^fragment-[0-9]{5}\\.json$")

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

/** Storage extension for one recording. Unknown/legacy mime keeps `.m4a`. */
internal fun recordingExtension(mimeType: String?): String =
    if (mimeType == MEETING_RECORDING_WAV_MIME) "wav" else "m4a"

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
    if (Files.isSymbolicLink(path)) {
        throw IOException("Refusing to delete a symlink.")
    }
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

/** Exact lower-case hex required for a source digest. */
private val SHA256_PATTERN = Regex("^[0-9a-f]{64}$")

internal fun requireSha256Hex(raw: String): String {
    if (!SHA256_PATTERN.matches(raw)) {
        throw meetingError(
            MeetingErrorCode.INVALID_INPUT,
            "The transcription source digest is invalid.",
            detail = "sourceSha256",
        )
    }
    return raw
}

private fun sha256Hex(digest: ByteArray): String =
    digest.joinToString("") { "%02x".format(it) }

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

internal fun JsonObject.longOrNull(key: String): Long? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
}

private fun JsonObject.requiredLong(key: String): Long =
    longOrNull(key) ?: throw meetingError(MeetingErrorCode.INTERRUPTED, "Meeting metadata is missing $key.")

internal fun JsonObject.intOrNull(key: String): Int? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull?.toIntOrNull()
}

private fun JsonObject.booleanOrNull(key: String): Boolean? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()
}
