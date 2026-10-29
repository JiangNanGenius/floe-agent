// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.Sha256

/**
 * Reading state for one PDF page: position, zoom, rotation and bookmarks.
 *
 * Ownership: this module NEVER stores reading state itself (no database, no
 * SharedPreferences, no file). The Notes authority owns the per-document store
 * and persists [PdfReadingState] through its own versioned save path; the
 * module only supplies the value types plus a bounded, strict codec so the
 * authority does not have to invent a second format. [PdfReadingState] is
 * bound to the source SHA-256, so after the PDF is replaced the state decodes
 * as [PdfReadingStateError.STALE_SOURCE] instead of silently pointing at a
 * different document.
 */
data class PdfReadingPosition(
    val page: PdfPageId,
    /** 1.0 == 100% of physical size. Clamped by the viewport, validated here. */
    val zoom: Float,
    /** Normalized offsets inside the page in [0,1] (survive screen rotation). */
    val offsetX: Float,
    val offsetY: Float,
) {
    init {
        require(zoom.isFinite() && zoom in PdfViewport.MIN_ZOOM..PdfViewport.MAX_ZOOM) { "Reading zoom out of range" }
        require(offsetX.isFinite() && offsetX in 0f..1f) { "Reading offsetX out of range" }
        require(offsetY.isFinite() && offsetY in 0f..1f) { "Reading offsetY out of range" }
    }
}

data class PdfBookmark(
    val id: String,
    val page: PdfPageId,
    val label: String,
    val createdAtMs: Long,
    /** Optional: the text/OCR snippet that motivated the bookmark. */
    val snippet: String? = null,
) {
    init {
        require(id.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$"))) { "Invalid bookmark id" }
        require(label.length in 1..MAX_LABEL_CHARS) { "Bookmark label out of bounds" }
        require(createdAtMs >= 0L) { "Bookmark timestamp must be non-negative" }
        require(snippet == null || snippet.length <= MAX_SNIPPET_CHARS) { "Bookmark snippet too long" }
    }

    companion object {
        const val MAX_LABEL_CHARS: Int = 128
        const val MAX_SNIPPET_CHARS: Int = 256
    }
}

data class PdfReadingState(
    val sourceSha256: String,
    val position: PdfReadingPosition?,
    val bookmarks: List<PdfBookmark>,
    val pageRotationQuarterTurns: Int = 0,
) {
    init {
        require(Sha256.isValid(sourceSha256)) { "Reading state must be bound to a source digest" }
        require(bookmarks.size <= MAX_BOOKMARKS) { "Too many bookmarks" }
        require(bookmarks.map { it.id }.toSet().size == bookmarks.size) { "Duplicate bookmark ids" }
        require(pageRotationQuarterTurns in 0..3) { "Rotation must be 0..3 quarter turns" }
    }

    companion object {
        const val MAX_BOOKMARKS: Int = 500
        const val CODEC_VERSION: Int = 1
    }
}

enum class PdfReadingStateError {
    MALFORMED,
    UNSUPPORTED_VERSION,
    STALE_SOURCE,
    OUT_OF_BOUNDS,
}

sealed class PdfReadingStateResult {
    data class Ok(val state: PdfReadingState) : PdfReadingStateResult()
    data class Invalid(val error: PdfReadingStateError) : PdfReadingStateResult()
}

/**
 * Strict line-based codec (UTF-8 text, `key=value`, tab-separated bookmark
 * rows). Chosen over JSON so the Notes authority can persist it in the same
 * revisioned record without a parser dependency, and so JVM tests are exact.
 *
 * Escaping: `\\`, `\t`, `\n` and `\r` are escaped in strings; unknown escapes
 * are rejected. Unknown keys are rejected (forward compatibility is handled by
 * [PdfReadingState.CODEC_VERSION], not by silently ignoring data).
 */
object PdfReadingStateCodec {

    private const val HEADER = "floe.pdf.reading"
    private const val KEY_VERSION = "version"
    private const val KEY_SOURCE = "source"
    private const val KEY_POSITION = "position"
    private const val KEY_ROTATION = "rotation"
    private const val KEY_BOOKMARKS = "bookmarks"
    private const val KEY_BOOKMARK = "bookmark"

    fun encode(state: PdfReadingState): String {
        val sb = StringBuilder(256)
        sb.append(HEADER).append('\n')
        sb.append(KEY_VERSION).append('=').append(PdfReadingState.CODEC_VERSION).append('\n')
        sb.append(KEY_SOURCE).append('=').append(state.sourceSha256).append('\n')
        sb.append(KEY_ROTATION).append('=').append(state.pageRotationQuarterTurns).append('\n')
        val p = state.position
        if (p != null) {
            sb.append(KEY_POSITION).append('=')
                .append(p.page.pageIndex).append('|')
                .append(p.zoom).append('|')
                .append(p.offsetX).append('|')
                .append(p.offsetY).append('\n')
        }
        sb.append(KEY_BOOKMARKS).append('=').append(state.bookmarks.size).append('\n')
        for (b in state.bookmarks) {
            sb.append(KEY_BOOKMARK).append('=')
            sb.append(b.id).append('\t')
            sb.append(b.page.pageIndex).append('\t')
            sb.append(b.createdAtMs).append('\t')
            sb.append(escape(b.label))
            b.snippet?.let { sb.append('\t').append(escape(it)) }
            sb.append('\n')
        }
        return sb.toString()
    }

    fun decode(text: String, expectedSourceSha256: String): PdfReadingStateResult {
        if (!text.startsWith(HEADER + "\n")) return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
        var source: String? = null
        var version = -1
        var rotation = 0
        var position: PdfReadingPosition? = null
        var declaredBookmarks = -1
        val bookmarks = ArrayList<PdfBookmark>()
        for (line in text.removeSuffix("\n").split('\n').drop(1)) {
            if (line.isEmpty()) continue
            val eq = line.indexOf('=')
            if (eq <= 0) return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
            val key = line.substring(0, eq)
            val value = line.substring(eq + 1)
            when (key) {
                KEY_VERSION -> version = value.toIntOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                KEY_SOURCE -> source = value
                KEY_ROTATION -> rotation = value.toIntOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                KEY_POSITION -> {
                    val parts = value.split('|')
                    if (parts.size != 4) return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val pageIndex = parts[0].toIntOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val page = PdfPageId.of(pageIndex) ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
                    val zoom = parts[1].toFloatOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val ox = parts[2].toFloatOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val oy = parts[3].toFloatOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    position = try {
                        PdfReadingPosition(page, zoom, ox, oy)
                    } catch (_: IllegalArgumentException) {
                        return PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
                    }
                }
                KEY_BOOKMARKS -> declaredBookmarks = value.toIntOrNull() ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                KEY_BOOKMARK -> {
                    if (bookmarks.size >= PdfReadingState.MAX_BOOKMARKS) {
                        return PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
                    }
                    val parts = value.split('\t')
                    if (parts.size !in 4..5) return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val pageIndex = parts[1].toIntOrNull()
                        ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val page = PdfPageId.of(pageIndex) ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
                    val created = parts[2].toLongOrNull()
                        ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val label = unescape(parts[3]) ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    val snippet = if (parts.size == 5) {
                        unescape(parts[4]) ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
                    } else {
                        null
                    }
                    bookmarks.add(
                        try {
                            PdfBookmark(
                                id = parts[0],
                                page = page,
                                label = label,
                                createdAtMs = created,
                                snippet = snippet,
                            )
                        } catch (_: IllegalArgumentException) {
                            return PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
                        },
                    )
                }
                else -> return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
            }
        }
        if (version != PdfReadingState.CODEC_VERSION) {
            return PdfReadingStateResult.Invalid(PdfReadingStateError.UNSUPPORTED_VERSION)
        }
        val sha = source ?: return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
        if (!Sha256.isValid(sha)) return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
        if (sha != expectedSourceSha256) {
            return PdfReadingStateResult.Invalid(PdfReadingStateError.STALE_SOURCE)
        }
        if (declaredBookmarks != bookmarks.size) {
            return PdfReadingStateResult.Invalid(PdfReadingStateError.MALFORMED)
        }
        return try {
            PdfReadingStateResult.Ok(PdfReadingState(sha, position, bookmarks, rotation))
        } catch (_: IllegalArgumentException) {
            PdfReadingStateResult.Invalid(PdfReadingStateError.OUT_OF_BOUNDS)
        }
    }

    private fun escape(raw: String): String {
        val sb = StringBuilder(raw.length + 8)
        for (c in raw) {
            when (c) {
                '\\' -> sb.append("\\\\")
                '\t' -> sb.append("\\t")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }

    private fun unescape(raw: String): String? {
        val sb = StringBuilder(raw.length)
        var i = 0
        while (i < raw.length) {
            val c = raw[i]
            if (c != '\\') {
                sb.append(c)
                i++
                continue
            }
            if (i + 1 >= raw.length) return null
            when (raw[i + 1]) {
                '\\' -> sb.append('\\')
                't' -> sb.append('\t')
                'n' -> sb.append('\n')
                'r' -> sb.append('\r')
                else -> return null
            }
            i += 2
        }
        return sb.toString()
    }
}
