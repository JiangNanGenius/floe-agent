// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Attribution of platform touch/click/scroll interaction events to the
 * session's OWN injected input.
 *
 * The accessibility stream echoes every injected dispatch back as
 * TYPE_TOUCH_INTERACTION_START / TYPE_VIEW_CLICKED / TYPE_VIEW_SCROLLED
 * events. Most echoes land inside the session's short arrival-based
 * suppression window. A Samsung API33 case (Full code105) reached a false
 * human-presence wait after automatic unlock with no intervening human input.
 * Delayed input echoes are a possible cause; the captured trace did not
 * include the accessibility event's timestamp, so device validation must
 * confirm this attribution rather than infer it from wake-lease expiry.
 *
 * An echo keeps the DISPATCH's own timestamp even when delivery lags — the
 * same timestamp the session uses for event-lag compensation — so attribution
 * compares that timestamp against a bounded own-input window. Events outside
 * it still enter the existing takeover path. Timestamp correlation cannot
 * distinguish simultaneous human input inside that short window; it does
 * not replace the existing task, approval or ownership checks.
 *
 * Android-free and time-injected: production stamps every note with
 * SystemClock.uptimeMillis(); JVM tests drive the same contract with a
 * deterministic clock. A burst of dispatches inside one window is ONE
 * transaction; an input after the echo horizon opens a fresh window, so an
 * unrelated older dispatch can never absorb a later human touch.
 */
internal class PhoneOwnInputEcho(
    private val echoWindowMs: Long = DEFAULT_ECHO_WINDOW_MS,
    private val startSkewMs: Long = DEFAULT_START_SKEW_MS,
) {
    private var windowFromMs = 0L
    private var windowUntilMs = 0L

    /** True while any own-input dispatch has been recorded. */
    val hasOwnInput: Boolean get() = windowFromMs != 0L

    fun noteOwnInput(uptimeMs: Long) {
        if (windowFromMs == 0L || uptimeMs > windowUntilMs) {
            windowFromMs = uptimeMs
        }
        windowUntilMs = uptimeMs + echoWindowMs
    }

    fun isOwnEcho(eventUptimeMs: Long): Boolean {
        val from = windowFromMs
        if (from == 0L) return false
        return eventUptimeMs >= from - startSkewMs && eventUptimeMs <= windowUntilMs
    }

    private companion object {
        // Echo horizon after the LAST own dispatch. It covers the observed
        // keyguard dismiss (~680ms from the final credential tap to the
        // observed unlock) with margin, and stays strictly inside the
        // session's existing ~3s arrival-based suppression, so a human touch
        // inside this horizon was already ignored before this attribution
        // existed. It is a fixed bounded window, never an indefinite hold.
        const val DEFAULT_ECHO_WINDOW_MS = 1_500L
        // Events derived from a dispatch are stamped at generation time,
        // which can precede the note by a few milliseconds of framework
        // scheduling; the small skew keeps those echoes attributed to us.
        const val DEFAULT_START_SKEW_MS = 250L
    }
}
