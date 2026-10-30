// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G07.1 terminal04 (job-c5eec0e0881346ff) — AUTHORED NOT RUN regressions for
 * the bounded runtime-side terminal-latency composition.
 *
 * Main's grouped JVM batch executes these; this source set keeps Android and
 * org.json deliberately absent, so the assertions drive the PURE clock-injected
 * core only (no IPC, no engine, no spawn, no /proc read).
 *
 * Pinned properties:
 *  1. A composed start names exactly the phases it reached, in order, with
 *     non-negative integer milliseconds and an honest `unobserved` split.
 *  2. An unreached phase is ABSENT — never zero-filled — so a start that died
 *     during recovery cannot masquerade as a completed import/spawn.
 *  3. A phase is measured once (no overwrite), and a backwards clock reading
 *     records 0 ms instead of inventing or subtracting time.
 *  4. Publishing is idempotent (the pump thread and a late observer can both
 *     reach the terminal) and bounded (≤512 chars) with a closed terminal
 *     vocabulary; nothing command-, path- or identifier-shaped can appear.
 */
class LinuxRuntimePhaseTimingTest {

    private fun run(now: Long = 1_000_000_000L) = LinuxRuntimePhaseTiming.begin { now }

    @Test
    fun composedStartAndTerminalNameEveryReachedPhaseInOrder() {
        var now = 1_000_000_000L
        val record = LinuxRuntimePhaseTiming.begin { now }
        now += 120_000_000   // recover 120ms
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        now += 5_000_000     // configure 5ms
        record.mark(LinuxRuntimePhaseTiming.Phase.CONFIGURE)
        now += 3_000_000     // acquire 3ms
        record.mark(LinuxRuntimePhaseTiming.Phase.ACQUIRE)
        now += 2_000_000     // materialize 2ms
        record.mark(LinuxRuntimePhaseTiming.Phase.MATERIALIZE)
        now += 18_400_000_000 // import 18400ms
        record.mark(LinuxRuntimePhaseTiming.Phase.IMPORT)
        now += 1_000_000     // spec 1ms
        record.mark(LinuxRuntimePhaseTiming.Phase.SPEC)
        now += 240_000_000   // spawn 240ms
        record.mark(LinuxRuntimePhaseTiming.Phase.SPAWN)
        now += 2_000_000     // bind 2ms
        record.mark(LinuxRuntimePhaseTiming.Phase.BIND)
        now += 900_000_000   // run 900ms
        record.mark(LinuxRuntimePhaseTiming.Phase.RUN)
        now += 40_000_000    // export 40ms
        record.mark(LinuxRuntimePhaseTiming.Phase.EXPORT)
        now += 4_000_000     // complete 4ms
        record.mark(LinuxRuntimePhaseTiming.Phase.COMPLETE)

        val text = record.render(LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        assertEquals(
            "runtimeLatency v1 terminal=exited recover=120ms configure=5ms acquire=3ms" +
                " materialize=2ms import=18400ms spec=1ms spawn=240ms bind=2ms run=900ms" +
                " export=40ms complete=4ms total=19717ms unobserved=processVsQuiescenceSplit",
            text,
        )
        assertTrue(text.length <= 512)
    }

    @Test
    fun unreachedPhaseIsAbsentNeverZero() {
        var now = 5_000L
        val record = LinuxRuntimePhaseTiming.begin { now }
        now += 150_000_000
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        val text = record.render(LinuxRuntimePhaseTiming.TERMINAL_FAILED)
        assertEquals(
            "runtimeLatency v1 terminal=failed recover=150ms total=150ms" +
                " unobserved=processVsQuiescenceSplit",
            text,
        )
        assertFalse("a start that never imported must not claim an import",
            text.contains("import="))
        assertFalse(text.contains("spawn="))
        assertFalse(text.contains("export="))
    }

    @Test
    fun repeatedMarkKeepsTheFirstMeasuredSpan() {
        var now = 0L
        val record = LinuxRuntimePhaseTiming.begin { now }
        now = 7_000_000
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        now = 900_000_000
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)   // must not overwrite
        val text = record.render(LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        assertTrue(text, text.contains("recover=7ms"))
    }

    @Test
    fun backwardsClockRecordsZeroNeverNegative() {
        var now = 1_000_000_000L
        val record = LinuxRuntimePhaseTiming.begin { now }
        now = 400_000_000   // anomaly
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        val text = record.render(LinuxRuntimePhaseTiming.TERMINAL_RETAINED)
        assertTrue(text, text.contains("recover=0ms"))
        assertFalse("no negative duration may ever be rendered", text.contains("=-"))
    }

    @Test
    fun publishIsIdempotentAndBounded() {
        var now = 0L
        val record = LinuxRuntimePhaseTiming.begin { now }
        now = 12_000_000
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        val first = record.publish(LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        assertTrue(record.isPublished())
        val second = record.publish("../../etc/passwd with spaces")
        assertEquals("a second terminal observer must not re-publish", first, second)
        assertTrue(first.startsWith("runtimeLatency v1 terminal=exited "))
        assertFalse(first.contains("passwd"))
        assertTrue(first.length <= 512)
        assertEquals(first, LinuxRuntimePhaseTiming.lastSummary())
    }

    @Test
    fun terminalTokenIsClosedAndSanitised() {
        val record = run()
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        // A caller cannot smuggle free-form text, a newline or a space run into
        // the rendered line: only printable non-space characters survive, and
        // the terminal token is truncated to a bounded length.
        val text = record.render("exited\ncommand=rm -rf /")
        val token = text.split(" ").first { it.startsWith("terminal=") }
        assertEquals("terminal=exitedcommand=rm-rf/", token)
        assertFalse(text.contains("\n"))
        assertFalse(text.contains("rm -rf"))
        assertTrue(text.startsWith("runtimeLatency v1 terminal="))
    }

    @Test
    fun renderingNeverPublishes() {
        val before = LinuxRuntimePhaseTiming.lastSummary()
        val record = run()
        record.mark(LinuxRuntimePhaseTiming.Phase.RECOVER)
        record.render(LinuxRuntimePhaseTiming.TERMINAL_EXITED)
        assertFalse("a plain render is not a publication", record.isPublished())
        assertEquals(before, LinuxRuntimePhaseTiming.lastSummary())
    }
}
