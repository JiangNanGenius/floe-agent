// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtimeipc

import java.util.concurrent.atomic.AtomicReference

/** Closed private host/runtime stop metadata; it grants no target authority. */
enum class ShellStopReason(val wireValue: String) {
    USER_STOP("user-stop"),
    TIMEOUT("timeout"),
    START_BINDING_FAILED("start-binding-failed");

    companion object {
        // The binding-failure cause belongs to the runtime itself; a caller
        // cannot assert it over the control wire.
        fun fromWire(value: String?): ShellStopReason? = when (value) {
            "user-stop" -> USER_STOP
            "timeout" -> TIMEOUT
            else -> null
        }
    }
}

/** One latch per owned session. Watchers must not turn a deadline into a new
 * user stop when repeating an already requested stop for settlement. */
class ShellStopReasonLatch {
    private val first = AtomicReference<ShellStopReason?>(null)
    val reason: ShellStopReason? get() = first.get()

    fun capture(reason: ShellStopReason): ShellStopReason =
        checkNotNull(first.updateAndGet { it ?: reason })
}
