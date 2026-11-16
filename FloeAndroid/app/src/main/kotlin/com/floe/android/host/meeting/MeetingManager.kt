// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.content.Context
import android.net.Uri
import com.floe.android.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * UI-facing meeting entry point.
 *
 * ```kotlin
 * val manager = MeetingManager(context)
 * val meetings by manager.meetings.collectAsState()
 * val recorderState by manager.recorder.state.collectAsState()
 * ```
 *
 * Construction is cheap and never blocks on disk; [ready] becomes true after
 * the initial crash recovery and catalog scan finish. Every suspend mutation
 * throws [MeetingException] with a typed [MeetingError]. The manager is a thin
 * facade over one process-wide store, so creating another instance does not
 * create a second catalog. [close] releases nothing shared and is safe to call
 * when a screen disposes.
 */
class MeetingManager(context: Context) {
    private val appContext: Context = context.applicationContext
    private val store = MeetingStoreRegistry.get(appContext)
    private val repository = store.repository
    private val importer = MeetingMediaImporter(appContext, repository)
    private val recordingController = MeetingRecordingController(appContext)
    private val permissionFlow = MutableStateFlow(MeetingPermissions.state(appContext))

    val meetings: StateFlow<List<MeetingSummary>> = repository.summaries
    val ready: StateFlow<Boolean> = store.ready
    val permission: StateFlow<MeetingPermissionState> = permissionFlow.asStateFlow()
    val recorder: MeetingRecorder = recordingController

    init {
        store.ensureLoaded(MeetingMediaProbe::probe)
    }

    /** Re-scans the durable catalog; does not change notes or files. */
    suspend fun refresh(): List<MeetingSummary> = withContext(Dispatchers.IO) {
        repository.refresh()
    }

    suspend fun createMeeting(title: String? = null): MeetingDetail = withContext(Dispatchers.IO) {
        val fallback = appContext.getString(R.string.meeting_default_title)
        repository.createMeeting(MeetingText.title(title ?: "", fallback))
    }

    suspend fun renameMeeting(meetingId: String, title: String): MeetingDetail =
        withContext(Dispatchers.IO) {
            val fallback = appContext.getString(R.string.meeting_default_title)
            repository.renameMeeting(meetingId, MeetingText.title(title, fallback))
        }

    /**
     * Persists notes and bumps only the notes revision. The transcription
     * object and all materials are preserved byte-for-byte. Supplying the
     * current [expectedNotesRevision] turns a concurrent edit into a typed
     * CONFLICT instead of silently overwriting another editor.
     */
    suspend fun updateNotes(
        meetingId: String,
        notes: String,
        expectedNotesRevision: Long? = null,
    ): MeetingDetail = withContext(Dispatchers.IO) {
        repository.updateNotes(meetingId, notes, expectedNotesRevision)
    }

    /**
     * Streams the selected audio/video content into app-owned storage, probes
     * it with the platform extractor, then atomically commits the metadata.
     * The caller's Uri is never retained; it only needs to be readable for the
     * duration of this call.
     */
    suspend fun importMedia(
        meetingId: String,
        uri: Uri,
        displayName: String? = null,
    ): MeetingMaterial = withContext(Dispatchers.IO) {
        importer.import(meetingId, uri, displayName)
    }

    suspend fun meeting(meetingId: String): MeetingDetail = withContext(Dispatchers.IO) {
        repository.detail(meetingId)
    }

    /**
     * Refuses to delete a meeting with an active take, moves the whole meeting
     * directory out of the live namespace atomically, then removes it without
     * following symlinks. Existing other meetings are untouched.
     */
    suspend fun deleteMeeting(meetingId: String): Boolean {
        MeetingIds.require(meetingId)
        val active = MeetingRecordingRuntime.state.value
        if (active.phase in MeetingRecordingRuntime.ACTIVE_PHASES && active.meetingId == meetingId) {
            throw meetingError(
                MeetingErrorCode.RECORDING_BUSY,
                "A recording is still active for this meeting.",
                retryable = true,
                detail = meetingId,
            )
        }
        return withContext(Dispatchers.IO) { repository.deleteMeeting(meetingId) }
    }

    /**
     * Marks interrupted active recordings as recoverable INCOMPLETE (or
     * adopts a finalized file that a crash left unreferenced). The live
     * recording id is excluded so an explicit call never disturbs capture.
     */
    suspend fun recoverInterrupted(): MeetingRecoveryReport = withContext(Dispatchers.IO) {
        repository.recoverInterrupted(
            probe = MeetingMediaProbe::probe,
            excludedRecordingIds = recordingController.activeRecordingIds(),
        )
    }

    /**
     * Builds a real MediaPlayer for a finalized recording or verified import.
     * A missing, interrupted or unfinalized file throws before a player is
     * returned; playback errors after that are reported through
     * [MeetingPlayerState.error].
     */
    suspend fun playerFor(meetingId: String, materialId: String): MeetingPlayer {
        val resolved = withContext(Dispatchers.IO) {
            repository.resolvedMaterial(meetingId, materialId)
        }
        return MeetingMediaPlayer(resolved.file, resolved.material.durationMillis)
    }

    fun requiredPermissions(): List<String> = MeetingPermissions.required()

    fun refreshPermissionState() {
        permissionFlow.value = MeetingPermissions.state(appContext)
    }

    /** No shared resources are released; the process-wide store remains. */
    fun close() = Unit
}
