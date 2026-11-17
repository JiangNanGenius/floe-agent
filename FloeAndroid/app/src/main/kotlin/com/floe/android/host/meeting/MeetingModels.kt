// SPDX-License-Identifier: MPL-2.0
//
// Independent meeting domain for Android Space.
//
// Meetings are app-owned durable records: a meeting is not a task, project,
// conversation or workspace, and no id from those domains is used here. The
// types below are the only UI-facing contract. The coordinator owns the
// Compose screens; this package owns storage, import, recording and playback.
package com.floe.android.host.meeting

import kotlinx.coroutines.flow.StateFlow
import java.io.File

/**
 * One durable meeting summary, derived from `meeting.json` on every refresh.
 *
 * [metadataCorrupt] is true only when the meeting directory still exists but
 * its metadata cannot be parsed. The files are intentionally retained so a
 * later repair can recover them; [MeetingManager.meeting] throws for such a
 * record instead of presenting invented contents.
 */
data class MeetingSummary(
    val id: String,
    val title: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val notesPreview: String,
    val materialCount: Int,
    val recordingCount: Int,
    val totalDurationMillis: Long,
    val hasIncompleteMedia: Boolean,
    val revision: Long,
    val metadataCorrupt: Boolean = false,
)

/**
 * One meeting with durable notes, versioned transcription and its ordered
 * material list. [materials] is the authoritative order; [recordings] and
 * [imports] are filtered convenience views over the same objects.
 */
data class MeetingDetail(
    val id: String,
    val title: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val notes: String,
    val notesRevision: Long,
    val revision: Long,
    val transcription: MeetingTranscription,
    val materials: List<MeetingMaterial>,
    val recordings: List<MeetingMaterial>,
    val imports: List<MeetingMaterial>,
)

/** Attribution of one audio or video file to a meeting. */
data class MeetingMaterial(
    val id: String,
    val meetingId: String,
    val kind: MeetingMaterialKind,
    val displayName: String,
    val order: Long,
    val createdAtMillis: Long,
    val durationMillis: Long,
    val sizeBytes: Long,
    val status: MeetingMaterialStatus,
    val isPlayable: Boolean,
    val mimeType: String?,
    val incompleteReason: String?,
)

enum class MeetingMaterialKind { RECORDING, AUDIO_IMPORT, VIDEO_IMPORT }

enum class MeetingMaterialStatus { RECORDING, PAUSED, FINALIZING, COMPLETED, INCOMPLETE, MISSING }

/**
 * Versioned transcription storage. Android has no local speech model in this
 * round, so a meeting always starts empty. The fields are preserved verbatim
 * by rename/notes edits until a real transcription producer writes them.
 */
data class MeetingTranscription(
    val schemaVersion: Int = SCHEMA_VERSION,
    val revision: Long = 0L,
    val language: String? = null,
    val updatedAtMillis: Long? = null,
    /** Exact app-owned material this transcript was produced from. */
    val materialId: String? = null,
    val segments: List<MeetingTranscriptSegment> = emptyList(),
) {
    companion object {
        const val SCHEMA_VERSION = 1
        val EMPTY = MeetingTranscription()
    }
}

/**
 * Durable receipt for one committed meeting transcription.
 *
 * [transcriptionRevision] is the compare-and-swap revision of the transcript
 * document, not the meeting's general metadata revision. [idempotent] is true
 * when an exact retry of an already-committed result was observed and no
 * second write occurred.
 */
data class MeetingTranscriptionReceipt(
    val meetingId: String,
    val materialId: String,
    val transcriptionRevision: Long,
    val segmentCount: Int,
    val updatedAtMillis: Long,
    val idempotent: Boolean,
)

data class MeetingTranscriptSegment(
    val id: String,
    val startMillis: Long,
    val endMillis: Long,
    val text: String,
    val speaker: String?,
)

/** Observable state of the single process-wide recording owner. */
data class MeetingRecordingState(
    val phase: MeetingRecordingPhase,
    val meetingId: String?,
    val recordingId: String?,
    val startedAtMillis: Long?,
    val elapsedMillis: Long,
    val error: MeetingError?,
)

enum class MeetingRecordingPhase { IDLE, STARTING, RECORDING, PAUSED, STOPPING, COMPLETED, FAILED }

/**
 * Public recording control. Only one recording may be active in the process.
 * [start] must be called from a user-visible, microphone-authorized context:
 * Android applies the while-in-use and background-FGS restrictions and this
 * implementation reports a denial instead of silently recording.
 *
 * [pause], [resume] and [stop] suspend until the durable metadata receipt is
 * written. [stop] returns an INCOMPLETE material when the platform could not
 * finalize the container; the bytes are retained and are not claimed playable.
 * [discard] is the only destructive operation and applies only to the current
 * take.
 */
interface MeetingRecorder {
    val state: StateFlow<MeetingRecordingState>

    suspend fun start(meetingId: String): MeetingMaterial
    suspend fun pause(): MeetingMaterial
    suspend fun resume(): MeetingMaterial
    suspend fun stop(): MeetingMaterial
    suspend fun discard(): MeetingMaterial?
}

/** Public playback control for one app-owned material file. */
interface MeetingPlayer {
    val state: StateFlow<MeetingPlayerState>

    fun play()
    fun pause()
    fun seekTo(positionMillis: Long)
    fun release()
}

data class MeetingPlayerState(
    val status: MeetingPlayerStatus,
    val positionMillis: Long,
    val durationMillis: Long,
    val error: MeetingError?,
)

enum class MeetingPlayerStatus { IDLE, PREPARING, PLAYING, PAUSED, ENDED, ERROR, RELEASED }

data class MeetingPermissionState(
    val microphoneGranted: Boolean,
    val notificationsGranted: Boolean,
    val notificationsRuntimeRequired: Boolean,
)

/** Typed failure code carried by [MeetingException] and observable states. */
enum class MeetingErrorCode {
    PERMISSION_REQUIRED,
    NOT_FOUND,
    INVALID_IDENTIFIER,
    INVALID_INPUT,
    CONFLICT,
    SOURCE_UNAVAILABLE,
    UNSUPPORTED_MEDIA,
    CORRUPT_MEDIA,
    TOO_LARGE,
    STORAGE_FAILURE,
    RECORDING_BUSY,
    RECORDING_NOT_ACTIVE,
    RECORDING_START_DENIED,
    RECORDING_FAILED,
    INTERRUPTED,
    PLAYBACK_FAILED,
    MISSING_MEDIA,
}

data class MeetingError(
    val code: MeetingErrorCode,
    val message: String,
    val retryable: Boolean,
    val detail: String? = null,
)

/** The only failure type thrown by [MeetingManager] and [MeetingRecorder]. */
class MeetingException(
    val error: MeetingError,
    cause: Throwable? = null,
) : Exception(error.message, cause) {
    val code: MeetingErrorCode get() = error.code
}

data class MeetingRecoveryReport(
    val recoveredCompleted: Int,
    val markedIncomplete: Int,
    val missingFiles: Int,
)

internal fun meetingError(
    code: MeetingErrorCode,
    message: String,
    retryable: Boolean = false,
    detail: String? = null,
    cause: Throwable? = null,
): MeetingException = MeetingException(
    MeetingError(code = code, message = message, retryable = retryable, detail = detail),
    cause,
)

internal fun notFound(id: String): MeetingException =
    meetingError(MeetingErrorCode.NOT_FOUND, "Meeting or material was not found.", detail = id)

internal fun invalidIdentifier(value: String): MeetingException =
    meetingError(
        MeetingErrorCode.INVALID_IDENTIFIER,
        "Invalid meeting or material identifier.",
        detail = value.take(160),
    )

internal fun storageFailure(cause: Throwable, detail: String): MeetingException =
    meetingError(
        MeetingErrorCode.STORAGE_FAILURE,
        "Meeting storage is unavailable.",
        retryable = true,
        detail = detail,
        cause = cause,
    )

/** Where a resolved material file lives; used internally only. */
internal data class ResolvedMaterial(
    val material: MeetingMaterial,
    val file: File,
)

/**
 * One private, immutable-for-one-attempt copy of an exact transcript source.
 *
 * [file] is an app-owned file under the meeting's snapshot namespace, never a
 * caller-supplied path. [sourceBytes] and [sourceSha256] identify the exact
 * bytes copied from the original material; [commitTranscription] re-hashes the
 * current original and refuses a mismatch. [snapshotId] is the only handle
 * accepted by [MeetingRepository.releaseTranscriptionSource].
 */
internal data class MeetingTranscriptionSnapshot(
    val material: MeetingMaterial,
    val file: File,
    val durationMillis: Long,
    val transcriptionRevision: Long,
    val sourceBytes: Long,
    val sourceSha256: String,
    val snapshotId: String,
)
