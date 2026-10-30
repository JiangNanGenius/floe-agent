// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.util.Log

/**
 * Bounded HOST-side terminal-latency composition (G07.1 terminal04,
 * job-c5eec0e0881346ff).
 *
 * WHY: one real device run of a trivial `exec.shell` echo reported
 * `durationMs=25577`. That number is measured by the Swift backend around the
 * WHOLE dispatch, so it cannot say whether the time belonged to the local
 * engine slot, the foreground-service admission, the workspace grant, the
 * engine start request (runtime recover/import/spawn), stdin delivery, process
 * execution or the release wait that carries the engine's workspace export.
 * The runtime component measures its own half (`LinuxRuntimePhaseTiming`);
 * this class measures the host pump half so the two compose without guessing.
 *
 * HONESTY / SAFETY:
 * * Monotonic clock only ([System.nanoTime]); no wall clock, so a system clock
 *   change cannot fabricate or subtract a phase.
 * * Closed phase vocabulary plus non-negative integers. A phase that was never
 *   reached is ABSENT, never zero-filled.
 * * No command text, paths, payloads, output bytes or identifiers reach the
 *   rendered line (the existing `FloeLinuxStart` diagnostic channel is
 *   stage/duration only).
 * * Diagnostic only: recording a mark gates nothing, changes no deadline,
 *   cancels nothing and releases nothing. Every admission/lease rule in
 *   [LinuxShellPump] is unchanged.
 */
// File-private helpers: a nested class can always resolve them, unlike a
// companion member, and the same bound applies to every rendered line.
private const val HOST_LATENCY_MAX_SUMMARY_CHARS = 512
private const val HOST_LATENCY_LOG_TAG = "FloeLinuxStart"

private fun hostLatencyBoundedToken(value: String): String =
    value.filter { it.code in 0x21..0x7e }.take(24)

private fun hostLatencyBounded(text: String): String =
    if (text.length <= HOST_LATENCY_MAX_SUMMARY_CHARS) text else text.take(HOST_LATENCY_MAX_SUMMARY_CHARS)

internal class LinuxTerminalLatency private constructor() {

    /** Closed host-side phase vocabulary, in reachable order. */
    enum class Phase(val token: String) {
        /** Mailbox claim accepted → pump start handling entered. */
        CLAIM("claim"),
        /** Runtime foreground lease acquisition (may wait for FGS confirm). */
        FOREGROUND("foreground"),
        /** Core workspace grant mint. */
        GRANT("grant"),
        /** The `shell.start` control request round trip (queued receipt). */
        DISPATCH("dispatch"),
        /** `request.status` polling until the engine's start receipt settles. */
        RECEIPT("receipt"),
        /** Engine session id bound (start reply proven). */
        READY("ready"),
        /** Release wait: execution + engine stop proof + workspace export. */
        SETTLE("settle"),
    }

    /**
     * One dispatch's host-side record. Thread-safe: `handle(...)` and the
     * service-owned `watch(...)` coroutine may both observe the terminal, and
     * publication must happen exactly once.
     */
    class Run internal constructor(private val originNanos: Long,
                                   private val clock: () -> Long) {
        private val spans = ArrayList<Pair<Phase, Long>>(Phase.values().size)
        private val marked = HashSet<Phase>(Phase.values().size)
        private var lastNanos = originNanos
        private var receiptPolls = 0
        private var published: String? = null

        /** Closes the CURRENT phase at `atNanos`; a phase is recorded once. */
        @Synchronized
        fun mark(phase: Phase, atNanos: Long = clock()) {
            if (!marked.add(phase)) return
            val millis = if (atNanos >= lastNanos) (atNanos - lastNanos) / 1_000_000 else 0L
            spans.add(phase to millis)
            if (atNanos >= lastNanos) lastNanos = atNanos
        }

        /** Counts `request.status` receipts observed while awaiting the start. */
        @Synchronized
        fun noteReceiptPoll() {
            receiptPolls += 1
        }

        @Synchronized
        fun render(terminal: String): String {
            val parts = ArrayList<String>(spans.size + 5)
            parts.add("hostLatency v1")
            parts.add("terminal=" + hostLatencyBoundedToken(terminal))
            for ((phase, millis) in spans) parts.add(phase.token + "=" + millis + "ms")
            parts.add("receiptPolls=" + receiptPolls)
            val totalMillis = if (lastNanos >= originNanos) (lastNanos - originNanos) / 1_000_000 else 0L
            parts.add("total=" + totalMillis + "ms")
            parts.add("unobserved=processExecution,quiescenceProof,workspaceExport")
            return hostLatencyBounded(parts.joinToString(" "))
        }

        /**
         * Renders and publishes EXACTLY ONCE for this dispatch, then emits the
         * one bounded diagnostic line. Returns the same string on re-entry so a
         * second observer (handle vs watch) never double-records.
         */
        @Synchronized
        fun publish(terminal: String): String {
            published?.let { return it }
            val text = render(terminal)
            published = text
            LinuxTerminalLatency.publishSummary(text)
            return text
        }

        @Synchronized
        fun isPublished(): Boolean = published != null
    }

    companion object {
        /** Closed terminal tokens the pump itself observes. */
        const val TERMINAL_EXITED = "exited"
        const val TERMINAL_CANCELLED = "cancelled"
        const val TERMINAL_FAILED = "failed"
        const val TERMINAL_RETAINED = "retained"

        private val lock = Any()
        private var last: String? = null

        fun begin(clock: () -> Long = { System.nanoTime() }): Run = Run(clock(), clock)

        /** The MOST RECENT published host composition (nil until a run). */
        fun lastSummary(): String? = synchronized(lock) { last }

        /** Records one bounded composition (idempotence is owned by [Run.publish]). */
        internal fun publishSummary(text: String) {
            store(text)
        }

        private fun store(text: String) {
            synchronized(lock) { last = text }
            // Existing bounded diagnostic channel: ONE line per terminal run,
            // stage names and durations only. Observational: a host without the
            // platform logger (plain JVM unit tests) must never fail a run.
            runCatching { Log.i(HOST_LATENCY_LOG_TAG, "HOST_LATENCY " + text) }
        }
    }
}
