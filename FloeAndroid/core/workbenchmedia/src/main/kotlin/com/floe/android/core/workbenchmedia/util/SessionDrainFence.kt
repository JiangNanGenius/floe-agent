// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.util

import java.util.concurrent.atomic.AtomicBoolean

/**
 * One-way drain fence for a media session. Once Root stop begins, the same
 * session must never accept a new export, player, preview or ticket claim:
 * native may unbind/free the Root as soon as `drain()` reports success, so a
 * late submission would otherwise hand out a reference to a retired root.
 *
 * The fence is intentionally irreversible for the session object. Reusing the
 * same object after drain is not an "intentional new epoch"; the App must
 * create a new session after native accepts a new live epoch.
 */
internal class SessionDrainFence {
    private val fenced = AtomicBoolean(false)

    /** Returns true only for the first fencing transition. */
    fun fence(): Boolean = fenced.compareAndSet(false, true)

    fun isFenced(): Boolean = fenced.get()

    fun ensureAccepting() {
        if (fenced.get()) {
            throw refusal(
                RENDERER_UNAVAILABLE,
                "The media session is draining; wait for a new accepted epoch and session",
                retryable = true,
            )
        }
    }
}
