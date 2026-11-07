// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/** Local diagnostics only. Closed fields never carry owner IDs, messages,
 * commands, credentials or file names; nothing here grants or retains work. */
object RunForegroundTrace {
    enum class Origin { ORDINARY_OPERATION, AGENT_LAUNCH_PROVISIONAL, AGENT_RUN_AUTHORITATIVE }
    enum class Stage {
        ACQUIRE_ENTER, PREFLIGHT_BLOCKED, REGISTERED, ATTACHED, OWNER_CONFLICT,
        SERVICE_START_REQUESTED, SERVICE_START_REFUSED, SERVICE_CONFIRMED,
        CONFIRM_TIMEOUT, ACQUIRE_CANCELLED, DENIAL_TYPED,
        NOTICE_POSTED, NOTICE_SUPPRESSED, NOTICE_UI_BOUND,
        SERVICE_NOTIFICATION_FAILED, SERVICE_PROMOTION_REFUSED, SERVICE_INSTANCE_RETIRED, SERVICE_PROMOTION_CONFIRMED,
    }
    enum class FailureKind { NONE, NOTIFICATIONS_BLOCKED, START_DENIED, UNAVAILABLE, OWNER_CONFLICT }

    enum class Cause {
        NONE, START_RESTRICTED, START_PERMISSION, START_DELIVERY,
        NOTIFICATION_BUILD, PROMOTION_STATE_EXCEPTION, PROMOTION_SECURITY_EXCEPTION,
        INSTANCE_REPLACED,
    }

    data class Attempt internal constructor(val sequence: Long, val origin: Origin, val kind: OperationKind)
    data class Attribution internal constructor(val attempt: Attempt?, val failure: FailureKind, val cause: Cause)
    data class Entry internal constructor(
        val attempt: Attempt?, val stage: Stage, val failure: FailureKind, val cause: Cause, val monotonicNanos: Long,
    ) {
        internal fun line(): String =
            "attempt=${attempt?.sequence ?: 0} stage=${stage.name} " +
                "origin=${attempt?.origin?.name ?: "UNKNOWN"} kind=${attempt?.kind?.name ?: "UNKNOWN"} " +
                "failure=${failure.name} cause=${cause.name} monoMs=${monotonicNanos / 1_000_000}"
    }

    internal const val HISTORY_CAPACITY = 32
    private val sequence = AtomicLong()
    private val lock = Any()
    private val history = ArrayDeque<Entry>(HISTORY_CAPACITY)
    private var terminal: Entry? = null
    @Volatile internal var logSinkForTesting: ((String) -> Unit)? = null
    private val terminalStages = setOf(
        Stage.PREFLIGHT_BLOCKED, Stage.ATTACHED, Stage.OWNER_CONFLICT,
        Stage.SERVICE_START_REFUSED, Stage.SERVICE_CONFIRMED, Stage.CONFIRM_TIMEOUT,
        Stage.ACQUIRE_CANCELLED, Stage.DENIAL_TYPED,
    )

    fun begin(origin: Origin, kind: OperationKind): Attempt =
        Attempt(sequence.incrementAndGet(), origin, kind).also { mark(it, Stage.ACQUIRE_ENTER) }

    fun classify(failure: RunForegroundFailure): FailureKind = when (failure) {
        is RunForegroundFailure.NotificationsBlocked -> FailureKind.NOTIFICATIONS_BLOCKED
        is RunForegroundFailure.StartDenied -> FailureKind.START_DENIED
        is RunForegroundFailure.Unavailable -> FailureKind.UNAVAILABLE
        is RunForegroundFailure.OwnerConflict -> FailureKind.OWNER_CONFLICT
    }

    /** Return the SAME exception and attach diagnostic metadata. Concurrent
     * attempts cannot steal this failure's notice attribution. */
    fun <T : RunForegroundFailure> failed(attempt: Attempt, stage: Stage, failure: T, cause: Cause = Cause.NONE): T {
        failure.diagnosticAttempt = attempt
        if (cause != Cause.NONE) failure.diagnosticCause = cause
        mark(attempt, stage, classify(failure), failure.diagnosticCause ?: Cause.NONE)
        return failure
    }

    fun mark(attempt: Attempt, stage: Stage, failure: FailureKind = FailureKind.NONE, cause: Cause = Cause.NONE) =
        record(Entry(attempt, stage, failure, cause, System.nanoTime()))

    fun notice(failure: RunForegroundFailure, posted: Boolean): Attribution {
        val attribution = Attribution(failure.diagnosticAttempt, classify(failure), failure.diagnosticCause ?: Cause.NONE)
        record(Entry(attribution.attempt, if (posted) Stage.NOTICE_POSTED else Stage.NOTICE_SUPPRESSED,
            attribution.failure, attribution.cause, System.nanoTime()))
        return attribution
    }

    /** Composition bound a notice to UI; this does not claim the device
     * was awake or the user physically saw the sheet. */
    fun noticeBoundToUi(attribution: Attribution?) {
        record(Entry(attribution?.attempt, Stage.NOTICE_UI_BOUND,
            attribution?.failure ?: FailureKind.NONE, attribution?.cause ?: Cause.NONE, System.nanoTime()))
    }

    /** A service event has no inferred acquisition owner. The controller
     * later associates a delivered typed denial with its exact waiter. */
    fun serviceEvent(stage: Stage, cause: Cause = Cause.NONE) =
        record(Entry(null, stage, FailureKind.NONE, cause, System.nanoTime()))

    fun <T : RunForegroundFailure> serviceFailure(stage: Stage, cause: Cause, failure: T): T {
        failure.diagnosticCause = cause
        record(Entry(null, stage, classify(failure), cause, System.nanoTime()))
        return failure
    }

    fun recent(): List<Entry> = synchronized(lock) { history.toList() }
    fun lastOutcome(): Entry? = synchronized(lock) { terminal }

    internal fun resetForTesting() {
        synchronized(lock) { history.clear(); terminal = null }
        sequence.set(0)
        logSinkForTesting = null
    }

    private fun record(entry: Entry) {
        synchronized(lock) {
            history.addLast(entry)
            while (history.size > HISTORY_CAPACITY) history.removeFirst()
            if (entry.stage in terminalStages) terminal = entry
        }
        // A failed optional Android log (including a JVM stub) cannot
        // change the real lease or the bounded in-memory evidence.
        runCatching {
            val line = entry.line()
            logSinkForTesting?.invoke(line) ?: Log.i("FloeRunForeground", line)
        }
    }
}
