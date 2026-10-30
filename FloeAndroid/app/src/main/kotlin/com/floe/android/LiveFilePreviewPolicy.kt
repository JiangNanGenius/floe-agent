// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest

/** ONE independently consistent page only; never combines changing file pages. */
internal object LiveFilePreviewPolicy {
    sealed interface Result {
        data class Text(val value: String, val truncated: Boolean) : Result
        data object NotText : Result
        data object Invalid : Result
    }
    fun decode(bytes: ByteArray, sha256: String, truncated: Boolean): Result {
        if (bytes.size > 24576 || !sha256.matches(Regex("[0-9a-f]{64}"))) return Result.Invalid
        val actual = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        if (actual != sha256) return Result.Invalid
        if (bytes.any { it == 0.toByte() }) return Result.NotText
        val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val input = ByteBuffer.wrap(bytes)
        val output = CharBuffer.allocate(bytes.size)
        // A bounded prefix may end in an incomplete UTF-8 character. The
        // decoder leaves that suffix unread without hiding malformed interior bytes.
        val result = decoder.decode(input, output, !truncated)
        if (result.isError || result.isOverflow) return Result.NotText
        if (!truncated && decoder.flush(output).isError) return Result.NotText
        output.flip()
        return Result.Text(output.toString(), truncated)
    }
}
