// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import java.security.MessageDigest

/** Bounded, exact reconstruction of one original conversation detail row. */
internal class ConversationDetailAssembler(
    private val kind: String,
    private val maximumBytes: Long,
) {
    private var first: ConversationWire.DetailPage? = null
    private val content = StringBuilder()
    private var settled = false

    fun accept(page: ConversationWire.DetailPage): Result {
        if (settled) return Result.Failed("detailAlreadySettled")
        fun fail(code: String): Result {
            settled = true
            content.clear()
            return Result.Failed(code)
        }
        if (page.kind != kind || page.encoding != "json-utf8") return fail("detailKindMismatch")
        if (!page.digest.matches(Regex("[0-9a-f]{64}"))) return fail("detailDigestMismatch")
        if (page.totalBytes < 0 || page.totalBytes > maximumBytes) return fail("detailTooLarge")
        val previous = first
        if (previous != null && (
                page.id != previous.id || page.digest != previous.digest ||
                    page.totalBytes != previous.totalBytes || page.revision != previous.revision ||
                    page.statusRaw != previous.statusRaw ||
                    page.revisionResourceID != previous.revisionResourceID ||
                    page.revisionVersion != previous.revisionVersion ||
                    page.planDigest != previous.planDigest ||
                    page.isDecisionComplete != previous.isDecisionComplete
                )) return fail("detailIdentityMismatch")
        val bytes = page.content.toByteArray(Charsets.UTF_8)
        if (page.offset != nextOffset || page.nextOffset < page.offset ||
            page.nextOffset > page.totalBytes ||
            page.nextOffset - page.offset != bytes.size.toLong() ||
            page.truncated != (page.nextOffset < page.totalBytes) ||
            (page.nextOffset == page.offset && page.nextOffset < page.totalBytes)
        ) return fail("detailBytesMismatch")
        if (first == null) first = page
        content.append(page.content)
        nextOffset = page.nextOffset
        if (page.truncated) return Result.Continue
        val text = content.toString()
        val completeBytes = text.toByteArray(Charsets.UTF_8)
        val actualDigest = MessageDigest.getInstance("SHA-256").digest(completeBytes)
            .joinToString("") { "%02x".format(it) }
        if (completeBytes.size.toLong() != page.totalBytes || actualDigest != page.digest) {
            return fail("detailDigestMismatch")
        }
        settled = true
        content.clear()
        return Result.Complete(text)
    }

    var nextOffset: Long = 0
        private set

    sealed interface Result {
        data object Continue : Result
        data class Complete(val content: String) : Result
        data class Failed(val code: String) : Result
    }
}
