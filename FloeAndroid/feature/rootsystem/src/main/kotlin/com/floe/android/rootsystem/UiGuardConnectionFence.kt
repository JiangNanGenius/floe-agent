// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

/** An ACK from a replaced, restarted or dead Binder never proves current sync. */
internal object UiGuardConnectionFence {
    fun isCurrent(
        expectedClient: Any,
        expectedGeneration: Long,
        currentClient: Any?,
        currentGeneration: Long,
        alive: Boolean,
    ): Boolean = expectedClient === currentClient &&
        expectedGeneration == currentGeneration && alive
}
