// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.util.Log

/**
 * Bounded RUNTIME-side terminal-latency composition (G07.1 terminal04,
 * job-c5eec0e0881346ff).
 *
 * WHY: `shell.start` is a single request as far as the host pump / Swift
 * backend can see, but inside this process it performs environment recovery, a
 * published-revision verification, a lease acquire, rootfs materialization, the
 * workspace import, the launch-spec build and the real spawn. The release wait
 * that follows carries an additional export commit plus the native release.
 * A 25 s `echo` can only be attributed if THOSE segments are measured where
 * they actually run — here — instead of guessed from the client's total.
 *
 * HONESTY / SAFETY:
 * * Monotonic clock only ([System.nanoTime]); a wall-clock change cannot
 *   fabricate or subtract a phase.
 * * Closed phase vocabulary plus non-negative integers; an unreached phase is
 *   ABSENT, never zero-filled. `unobserved` names the one split this process
 *   cannot make (process lifetime vs. the whole-UID stop proof inside it).
 * * No command text, paths, output bytes, payloads or identifiers are ever
 *   rendered or logged: the existing `FloeLinuxStart` diagnostic channel stays
 *   stage/duration only.
 * * Diagnostic only. It never gates admission, changes a deadline, requests a
 *   cancel, releases a lease or alters workspace custody; every call site below
 *   is a pure observation next to an existing Trace.mark or completion step.
 */
// File-private helpers: a nested class can always resolve them, unlike a
// companion member, and the same bound applies to every rendered line.
private const val LATENCY_MAX_SUMMARY_CHARS = 512
private const val LATENCY_LOG_TAG = "FloeLinuxStart"

private fun latencyBoundedToken(value: String): String =
    value.filter { it.code in 0x21..0x7e }.take(24)

private fun latencyBounded(text: String): String =
    if (text.length <= LATENCY_MAX_SUMMARY_CHARS) text else text.take(LATENCY_MAX_SUMMARY_CHARS)

internal object LinuxRuntimePhaseTiming {

    /** Closed runtime phase vocabulary, in reachable order. */
    enum class Phase(val token: String) {
        /** Whole-UID recovery proof before the lease is taken. */
        RECOVER("recover"),
        /** Published-revision verification + authority configure. */
        CONFIGURE("configure"),
        /** Native lease acquire. */
        ACQUIRE("acquire"),
        /** Rootfs layer materialization (fast when the marker is present). */
        MATERIALIZE("materialize"),
        /** Core→guest workspace import (baseline scan + transfer + apply). */
        IMPORT("import"),
        /** Launch-spec build (binds, env, argv). */
        SPEC("spec"),
        /** Supervisor spawn (includes the pre-admission quiescence proof). */
        SPAWN("spawn"),
        /** Root-birth binding to the lease authority. */
        BIND("bind"),
        /** From the start reply to the terminal: process lifetime + the
         *  whole-UID stop proof (the split stays `unobserved`). */
        RUN("run"),
        /** Workspace export after quiescence (guest walk + Core commit). */
        EXPORT("export"),
        /** Native lease completion / release. */
        COMPLETE("complete"),
    }

    /** Terminal vocabulary of the runtime's own settled terminal. */
    const val TERMINAL_EXITED = "exited"
    const val TERMINAL_CANCELLED = "cancelled"
    const val TERMINAL_FAILED = "failed"
    const val TERMINAL_RETAINED = "retained"

    private val lock = Any()
    private var last: String? = null

    /** One start's record. Publishing is idempotent; publishing never blocks. */
    class Run internal constructor(private val originNanos: Long,
                                   private val clock: () -> Long) {
        private val spans = ArrayList<Pair<Phase, Long>>(Phase.values().size)
        private val marked = HashSet<Phase>(Phase.values().size)
        private var lastNanos = originNanos
        private var published: String? = null

        @Synchronized
        fun mark(phase: Phase, atNanos: Long = clock()) {
            if (!marked.add(phase)) return
            val millis = if (atNanos >= lastNanos) (atNanos - lastNanos) / 1_000_000 else 0L
            spans.add(phase to millis)
            if (atNanos >= lastNanos) lastNanos = atNanos
        }

        @Synchronized
        fun render(terminal: String): String {
            val parts = ArrayList<String>(spans.size + 4)
            parts.add("runtimeLatency v1")
            parts.add("terminal=" + latencyBoundedToken(terminal))
            for ((phase, millis) in spans) parts.add(phase.token + "=" + millis + "ms")
            val totalMillis = if (lastNanos >= originNanos) (lastNanos - originNanos) / 1_000_000 else 0L
            parts.add("total=" + totalMillis + "ms")
            parts.add("unobserved=processVsQuiescenceSplit")
            return latencyBounded(parts.joinToString(" "))
        }

        @Synchronized
        fun publish(terminal: String): String {
            published?.let { return it }
            val text = render(terminal)
            published = text
            LinuxRuntimePhaseTiming.publishSummary(text)
            return text
        }

        @Synchronized
        fun isPublished(): Boolean = published != null
    }

    fun begin(clock: () -> Long = { System.nanoTime() }): Run = Run(clock(), clock)

    /** The MOST RECENT settled composition (nil before the first terminal). */
    fun lastSummary(): String? = synchronized(lock) { last }

    internal fun publishSummary(text: String) {
        synchronized(lock) { last = text }
        // Existing bounded diagnostic channel: ONE line per settled workload,
        // stage names and durations only. Observational: a host without the
        // platform logger (plain JVM unit tests) must never fail a terminal.
        runCatching { Log.i(LATENCY_LOG_TAG, "RUNTIME_LATENCY " + text) }
    }

}
