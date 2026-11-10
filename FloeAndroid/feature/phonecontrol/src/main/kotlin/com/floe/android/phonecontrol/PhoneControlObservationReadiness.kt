// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * The observable channels for ONE bounded post-transition observation-readiness
 * transaction. Production wires these to the AccessibilityService main looper,
 * the live session fence/keyguard reads and one genuine snapshot attempt per
 * poll; JVM tests drive the same contract with a deterministic clock. Nothing
 * here may block, sleep or read node content outside [capture].
 */
internal interface PhoneObservationReadinessDriver {
    val now: Long
    fun after(delayMs: Long, action: () -> Unit): () -> Unit
    /** False once the owning operation was aborted/completed elsewhere: the
     *  existing session fence/cancel path owns that terminal result, so the
     *  transaction must stop silently instead of inventing a second one. */
    fun stillCurrent(): Boolean
    fun blocker(): PhoneControlBlocker?
    fun keyguardLocked(): Boolean
    /** One fresh capture attempt; null means the active window is genuinely
     *  not published yet, never an authorization decision. */
    fun capture(): PhoneControlCapture?
}

/**
 * The ONE bounded readiness transaction for an explicit observation whose
 * first capture found no published active window. The demonstrated case
 * (Samsung API33, public78/code104): an admitted task's first phone.observe
 * performed the in-call automatic unlock, the keyguard reported unlocked at
 * the exact completion second, and the framework had not yet re-published the
 * active accessibility window — the old single-shot capture mapped that
 * ordinary transition instant to OBSERVATION_FAILED and the model stopped.
 *
 * Rules, mirroring the existing post-action settle lifecycle:
 *  - fence first: an existing blocker, or a keyguard relock, terminates with
 *    the corresponding typed denial and a late capture is never published
 *    across either;
 *  - success requires one genuinely observed capture — an elapsed deadline
 *    alone never fabricates one;
 *  - waiting is bounded by the existing [PhoneControlLimits.SETTLE_TIMEOUT_MS]
 *    window with the same 60ms poll cadence as the post-action settle loop —
 *    no arbitrary new timeout, no fixed sleep, no blind retry of anything but
 *    a fresh, genuinely-unavailable capture;
 *  - after [PhoneObservationReadinessDriver.stillCurrent] turns false the
 *    transaction stops without completing: stop/takeover/user-touch/screen-off,
 *    run release and caller cancellation own the terminal result through the
 *    session's existing abort path, so a late poll can never double-complete,
 *    leak a phone lease or relock a user's active phone.
 */
internal class PhoneControlObservationReadiness(
    private val driver: PhoneObservationReadinessDriver,
    private val deadlineMs: Long = PhoneControlLimits.SETTLE_TIMEOUT_MS,
    private val pollMs: Long = 60L,
) {
    fun start(complete: (PhoneControlResult<PhoneControlCapture>) -> Unit) {
        val startedAt = driver.now
        // The first poll runs immediately: a window published between the
        // caller's failed capture and this transaction must not wait a tick.
        fun poll() {
            if (!driver.stillCurrent()) return
            val blocker = driver.blocker()
            if (blocker != null) {
                complete(PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(blocker)))
                return
            }
            if (driver.keyguardLocked()) {
                complete(PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED))
                return
            }
            val capture = driver.capture()
            // Framework reads can overlap a cancellation, fence change or
            // relock. Revalidate before publishing the captured observation.
            if (!driver.stillCurrent()) return
            driver.blocker()?.let {
                complete(PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(it)))
                return
            }
            if (driver.keyguardLocked()) {
                complete(PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED))
                return
            }
            if (capture != null) {
                complete(PhoneControlResult.Ok(capture))
                return
            }
            if (driver.now - startedAt >= deadlineMs) {
                complete(
                    PhoneControlResult.Failed(
                        PhoneControlFailure.OBSERVATION_FAILED,
                        "active window content stayed unavailable through the bounded " +
                            "post-transition readiness window",
                    ),
                )
                return
            }
            driver.after(pollMs) { poll() }
        }
        poll()
    }
}
