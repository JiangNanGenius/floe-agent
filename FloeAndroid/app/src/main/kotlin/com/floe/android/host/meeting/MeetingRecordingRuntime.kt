// SPDX-License-Identifier: MPL-2.0
//
// The one process-wide microphone owner. The foreground service drives this
// object; the public controller only sends explicit user commands. No code
// path silently restarts capture after process death: the next launch sees the
// retained `.part` file and marks it INCOMPLETE instead of pretending the
// audio is playable.
package com.floe.android.host.meeting

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

internal object MeetingRecordingRuntime {
    private val _state = MutableStateFlow(
        MeetingRecordingState(
            phase = MeetingRecordingPhase.IDLE,
            meetingId = null,
            recordingId = null,
            startedAtMillis = null,
            elapsedMillis = 0L,
            error = null,
        ),
    )
    val state: StateFlow<MeetingRecordingState> = _state.asStateFlow()

    @Volatile
    private var session: Session? = null

    @Volatile
    private var errorDispatched: Boolean = false

    /**
     * Serializes start/pause/resume/stop/discard across their metadata
     * suspension points. A stop command therefore cannot interleave a late
     * start's repository write and resurrect a finished take as RECORDING.
     */
    private val transition = Mutex()

    @Volatile
    private var pendingStartCancellation: String? = null

    /** Set by the foreground service; invoked on the main thread on a recorder error. */
    @Volatile
    var errorHandler: (() -> Unit)? = null

    val isActive: Boolean get() = session != null

    /**
     * Binds a command or notification PendingIntent to the exact live
     * meeting+recording generation. A stale intent from a previous take can
     * never match a newly started session.
     */
    fun matchesOwner(meetingId: String?, recordingId: String?): Boolean {
        if (meetingId == null || recordingId == null) return false
        val current = session
        if (current != null) {
            return MeetingRecordingCommandBinding.matches(
                intentMeetingId = meetingId,
                intentRecordingId = recordingId,
                ownerMeetingId = current.meetingId,
                ownerRecordingId = current.recordingId,
                ownerActive = true,
            )
        }
        val snapshot = _state.value
        return MeetingRecordingCommandBinding.matches(
            intentMeetingId = meetingId,
            intentRecordingId = recordingId,
            ownerMeetingId = snapshot.meetingId,
            ownerRecordingId = snapshot.recordingId,
            ownerActive = snapshot.phase in ACTIVE_PHASES,
        )
    }

    /**
     * Requests cancellation of a STARTING take that has not yet published a
     * session. Returns false once the take is live (then normal stop applies).
     */
    fun cancelPendingStart(meetingId: String, recordingId: String): Boolean {
        val snapshot = _state.value
        if (session == null &&
            snapshot.phase == MeetingRecordingPhase.STARTING &&
            snapshot.meetingId == meetingId &&
            snapshot.recordingId == recordingId
        ) {
            pendingStartCancellation = recordingId
            return true
        }
        return false
    }

    fun activeRecordingIds(): Set<String> {
        val current = session
        if (current != null) return setOf(current.recordingId)
        val state = _state.value
        if (state.phase in ACTIVE_PHASES && state.recordingId != null) {
            return setOf(requireNotNull(state.recordingId))
        }
        return emptySet()
    }

    suspend fun begin(context: Context, meetingId: String, recordingId: String): Boolean =
        transition.withLock {
        if (pendingStartCancellation == recordingId) pendingStartCancellation = null
        if (session != null) return false
        if (_state.value.phase in ACTIVE_PHASES) return false
        errorDispatched = false
        _state.value = MeetingRecordingState(
            phase = MeetingRecordingPhase.STARTING,
            meetingId = meetingId,
            recordingId = recordingId,
            startedAtMillis = null,
            elapsedMillis = 0L,
            error = null,
        )
        val app = context.applicationContext
        val repository = MeetingStoreRegistry.get(app).repository
        val part = try {
            withContext(Dispatchers.IO) { repository.recordingFile(meetingId, recordingId, final = false) }
        } catch (error: Exception) {
            return failStart(
                repository,
                meetingId,
                recordingId,
                storageFailure(error, "recordingPath"),
                startedAtMillis = null,
                elapsedMillis = 0L,
            )
        }
        if (pendingStartCancellation == recordingId) {
            pendingStartCancellation = null
            return failStart(
                repository,
                meetingId,
                recordingId,
                startCancelledFailure(),
                startedAtMillis = null,
                elapsedMillis = 0L,
                reason = "cancelledStart",
            )
        }
        val recorder = try {
            createRecorder(app)
        } catch (error: Exception) {
            return failStart(
                repository,
                meetingId,
                recordingId,
                recorderFailure(error, "The microphone is unavailable."),
                startedAtMillis = null,
                elapsedMillis = 0L,
            )
        }
        try {
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioChannels(1)
            recorder.setAudioSamplingRate(RECORDING_SAMPLE_RATE)
            recorder.setAudioEncodingBitRate(RECORDING_BIT_RATE)
            recorder.setOutputFile(part.absolutePath)
            recorder.setOnErrorListener { _, what, extra ->
                onRecorderError(recordingId, what, extra)
            }
            recorder.prepare()
            recorder.start()
        } catch (error: Exception) {
            runCatching { recorder.release() }
            return failStart(
                repository,
                meetingId,
                recordingId,
                recorderFailure(error, "The microphone could not start."),
                startedAtMillis = null,
                elapsedMillis = 0L,
            )
        }
        if (pendingStartCancellation == recordingId) {
            pendingStartCancellation = null
            runCatching { recorder.stop() }
            runCatching { recorder.release() }
            return failStart(
                repository,
                meetingId,
                recordingId,
                startCancelledFailure(),
                startedAtMillis = null,
                elapsedMillis = 0L,
                reason = "cancelledStart",
            )
        }
        val startedAt = System.currentTimeMillis()
        val timeline = MeetingRecordingTimeline(startedAt)
        session = Session(
            meetingId = meetingId,
            recordingId = recordingId,
            partFile = part,
            recorder = recorder,
            timeline = timeline,
        )
        return try {
            withContext(Dispatchers.IO) {
                repository.updateRecording(meetingId, recordingId) {
                    it.copy(
                        state = MeetingRepository.STATE_RECORDING,
                        startedAtMillis = startedAt,
                        accumulatedMillis = 0L,
                    )
                }
            }
            _state.value = MeetingRecordingState(
                phase = MeetingRecordingPhase.RECORDING,
                meetingId = meetingId,
                recordingId = recordingId,
                startedAtMillis = startedAt,
                elapsedMillis = 0L,
                error = null,
            )
            true
        } catch (error: Exception) {
            session = null
            runCatching { recorder.stop() }
            runCatching { recorder.release() }
            withContext(Dispatchers.IO) {
                runCatching {
                    repository.failRecordingStart(meetingId, recordingId, "metadataStartFailed")
                }
            }
            _state.value = MeetingRecordingState(
                phase = MeetingRecordingPhase.FAILED,
                meetingId = meetingId,
                recordingId = recordingId,
                startedAtMillis = startedAt,
                elapsedMillis = timeline.stop(System.currentTimeMillis()),
                error = storageFailure(error, "recordingStartMetadata").error,
            )
            false
        }
        }

    suspend fun pause(context: Context): Boolean = transition.withLock {
        val current = session ?: throw recordingNotActive()
        if (_state.value.phase != MeetingRecordingPhase.RECORDING) throw recordingNotActive()
        val now = System.currentTimeMillis()
        try {
            current.recorder.pause()
        } catch (error: Exception) {
            finalizeSession(context, current, "pauseFailed")
            throw recorderFailureException(error, "The recording could not be paused.")
        }
        val elapsed = current.timeline.pause(now)
        val repository = MeetingStoreRegistry.get(context.applicationContext).repository
        try {
            withContext(Dispatchers.IO) {
                repository.updateRecording(current.meetingId, current.recordingId) {
                    it.copy(
                        state = MeetingRepository.STATE_PAUSED,
                        accumulatedMillis = elapsed,
                    )
                }
            }
        } catch (error: Exception) {
            val failure = storageFailure(error, "recordingPause")
            _state.value = _state.value.copy(
                phase = MeetingRecordingPhase.PAUSED,
                elapsedMillis = elapsed,
                error = failure.error,
            )
            throw failure
        }
        _state.value = _state.value.copy(
            phase = MeetingRecordingPhase.PAUSED,
            elapsedMillis = elapsed,
            error = null,
        )
        true
    }

    suspend fun resume(context: Context): Boolean = transition.withLock {
        val current = session ?: throw recordingNotActive()
        if (_state.value.phase != MeetingRecordingPhase.PAUSED) throw recordingNotActive()
        val now = System.currentTimeMillis()
        try {
            current.recorder.resume()
        } catch (error: Exception) {
            finalizeSession(context, current, "resumeFailed")
            throw recorderFailureException(error, "The recording could not resume.")
        }
        current.timeline.resume(now)
        val elapsed = current.timeline.elapsed(now)
        val repository = MeetingStoreRegistry.get(context.applicationContext).repository
        try {
            withContext(Dispatchers.IO) {
                repository.updateRecording(current.meetingId, current.recordingId) {
                    it.copy(
                        state = MeetingRepository.STATE_RECORDING,
                        accumulatedMillis = elapsed,
                    )
                }
            }
        } catch (error: Exception) {
            val failure = storageFailure(error, "recordingResume")
            _state.value = _state.value.copy(
                phase = MeetingRecordingPhase.RECORDING,
                elapsedMillis = elapsed,
                error = failure.error,
            )
            throw failure
        }
        _state.value = _state.value.copy(
            phase = MeetingRecordingPhase.RECORDING,
            elapsedMillis = elapsed,
            error = null,
        )
        true
    }

    suspend fun stop(context: Context) = transition.withLock {
        val current = session ?: throw recordingNotActive()
        finalizeSession(context, current, null)
    }

    suspend fun stopAfterError(context: Context, detail: String) = transition.withLock {
        val current = session ?: return@withLock
        finalizeSession(context, current, detail)
    }

    suspend fun discard(context: Context) = transition.withLock {
        val current = session ?: throw recordingNotActive()
        val elapsed = current.timeline.stop(System.currentTimeMillis())
        session = null
        runCatching { current.recorder.stop() }
        runCatching { current.recorder.release() }
        val repository = MeetingStoreRegistry.get(context.applicationContext).repository
        _state.value = _state.value.copy(
            phase = MeetingRecordingPhase.STOPPING,
            elapsedMillis = elapsed,
        )
        try {
            withContext(Dispatchers.IO) {
                repository.deleteRecording(current.meetingId, current.recordingId)
            }
        } catch (error: Exception) {
            val failure = storageFailure(error, "recordingDiscard")
            _state.value = MeetingRecordingState(
                phase = MeetingRecordingPhase.FAILED,
                meetingId = current.meetingId,
                recordingId = current.recordingId,
                startedAtMillis = _state.value.startedAtMillis,
                elapsedMillis = elapsed,
                error = failure.error,
            )
            throw failure
        }
        _state.value = MeetingRecordingState(
            phase = MeetingRecordingPhase.IDLE,
            meetingId = null,
            recordingId = null,
            startedAtMillis = null,
            elapsedMillis = 0L,
            error = null,
        )
    }

    fun tick() {
        val current = session ?: return
        if (_state.value.phase != MeetingRecordingPhase.RECORDING) return
        _state.value = _state.value.copy(
            elapsedMillis = current.timeline.elapsed(System.currentTimeMillis()),
        )
    }

    /**
     * Called from Service.onDestroy. It attempts one last finalization and a
     * bounded metadata write; any failure is still covered by the next launch's
     * recovery, which retains the file.
     */
    fun onServiceDestroyed(context: Context) {
        errorHandler = null
        val current = session ?: return
        session = null
        val now = System.currentTimeMillis()
        val elapsed = current.timeline.stop(now)
        var stopped = false
        try {
            current.recorder.stop()
            stopped = true
        } catch (_: Exception) {
        }
        runCatching { current.recorder.release() }
        val repository = MeetingStoreRegistry.get(context.applicationContext).repository
        var completed = false
        runCatching {
            runBlocking {
                withTimeoutOrNull(DESTROY_PERSIST_TIMEOUT_MILLIS) {
                    withContext(Dispatchers.IO) {
                        val size = current.partFile.length()
                        if (stopped && size > 0) {
                            val finalFile = repository.recordingFile(
                                current.meetingId,
                                current.recordingId,
                                final = true,
                            )
                            if (runCatching { moveAtomically(current.partFile, finalFile) }.isSuccess) {
                                val probed = MeetingMediaProbe.probe(finalFile)
                                if (probed.readable && (probed.hasAudio || probed.hasVideo)) {
                                    repository.updateRecording(current.meetingId, current.recordingId) {
                                        it.copy(
                                            state = MeetingRepository.STATE_COMPLETED,
                                            durationMillis = if (probed.durationMillis > 0) {
                                                probed.durationMillis
                                            } else {
                                                elapsed
                                            },
                                            sizeBytes = finalFile.length(),
                                            accumulatedMillis = elapsed,
                                            incompleteReason = null,
                                        )
                                    }
                                    completed = true
                                } else {
                                    repository.failRecordingStart(
                                        current.meetingId,
                                        current.recordingId,
                                        "unreadableAfterStop",
                                    )
                                }
                            } else {
                                repository.failRecordingStart(
                                    current.meetingId,
                                    current.recordingId,
                                    "renameFailed",
                                )
                            }
                        } else {
                            repository.failRecordingStart(
                                current.meetingId,
                                current.recordingId,
                                if (size <= 0) "noAudio" else "destroyedBeforeFinalize",
                            )
                        }
                    }
                }
            }
        }
        _state.value = if (completed) {
            MeetingRecordingState(
                phase = MeetingRecordingPhase.COMPLETED,
                meetingId = current.meetingId,
                recordingId = current.recordingId,
                startedAtMillis = null,
                elapsedMillis = elapsed,
                error = null,
            )
        } else {
            MeetingRecordingState(
                phase = MeetingRecordingPhase.FAILED,
                meetingId = current.meetingId,
                recordingId = current.recordingId,
                startedAtMillis = null,
                elapsedMillis = elapsed,
                error = MeetingError(
                    code = MeetingErrorCode.INTERRUPTED,
                    message = "The recording service stopped unexpectedly.",
                    retryable = true,
                ),
            )
        }
    }

    private suspend fun finalizeSession(context: Context, current: Session, reason: String?) {
        session = null
        val now = System.currentTimeMillis()
        val elapsed = current.timeline.stop(now)
        _state.value = _state.value.copy(
            phase = MeetingRecordingPhase.STOPPING,
            elapsedMillis = elapsed,
        )
        var stopped = false
        var stopError: Throwable? = null
        try {
            current.recorder.stop()
            stopped = true
        } catch (error: Exception) {
            stopError = error
        }
        runCatching { current.recorder.release() }
        val repository = MeetingStoreRegistry.get(context.applicationContext).repository
        var completed = false
        var size = current.partFile.length()
        var incompleteReason = reason
        if (stopped && size > 0) {
            val finalFile = try {
                withContext(Dispatchers.IO) {
                    repository.recordingFile(current.meetingId, current.recordingId, final = true)
                }
            } catch (error: Exception) {
                finalFileFailure(context, current, elapsed, storageFailure(error, "recordingFinalPath"))
                return
            }
            if (runCatching { moveAtomically(current.partFile, finalFile) }.isSuccess) {
                size = finalFile.length()
                val probed = MeetingMediaProbe.probe(finalFile)
                if (probed.readable && (probed.hasAudio || probed.hasVideo)) {
                    completed = true
                    incompleteReason = null
                    val duration = if (probed.durationMillis > 0) probed.durationMillis else elapsed
                    try {
                        withContext(Dispatchers.IO) {
                            repository.updateRecording(current.meetingId, current.recordingId) {
                                it.copy(
                                    state = MeetingRepository.STATE_COMPLETED,
                                    durationMillis = duration,
                                    sizeBytes = size,
                                    accumulatedMillis = elapsed,
                                    incompleteReason = null,
                                )
                            }
                        }
                        _state.value = MeetingRecordingState(
                            phase = MeetingRecordingPhase.COMPLETED,
                            meetingId = current.meetingId,
                            recordingId = current.recordingId,
                            startedAtMillis = _state.value.startedAtMillis,
                            elapsedMillis = elapsed,
                            error = null,
                        )
                    } catch (error: Exception) {
                        finalFileFailure(context, current, elapsed, storageFailure(error, "recordingStopMetadata"))
                    }
                    return
                }
                incompleteReason = "unreadableAfterStop"
            } else {
                incompleteReason = "renameFailed"
            }
        } else if (size <= 0) {
            incompleteReason = incompleteReason ?: "noAudio"
        } else {
            incompleteReason = incompleteReason ?: "finalizeFailed"
        }
        val failure = MeetingError(
            code = MeetingErrorCode.RECORDING_FAILED,
            message = if (completed) {
                "The recording was saved."
            } else {
                "The recording could not be finalized."
            },
            retryable = false,
            detail = incompleteReason ?: stopError?.javaClass?.simpleName,
        )
        try {
            withContext(Dispatchers.IO) {
                repository.failRecordingStart(
                    current.meetingId,
                    current.recordingId,
                    incompleteReason ?: "finalizeFailed",
                )
            }
        } catch (error: Exception) {
            finalFileFailure(context, current, elapsed, storageFailure(error, "recordingFailMetadata"))
            return
        }
        _state.value = MeetingRecordingState(
            phase = MeetingRecordingPhase.FAILED,
            meetingId = current.meetingId,
            recordingId = current.recordingId,
            startedAtMillis = _state.value.startedAtMillis,
            elapsedMillis = elapsed,
            error = failure,
        )
    }

    private suspend fun finalFileFailure(
        context: Context,
        current: Session,
        elapsed: Long,
        failure: MeetingException,
    ) {
        // The finalized bytes are retained on disk; only metadata publication
        // failed. Leave the stored state as STOPPING so the next recovery can
        // probe and adopt the final file instead of permanently marking it
        // unplayable.
        _state.value = MeetingRecordingState(
            phase = MeetingRecordingPhase.FAILED,
            meetingId = current.meetingId,
            recordingId = current.recordingId,
            startedAtMillis = _state.value.startedAtMillis,
            elapsedMillis = elapsed,
            error = failure.error,
        )
    }

    private fun startCancelledFailure(): MeetingException = meetingError(
        MeetingErrorCode.INTERRUPTED,
        "The recording start was cancelled.",
        retryable = false,
    )

    private suspend fun failStart(
        repository: MeetingRepository,
        meetingId: String,
        recordingId: String,
        failure: MeetingException,
        startedAtMillis: Long?,
        elapsedMillis: Long,
        reason: String = "startFailed",
    ): Boolean {
        session = null
        if (pendingStartCancellation == recordingId) pendingStartCancellation = null
        withContext(Dispatchers.IO) {
            runCatching {
                repository.failRecordingStart(meetingId, recordingId, reason)
            }
        }
        _state.value = MeetingRecordingState(
            phase = MeetingRecordingPhase.FAILED,
            meetingId = meetingId,
            recordingId = recordingId,
            startedAtMillis = startedAtMillis,
            elapsedMillis = elapsedMillis,
            error = failure.error,
        )
        return false
    }

    private fun onRecorderError(expectedRecordingId: String, what: Int, extra: Int) {
        val current = session
        if (current == null || current.recordingId != expectedRecordingId) return
        if (errorDispatched) return
        errorDispatched = true
        _state.value = _state.value.copy(
            error = MeetingError(
                code = MeetingErrorCode.RECORDING_FAILED,
                message = "The microphone stopped unexpectedly.",
                retryable = true,
                detail = "what=$what extra=$extra",
            ),
        )
        errorHandler?.invoke()
    }

    private fun createRecorder(context: Context): MediaRecorder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }

    private fun recordingNotActive(): MeetingException = meetingError(
        MeetingErrorCode.RECORDING_NOT_ACTIVE,
        "No recording is active.",
    )

    private fun recorderFailure(error: Throwable, fallback: String): MeetingException {
        val code = if (error is SecurityException) {
            MeetingErrorCode.PERMISSION_REQUIRED
        } else {
            MeetingErrorCode.RECORDING_FAILED
        }
        return meetingError(
            code = code,
            message = if (code == MeetingErrorCode.PERMISSION_REQUIRED) {
                "Microphone permission is required."
            } else {
                fallback
            },
            retryable = code != MeetingErrorCode.PERMISSION_REQUIRED,
            detail = error.javaClass.simpleName,
            cause = error,
        )
    }

    private fun recorderFailureException(error: Throwable, fallback: String): MeetingException =
        recorderFailure(error, fallback)

    private class Session(
        val meetingId: String,
        val recordingId: String,
        val partFile: File,
        val recorder: MediaRecorder,
        val timeline: MeetingRecordingTimeline,
    )

    val ACTIVE_PHASES = setOf(
        MeetingRecordingPhase.STARTING,
        MeetingRecordingPhase.RECORDING,
        MeetingRecordingPhase.PAUSED,
        MeetingRecordingPhase.STOPPING,
    )

    private const val RECORDING_SAMPLE_RATE = 44_100
    private const val RECORDING_BIT_RATE = 96_000
    private const val DESTROY_PERSIST_TIMEOUT_MILLIS = 3_000L
}
