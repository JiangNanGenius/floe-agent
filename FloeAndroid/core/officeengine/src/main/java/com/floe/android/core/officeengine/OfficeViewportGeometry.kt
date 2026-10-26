// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Strict parser for the pinned dist's one-shot Writer viewport re-sync packet.
 *
 * The packet is numeric-only and consumed by the host for the bounded
 * RAM-only Technical details history. It is never a document-content
 * carrier, native command, permission fact or rendering-readiness witness.
 */
internal object OfficeViewportGeometry {
    const val COMMAND = "floe-viewport-geometry"

    private const val MAX_MESSAGE_CHARS = 256

    private val pairedDimensions = Regex("""^\d{1,6}x\d{1,6}>\d{1,6}x\d{1,6}$""")
    private val singleDimensions = Regex("""^\d{1,6}x\d{1,6}$""")
    private val outcomes = setOf("applied", "absent", "failed", "stale")

    /** Returns the sanitized detail (without the command word), or null. */
    fun diagnosticDetail(message: String): String? {
        if (message.length !in (COMMAND.length + 8)..MAX_MESSAGE_CHARS) return null
        if (message.any { it.code !in 32..126 }) return null

        val tokens = message.split(' ')
        if (tokens.size != 8 || tokens[0] != COMMAND) return null
        if (!tokens[1].startsWith("main=") ||
            !pairedDimensions.matches(tokens[1].removePrefix("main=")) ||
            !tokens[2].startsWith("doc=") ||
            !pairedDimensions.matches(tokens[2].removePrefix("doc=")) ||
            !tokens[3].startsWith("canvas=") ||
            !pairedDimensions.matches(tokens[3].removePrefix("canvas=")) ||
            !tokens[4].startsWith("viewport=") ||
            !singleDimensions.matches(tokens[4].removePrefix("viewport=")) ||
            !tokens[5].startsWith("html=") ||
            !singleDimensions.matches(tokens[5].removePrefix("html=")) ||
            !tokens[6].startsWith("body=") ||
            !singleDimensions.matches(tokens[6].removePrefix("body=")) ||
            !tokens[7].startsWith("sync=") ||
            tokens[7].removePrefix("sync=") !in outcomes
        ) return null

        return message.substring(COMMAND.length + 1)
    }
}
