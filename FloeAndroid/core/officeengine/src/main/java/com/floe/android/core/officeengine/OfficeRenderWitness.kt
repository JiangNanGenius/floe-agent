// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/** One small owned renderer receipt, not progress text or pixel variance. */
internal object OfficeRenderWitness {
    const val COMMAND = "floe-renderwitness"
    data class Report(val nonce: String, val ready: Boolean, val draws: Int, val width: Int, val height: Int) {
        fun readyFor(expectedNonce: String): Boolean = ready && nonce == expectedNonce && draws > 0 && width > 0 && height > 0
    }

    fun parse(message: String): Report? {
        if (message.length !in 1..1024 || message.any { it.code !in 32..126 }) return null
        val tokens = message.split(' ')
        if (tokens.size != 6 || tokens[0] != COMMAND) return null
        val values = HashMap<String, String>(5)
        for (token in tokens.drop(1)) {
            val index = token.indexOf('=')
            if (index <= 0 || index == token.lastIndex) return null
            val key = token.substring(0, index)
            if (values.put(key, token.substring(index + 1)) != null) return null
        }
        if (values.keys != setOf("nonce", "kind", "draws", "width", "height")) return null
        val nonce = values["nonce"]?.takeIf { it.length in 1..512 } ?: return null
        val kind = values["kind"]?.takeIf { it == "ready" || it == "pending" } ?: return null
        val draws = values["draws"]?.toIntOrNull()?.takeIf { it >= 0 } ?: return null
        val width = values["width"]?.toIntOrNull()?.takeIf { it in 0..32768 } ?: return null
        val height = values["height"]?.toIntOrNull()?.takeIf { it in 0..32768 } ?: return null
        if (kind == "ready" && (draws == 0 || width == 0 || height == 0)) return null
        return Report(nonce, kind == "ready", draws, width, height)
    }
}
