// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Read-only, bounded UTF-8 reader for the App-owned run-output text viewer.
 *
 * The sealed snapshot is read in 64 KiB pages to real EOF; the returned
 * [Page] reports the actual whole-file byte count, so a 64 KiB page is never
 * mistaken for whole-file truncation. The only truncation this reader reports
 * is its own 4 MiB display cap, and it is disclosed.
 *
 * Bytes are decoded strictly: NUL or invalid UTF-8 is [Result.NotUTF8Text],
 * never replacement characters. A truncated cap may cut one multi-byte
 * scalar at the very end; at most three incomplete suffix bytes are trimmed
 * (the same rule as the workspace text page contract), while any invalid
 * interior still fails closed. A leading UTF-8 BOM is preserved as U+FEFF,
 * and a second literal U+FEFF stays intact, so the display matches the
 * exact sealed text bytes (including CRLF and emoji).
 */
internal object RunOutputTextViewReader {
    const val CHUNK_BYTES = 64 * 1024
    const val MAX_BYTES = 4L * 1024 * 1024

    /** A read page is not a layout page. Keep each selectable Text small
     * enough to measure on the UI thread, without dropping any content. */
    const val DISPLAY_PAGE_CHARS = 4096

    fun displayPages(text: String): List<String> {
        if (text.isEmpty()) return listOf("")
        val pages = ArrayList<String>()
        var start = 0
        while (start < text.length) {
            var end = minOf(start + DISPLAY_PAGE_CHARS, text.length)
            if (end < text.length) {
                // Prefer a line boundary in the latter half of the page.
                val newline = text.lastIndexOf('\n', end - 1)
                if (newline >= start + DISPLAY_PAGE_CHARS / 2) end = newline + 1
                // Neither a surrogate pair nor CRLF may straddle pages.
                if (text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end--
                if (text[end - 1] == '\r' && text[end] == '\n') end--
            }
            pages.add(text.substring(start, end))
            start = end
        }
        return pages
    }

    data class Page(
        val text: String,
        val truncated: Boolean,
        val totalBytes: Long,
        val chunksRead: Int,
    )

    sealed interface Result {
        data class Success(val page: Page) : Result
        data object NotUTF8Text : Result
        data class ReadFailure(val error: Throwable) : Result
    }

    fun read(file: File): Result {
        if (!file.isFile || file.length() < 0) {
            return Result.ReadFailure(java.io.FileNotFoundException(file.name))
        }
        val totalBytes = file.length()
        val cap = minOf(totalBytes, MAX_BYTES + 1)
        val collected = try {
            ByteArrayOutputStream(cap.toInt()).use { output ->
                FileInputStream(file).use { input ->
                    val buffer = ByteArray(CHUNK_BYTES)
                    var total = 0L
                    while (total < cap) {
                        val want = minOf(buffer.size.toLong(), cap - total).toInt()
                        val read = input.read(buffer, 0, want)
                        if (read < 0) break
                        if (read == 0) continue
                        output.write(buffer, 0, read)
                        total += read
                    }
                }
                output.toByteArray()
            }
        } catch (error: Throwable) {
            return Result.ReadFailure(error)
        }
        val truncated = collected.size.toLong() > MAX_BYTES
        val limit = if (truncated) MAX_BYTES.toInt() else collected.size
        if (collected.copyOfRange(0, limit).any { it == 0.toByte() }) {
            return Result.NotUTF8Text
        }
        var text = decodeStrict(collected, limit, allowIncompleteSuffix = truncated)
            ?: return Result.NotUTF8Text
        // Normalize exactly one leading UTF-8 BOM to U+FEFF regardless of
        // whether the platform decoder consumed it. A second literal U+FEFF
        // remains as text, so `text.toByteArray(UTF_8)` reproduces the sealed
        // bytes (including the double-BOM case).
        if (limit >= 3 && collected[0] == 0xEF.toByte() &&
            collected[1] == 0xBB.toByte() && collected[2] == 0xBF.toByte()) {
            if (text.startsWith('\uFEFF')) text = text.substring(1)
            text = "\uFEFF" + text
        }
        val chunks = if (collected.isEmpty()) 0 else
            ((collected.size + CHUNK_BYTES - 1) / CHUNK_BYTES)
        return Result.Success(Page(text, truncated, totalBytes, chunks))
    }

    /** Strict UTF-8 decode. A non-truncated read must decode every byte; a
     * truncated cap drops up to three incomplete suffix bytes, never an
     * invalid interior sequence. */
    private fun decodeStrict(bytes: ByteArray, limit: Int, allowIncompleteSuffix: Boolean): String? {
        fun attempt(length: Int): String? {
            if (length < 0) return null
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            return try {
                decoder.decode(ByteBuffer.wrap(bytes, 0, length)).toString()
            } catch (_: CharacterCodingException) {
                null
            }
        }
        attempt(limit)?.let { return it }
        if (!allowIncompleteSuffix) return null
        for (trim in 1..minOf(3, limit)) {
            attempt(limit - trim)?.let { return it }
        }
        return null
    }
}
