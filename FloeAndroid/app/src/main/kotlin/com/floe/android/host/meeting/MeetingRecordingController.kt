// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.floe.android.R
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Public recording control facade. Start is gated by the real microphone
 * permission; Android still enforces the user-visible/FGS start rules and a
 * denial is surfaced. Pause/resume/stop/discard are delivered to the
 * non-exported service and wait for the matching durable state transition.
 */
internal class MeetingRecordingController(context: Context) : MeetingRecorder {
    private val appContext: Context = context.applicationContext
    private val repository = MeetingStoreRegistry.get(appContext).repository

    override val state: StateFlow<MeetingRecordingState> = MeetingRecordingRuntime.state

    override suspend fun start(
        meetingId: String,
        liveCloudTranscription: Boolean,
    ): MeetingMaterial {
        val id = MeetingIds.require(meetingId)
        if (ContextCompat.checkSelfPermission(appContext, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            throw meetingError(
                MeetingErrorCode.PERMISSION_REQUIRED,
                "Microphone access is required to record a meeting.",
            )
        }
        if (MeetingRecordingRuntime.state.value.phase in MeetingRecordingRuntime.ACTIVE_PHASES) {
            throw meetingError(
                MeetingErrorCode.RECORDING_BUSY,
                "Another recording is already active.",
                retryable = true,
                detail = MeetingRecordingRuntime.state.value.recordingId,
            )
        }
        val detail = withContext(Dispatchers.IO) { repository.detail(id) }
        val fallbackName = appContext.getString(
            R.string.meeting_recording_name,
            detail.recordings.size + 1,
        )
        val draft = withContext(Dispatchers.IO) {
            repository.createRecordingDraft(
                meetingId = id,
                displayName = fallbackName,
                liveAudio = liveCloudTranscription,
            )
        }
        val startIntent = Intent(appContext, MeetingRecordingService::class.java)
            .setAction(MeetingRecordingService.ACTION_START)
            .putExtra(MeetingRecordingService.EXTRA_MEETING_ID, id)
            .putExtra(MeetingRecordingService.EXTRA_RECORDING_ID, draft.id)
            .putExtra(MeetingRecordingService.EXTRA_LIVE_CLOUD, liveCloudTranscription)
        try {
            ContextCompat.startForegroundService(appContext, startIntent)
        } catch (error: Exception) {
            withContext(Dispatchers.IO) {
                runCatching { repository.failRecordingStart(id, draft.id, "serviceStartDenied") }
            }
            throw meetingError(
                MeetingErrorCode.RECORDING_START_DENIED,
                "Android did not allow the recording service to start. Open the app and try again.",
                retryable = true,
                detail = error.javaClass.simpleName,
                cause = error,
            )
        }
        val accepted = withTimeoutOrNull(START_TIMEOUT_MILLIS) {
            MeetingRecordingRuntime.state.first {
                it.recordingId == draft.id &&
                    (it.phase == MeetingRecordingPhase.RECORDING || it.phase == MeetingRecordingPhase.FAILED)
            }
        }
        if (accepted == null) {
            runCatching { sendCommand(MeetingRecordingService.ACTION_STOP, id, draft.id) }
            withTimeoutOrNull(STOP_AFTER_TIMEOUT_MILLIS) {
                MeetingRecordingRuntime.state.first {
                    it.recordingId == draft.id &&
                        (it.phase == MeetingRecordingPhase.COMPLETED || it.phase == MeetingRecordingPhase.FAILED)
                }
            }
            // The late take may have started after the timeout. Never rewrite
            // a material that now exists; only retire a draft that produced
            // nothing. Any service-side stop is bound to draft.id and cannot
            // stop a newer recording.
            val material = withContext(Dispatchers.IO) {
                runCatching { repository.material(id, draft.id) }.getOrNull()
            }
            val ownerStillLive = MeetingRecordingRuntime.matchesOwner(id, draft.id)
            // Retire a draft only when it never became the live owner and
            // never produced a terminal material. Never downgrade a take that
            // finalized while the timeout raced it.
            if (!ownerStillLive &&
                (material == null || material.status == MeetingMaterialStatus.RECORDING)
            ) {
                withContext(Dispatchers.IO) {
                    runCatching { repository.failRecordingStart(id, draft.id, "startTimeout") }
                }
            }
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "The recording did not start in time.",
                retryable = true,
                detail = draft.id,
            )
        }
        if (accepted.phase == MeetingRecordingPhase.FAILED) {
            throw MeetingException(
                accepted.error ?: MeetingError(
                    MeetingErrorCode.RECORDING_FAILED,
                    "The recording could not start.",
                    retryable = true,
                ),
            )
        }
        return withContext(Dispatchers.IO) { repository.material(id, draft.id) }
    }

    override suspend fun pause(): MeetingMaterial {
        val snapshot = MeetingRecordingRuntime.state.value
        val meetingId = snapshot.meetingId ?: throw recordingNotActive()
        val recordingId = snapshot.recordingId ?: throw recordingNotActive()
        if (snapshot.phase != MeetingRecordingPhase.RECORDING) throw recordingNotActive()
        sendCommand(MeetingRecordingService.ACTION_PAUSE, meetingId, recordingId)
        val next = awaitRecording(recordingId, PAUSE_TIMEOUT_MILLIS) {
            it.phase == MeetingRecordingPhase.PAUSED ||
                it.phase == MeetingRecordingPhase.FAILED ||
                it.phase == MeetingRecordingPhase.COMPLETED
        } ?: throw meetingError(
            MeetingErrorCode.INTERRUPTED,
            "The recording pause did not complete.",
            retryable = true,
        )
        if (next.phase == MeetingRecordingPhase.COMPLETED) {
            throw meetingError(
                MeetingErrorCode.RECORDING_NOT_ACTIVE,
                "The recording ended before it could pause.",
            )
        }
        if (next.phase != MeetingRecordingPhase.PAUSED) {
            val error = next.error
            if (error != null) throw MeetingException(error)
            throw recordingFailed()
        }
        if (next.error?.code == MeetingErrorCode.STORAGE_FAILURE) throw MeetingException(next.error)
        return withContext(Dispatchers.IO) { repository.material(meetingId, recordingId) }
    }

    override suspend fun resume(): MeetingMaterial {
        val snapshot = MeetingRecordingRuntime.state.value
        val meetingId = snapshot.meetingId ?: throw recordingNotActive()
        val recordingId = snapshot.recordingId ?: throw recordingNotActive()
        if (snapshot.phase != MeetingRecordingPhase.PAUSED) throw recordingNotActive()
        sendCommand(MeetingRecordingService.ACTION_RESUME, meetingId, recordingId)
        val next = awaitRecording(recordingId, RESUME_TIMEOUT_MILLIS) {
            it.phase == MeetingRecordingPhase.RECORDING ||
                it.phase == MeetingRecordingPhase.FAILED ||
                it.phase == MeetingRecordingPhase.COMPLETED
        } ?: throw meetingError(
            MeetingErrorCode.INTERRUPTED,
            "The recording resume did not complete.",
            retryable = true,
        )
        if (next.phase == MeetingRecordingPhase.COMPLETED) {
            throw meetingError(
                MeetingErrorCode.RECORDING_NOT_ACTIVE,
                "The recording ended before it could resume.",
            )
        }
        if (next.phase != MeetingRecordingPhase.RECORDING) {
            val error = next.error
            if (error != null) throw MeetingException(error)
            throw recordingFailed()
        }
        if (next.error?.code == MeetingErrorCode.STORAGE_FAILURE) throw MeetingException(next.error)
        return withContext(Dispatchers.IO) { repository.material(meetingId, recordingId) }
    }

    override suspend fun stop(): MeetingMaterial {
        val snapshot = MeetingRecordingRuntime.state.value
        val meetingId = snapshot.meetingId ?: throw recordingNotActive()
        val recordingId = snapshot.recordingId ?: throw recordingNotActive()
        if (snapshot.phase == MeetingRecordingPhase.STARTING) {
            // A user can stop a take that is still acquiring the microphone.
            // The service cancels that exact STARTING generation; nothing from
            // a newer take can be affected.
            sendCommand(MeetingRecordingService.ACTION_STOP, meetingId, recordingId)
            awaitRecording(recordingId, START_TIMEOUT_MILLIS) {
                it.phase == MeetingRecordingPhase.COMPLETED || it.phase == MeetingRecordingPhase.FAILED
            }
            val late = withContext(Dispatchers.IO) {
                runCatching { repository.material(meetingId, recordingId) }.getOrNull()
            }
            if (!MeetingRecordingRuntime.matchesOwner(meetingId, recordingId) &&
                (late == null || late.status == MeetingMaterialStatus.RECORDING)
            ) {
                withContext(Dispatchers.IO) {
                    runCatching {
                        repository.failRecordingStart(meetingId, recordingId, "startCancelled")
                    }
                }
            }
            if (late != null && late.status in setOf(
                    MeetingMaterialStatus.COMPLETED,
                    MeetingMaterialStatus.INCOMPLETE,
                    MeetingMaterialStatus.MISSING,
                )
            ) {
                return late
            }
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "The recording start was cancelled.",
                retryable = true,
                detail = recordingId,
            )
        }
        if (snapshot.phase != MeetingRecordingPhase.RECORDING &&
            snapshot.phase != MeetingRecordingPhase.PAUSED
        ) {
            throw recordingNotActive()
        }
        sendCommand(MeetingRecordingService.ACTION_STOP, meetingId, recordingId)
        val next = awaitRecording(recordingId, STOP_TIMEOUT_MILLIS) {
            it.phase == MeetingRecordingPhase.COMPLETED || it.phase == MeetingRecordingPhase.FAILED
        } ?: throw meetingError(
            MeetingErrorCode.INTERRUPTED,
            "The recording finalization is still running.",
            retryable = true,
            detail = recordingId,
        )
        val material = withContext(Dispatchers.IO) {
            runCatching { repository.material(meetingId, recordingId) }.getOrNull()
        }
        if (material != null && material.status in setOf(
                MeetingMaterialStatus.COMPLETED,
                MeetingMaterialStatus.INCOMPLETE,
                MeetingMaterialStatus.MISSING,
            )
        ) {
            return material
        }
        throw MeetingException(
            next.error ?: MeetingError(
                MeetingErrorCode.RECORDING_FAILED,
                "The recording could not be finalized.",
                retryable = true,
            ),
        )
    }

    override suspend fun discard(): MeetingMaterial? {
        val snapshot = MeetingRecordingRuntime.state.value
        val meetingId = snapshot.meetingId ?: throw recordingNotActive()
        val recordingId = snapshot.recordingId ?: throw recordingNotActive()
        if (snapshot.phase !in MeetingRecordingRuntime.ACTIVE_PHASES) throw recordingNotActive()
        sendCommand(MeetingRecordingService.ACTION_DISCARD, meetingId, recordingId)
        val next = withTimeoutOrNull(DISCARD_TIMEOUT_MILLIS) {
            MeetingRecordingRuntime.state.first {
                it.phase == MeetingRecordingPhase.IDLE || it.phase == MeetingRecordingPhase.FAILED
            }
        }
        if (next == null) {
            if (!MeetingRecordingRuntime.matchesOwner(meetingId, recordingId)) {
                withContext(Dispatchers.IO) {
                    runCatching {
                        repository.failRecordingStart(meetingId, recordingId, "discardTimeout")
                    }
                }
            }
            throw meetingError(
                MeetingErrorCode.INTERRUPTED,
                "The recording discard did not complete.",
                retryable = true,
            )
        }
        if (next.error != null) {
            // A STARTING take cancelled before it produced a file has nothing
            // to retain; the explicit discard is complete.
            if (next.phase == MeetingRecordingPhase.FAILED &&
                next.error.code == MeetingErrorCode.INTERRUPTED
            ) {
                val material = withContext(Dispatchers.IO) {
                    runCatching { repository.material(meetingId, recordingId) }.getOrNull()
                }
                if (material == null) return null
            }
            throw MeetingException(next.error)
        }
        return null
    }

    override suspend fun cancelLiveTranscription(): Boolean {
        val snapshot = MeetingRecordingRuntime.state.value
        val meetingId = snapshot.meetingId ?: return false
        val recordingId = snapshot.recordingId ?: return false
        if (snapshot.phase != MeetingRecordingPhase.RECORDING &&
            snapshot.phase != MeetingRecordingPhase.PAUSED
        ) {
            return false
        }
        return try {
            sendCommand(
                MeetingRecordingService.ACTION_CANCEL_LIVE,
                meetingId,
                recordingId,
            )
            true
        } catch (_: MeetingException) {
            false
        }
    }

    fun activeRecordingIds(): Set<String> = MeetingRecordingRuntime.activeRecordingIds()

    private fun sendCommand(action: String, meetingId: String, recordingId: String) {
        val intent = Intent(appContext, MeetingRecordingService::class.java)
            .setAction(action)
            .putExtra(MeetingRecordingService.EXTRA_MEETING_ID, meetingId)
            .putExtra(MeetingRecordingService.EXTRA_RECORDING_ID, recordingId)
        try {
            appContext.startService(intent)
        } catch (error: Exception) {
            throw meetingError(
                MeetingErrorCode.RECORDING_NOT_ACTIVE,
                "The recording service is not available.",
                retryable = true,
                detail = error.javaClass.simpleName,
                cause = error,
            )
        }
    }

    private suspend fun awaitRecording(
        recordingId: String,
        timeoutMillis: Long,
        predicate: (MeetingRecordingState) -> Boolean,
    ): MeetingRecordingState? = withTimeoutOrNull(timeoutMillis) {
        MeetingRecordingRuntime.state.first {
            it.recordingId == recordingId && predicate(it)
        }
    }

    private fun recordingNotActive(): MeetingException = meetingError(
        MeetingErrorCode.RECORDING_NOT_ACTIVE,
        "No recording is active.",
    )

    private fun recordingFailed(): MeetingException = meetingError(
        MeetingErrorCode.RECORDING_FAILED,
        "The recording could not be finalized.",
        retryable = true,
    )

    private companion object {
        const val START_TIMEOUT_MILLIS = 15_000L
        const val STOP_AFTER_TIMEOUT_MILLIS = 5_000L
        const val PAUSE_TIMEOUT_MILLIS = 10_000L
        const val RESUME_TIMEOUT_MILLIS = 10_000L
        const val STOP_TIMEOUT_MILLIS = 60_000L
        const val DISCARD_TIMEOUT_MILLIS = 10_000L
    }
}
