// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

/**
 * Pure recording clock used by [MeetingRecordingRuntime]. The wall-clock start
 * is used only for display; elapsed time is accumulated across pause/resume so
 * a long or paused meeting never reports a negative or double-counted value.
 */
internal class MeetingRecordingTimeline(
    private val startedAtMillis: Long,
) {
    private var accumulatedMillis: Long = 0L
    private var resumedAtMillis: Long = startedAtMillis
    private var running: Boolean = true

    fun elapsed(nowMillis: Long): Long {
        if (!running) return accumulatedMillis
        val current = (nowMillis - resumedAtMillis).coerceAtLeast(0L)
        return accumulatedMillis + current
    }

    fun pause(nowMillis: Long): Long {
        if (running) {
            accumulatedMillis += (nowMillis - resumedAtMillis).coerceAtLeast(0L)
            running = false
        }
        return accumulatedMillis
    }

    fun resume(nowMillis: Long) {
        if (!running) {
            resumedAtMillis = nowMillis
            running = true
        }
    }

    fun stop(nowMillis: Long): Long {
        pause(nowMillis)
        return accumulatedMillis
    }

    val isRunning: Boolean get() = running
}
