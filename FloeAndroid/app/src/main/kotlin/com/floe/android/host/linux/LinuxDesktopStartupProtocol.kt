// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/** Closed guest startup receipts, not arbitrary shell output or authority. */
internal object LinuxDesktopStartupProtocol {
    class Failure(val stage: String, val exitCode: Int) : Exception()
    private val stages = setOf("packages", "session_bus", "vnc_tools", "credential", "display", "desktop")

    fun failure(output: CharSequence, nonce: String): Failure? {
        require(nonce.matches(Regex("[a-f0-9]{32}")))
        val match = Regex("(?m)^FLOE_START_FAILED:$nonce:([a-z_]+):([0-9]{1,3})\\r?$")
            .find(output) ?: return null
        val stage = match.groupValues[1].takeIf { it in stages } ?: return null
        val code = match.groupValues[2].toIntOrNull()?.takeIf { it in 0..255 } ?: return null
        return Failure(stage, code)
    }
}
