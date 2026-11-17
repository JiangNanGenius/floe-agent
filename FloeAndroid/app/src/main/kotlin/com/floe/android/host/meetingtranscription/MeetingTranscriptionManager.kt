// SPDX-License-Identifier: MPL-2.0
//
// Independent meeting cloud transcription owner.
//
// One process-wide session at a time:
//  * resolves the exact playable recording/import from the meeting store by
//    canonical meeting ID + material ID (never a model/UI path);
//  * reads the user's canonical cloud voice selection and reuses the existing
//    provider credential through the Swift domain;
//  * decodes bounded PCM chunks with the existing C03 audio chunker, uploads
//    each chunk with its real source offset, and returns only provider-timed
//    text;
//  * commits through the meeting repository's revision/material/snapshot
//    check, so a stale or concurrent attempt cannot overwrite a newer
//    transcript.
//
// The attempt is owned by a process-scoped coordinator, not by the Compose
// caller. Leaving the page, recomposition, backgrounding or re-entering the
// meeting does not cancel it. Only an explicit [MeetingTranscriptionManager.cancel]
// asks the provider to stop. There is no local model, no fabricated transcript
// and no silent fallback.
package com.floe.android.host.meetingtranscription

import android.content.Context
import com.floe.android.host.meeting.MediaProbe
import com.floe.android.host.meeting.MeetingErrorCode
import com.floe.android.host.meeting.MeetingException
import com.floe.android.host.meeting.MeetingIds
import com.floe.android.host.meeting.MeetingMediaProbe
import com.floe.android.host.meeting.MeetingRepository
import com.floe.android.host.meeting.MeetingStoreRegistry
import com.floe.android.host.meeting.MeetingTranscriptionReceipt
import com.floe.android.host.meeting.MeetingTranscriptionSnapshot
import com.floe.android.host.meeting.StoredTranscriptSegment
import com.floe.android.host.voice.C03TimedSegment
import com.floe.android.host.voice.C03VoiceErrorCode
import com.floe.android.host.voice.C03VoiceFailure
import kotlin.math.roundToLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * Result of an explicit start request.
 *
 * [Started] means this manager now owns the one process-wide attempt and
 * [MeetingTranscriptionManager.state] will report its progress. [Busy] is
 * returned only to the rejected second caller: it never replaces the running
 * session's observable state, so the first caller can still cancel it.
 * [Rejected] means the request itself was invalid and no attempt exists.
 */
sealed interface MeetingTranscriptionStart {
    data class Started(
        val meetingId: String,
        val materialId: String,
    ) : MeetingTranscriptionStart

    data class Busy(
        val failure: MeetingTranscriptionFailure,
    ) : MeetingTranscriptionStart

    data class Rejected(
        val failure: MeetingTranscriptionFailure,
    ) : MeetingTranscriptionStart
}

/** Outcome of [MeetingTranscriptionManager.cancel]. */
enum class MeetingTranscriptionCancelResult {
    /** The running attempt was fenced as cancelled; provider cancellation was requested. */
    REQUESTED,

    /**
     * The attempt already owned the commit fence. Committing wins: the
     * transcript is allowed to finish and the caller must not claim that it
     * was cancelled.
     */
    TOO_LATE,

    /** No attempt was active. */
    IDLE,
}

/**
 * A temporary source snapshot that could not be confirmed removed. The
 * original material, notes and committed transcript are unaffected; the
 * repository retains its stale-snapshot recovery path for the next attempt.
 */
data class MeetingTranscriptionCleanupFailure(
    val meetingId: String,
    val materialId: String,
    val snapshotId: String,
    val reason: String,
    val retryable: Boolean = true,
)

/**
 * UI-facing owner for the one meeting transcription attempt in this process.
 *
 * ```kotlin
 * val manager = MeetingTranscriptionManager(context, { runtimeHost.nativeRootEpoch() })
 * val state by manager.state.collectAsState()
 * val start = manager.start(meetingId, materialId, expectedRevision)
 * // Cancel only from an explicit user action.
 * manager.cancel()
 * ```
 *
 * Managers constructed with an application [Context] share one process-wide
 * coordinator, so recreating the meeting page (or rotating the device) shows
 * the same running attempt instead of starting a second one. The legacy
 * [transcribe] call remains available for a caller that wants to await the
 * receipt, but its coroutine is no longer the owner: cancelling the caller's
 * coroutine does not stop the process-owned attempt.
 *
 * Root-epoch limitation: this owner re-reads the live epoch before admitting
 * the durable write and passes the same non-suspending check to the
 * repository, which runs it under its own mutex immediately before the
 * metadata write. That covers the repository wait window, but root retirement
 * does not take those locks, so a retirement in the tiny interval after the
 * callback and before the write remains possible. This lane does not claim an
 * absolute linearization with root retirement. Source-byte/digest/revision CAS
 * still prevents a stale or same-length replacement from committing.
 *
 * [close] intentionally does not cancel. Page disposal is not a cancellation
 * signal; only [cancel] is. A process restart loses the live attempt and its
 * observable state. This owner never presents a leftover snapshot or a stale
 * receipt as resumed work; the repository's own stale-snapshot recovery is the
 * only cleanup path.
 */
class MeetingTranscriptionManager internal constructor(
    private val owner: MeetingTranscriptionOwner,
) {
    constructor(
        context: Context,
        currentEpoch: () -> Long?,
    ) : this(
        owner = MeetingTranscriptionProcess.acquire(
            context = context.applicationContext ?: context,
            currentEpoch = currentEpoch,
        ),
    )

    /**
     * Test seam with one fixed extractor instance. Production should use the
     * context constructor or the factory overload so every attempt gets a
     * fresh chunker: [com.floe.android.host.voice.C03AudioChunker] cannot be
     * reused after [MeetingAudioExtractor.cancel].
     */
    internal constructor(
        repository: MeetingRepository,
        currentEpoch: () -> Long?,
        ioDispatcher: CoroutineDispatcher,
        backend: MeetingTranscriptionBackend,
        extractor: MeetingAudioExtractor,
        probe: MediaProbe,
    ) : this(
        owner = MeetingTranscriptionOwner(
            repositoryProvider = { repository },
            epochProvider = currentEpoch,
            ioDispatcher = ioDispatcher,
            backend = backend,
            extractorFactory = { extractor },
            probe = probe,
        ),
    )

    /** Test seam that proves a retry after cancel creates a fresh extractor. */
    internal constructor(
        repository: MeetingRepository,
        currentEpoch: () -> Long?,
        ioDispatcher: CoroutineDispatcher,
        backend: MeetingTranscriptionBackend,
        extractorFactory: () -> MeetingAudioExtractor,
        probe: MediaProbe,
    ) : this(
        owner = MeetingTranscriptionOwner(
            repositoryProvider = { repository },
            epochProvider = currentEpoch,
            ioDispatcher = ioDispatcher,
            backend = backend,
            extractorFactory = extractorFactory,
            probe = probe,
        ),
    )

    val state: StateFlow<MeetingTranscriptionState> = owner.state

    /** Observable non-fatal snapshot cleanup failure; never silently dropped. */
    val cleanupFailure: StateFlow<MeetingTranscriptionCleanupFailure?> = owner.cleanupFailure

    /**
     * Cheap preflight for the page. It resolves only the app-owned material and
     * the canonical cloud selection; it does not copy the source file and does
     * not open a provider operation.
     */
    suspend fun readiness(
        meetingId: String,
        materialId: String,
    ): MeetingTranscriptionReadiness = owner.readiness(meetingId, materialId)

    /**
     * Claims the process-wide attempt and returns immediately. Progress is
     * observable through [state]; the job keeps running if the caller or its
     * Compose scope goes away.
     */
    fun start(
        meetingId: String,
        materialId: String,
        expectedTranscriptionRevision: Long? = null,
    ): MeetingTranscriptionStart {
        val started = owner.start(meetingId, materialId, expectedTranscriptionRevision)
        return when (started) {
            is MeetingTranscriptionOwnedStart.Started -> MeetingTranscriptionStart.Started(
                meetingId = started.attempt.meetingId,
                materialId = started.attempt.materialId,
            )
            is MeetingTranscriptionOwnedStart.Busy -> MeetingTranscriptionStart.Busy(started.failure)
            is MeetingTranscriptionOwnedStart.Rejected ->
                MeetingTranscriptionStart.Rejected(started.failure)
        }
    }

    /**
     * Runs one complete meeting transcription and awaits its durable receipt.
     *
     * The attempt itself belongs to the process coordinator. If this caller's
     * coroutine is cancelled, only the wait ends; use [cancel] to actually
     * cancel the work. [expectedTranscriptionRevision] is optional; when
     * supplied it must equal the revision resolved for the snapshot. The
     * commit re-checks the captured snapshot bytes, digest, revision and the
     * live root epoch (with the epoch check repeated under the repository
     * mutex), so a concurrent transcript write produces a typed conflict
     * instead of an overwrite.
     */
    suspend fun transcribe(
        meetingId: String,
        materialId: String,
        expectedTranscriptionRevision: Long? = null,
    ): MeetingTranscriptionReceipt {
        return when (val started = owner.start(meetingId, materialId, expectedTranscriptionRevision)) {
            is MeetingTranscriptionOwnedStart.Busy -> throw MeetingTranscriptionException(started.failure)
            is MeetingTranscriptionOwnedStart.Rejected ->
                throw MeetingTranscriptionException(started.failure)
            is MeetingTranscriptionOwnedStart.Started -> started.attempt.awaitReceipt()
        }
    }

    /**
     * Explicit cancellation. It is linearized against the final commit: if the
     * commit already owns the fence, this returns [MeetingTranscriptionCancelResult.TOO_LATE]
     * and the transcript is allowed to finish instead of being reported as
     * cancelled. A successful request also asks the provider to stop even if
     * this manager/page is gone.
     */
    fun cancel(): MeetingTranscriptionCancelResult = owner.cancel()

    /**
     * Releases nothing; it never cancels a running attempt. Page disposal,
     * backgrounding and rotation are not user cancellation.
     */
    fun close() = Unit

    /** Acknowledges the last cleanup warning for this process. */
    fun acknowledgeCleanupFailure() = owner.acknowledgeCleanupFailure()
}

/* ------------------------------------------------------------------------- */
/* Process-owned attempt                                                     */
/* ------------------------------------------------------------------------- */

/**
 * One process-wide owner. It keeps the application context's repository, the
 * root epoch resolver, the backend and the process scope for the life of the
 * app process.
 */
internal class MeetingTranscriptionOwner(
    private val repositoryProvider: () -> MeetingRepository,
    epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher,
    private val backend: MeetingTranscriptionBackend,
    private val extractorFactory: () -> MeetingAudioExtractor,
    private val probe: MediaProbe,
) {
    @Volatile
    private var epochProvider: () -> Long? = epochProvider

    private val processScope = CoroutineScope(
        SupervisorJob() + ioDispatcher + CoroutineName("meeting-transcription"),
    )
    private val stateLock = Any()
    private val _state = MutableStateFlow(MeetingTranscriptionState())
    val state: StateFlow<MeetingTranscriptionState> = _state.asStateFlow()
    private val _cleanupFailure = MutableStateFlow<MeetingTranscriptionCleanupFailure?>(null)
    val cleanupFailure: StateFlow<MeetingTranscriptionCleanupFailure?> =
        _cleanupFailure.asStateFlow()

    /**
     * Serializes cancellation against commit admission. Commit holds it while
     * it re-checks the epoch and writes the transcript; cancel uses `tryLock`
     * so it can never interleave with a commit that already started.
     */
    private val commitFence = Mutex()

    private var active: MeetingTranscriptionAttempt? = null
    private var lastSettled: MeetingTranscriptionAttempt? = null

    fun updateEpochProvider(provider: () -> Long?) {
        epochProvider = provider
    }

    fun acknowledgeCleanupFailure() {
        _cleanupFailure.value = null
    }

    suspend fun readiness(
        meetingId: String,
        materialId: String,
    ): MeetingTranscriptionReadiness = withContext(ioDispatcher) {
        try {
            val epoch = requireEpoch()
            val source = repositoryProvider().transcriptionSource(meetingId, materialId, probe)
            val configuration = backend.configuration(epoch)
            MeetingTranscriptionReadiness.Ready(
                meetingId = source.material.meetingId,
                materialId = source.material.id,
                providerName = configuration.providerName,
                durationMillis = source.durationMillis,
                transcriptionRevision = source.transcriptionRevision,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            MeetingTranscriptionReadiness.Unavailable(meetingTranscriptionFailureOf(error))
        }
    }

    fun start(
        meetingId: String,
        materialId: String,
        expectedTranscriptionRevision: Long?,
    ): MeetingTranscriptionOwnedStart {
        try {
            MeetingIds.require(meetingId)
            MeetingIds.require(materialId)
        } catch (error: MeetingException) {
            return MeetingTranscriptionOwnedStart.Rejected(meetingTranscriptionFailureOf(error))
        }
        val attempt = synchronized(stateLock) {
            if (active != null) {
                // Busy is returned only to this caller. The running attempt's
                // observable state must not be replaced by this rejection.
                return MeetingTranscriptionOwnedStart.Busy(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.BUSY,
                        "transcriptionAlreadyRunning",
                        retryable = true,
                    ),
                )
            }
            val created = MeetingTranscriptionAttempt(
                meetingId = meetingId,
                materialId = materialId,
                expectedTranscriptionRevision = expectedTranscriptionRevision,
                startedAtMillis = System.currentTimeMillis(),
            )
            active = created
            lastSettled = null
            _state.value = MeetingTranscriptionState(
                phase = MeetingTranscriptionPhase.PREPARING,
                session = MeetingTranscriptionSession(
                    meetingId = meetingId,
                    materialId = materialId,
                    startedAtMillis = created.startedAtMillis,
                    completedChunks = 0,
                    totalChunks = 0,
                    progress = 0.0,
                ),
            )
            created
        }
        try {
            attempt.job = processScope.launch(start = CoroutineStart.LAZY) {
                runAttempt(attempt)
            }
            attempt.job?.start()
        } catch (error: Throwable) {
            // A dispatcher rejection must not leave a forever-PREPARING slot.
            attempt.job?.cancel(CancellationException("meetingTranscriptionStartFailed"))
            val failure = meetingTranscriptionFailureOf(error)
            settle(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.FAILED,
                    session = _state.value.session,
                    failure = failure,
                ),
            )
            attempt.completion.completeExceptionally(MeetingTranscriptionException(failure, error))
            return MeetingTranscriptionOwnedStart.Rejected(failure)
        }
        return MeetingTranscriptionOwnedStart.Started(attempt)
    }

    fun cancel(): MeetingTranscriptionCancelResult {
        val attempt = synchronized(stateLock) { active } ?: return MeetingTranscriptionCancelResult.IDLE
        if (attempt.cancelRequested) return MeetingTranscriptionCancelResult.REQUESTED
        if (!commitFence.tryLock()) {
            // The commit already owns the fence. Do not pretend this request
            // stopped anything: the durable transcript will finish.
            return MeetingTranscriptionCancelResult.TOO_LATE
        }
        val fenced = try {
            if (!attempt.fence.tryCancel()) {
                return if (attempt.fence.isFinished()) {
                    MeetingTranscriptionCancelResult.IDLE
                } else {
                    MeetingTranscriptionCancelResult.TOO_LATE
                }
            }
            attempt.cancelRequested = true
            publish(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.CANCELLING,
                    session = _state.value.session,
                ),
            )
            true
        } finally {
            commitFence.unlock()
        }
        if (!fenced) return MeetingTranscriptionCancelResult.TOO_LATE

        // These run outside the commit fence so the attempt can settle as
        // CANCELLED without waiting for a provider response. The provider
        // cancel is launched in the process scope, so it still runs after the
        // page is gone.
        attempt.extractor?.cancel()
        requestBackendCancel(attempt)
        attempt.job?.cancel(CancellationException("meetingTranscriptionCancelled"))
        settleCancelledIfStillRunning(attempt)
        return MeetingTranscriptionCancelResult.REQUESTED
    }

    /**
     * A coroutine cancelled before its body starts never reaches the attempt's
     * catch/finally. This watcher is the guaranteed settlement path for that
     * case; a normal cancellation settles inside [runAttempt] and makes this a
     * no-op.
     */
    private fun settleCancelledIfStillRunning(attempt: MeetingTranscriptionAttempt) {
        val job = attempt.job ?: return
        processScope.launch {
            job.join()
            val failure = if (attempt.cancelUnconfirmed) {
                MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.CANCELLED,
                    "cancelUnconfirmed",
                    retryable = true,
                )
            } else {
                null
            }
            val settledNow = settle(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.CANCELLED,
                    session = _state.value.session,
                    failure = failure,
                ),
            )
            if (settledNow) {
                attempt.completion.completeExceptionally(
                    MeetingTranscriptionException(
                        failure ?: MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.CANCELLED,
                            "meetingTranscriptionCancelled",
                        ),
                    ),
                )
            }
        }
    }

    private suspend fun runAttempt(attempt: MeetingTranscriptionAttempt) {
        var snapshot: MeetingTranscriptionSnapshot? = null
        var settled = false
        try {
            val epoch = requireEpoch()
            attempt.epoch = epoch
            throwIfCancelled(attempt)
            val repository = repositoryProvider()
            val source = repository.createTranscriptionSnapshot(
                meetingId = attempt.meetingId,
                materialId = attempt.materialId,
                probe = probe,
            )
            snapshot = source
            requireSameEpoch(attempt)
            if (attempt.expectedTranscriptionRevision != null &&
                (attempt.expectedTranscriptionRevision < 0L ||
                    attempt.expectedTranscriptionRevision != source.transcriptionRevision)
            ) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.STALE_REVISION,
                        "transcriptionRevisionChanged",
                        retryable = true,
                    ),
                )
            }
            throwIfCancelled(attempt)
            val configuration = backend.configuration(epoch)
            throwIfCancelled(attempt)
            if (source.sourceBytes <= 0L) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE,
                        "sourceFileEmpty",
                    ),
                )
            }
            val durationSeconds = source.durationMillis.toDouble() / 1_000.0
            if (durationSeconds <= 0.0) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.SOURCE_UNREADABLE,
                        "durationUnavailable",
                    ),
                )
            }
            attempt.planStarted = true
            val planned = backend.plan(
                epoch = epoch,
                meetingId = attempt.meetingId,
                materialId = attempt.materialId,
                sourceBytes = source.sourceBytes,
                durationSeconds = durationSeconds,
                configuration = configuration,
            )
            attempt.operationId = planned.operationId
            if (attempt.cancelRequested) {
                // The request arrived while plan was in flight. The operation
                // now has a real ID, so ask the provider to drain it.
                requestBackendCancel(attempt)
                throw CancellationException("meetingTranscriptionCancelled")
            }
            publish(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.TRANSCRIBING,
                    session = runningSession(
                        attempt = attempt,
                        completedChunks = 0,
                        totalChunks = planned.estimatedChunks,
                    ),
                ),
            )
            // A new extractor per attempt: C03AudioChunker's cancelled state is
            // terminal and a retry must not inherit it.
            val runningExtractor = extractorFactory()
            attempt.extractor = runningExtractor
            var completedChunks = 0
            runningExtractor.extract(
                sourcePath = source.file.path,
                stagingPath = planned.stagingPath,
                chunkLimitBytes = planned.chunkLimitBytes,
            ) { chunk ->
                throwIfCancelled(attempt)
                backend.applyChunk(
                    meetingId = attempt.meetingId,
                    materialId = attempt.materialId,
                    operationId = planned.operationId,
                    chunkIndex = chunk.index,
                    sourceStartSeconds = chunk.sourceStartSeconds,
                    sourceDurationSeconds = chunk.durationSeconds,
                    sampleRate = chunk.sampleRate,
                    channels = chunk.channels,
                )
                throwIfCancelled(attempt)
                completedChunks += 1
                publish(
                    attempt,
                    MeetingTranscriptionState(
                        phase = MeetingTranscriptionPhase.TRANSCRIBING,
                        session = runningSession(
                            attempt = attempt,
                            completedChunks = completedChunks,
                            totalChunks = maxOf(planned.estimatedChunks, completedChunks),
                        ),
                    ),
                )
            }
            throwIfCancelled(attempt)
            publish(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.FINALIZING,
                    session = runningSession(
                        attempt = attempt,
                        completedChunks = completedChunks,
                        totalChunks = maxOf(planned.estimatedChunks, completedChunks),
                    ),
                ),
            )
            val finished = backend.finish(
                meetingId = attempt.meetingId,
                materialId = attempt.materialId,
                operationId = planned.operationId,
                totalChunks = completedChunks,
                sourceDurationSeconds = durationSeconds,
            )
            if (finished <= 0) {
                throw MeetingTranscriptionException(
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.EMPTY_TRANSCRIPT,
                        "emptyTranscript",
                    ),
                )
            }
            requireSameEpoch(attempt)
            val timed = readTimedSegments(attempt, planned.operationId)
            if (timed.size != finished) {
                // finish() and page() must describe the same transcript. A
                // provider/bridge difference is an incomplete result, not
                // something to commit partially.
                throw incompleteTranscript("transcriptCountMismatch")
            }
            throwIfCancelled(attempt)
            val receipt = commitFenced(attempt) {
                // The repository calls this after it acquires its own
                // mutex and immediately before the durable metadata write.
                // It is non-suspending and must throw on a stale generation.
                // Even this check is not an absolute linearization against
                // root retirement: retirement does not take these locks, so a
                // retirement after the check and before the write remains a
                // very short residual race. Source byte/digest/revision CAS
                // is still authoritative for source and transcript identity.
                repository.commitTranscription(
                    meetingId = attempt.meetingId,
                    materialId = attempt.materialId,
                    expectedSourceBytes = source.sourceBytes,
                    expectedSourceSha256 = source.sourceSha256,
                    expectedTranscriptionRevision = source.transcriptionRevision,
                    language = configuration.language,
                    segments = toStoredSegments(attempt.materialId, timed),
                    validateBeforeCommit = {
                        throwIfCancelled(attempt)
                        requireSameEpoch(attempt)
                    },
                )
            }
            settled = settle(
                attempt,
                MeetingTranscriptionState(
                    phase = MeetingTranscriptionPhase.COMPLETED,
                    session = runningSession(
                        attempt = attempt,
                        completedChunks = completedChunks,
                        totalChunks = maxOf(planned.estimatedChunks, completedChunks),
                        completed = true,
                    ),
                    receipt = receipt,
                ),
            )
            attempt.completion.complete(receipt)
        } catch (cancelled: CancellationException) {
            requestBackendCancel(attempt)
            val explicitlyCancelled = attempt.cancelRequested || attempt.fence.isCancelled()
            if (!explicitlyCancelled) {
                // Only the explicit Cancel action may report CANCELLED. An
                // unexpected cancellation is an internal failure, not a user
                // cancellation, and no transcript was written.
                val failure = MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.INTERNAL,
                    "transcriptionCancelledUnexpectedly",
                )
                settled = settle(
                    attempt,
                    MeetingTranscriptionState(
                        phase = MeetingTranscriptionPhase.FAILED,
                        session = _state.value.session,
                        failure = failure,
                    ),
                )
                attempt.completion.completeExceptionally(
                    MeetingTranscriptionException(failure, cancelled),
                )
            } else {
                val failure = if (attempt.cancelUnconfirmed) {
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.CANCELLED,
                        "cancelUnconfirmed",
                        retryable = true,
                    )
                } else {
                    null
                }
                settled = settle(
                    attempt,
                    MeetingTranscriptionState(
                        phase = MeetingTranscriptionPhase.CANCELLED,
                        session = _state.value.session,
                        failure = failure,
                    ),
                )
                attempt.completion.completeExceptionally(
                    MeetingTranscriptionException(
                        failure ?: MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.CANCELLED,
                            "meetingTranscriptionCancelled",
                        ),
                        cancelled,
                    ),
                )
            }
        } catch (error: Throwable) {
            // A failed operation may still be open on the provider. Ask it to
            // drain even when the local attempt ended in FAILED.
            requestBackendCancel(attempt)
            val failure = meetingTranscriptionFailureOf(error)
            // A cancellation that also surfaced as a provider failure must
            // still be reported as cancelled, not as a successful transcript.
            val phase = if (attempt.cancelRequested) {
                MeetingTranscriptionPhase.CANCELLED
            } else {
                MeetingTranscriptionPhase.FAILED
            }
            settled = settle(
                attempt,
                MeetingTranscriptionState(
                    phase = phase,
                    session = _state.value.session,
                    failure = failure,
                ),
            )
            attempt.completion.completeExceptionally(
                if (error is MeetingTranscriptionException) error
                else MeetingTranscriptionException(failure, error),
            )
        } finally {
            val ownedSnapshot = snapshot
            if (ownedSnapshot != null) {
                // Snapshot cleanup must happen for success, failure and
                // cancellation, and must not be skipped by coroutine cancel.
                // A false return or an exception is observable: the repository
                // retains its stale-snapshot recovery path, so this is a
                // cleanup warning, not a fake success or a destructive retry.
                val released = withContext(NonCancellable) {
                    runCatching {
                        repositoryProvider().releaseTranscriptionSource(
                            meetingId = attempt.meetingId,
                            snapshotId = ownedSnapshot.snapshotId,
                        )
                    }
                }
                if (released.getOrNull() != true) {
                    _cleanupFailure.value = MeetingTranscriptionCleanupFailure(
                        meetingId = attempt.meetingId,
                        materialId = attempt.materialId,
                        snapshotId = ownedSnapshot.snapshotId,
                        reason = if (released.isFailure) {
                            "snapshotReleaseFailed"
                        } else {
                            "snapshotReleaseUnconfirmed"
                        },
                        retryable = true,
                    )
                }
            }
            attempt.extractor = null
            if (!settled) {
                val failure = if (attempt.cancelRequested) {
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.CANCELLED,
                        if (attempt.cancelUnconfirmed) "cancelUnconfirmed" else "meetingTranscriptionCancelled",
                        retryable = attempt.cancelUnconfirmed,
                    )
                } else {
                    MeetingTranscriptionFailure(
                        MeetingTranscriptionFailureCode.INTERNAL,
                        "transcriptionEndedUnexpectedly",
                    )
                }
                settle(
                    attempt,
                    MeetingTranscriptionState(
                        phase = if (attempt.cancelRequested) {
                            MeetingTranscriptionPhase.CANCELLED
                        } else {
                            MeetingTranscriptionPhase.FAILED
                        },
                        session = _state.value.session,
                        failure = failure,
                    ),
                )
                attempt.completion.completeExceptionally(MeetingTranscriptionException(failure))
            }
        }
    }

    /**
     * The only place that admits a durable transcript write. Cancellation and
     * commit share [commitFence]; a successful cancel always wins before this
     * block, and a commit that already started cannot be cancelled. The live
     * root epoch is re-read inside the same fence; a stale epoch rejects the
     * write with a typed retryable failure.
     *
     * The epoch check is also passed to the repository as
     * `validateBeforeCommit`, which re-runs it under the repository mutex
     * immediately before the durable write. This narrows the race but is not
     * an absolute linearization: root retirement does not take the same lock,
     * so a retirement after that callback and before the write remains a very
     * short residual race. The durable source-byte/digest/revision CAS remains
     * authoritative for source and transcript identity.
     */
    private suspend fun commitFenced(
        attempt: MeetingTranscriptionAttempt,
        commit: suspend () -> MeetingTranscriptionReceipt,
    ): MeetingTranscriptionReceipt = withContext(NonCancellable) {
        commitFence.withLock {
            when (attempt.fence.tryBeginCommit(attempt.epoch, epochProvider())) {
                MeetingTranscriptionCommitAdmission.ADMITTED -> {
                    if (attempt.cancelRequested) {
                        throw CancellationException("meetingTranscriptionCancelled")
                    }
                    commit()
                }
                MeetingTranscriptionCommitAdmission.CANCELLED ->
                    throw CancellationException("meetingTranscriptionCancelled")
                MeetingTranscriptionCommitAdmission.EPOCH_CHANGED ->
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
                            "rootEpochChanged",
                            retryable = true,
                        ),
                    )
                MeetingTranscriptionCommitAdmission.FINISHED ->
                    throw MeetingTranscriptionException(
                        MeetingTranscriptionFailure(
                            MeetingTranscriptionFailureCode.INTERNAL,
                            "attemptAlreadySettled",
                        ),
                    )
            }
        }
    }

    /**
     * Reads every page the provider reports. The total must be stable, every
     * cursor must strictly advance, no page may be empty while more segments
     * are expected, and the final count must exactly match the total. A
     * partial transcript is never committed.
     */
    private suspend fun readTimedSegments(
        attempt: MeetingTranscriptionAttempt,
        operationId: String,
    ): List<C03TimedSegment> {
        var offset = 0
        var expectedTotal: Int? = null
        val result = ArrayList<C03TimedSegment>()
        while (true) {
            throwIfCancelled(attempt)
            val page = backend.page(
                meetingId = attempt.meetingId,
                materialId = attempt.materialId,
                operationId = operationId,
                offset = offset,
                limit = PAGE_LIMIT,
            )
            val total = page.total
            if (total < 0 || total > MAX_SEGMENTS) throw incompleteTranscript("transcriptTooLong")
            val expected = expectedTotal
            if (expected == null) {
                if (total == 0) throw incompleteTranscript("transcriptPageEmpty")
                expectedTotal = total
            } else if (total != expected) {
                throw incompleteTranscript("transcriptPageInconsistent")
            }
            if (offset >= total) break
            if (page.segments.isEmpty()) throw incompleteTranscript("transcriptPageEmpty")
            if (page.segments.size > PAGE_LIMIT) throw incompleteTranscript("transcriptPageOverflow")
            val next = offset + page.segments.size
            if (next <= offset || next > total) {
                throw incompleteTranscript("transcriptPageOverflow")
            }
            result += page.segments
            offset = next
            if (offset == total) break
        }
        val total = expectedTotal ?: throw incompleteTranscript("transcriptPageEmpty")
        if (offset != total || result.size != total) {
            throw incompleteTranscript("transcriptPageIncomplete")
        }
        return result
    }

    private fun incompleteTranscript(reason: String): MeetingTranscriptionException =
        MeetingTranscriptionException(
            MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT,
                reason,
            ),
        )

    private fun requestBackendCancel(attempt: MeetingTranscriptionAttempt) {
        if (attempt.cancelDispatched) return
        val operationId = attempt.operationId
        if (operationId == null) {
            // Only an in-flight/failed plan may have created a provider
            // operation whose response was lost. A cancel before plan has no
            // provider operation to confirm.
            if (attempt.planStarted) attempt.cancelUnconfirmed = true
            return
        }
        attempt.cancelDispatched = true
        processScope.launch {
            // A hung bridge is an unconfirmed stop, not a silent success.
            val confirmed = runCatching {
                withTimeout(CANCEL_RECEIPT_TIMEOUT_MS) {
                    backend.cancel(attempt.meetingId, attempt.materialId, operationId)
                }
            }.isSuccess
            if (!confirmed) {
                attempt.cancelUnconfirmed = true
                updateCancelWarning(attempt)
            }
        }
    }

    private fun updateCancelWarning(attempt: MeetingTranscriptionAttempt) {
        synchronized(stateLock) {
            val current = _state.value
            val ownsState = active === attempt || (active == null && lastSettled === attempt)
            if (!ownsState || current.phase != MeetingTranscriptionPhase.CANCELLED) return
            _state.value = current.copy(
                failure = MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.CANCELLED,
                    "cancelUnconfirmed",
                    retryable = true,
                ),
            )
        }
    }

    private fun publish(
        attempt: MeetingTranscriptionAttempt,
        state: MeetingTranscriptionState,
    ) {
        synchronized(stateLock) {
            if (active !== attempt) return
            val current = _state.value.phase
            if (current == MeetingTranscriptionPhase.CANCELLING &&
                state.phase != MeetingTranscriptionPhase.CANCELLED &&
                state.phase != MeetingTranscriptionPhase.FAILED &&
                state.phase != MeetingTranscriptionPhase.COMPLETED
            ) {
                return
            }
            _state.value = state
        }
    }

    /** Publishes one terminal state and releases the single active slot. */
    private fun settle(
        attempt: MeetingTranscriptionAttempt,
        state: MeetingTranscriptionState,
    ): Boolean {
        attempt.fence.finish()
        synchronized(stateLock) {
            if (active !== attempt) return false
            _state.value = state
            active = null
            lastSettled = attempt
            return true
        }
    }

    private fun throwIfCancelled(attempt: MeetingTranscriptionAttempt) {
        if (attempt.cancelRequested || attempt.fence.isCancelled()) {
            throw CancellationException("meetingTranscriptionCancelled")
        }
    }

    private fun requireSameEpoch(attempt: MeetingTranscriptionAttempt) {
        val live = epochProvider()
        if (live == null || live <= 0L) {
            throw MeetingTranscriptionException(
                MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
                    "rootNotLive",
                    retryable = true,
                ),
            )
        }
        if (live != attempt.epoch) {
            throw MeetingTranscriptionException(
                MeetingTranscriptionFailure(
                    MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
                    "rootEpochChanged",
                    retryable = true,
                ),
            )
        }
    }

    private fun requireEpoch(): Long {
        val epoch = epochProvider() ?: 0L
        if (epoch <= 0L) {
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

    private fun runningSession(
        attempt: MeetingTranscriptionAttempt,
        completedChunks: Int,
        totalChunks: Int,
        completed: Boolean = false,
    ): MeetingTranscriptionSession {
        val total = maxOf(totalChunks, completedChunks, if (completed) 1 else 0)
        val progress = if (completed) {
            1.0
        } else if (total <= 0) {
            0.0
        } else {
            (completedChunks.toDouble() / total.toDouble()).coerceIn(0.0, 0.99)
        }
        return MeetingTranscriptionSession(
            meetingId = attempt.meetingId,
            materialId = attempt.materialId,
            startedAtMillis = attempt.startedAtMillis,
            completedChunks = completedChunks,
            totalChunks = total,
            progress = progress,
        )
    }

    private fun toStoredSegments(
        materialId: String,
        segments: List<C03TimedSegment>,
    ): List<StoredTranscriptSegment> = segments.mapIndexed { index, segment ->
        StoredTranscriptSegment(
            id = "mt-$materialId-${index.toString().padStart(5, '0')}",
            startMillis = (segment.start * 1_000.0).roundToLong(),
            endMillis = (segment.end * 1_000.0).roundToLong(),
            text = segment.text,
            speaker = null,
        )
    }

    companion object {
        private const val PAGE_LIMIT = 200
        private const val MAX_SEGMENTS = 2_000
        private const val CANCEL_RECEIPT_TIMEOUT_MS = 30_000L
    }
}

internal sealed interface MeetingTranscriptionOwnedStart {
    data class Started(val attempt: MeetingTranscriptionAttempt) : MeetingTranscriptionOwnedStart
    data class Busy(val failure: MeetingTranscriptionFailure) : MeetingTranscriptionOwnedStart
    data class Rejected(val failure: MeetingTranscriptionFailure) : MeetingTranscriptionOwnedStart
}

/** Mutable state of one claimed attempt; only the owner touches it. */
internal class MeetingTranscriptionAttempt(
    val meetingId: String,
    val materialId: String,
    val expectedTranscriptionRevision: Long?,
    val startedAtMillis: Long,
) {
    val completion = CompletableDeferred<MeetingTranscriptionReceipt>()
    val fence = MeetingTranscriptionAttemptFence()

    @Volatile
    var epoch: Long = 0L

    @Volatile
    var planStarted: Boolean = false

    @Volatile
    var operationId: String? = null

    @Volatile
    var extractor: MeetingAudioExtractor? = null

    @Volatile
    var cancelRequested: Boolean = false

    @Volatile
    var cancelDispatched: Boolean = false

    @Volatile
    var cancelUnconfirmed: Boolean = false

    @Volatile
    var job: Job? = null

    suspend fun awaitReceipt(): MeetingTranscriptionReceipt = completion.await()
}

internal enum class MeetingTranscriptionCommitAdmission {
    ADMITTED,
    CANCELLED,
    EPOCH_CHANGED,
    FINISHED,
}

/**
 * Tiny serial state for one attempt. Cancellation and commit admission are
 * decided under the same monitor: whichever happens first wins, so a
 * cancellation observed before admission can never be followed by a write,
 * and a write that already owns admission cannot be misreported as cancelled.
 */
internal class MeetingTranscriptionAttemptFence {
    private val lock = Any()
    private var state = RUNNING

    fun tryBeginCommit(
        expectedEpoch: Long,
        liveEpoch: Long?,
    ): MeetingTranscriptionCommitAdmission = synchronized(lock) {
        when {
            state == CANCELLED -> MeetingTranscriptionCommitAdmission.CANCELLED
            state != RUNNING -> MeetingTranscriptionCommitAdmission.FINISHED
            liveEpoch == null || liveEpoch <= 0L || liveEpoch != expectedEpoch -> {
                // An invalid generation can never write back. Move to a
                // terminal fence so a later cancel cannot claim it either.
                state = CANCELLED
                MeetingTranscriptionCommitAdmission.EPOCH_CHANGED
            }
            else -> {
                state = COMMITTING
                MeetingTranscriptionCommitAdmission.ADMITTED
            }
        }
    }

    fun tryCancel(): Boolean = synchronized(lock) {
        if (state != RUNNING) {
            false
        } else {
            state = CANCELLED
            true
        }
    }

    fun isCancelled(): Boolean = synchronized(lock) { state == CANCELLED }

    fun isFinished(): Boolean = synchronized(lock) { state == FINISHED }

    fun finish() {
        synchronized(lock) {
            if (state != CANCELLED) state = FINISHED
        }
    }

    private companion object {
        const val RUNNING = 0
        const val COMMITTING = 1
        const val CANCELLED = 2
        const val FINISHED = 3
    }
}

/**
 * Process singleton used by the real app. Tests construct their own owner so
 * one test's fake backend can never leak into another.
 */
private object MeetingTranscriptionProcess {
    private var owner: MeetingTranscriptionOwner? = null

    fun acquire(
        context: Context,
        currentEpoch: () -> Long?,
    ): MeetingTranscriptionOwner = synchronized(this) {
        owner?.also { it.updateEpochProvider(currentEpoch) } ?: MeetingTranscriptionOwner(
            repositoryProvider = { repositoryFor(context) },
            epochProvider = currentEpoch,
            ioDispatcher = Dispatchers.IO,
            backend = SwiftMeetingTranscriptionBackend(),
            extractorFactory = { AndroidMeetingAudioExtractor() },
            probe = MeetingMediaProbe::probe,
        ).also { owner = it }
    }

    private fun repositoryFor(context: Context): MeetingRepository {
        val app = context.applicationContext ?: context
        val store = MeetingStoreRegistry.get(app)
        // Ensure an interrupted recording is recovered before it can be
        // resolved as a playable transcription source.
        store.ensureLoaded(MeetingMediaProbe::probe)
        return store.repository
    }
}

/* ------------------------------------------------------------------------- */
/* Failure mapping                                                           */
/* ------------------------------------------------------------------------- */

internal fun meetingTranscriptionFailureOf(error: Throwable): MeetingTranscriptionFailure {
    if (error is MeetingTranscriptionException) return error.failure
    if (error is C03VoiceFailure) {
        if (error.code == C03VoiceErrorCode.UNCONFIGURED &&
            error.reason == "runtimeNotInstalled"
        ) {
            return MeetingTranscriptionFailure(
                MeetingTranscriptionFailureCode.CORE_UNAVAILABLE,
                "runtimeNotInstalled",
                retryable = true,
            )
        }
        return MeetingTranscriptionFailure(
            code = when (error.code) {
                C03VoiceErrorCode.UNCONFIGURED ->
                    MeetingTranscriptionFailureCode.NOT_CONFIGURED
                C03VoiceErrorCode.CREDENTIAL_MISSING ->
                    MeetingTranscriptionFailureCode.CREDENTIAL_MISSING
                C03VoiceErrorCode.UNSUPPORTED_MODEL ->
                    MeetingTranscriptionFailureCode.UNSUPPORTED_MODEL
                C03VoiceErrorCode.TRANSPORT_UNAVAILABLE ->
                    MeetingTranscriptionFailureCode.TRANSPORT_UNAVAILABLE
                C03VoiceErrorCode.CORE_UNAVAILABLE ->
                    MeetingTranscriptionFailureCode.CORE_UNAVAILABLE
                C03VoiceErrorCode.NEEDS_CORE_UPDATE ->
                    MeetingTranscriptionFailureCode.NEEDS_CORE_UPDATE
                C03VoiceErrorCode.FILE_TOO_LARGE ->
                    MeetingTranscriptionFailureCode.SOURCE_TOO_LARGE
                C03VoiceErrorCode.FILE_UNREADABLE,
                C03VoiceErrorCode.UNSUPPORTED_MEDIA,
                C03VoiceErrorCode.CODEC_UNAVAILABLE,
                C03VoiceErrorCode.MEDIA_UNAVAILABLE,
                C03VoiceErrorCode.PROJECT_NOT_FOUND,
                C03VoiceErrorCode.SESSION_REQUIRED ->
                    MeetingTranscriptionFailureCode.SOURCE_UNREADABLE
                C03VoiceErrorCode.NEEDS_TIMING ->
                    MeetingTranscriptionFailureCode.NO_TIMED_TRANSCRIPT
                C03VoiceErrorCode.STALE_REVISION ->
                    MeetingTranscriptionFailureCode.STALE_REVISION
                C03VoiceErrorCode.BUSY -> MeetingTranscriptionFailureCode.BUSY
                C03VoiceErrorCode.EMPTY_TRANSCRIPT ->
                    MeetingTranscriptionFailureCode.EMPTY_TRANSCRIPT
                C03VoiceErrorCode.PROVIDER_REJECTED ->
                    MeetingTranscriptionFailureCode.PROVIDER_REJECTED
                C03VoiceErrorCode.AUTHENTICATION ->
                    MeetingTranscriptionFailureCode.AUTHENTICATION
                C03VoiceErrorCode.QUOTA_OR_RATE_LIMITED ->
                    MeetingTranscriptionFailureCode.QUOTA_OR_RATE_LIMITED
                C03VoiceErrorCode.NETWORK -> MeetingTranscriptionFailureCode.NETWORK
                C03VoiceErrorCode.CANCELLED -> MeetingTranscriptionFailureCode.CANCELLED
                C03VoiceErrorCode.TIMEOUT -> MeetingTranscriptionFailureCode.TIMEOUT
                C03VoiceErrorCode.WRITE_FAILED ->
                    MeetingTranscriptionFailureCode.STORAGE_FAILURE
                C03VoiceErrorCode.INVALID_RESPONSE,
                C03VoiceErrorCode.INTERNAL -> MeetingTranscriptionFailureCode.INTERNAL
                C03VoiceErrorCode.INVALID_SELECTION,
                C03VoiceErrorCode.PERMISSION_REQUIRED -> MeetingTranscriptionFailureCode.INVALID_REQUEST
            },
            reason = error.reason,
            retryable = error.retryable,
        )
    }
    if (error is MeetingException) {
        return MeetingTranscriptionFailure(
            code = when (error.code) {
                MeetingErrorCode.INVALID_IDENTIFIER ->
                    MeetingTranscriptionFailureCode.INVALID_IDENTIFIER
                MeetingErrorCode.NOT_FOUND -> MeetingTranscriptionFailureCode.NOT_FOUND
                MeetingErrorCode.INVALID_INPUT ->
                    MeetingTranscriptionFailureCode.INVALID_REQUEST
                MeetingErrorCode.CONFLICT ->
                    MeetingTranscriptionFailureCode.STALE_REVISION
                MeetingErrorCode.SOURCE_UNAVAILABLE,
                MeetingErrorCode.MISSING_MEDIA ->
                    MeetingTranscriptionFailureCode.SOURCE_UNAVAILABLE
                MeetingErrorCode.UNSUPPORTED_MEDIA,
                MeetingErrorCode.CORRUPT_MEDIA ->
                    MeetingTranscriptionFailureCode.UNSUPPORTED_AUDIO
                MeetingErrorCode.TOO_LARGE ->
                    MeetingTranscriptionFailureCode.SOURCE_TOO_LARGE
                MeetingErrorCode.STORAGE_FAILURE ->
                    MeetingTranscriptionFailureCode.STORAGE_FAILURE
                else -> MeetingTranscriptionFailureCode.INTERNAL
            },
            reason = error.code.name.lowercase(),
            retryable = error.error.retryable,
        )
    }
    return MeetingTranscriptionFailure(
        MeetingTranscriptionFailureCode.INTERNAL,
        "unexpectedFailure",
    )
}
