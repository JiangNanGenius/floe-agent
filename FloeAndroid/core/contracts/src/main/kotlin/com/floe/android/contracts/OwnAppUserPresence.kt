// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

/**
 * Neutral process-local bridge carrying trusted physical user input from
 * Floe's own Activity window into the Full-only phone-control session.
 *
 * Only a genuine user touch/key on Floe's own Activity reports through this
 * bridge ([android.app.Activity.onUserInteraction] is the sole producer, so
 * ordinary programmatic own-App clicks/scrolls can never emit it). The
 * phone-control runtime binds one listener while its AccessibilityService is
 * live and clears it on detach: a retired service can therefore never
 * receive new task input, and no global listener survives service death. The
 * App module (common source set, which cannot depend on the Full-only phone
 * module) only calls [reportOwnAppUserInteraction]; it never owns a listener.
 *
 * Android-free and thread-safe: production delivers on the main thread, the
 * slot is volatile so detach is immediately visible.
 */
object OwnAppUserPresence {
    fun interface Listener {
        fun onOwnAppUserInteraction()
    }

    @Volatile
    private var listener: Listener? = null

    /**
     * Bind or replace the live-session listener. Called only by the
     * phone-control runtime on real service attach/detach — never by UI code.
     */
    fun setListener(listener: Listener?) {
        this.listener = listener
    }

    /** Reported by Floe's own Activity for every genuine physical user input. */
    fun reportOwnAppUserInteraction() {
        listener?.onOwnAppUserInteraction()
    }
}
