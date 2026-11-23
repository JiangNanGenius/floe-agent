// SPDX-License-Identifier: MPL-2.0
//
// While-recording meeting transcription owner.
//
// The recording service writes ONE PCM source. When the user explicitly opts
// into live cloud transcription, bounded finalized WAV fragments are queued on
// disk and sent one at a time through the existing Swift meeting-ASR domain.
// Each fragment is an independent plan/chunk/finish/page operation, so the
// exact absolute capture offset comes from the fragment's own measured start
// and every confirmed fragment is durable before the recording stops.
//
// This owner is process-scoped. The foreground service remains the microphone
// owner; cloud failure or cancellation never stops local capture. A process
// restart loses only the in-memory worker: confirmed text and unconfirmed
// fragment files stay in the meeting store, and an explicit retry resumes the
// unconfirmed fragments. Nothing is sent automatically after a restart.
package com.floe.android.host.meetingtranscription

import android.content.Context
import com.floe.android.host.meeting.MeetingException
import com.floe.android.host.meeting.MeetingIds
import com.floe.android.host.meeting.MeetingLiveFragment
import com.floe.android.host.meeting.MeetingLiveSession
import com.floe.android.host.meeting.MeetingLiveTranscript
import com.floe.android.host.meeting.MeetingLiveTranscriptPhase
import com.floe.android.host.meeting.MeetingLivePromotion
import com.floe.android.host.meeting.MeetingRepository
import com.floe.android.host.meeting.MeetingStoreRegistry
import com.floe.android.host.meeting.MeetingTranscriptSegment
import com.floe.android.host.meeting.MeetingTranscriptionReceipt
import com.floe.android.host.meeting.StoredTranscriptSegment
import com.floe.android.host.meeting.meetingFragmentHasVoice
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import java.io.File
import java.util.UUID
import kotlin.math.roundToLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

/** Observable while-recording state. [segments] are real provider output. */
data class MeetingLiveState(
    val phase: MeetingLiveTranscriptPhase? = null,
    val meetingId: String? = null,
    val recordingId: String? = null,
    val sessionId: String? = null,
    val segments: List<MeetingTranscriptSegment> = emptyList(),
    val confirmedFragments: Int = 0,
    val pendingFragments: Int = 0,
    val failedFragments: Int = 0,
    val failure: MeetingTranscriptionFailure? = null,
    val receipt: MeetingTranscriptionReceipt? = null,
    val cancelUnconfirmed: Boolean = false,
) {
    val isActive: Boolean
        get() = phase == MeetingLiveTranscriptPhase.RECORDING ||
            phase == MeetingLiveTranscriptPhase.DRAINING
}

internal sealed interface MeetingLiveStartOutcome {
    data class Started(val session: MeetingLiveSession) : MeetingLiveStartOutcome
    data class Unavailable(val failure: MeetingTranscriptionFailure) : MeetingLiveStartOutcome
}

/**
 * Public facade used by both the foreground recording service and the page.
 * Constructing it again returns the same process-wide owner.
 */
class MeetingLiveTranscriptionManager internal constructor(
    private val owner: MeetingLiveTranscriptionOwner,
) {
    constructor(
        context: Context,
        currentEpoch: () -> Long?,
    ) : this(
        owner = MeetingLiveTranscriptionProcess.acquire(
            context = context.applicationContext ?: context,
            currentEpoch = currentEpoch,
        ),
    )

    internal constructor(
        repository: MeetingRepository,
        currentEpoch: () -> Long?,
        ioDispatcher: CoroutineDispatcher,
        backend: MeetingTranscriptionBackend,
        retryDelay: suspend (Int) -> Unit,
    ) : this(
        owner = MeetingLiveTranscriptionOwner(
            repositoryProvider = { repository },
            epochProvider = currentEpoch,
            ioDispatcher = ioDispatcher,
            backend = backend,
            retryDelay = retryDelay,
        ),
    )

    val state: StateFlow<MeetingLiveState> = owner.state

    internal suspend fun start(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        chunkSeconds: Int,
    ): MeetingLiveStartOutcome = owner.start(meetingId, recordingId, sessionId, chunkSeconds)

    internal fun recordUnavailable(
        meetingId: String,
        recordingId: String,
        failure: MeetingTranscriptionFailure,
    ) = owner.recordUnavailable(meetingId, recordingId, failure)

    internal fun fragmentReady(fragment: MeetingLiveFragment) = owner.fragmentReady(fragment)

    /**
     * Bounded handoff used by the capture thread at a fragment boundary. It
     * returns only after the durable manifest contains this fragment, which
     * prevents a stop from promoting and deleting the ledger before the last
     * finalized fragment is queued.
     */
    internal suspend fun enqueueFragment(fragment: MeetingLiveFragment) =
        owner.enqueueFragment(fragment)

    fun captureStopped(completed: Boolean) = owner.captureStopped(completed)

    fun cancel() = owner.cancel()

    fun retry(meetingId: String, recordingId: String) = owner.retry(meetingId, recordingId)

    fun discard(meetingId: String, recordingId: String) = owner.discard(meetingId, recordingId)

    internal suspend fun awaitIdleForTest() = owner.awaitIdleForTest()

    fun close() = Unit
}

internal class MeetingLiveTranscriptionOwner(
    private val repositoryProvider: () -> MeetingRepository,
    epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher,
    private val backend: MeetingTranscriptionBackend,
    private val retryDelay: suspend (Int) -> Unit = { attempt -> delay(400L * attempt) },
) {
    @Volatile
    private var epochProvider: () -> Long? = epochProvider

    private val processScope = CoroutineScope(
        SupervisorJob() + ioDispatcher + CoroutineName("meeting-live-transcription"),
    )
    private val startLock = Mutex()
    private val stateLock = Any()
    private val _state = MutableStateFlow(MeetingLiveState())
    val state: StateFlow<MeetingLiveState> = _state.asStateFlow()

    private var active: LiveSession? = null
    private var starting = false

    fun updateEpochProvider(provider: () -> Long?) {
        epochProvider = provider
    }

    internal suspend fun start(
        meetingId: String,
        recordingId: String,
        sessionId: String,
        chunkSeconds: Int,
    ): MeetingLiveStartOutcome {
        try {
            MeetingIds.require(meetingId)
            MeetingIds.require(recordingId)
            MeetingIds.require(sessionId)
        } catch (error: MeetingException) {
            return MeetingLiveStartOutcome.Unavailable(meetingTranscriptionFailureOf(error))
        }
        return startLock.withLock {
            synchronized(stateLock) {
                val existing = active
                if (existing != null && !existing.cancelRequested) {
                    return@withLock MeetingLiveStartOutcome.Unavailable(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.BUSY,
                            "liveTranscriptionAlreadyRunning",
                            retryable = true,
                        ),
                    )
                }
                if (existing != null) {
                    existing.worker?.cancel(CancellationException("liveReplaced"))
                    active = null
                }
                if (starting) {
                    return@withLock MeetingLiveStartOutcome.Unavailable(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.BUSY,
                            "liveTranscriptionAlreadyRunning",
                            retryable = true,
                        ),
                    )
                }
                starting = true
            }
            var prepared = false
            try {
                val session = repositoryProvider().beginLiveTranscription(
                    meetingId = meetingId,
                    recordingId = recordingId,
                    sessionId = sessionId,
                    chunkSeconds = chunkSeconds,
                )
                prepared = true
                val live = LiveSession(
                    meetingId = meetingId,
                    recordingId = recordingId,
                    sessionId = sessionId,
                    directory = session.directory,
                    recordingCompleted = session.recordingCompleted,
                    captureStopped = !session.recordingActive,
                )
                synchronized(stateLock) {
                    active = live
                    publishLocked(live, session.transcript)
                }
                processScope.launch { configure(live) }
                MeetingLiveStartOutcome.Started(session)
            } catch (error: Throwable) {
                if (prepared) {
                    runCatching {
                        repositoryProvider().deleteLiveTranscription(meetingId, recordingId)
                    }
                }
                synchronized(stateLock) {
                    if (active?.sessionId == sessionId) active = null
                }
                MeetingLiveStartOutcome.Unavailable(meetingTranscriptionFailureOf(error))
            } finally {
                synchronized(stateLock) { starting = false }
            }
        }
    }

    fun recordUnavailable(
        meetingId: String,
        recordingId: String,
        failure: MeetingTranscriptionFailure,
    ) {
        synchronized(stateLock) {
            if (active != null || starting) return
            _state.value = MeetingLiveState(
                phase = MeetingLiveTranscriptPhase.FAILED,
                meetingId = meetingId,
                recordingId = recordingId,
                failure = failure,
            )
        }
    }

    fun fragmentReady(fragment: MeetingLiveFragment) {
        processScope.launch { enqueueFragment(fragment) }
    }

    internal suspend fun enqueueFragment(fragment: MeetingLiveFragment) {
        val live = synchronized(stateLock) { active } ?: return
        if (live.cancelRequested || live.discardRequested) return
        if (!isCurrent(live)) return
        try {
            val ledger = repositoryProvider().appendLiveFragment(
                meetingId = live.meetingId,
                recordingId = live.recordingId,
                sessionId = live.sessionId,
                fragment = fragment,
            )
            synchronized(stateLock) {
                if (active === live) publishLocked(live, ledger)
            }
            scheduleWorker(live)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            // A queue write failure must remain visible but cannot stop
            // capture: the canonical WAV is independent of this manifest.
            synchronized(stateLock) {
                if (active === live) {
                    _state.value = _state.value.copy(
                        failure = meetingTranscriptionFailureOf(error),
                    )
                }
            }
        }
    }

    fun captureStopped(completed: Boolean) {
        val live = synchronized(stateLock) { active } ?: return
        if (live.cancelRequested || live.discardRequested) return
        live.captureStopped = true
        live.recordingCompleted = completed
        processScope.launch {
            if (!isCurrent(live)) return@launch
            try {
                val failure = live.configurationFailure
                val ledger = repositoryProvider().setLiveTranscriptionState(
                    meetingId = live.meetingId,
                    recordingId = live.recordingId,
                    sessionId = live.sessionId,
                    phase = if (failure != null) {
                        MeetingLiveTranscriptPhase.FAILED
                    } else {
                        MeetingLiveTranscriptPhase.DRAINING
                    },
                    failureCode = failure?.code?.name,
                    failureReason = failure?.reason,
                )
                synchronized(stateLock) {
                    if (active === live) publishLocked(live, ledger)
                }
                if (failure != null) {
                    synchronized(stateLock) {
                        if (active === live) active = null
                    }
                } else {
                    scheduleWorker(live)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                synchronized(stateLock) {
                    if (active === live) {
                        _state.value = _state.value.copy(
                            failure = meetingTranscriptionFailureOf(error),
                        )
                    }
                }
            }
        }
    }

    fun cancel() {
        val live = synchronized(stateLock) { active } ?: return
        if (live.cancelRequested) return
        live.cancelRequested = true
        live.captureStopped = true
        live.worker?.cancel(CancellationException("liveTranscriptionCancelled"))
        requestBackendCancel(live)
        synchronized(stateLock) {
            if (active === live) {
                _state.value = _state.value.copy(
                    phase = MeetingLiveTranscriptPhase.CANCELLED,
                    failure = MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.CANCELLED,
                        "userCancelled",
                        retryable = true,
                    ),
                )
            }
        }
        processScope.launch {
            runCatching {
                repositoryProvider().setLiveTranscriptionState(
                    meetingId = live.meetingId,
                    recordingId = live.recordingId,
                    sessionId = live.sessionId,
                    phase = MeetingLiveTranscriptPhase.CANCELLED,
                    failureCode = MeetingTranscriptionFailureCode.CANCELLED.name,
                    failureReason = "userCancelled",
                )
            }
            synchronized(stateLock) {
                if (active === live) active = null
            }
        }
    }

    fun retry(meetingId: String, recordingId: String) {
        processScope.launch {
            try {
                MeetingIds.require(meetingId)
                MeetingIds.require(recordingId)
            } catch (_: MeetingException) {
                return@launch
            }
            startLock.withLock {
                synchronized(stateLock) {
                    val existing = active
                    if (existing != null) {
                        if (existing.meetingId != meetingId ||
                            existing.recordingId != recordingId
                        ) {
                            return@launch
                        }
                        if (!existing.captureStopped) return@launch
                        existing.worker?.cancel(CancellationException("liveRetry"))
                        active = null
                    }
                    if (starting) return@launch
                    starting = true
                }
                try {
                    val repository = repositoryProvider()
                    repository.reconcileLiveTranscription(meetingId, recordingId)
                    val sessionId = UUID.randomUUID().toString()
                    val session = repository.retryLiveTranscription(
                        meetingId = meetingId,
                        recordingId = recordingId,
                        sessionId = sessionId,
                        chunkSeconds = DEFAULT_CHUNK_SECONDS,
                    ) ?: return@launch
                    val live = LiveSession(
                        meetingId = meetingId,
                        recordingId = recordingId,
                        sessionId = sessionId,
                        directory = session.directory,
                        recordingCompleted = session.recordingCompleted,
                        captureStopped = !session.recordingActive,
                    )
                    synchronized(stateLock) {
                        active = live
                        publishLocked(live, session.transcript)
                    }
                    processScope.launch { configure(live) }
                } catch (error: Throwable) {
                    synchronized(stateLock) {
                        _state.value = _state.value.copy(
                            failure = meetingTranscriptionFailureOf(error),
                        )
                    }
                } finally {
                    synchronized(stateLock) { starting = false }
                }
            }
        }
    }

    fun discard(meetingId: String, recordingId: String) {
        val live = synchronized(stateLock) {
            active?.takeIf { it.meetingId == meetingId && it.recordingId == recordingId }
        }
        if (live != null) {
            live.discardRequested = true
            live.cancelRequested = true
            live.worker?.cancel(CancellationException("liveTranscriptionDiscarded"))
            requestBackendCancel(live)
        }
        processScope.launch {
            runCatching { repositoryProvider().deleteLiveTranscription(meetingId, recordingId) }
            synchronized(stateLock) {
                if (live == null || active === live) {
                    active = null
                    _state.value = MeetingLiveState()
                }
            }
        }
    }

    internal suspend fun awaitIdleForTest() {
        while (true) {
            val job = synchronized(stateLock) { active?.worker }
            if (job == null || job.isCompleted) return
            job.join()
        }
    }

    private suspend fun configure(live: LiveSession) {
        if (!isCurrent(live)) return
        try {
            val epoch = requireEpoch()
            val configuration = backend.configuration(epoch)
            if (!isCurrent(live)) return
            live.configuration = configuration
            live.configurationFailure = null
            synchronized(stateLock) {
                if (active === live) {
                    _state.value = _state.value.copy(
                        phase = if (live.captureStopped) {
                            MeetingLiveTranscriptPhase.DRAINING
                        } else {
                            MeetingLiveTranscriptPhase.RECORDING
                        },
                        failure = null,
                    )
                }
            }
            scheduleWorker(live)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = meetingTranscriptionFailureOf(error)
            if (!isCurrent(live)) return
            live.configurationFailure = failure
            synchronized(stateLock) {
                if (active === live) {
                    _state.value = _state.value.copy(
                        phase = MeetingLiveTranscriptPhase.FAILED,
                        failure = failure,
                    )
                }
            }
        }
    }

    private fun scheduleWorker(live: LiveSession) {
        synchronized(stateLock) {
            if (active !== live || live.cancelRequested || live.discardRequested) return
            if (live.configuration == null) {
                if (live.configurationFailure != null) return
                // Configuration is still being resolved by configure().
                return
            }
            if (live.worker?.isActive == true) {
                live.scheduleAgain = true
                return
            }
            live.scheduleAgain = false
            live.worker = processScope.launch { drain(live) }
        }
    }

    private suspend fun drain(live: LiveSession) {
        val workerJob = kotlinx.coroutines.currentCoroutineContext()[Job]
        try {
            while (true) {
                if (!isCurrent(live) || live.cancelRequested || live.discardRequested) return
                val next = repositoryProvider().nextPendingLiveFragment(
                    meetingId = live.meetingId,
                    recordingId = live.recordingId,
                    sessionId = live.sessionId,
                ) ?: break
                if (!process(live, next)) return
            }
            val ledger = repositoryProvider().liveTranscription(live.meetingId, live.recordingId)
                ?: return
            synchronized(stateLock) {
                if (active === live) publishLocked(live, ledger)
            }
            if (live.captureStopped) {
                when {
                    ledger.pendingFragments > 0 -> Unit
                    ledger.failedFragments > 0 -> {
                        val failure = _state.value.failure ?: MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.PROVIDER_REJECTED,
                            "liveFragmentsUnconfirmed",
                            retryable = true,
                        )
                        live.lastFailure = failure
                        val durable = runCatching {
                            repositoryProvider().setLiveTranscriptionState(
                                meetingId = live.meetingId,
                                recordingId = live.recordingId,
                                sessionId = live.sessionId,
                                phase = MeetingLiveTranscriptPhase.FAILED,
                                failureCode = failure.code.name,
                                failureReason = failure.reason,
                            )
                        }.getOrNull()
                        synchronized(stateLock) {
                            if (active === live) {
                                if (durable != null) {
                                    publishLocked(live, durable)
                                    _state.value = _state.value.copy(failure = failure)
                                } else {
                                    _state.value = _state.value.copy(
                                        phase = MeetingLiveTranscriptPhase.FAILED,
                                        failure = failure,
                                    )
                                }
                                active = null
                            }
                        }
                    }
                    live.recordingCompleted -> promote(live)
                    else -> finishInterrupted(live)
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = meetingTranscriptionFailureOf(error)
            live.lastFailure = failure
            if (!live.cancelRequested && !live.discardRequested) {
                runCatching {
                    repositoryProvider().setLiveTranscriptionState(
                        meetingId = live.meetingId,
                        recordingId = live.recordingId,
                        sessionId = live.sessionId,
                        phase = MeetingLiveTranscriptPhase.FAILED,
                        failureCode = failure.code.name,
                        failureReason = failure.reason,
                    )
                }
            }
            synchronized(stateLock) {
                if (active === live && !live.cancelRequested && !live.discardRequested) {
                    _state.value = _state.value.copy(
                        phase = MeetingLiveTranscriptPhase.FAILED,
                        failure = failure,
                    )
                }
            }
        } finally {
            var again = false
            synchronized(stateLock) {
                if (live.worker === workerJob) {
                    live.worker = null
                }
                if (active === live && live.scheduleAgain &&
                    !live.cancelRequested && !live.discardRequested
                ) {
                    live.scheduleAgain = false
                    again = true
                }
            }
            if (again) scheduleWorker(live)
        }
    }

    private suspend fun process(live: LiveSession, fragment: MeetingLiveFragment): Boolean {
        val directory = live.directory.canonicalFile
        val file = runCatching { File(directory, fragment.fileName).canonicalFile }.getOrNull()
            ?: return failFragment(live, fragment, noTimed("fragmentPathInvalid"), retryable = false)
        if (file.parentFile?.path != directory.path || !file.isFile ||
            file.length() != fragment.sizeBytes || file.length() <= 44L
        ) {
            return failFragment(live, fragment, noTimed("fragmentMissing"), retryable = false)
        }
        val voiced = runCatching { meetingFragmentHasVoice(file) }.getOrNull()
        if (voiced == false) {
            // Silence is a real completed observation, not a provider request.
            return confirm(live, fragment, emptyList())
        }
        var attempt = 0
        while (true) {
            if (!isCurrent(live) || live.cancelRequested || live.discardRequested) return false
            attempt += 1
            var operationId: String? = null
            var stagingTarget: File? = null
            try {
                val epoch = requireEpoch()
                val configuration = live.configuration ?: run {
                    val loaded = backend.configuration(epoch)
                    live.configuration = loaded
                    loaded
                }
                val plan = backend.plan(
                    epoch = epoch,
                    meetingId = live.meetingId,
                    materialId = live.recordingId,
                    sourceBytes = fragment.sizeBytes,
                    durationSeconds = fragment.durationMillis / 1_000.0,
                    configuration = configuration,
                )
                val op = plan.operationId
                operationId = op
                live.inFlightOperationId = op
                val staging = File(plan.stagingPath).canonicalFile
                if (!staging.isDirectory && !staging.mkdirs()) {
                    throw C03VoiceFailure(C03VoiceErrorCode.WRITE_FAILED, "chunkStagingUnavailable")
                }
                val target = File(staging, "chunk-00000.wav").canonicalFile
                if (target.parentFile?.path != staging.path) {
                    throw C03VoiceFailure(C03VoiceErrorCode.WRITE_FAILED, "chunkStagingInvalid")
                }
                stagingTarget = target
                file.copyTo(target, overwrite = true)
                if (target.length() != fragment.sizeBytes) {
                    throw C03VoiceFailure(C03VoiceErrorCode.FILE_UNREADABLE, "chunkReadFailed")
                }
                val applied = backend.applyChunk(
                    meetingId = live.meetingId,
                    materialId = live.recordingId,
                    operationId = op,
                    chunkIndex = 0,
                    // The fragment is its own bounded source operation; the
                    // absolute capture origin is added only after the provider
                    // returns its local timed segments.
                    sourceStartSeconds = 0.0,
                    sourceDurationSeconds = fragment.durationMillis / 1_000.0,
                    sampleRate = fragment.sampleRate,
                    channels = fragment.channels,
                )
                if (applied <= 0) {
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                            "providerReturnedNoTimedText",
                        ),
                    )
                }
                val finished = backend.finish(
                    meetingId = live.meetingId,
                    materialId = live.recordingId,
                    operationId = op,
                    totalChunks = 1,
                    sourceDurationSeconds = fragment.durationMillis / 1_000.0,
                )
                if (finished <= 0 || finished != applied) {
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                            "transcriptCountMismatch",
                        ),
                    )
                }
                val timed = readTimedSegments(live, op)
                if (timed.size != finished) {
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                            "transcriptCountMismatch",
                        ),
                    )
                }
                val absolute = toAbsoluteSegments(live, fragment, timed)
                if (absolute.isEmpty()) {
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                            "noUsableTimedSegments",
                        ),
                    )
                }
                live.inFlightOperationId = null
                return confirm(live, fragment, absolute)
            } catch (cancelled: CancellationException) {
                operationId?.let { requestBackendCancel(live, it) }
                throw cancelled
            } catch (error: Throwable) {
                operationId?.let { requestBackendCancel(live, it) }
                live.inFlightOperationId = null
                val failure = meetingTranscriptionFailureOf(error)
                val retryable = failure.retryable &&
                    failure.code !in NON_RETRYABLE_LIVE_FAILURES &&
                    attempt < MAX_LIVE_ATTEMPTS
                if (retryable && isCurrent(live) && !live.cancelRequested) {
                    retryDelay(attempt)
                    continue
                }
                return failFragment(live, fragment, failure, retryable = failure.retryable)
            } finally {
                stagingTarget?.let { runCatching { it.delete() } }
            }
        }
    }

    private suspend fun confirm(
        live: LiveSession,
        fragment: MeetingLiveFragment,
        segments: List<StoredTranscriptSegment>,
    ): Boolean {
        if (!isCurrent(live) || live.cancelRequested || live.discardRequested) return false
        return try {
            val ledger = repositoryProvider().confirmLiveFragment(
                meetingId = live.meetingId,
                recordingId = live.recordingId,
                sessionId = live.sessionId,
                fragmentIndex = fragment.index,
                segments = segments,
                language = live.configuration?.language,
            )
            live.lastFailure = null
            synchronized(stateLock) {
                if (active === live) publishLocked(live, ledger)
            }
            runCatching { File(live.directory, fragment.fileName).delete() }
            runCatching {
                File(live.directory, fragment.fileName.substringBeforeLast('.') + ".json").delete()
            }
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = meetingTranscriptionFailureOf(error)
            runCatching {
                repositoryProvider().setLiveTranscriptionState(
                    meetingId = live.meetingId,
                    recordingId = live.recordingId,
                    sessionId = live.sessionId,
                    phase = MeetingLiveTranscriptPhase.FAILED,
                    failureCode = failure.code.name,
                    failureReason = failure.reason,
                )
            }
            synchronized(stateLock) {
                if (active === live && !live.cancelRequested && !live.discardRequested) {
                    _state.value = _state.value.copy(
                        phase = MeetingLiveTranscriptPhase.FAILED,
                        failure = failure,
                    )
                }
            }
            false
        }
    }

    private suspend fun failFragment(
        live: LiveSession,
        fragment: MeetingLiveFragment,
        failure: MeetingTranscriptionFailure,
        retryable: Boolean,
    ): Boolean {
        val ledger = repositoryProvider().failLiveFragment(
            meetingId = live.meetingId,
            recordingId = live.recordingId,
            sessionId = live.sessionId,
            fragmentIndex = fragment.index,
            failureCode = failure.code.name,
            failureReason = failure.reason,
            retryable = retryable,
        )
        synchronized(stateLock) {
            if (active === live && !live.cancelRequested && !live.discardRequested) {
                live.lastFailure = failure
                publishLocked(live, ledger)
            }
        }
        return false
    }

    private suspend fun promote(live: LiveSession) {
        if (!isCurrent(live) || live.cancelRequested) return
        try {
            when (
                val result = repositoryProvider().promoteLiveTranscription(
                    meetingId = live.meetingId,
                    recordingId = live.recordingId,
                    sessionId = live.sessionId,
                )
            ) {
                is MeetingLivePromotion.Promoted -> {
                    synchronized(stateLock) {
                        if (active === live) {
                            _state.value = _state.value.copy(
                                phase = MeetingLiveTranscriptPhase.COMPLETED,
                                failure = null,
                                receipt = result.receipt,
                                pendingFragments = 0,
                                failedFragments = 0,
                            )
                            active = null
                        }
                    }
                }
                MeetingLivePromotion.NoSpeech -> {
                    synchronized(stateLock) {
                        if (active === live) {
                            _state.value = _state.value.copy(
                                phase = MeetingLiveTranscriptPhase.COMPLETED,
                                failure = null,
                                receipt = null,
                                pendingFragments = 0,
                                failedFragments = 0,
                            )
                            active = null
                        }
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            val failure = meetingTranscriptionFailureOf(error)
            synchronized(stateLock) {
                if (active === live) {
                    _state.value = _state.value.copy(
                        phase = MeetingLiveTranscriptPhase.FAILED,
                        failure = failure,
                    )
                    active = null
                }
            }
        }
    }

    private suspend fun finishInterrupted(live: LiveSession) {
        val ledger = runCatching {
            repositoryProvider().setLiveTranscriptionState(
                meetingId = live.meetingId,
                recordingId = live.recordingId,
                sessionId = live.sessionId,
                phase = MeetingLiveTranscriptPhase.INTERRUPTED,
                failureCode = "INTERRUPTED",
                failureReason = "recordingIncomplete",
            )
        }.getOrNull()
        synchronized(stateLock) {
            if (active === live) {
                if (ledger != null) {
                    publishLocked(live, ledger.copy(phase = MeetingLiveTranscriptPhase.INTERRUPTED))
                } else {
                    _state.value = _state.value.copy(
                        phase = MeetingLiveTranscriptPhase.INTERRUPTED,
                        failure = MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE,
                            "recordingIncomplete",
                            retryable = true,
                        ),
                    )
                }
                active = null
            }
        }
    }

    private suspend fun readTimedSegments(
        live: LiveSession,
        operationId: String,
    ): List<C03TimedSegment> {
        var offset = 0
        var expectedTotal: Int? = null
        val result = ArrayList<C03TimedSegment>()
        while (true) {
            if (!isCurrent(live) || live.cancelRequested) {
                throw CancellationException("liveTranscriptionCancelled")
            }
            val page = backend.page(
                meetingId = live.meetingId,
                materialId = live.recordingId,
                operationId = operationId,
                offset = offset,
                limit = PAGE_LIMIT,
            )
            val total = page.total
            if (total < 0 || total > MAX_SEGMENTS) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                        "transcriptTooLong",
                    ),
                )
            }
            val expected = expectedTotal
            if (expected == null) {
                if (total == 0) {
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                            "transcriptPageEmpty",
                        ),
                    )
                }
                expectedTotal = total
            } else if (total != expected) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                        "transcriptPageInconsistent",
                    ),
                )
            }
            if (offset >= total) break
            if (page.segments.isEmpty()) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                        "transcriptPageEmpty",
                    ),
                )
            }
            if (page.segments.size > PAGE_LIMIT) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                        "transcriptPageOverflow",
                    ),
                )
            }
            result += page.segments
            offset += page.segments.size
            if (offset == total) break
        }
        val total = expectedTotal ?: throw MeetingTranscriptionException(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                "transcriptPageEmpty",
            ),
        )
        if (offset != total || result.size != total) {
            throw MeetingTranscriptionException(
                MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                    "transcriptPageIncomplete",
                ),
            )
        }
        return result
    }

    private fun toAbsoluteSegments(
        live: LiveSession,
        fragment: MeetingLiveFragment,
        segments: List<C03TimedSegment>,
    ): List<StoredTranscriptSegment> {
        val durationMillis = fragment.durationMillis.coerceAtLeast(1L)
        val prefix = "ml-${live.recordingId.take(8)}-${fragment.index.toString().padStart(5, '0')}"
        return segments.mapIndexedNotNull { index, segment ->
            val startOffset = (segment.start * 1_000.0).roundToLong()
                .coerceIn(0L, durationMillis)
            val endOffset = (segment.end * 1_000.0).roundToLong()
                .coerceIn(0L, durationMillis)
            val text = segment.text.replace(Regex("\\s+"), " ").trim()
            if (text.isEmpty() || endOffset <= startOffset) return@mapIndexedNotNull null
            StoredTranscriptSegment(
                id = "$prefix-${index.toString().padStart(4, '0')}",
                startMillis = (fragment.startMillis + startOffset)
                    .coerceAtMost(MAX_TRANSCRIPT_MILLIS),
                endMillis = (fragment.startMillis + endOffset)
                    .coerceAtMost(MAX_TRANSCRIPT_MILLIS),
                text = text.take(MAX_TEXT_CHARS),
                speaker = segment.speaker,
            )
        }
    }

    private fun requestBackendCancel(live: LiveSession) {
        val operationId = live.inFlightOperationId ?: return
        requestBackendCancel(live, operationId)
    }

    private fun requestBackendCancel(live: LiveSession, operationId: String) {
        if (live.cancelDispatchedFor == operationId) return
        live.cancelDispatchedFor = operationId
        processScope.launch {
            val confirmed = runCatching {
                withTimeout(CANCEL_TIMEOUT_MILLIS) {
                    backend.cancel(live.meetingId, live.recordingId, operationId)
                }
            }.isSuccess
            if (!confirmed) {
                live.cancelUnconfirmed = true
                synchronized(stateLock) {
                    if (active === live) {
                        _state.value = _state.value.copy(cancelUnconfirmed = true)
                    }
                }
            }
        }
    }

    private fun publishLocked(live: LiveSession, ledger: MeetingLiveTranscript) {
        val failure = live.configurationFailure ?: live.lastFailure
        val phase = when {
            live.cancelRequested -> MeetingLiveTranscriptPhase.CANCELLED
            failure != null &&
                ledger.phase != MeetingLiveTranscriptPhase.COMPLETED -> MeetingLiveTranscriptPhase.FAILED
            else -> ledger.phase
        }
        _state.value = MeetingLiveState(
            phase = phase,
            meetingId = live.meetingId,
            recordingId = live.recordingId,
            sessionId = live.sessionId,
            segments = ledger.segments,
            confirmedFragments = ledger.confirmedFragments,
            pendingFragments = ledger.pendingFragments,
            failedFragments = ledger.failedFragments,
            failure = failure ?: if (phase == MeetingLiveTranscriptPhase.FAILED) {
                val code = ledger.errorCode?.let { raw ->
                    runCatching { MeetingTranscriptionFailureCode.valueOf(raw) }.getOrNull()
                } ?: MeetingTranscriptionFailureCode.INTERNAL
                MeetingTranscriptionFailure(code, ledger.errorReason, retryable = true)
            } else {
                null
            },
            receipt = _state.value.receipt.takeIf {
                _state.value.recordingId == live.recordingId
            },
            cancelUnconfirmed = live.cancelUnconfirmed,
        )
    }

    private fun isCurrent(live: LiveSession): Boolean =
        synchronized(stateLock) { active === live }

    private fun requireEpoch(): Long {
        val epoch = epochProvider()
        if (epoch == null || epoch <= 0L) {
            throw MeetingTranscriptionException(
                MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
                    "rootNotLive",
                    retryable = true,
                ),
            )
        }
        return epoch
    }

    private fun noTimed(reason: String): MeetingTranscriptionFailure =
        MeetingTranscriptionFailure(
            MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
            reason,
        )

    private class LiveSession(
        val meetingId: String,
        val recordingId: String,
        val sessionId: String,
        val directory: File,
        recordingCompleted: Boolean,
        captureStopped: Boolean,
    ) {
        @Volatile
        var recordingCompleted: Boolean = recordingCompleted

        @Volatile
        var configuration: MeetingTranscriptionConfiguration? = null

        @Volatile
        var configurationFailure: MeetingTranscriptionFailure? = null

        @Volatile
        var lastFailure: MeetingTranscriptionFailure? = null

        @Volatile
        var captureStopped: Boolean = captureStopped

        @Volatile
        var cancelRequested: Boolean = false

        @Volatile
        var discardRequested: Boolean = false

        @Volatile
        var cancelDispatchedFor: String? = null

        @Volatile
        var cancelUnconfirmed: Boolean = false

        @Volatile
        var inFlightOperationId: String? = null

        @Volatile
        var worker: Job? = null

        @Volatile
        var scheduleAgain: Boolean = false
    }

    companion object {
        private const val DEFAULT_CHUNK_SECONDS = 30
        private const val PAGE_LIMIT = 200
        private const val MAX_SEGMENTS = 2_000
        private const val MAX_LIVE_ATTEMPTS = 3
        private const val MAX_TRANSCRIPT_MILLIS = 12L * 60L * 60L * 1_000L
        private const val MAX_TEXT_CHARS = 2_000
        private const val CANCEL_TIMEOUT_MILLIS = 30_000L
        private val NON_RETRYABLE_LIVE_FAILURES = setOf(
            MeetingTranscriptionFailureCode.NOT_CONFIGURED,
            MeetingTranscriptionFailureCode.CREDENTIAL_MISSING,
            MeetingTranscriptionFailureCode.UNSUPPORTED_MODEL,
            MeetingTranscriptionFailureCode.AUTHENTICATION,
            MeetingTranscriptionFailureCode.NEEDS_CORE_UPDATE,
            MeetingTranscriptionFailureCode.INVALID_IDENTIFIER,
            MeetingTranscriptionFailureCode.INVALID_REQUEST,
            MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE,
            MeetingTranscriptionFailureCode.SOURCE_UNREADABLE,
            MeetingTranscriptionFailureCode.UNSUPPORTED_AUDIO,
            MeetingTranscriptionFailureCode.SOURCE_TOO_LARGE,
        )
    }
}

private object MeetingLiveTranscriptionProcess {
    private var owner: MeetingLiveTranscriptionOwner? = null

    fun acquire(
        context: Context,
        currentEpoch: () -> Long?,
    ): MeetingLiveTranscriptionOwner = synchronized(this) {
        owner?.also { it.updateEpochProvider(currentEpoch) }
            ?: MeetingLiveTranscriptionOwner(
                repositoryProvider = { repositoryFor(context) },
                epochProvider = currentEpoch,
                ioDispatcher = Dispatchers.IO,
                backend = SwiftMeetingTranscriptionBackend(),
            ).also { owner = it }
    }

    private fun repositoryFor(context: Context): MeetingRepository {
        val app = context.applicationContext ?: context
        val store = MeetingStoreRegistry.get(app)
        store.ensureLoaded(com.floe.android.host.meeting.MeetingMediaProbe::probe)
        return store.repository
    }
}
