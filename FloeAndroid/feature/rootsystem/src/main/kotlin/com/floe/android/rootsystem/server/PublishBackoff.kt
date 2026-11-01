// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

/**
 * Bounded exponential retry cadence for App-provider publication.
 *
 * The first attempt is immediate; retries start at [INITIAL_DELAY_MILLIS] and
 * double until [MAX_DELAY_MILLIS]. The App waits 12 s for adoption, so a
 * transient provider/App-process start is covered without unbounded growth.
 */
internal class PublishBackoff(
    private val initialMillis: Long = INITIAL_DELAY_MILLIS,
    private val maximumMillis: Long = MAX_DELAY_MILLIS,
) {
    private var nextMillis: Long = initialMillis

    fun nextDelayMillis(): Long {
        val delay = nextMillis
        nextMillis = (nextMillis * 2).coerceAtMost(maximumMillis)
        return delay
    }

    fun reset() {
        nextMillis = initialMillis
    }

    companion object {
        const val INITIAL_DELAY_MILLIS = 250L
        const val MAX_DELAY_MILLIS = 10_000L
    }
}
