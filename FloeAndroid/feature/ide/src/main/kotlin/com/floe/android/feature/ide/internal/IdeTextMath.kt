// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide.internal

/**
 * Pure UTF-16 text math shared by the presenter and the Sora projection
 * adapter. Sora's [Content] indexes are Java character (UTF-16 code unit)
 * indexes, so the contract's UTF-16 offsets map 1:1 onto the editor after a
 * surrogate-pair safety check — writes never split a pair.
 */
internal object IdeTextMath {

    /** Delete events arrive after Sora shortened its buffer, but their range
     * belongs to the presenter's pre-edit mirror. Never clamp to the new size:
     * deleting EOF would become a no-op and silently restore deleted text. */
    fun deletionRange(beforeLength: Int, start: Int, deletedLength: Int):
        com.floe.android.feature.ide.api.IdeUtf16Range? {
        if (beforeLength < 0 || deletedLength <= 0 || start < 0 ||
            deletedLength > beforeLength || start > beforeLength - deletedLength) return null
        return com.floe.android.feature.ide.api.IdeUtf16Range(start, start + deletedLength)
    }

    /** True when [index] falls strictly between the halves of a surrogate pair. */
    fun insideSurrogatePair(text: CharSequence, index: Int): Boolean {
        if (index <= 0 || index >= text.length) return false
        return text[index - 1].isHighSurrogate() && text[index].isLowSurrogate()
    }

    /**
     * Converts a whole-document UTF-16 offset to a 0-based (line, column)
     * where lines are LF-terminated and a CR before the LF belongs to the
     * previous line's separator. Used for the human status line only; the
     * editor's own indexer is authoritative for selection mapping.
     */
    fun lineColumnAt(text: CharSequence, utf16Index: Int): Pair<Int, Int> {
        val safe = utf16Index.coerceIn(0, text.length)
        var line = 0
        var lineStart = 0
        var i = 0
        while (i < safe) {
            if (text[i] == '\n') {
                line++
                lineStart = i + 1
            }
            i++
        }
        // Skip a CR that opens this segment only when it is the leftover half
        // of a CRLF (it never starts line 0 of the document text).
        if (lineStart < safe && text[lineStart] == '\r') {
            lineStart += 1
        }
        return line to (safe - lineStart).coerceAtLeast(0)
    }

    /**
     * Minimal projection sync: keep the common prefix/suffix and replace only
     * the middle, surrogate-safely on both sides. Returns null when no write
     * is needed. When a prefix/suffix boundary would cut a surrogate pair,
     * falls back to a single full-range replace (never two half-pair writes).
     */
    fun minimalReplacement(current: CharSequence, desired: CharSequence): IdeUtf16Replacement? {
        if (current.length == desired.length) {
            var same = true
            for (i in current.indices) {
                if (current[i] != desired[i]) {
                    same = false
                    break
                }
            }
            if (same) return null
        }
        val maxPrefix = minOf(current.length, desired.length)
        var rawStart = 0
        while (rawStart < maxPrefix && current[rawStart] == desired[rawStart]) rawStart++
        var suffix = 0
        while (suffix < maxPrefix - rawStart &&
            current[current.length - 1 - suffix] == desired[desired.length - 1 - suffix]
        ) suffix++
        val end = current.length - suffix
        val desiredEnd = desired.length - suffix
        val boundariesPairSafe =
            !insideSurrogatePair(current, rawStart) && !insideSurrogatePair(current, end) &&
                !insideSurrogatePair(desired, rawStart) && !insideSurrogatePair(desired, desiredEnd)
        if (!boundariesPairSafe) {
            return IdeUtf16Replacement(0, current.length, desired.toString())
        }
        val middle = desired.subSequence(rawStart, desiredEnd).toString()
        if (rawStart == end && middle.isEmpty()) return null
        return IdeUtf16Replacement(rawStart, end, middle)
    }
}

/** A single UTF-16 range replacement in the projection ([startUtf16, endUtf16)). */
internal data class IdeUtf16Replacement(
    val startUtf16: Int,
    val endUtf16: Int,
    val replacement: String,
)
