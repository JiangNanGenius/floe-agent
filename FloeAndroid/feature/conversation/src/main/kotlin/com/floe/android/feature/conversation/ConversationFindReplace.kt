// SPDX-License-Identifier: MPL-2.0
//
// Local, literal find/replace over the ONE shared composer draft.
//
// This file is deliberately free of Android runtime, provider, backend,
// network, credential, file and persistence dependencies. It scans the
// in-memory draft String only; no request is made to a model or service just
// because the user searched. The full editor's Find bar, the holder mutation
// path and the unit tests all consume these pure helpers.
//
// Search semantics (⇄ the native editor's literal find/replace, without
// pretending a platform navigator exists):
//  - the query is LITERAL: Pattern.quote makes every metacharacter ordinary,
//    including `$`, `\`, `.`, `*`, `[` and `]`; no user-facing regex mode;
//  - matching is non-overlapping, left to right;
//  - case-insensitive by default with Unicode case folding; Match Case makes
//    it exact;
//  - Whole Word checks Unicode word boundaries at the ends of the match that
//    are themselves word characters (letters/digits/marks/connector
//    punctuation). A punctuation-only query is not artificially rejected;
//  - the replacement is appended exactly as typed. `$1`, `\n`, `\` and every
//    other sequence are literal text, never a replacement-group template.
//
// Replacement is a pure String transform: the caller (ConversationFlowHolder)
// applies the returned text through the ONE shared draft/undo/save/send
// pipeline. Replace All is one transform and therefore one atomic edit; a
// refusal returns a typed result and never returns a truncated replacement.
//
// Draft content is user data. The identity/state classes below redact the
// actual query/replacement/draft from toString so a diagnostic log can never
// print what the user typed.

package com.floe.android.feature.conversation

import androidx.compose.runtime.Immutable
import androidx.compose.ui.text.TextRange
import java.util.regex.Matcher
import java.util.regex.Pattern
import kotlin.math.roundToInt

/** Case/whole-word options for the literal matcher. */
@Immutable
data class FindOptions(
    val matchCase: Boolean = false,
    val wholeWord: Boolean = false,
)

/** One non-empty literal occurrence in UTF-16 offsets (end-exclusive). */
@Immutable
data class FindMatch(val start: Int, val end: Int) {
    init {
        require(start >= 0 && end > start) { "invalid find match range" }
    }

    val range: TextRange get() = TextRange(start, end)
}

/**
 * Identity of one search over one immutable draft revision.
 *
 * `text` participates in identity on purpose: a snapshot may only be applied
 * while the exact same draft content, generation, session, query and options
 * are still current. A late result from an older edit/session is rejected
 * instead of selecting text it was not computed against.
 */
@Immutable
data class FindSearchKey(
    val sessionEpoch: Long,
    val draftGeneration: Long,
    val text: String,
    val query: String,
    val matchCase: Boolean,
    val wholeWord: Boolean,
    /** Host temporary-generation identity; part of the session fence. */
    val temporaryIncarnationId: String? = null,
) {
    val options: FindOptions get() = FindOptions(matchCase, wholeWord)

    /** Redacts the draft/query/host incarnation id from any diagnostic log. */
    override fun toString(): String =
        "FindSearchKey(sessionEpoch=$sessionEpoch, draftGeneration=$draftGeneration, " +
            "textLength=${text.length}, queryLength=${query.length}, " +
            "matchCase=$matchCase, wholeWord=$wholeWord, " +
            "temporaryIncarnationPresent=${temporaryIncarnationId != null})"
}

/** One scan over an immutable draft/query snapshot. */
@Immutable
data class FindScan(
    val totalMatches: Int,
    val currentMatch: FindMatch?,
    val currentOrdinal: Int,
)

/** Result of replacing exactly one current match. */
sealed interface FindReplaceOneOutcome {
    data class Replaced(val text: String, val caretOffset: Int) : FindReplaceOneOutcome
    data object Stale : FindReplaceOneOutcome
}

/** Result of replacing every non-overlapping match in one atomic transform. */
sealed interface FindReplaceAllOutcome {
    data class Replaced(
        val text: String,
        val count: Int,
        val caretOffset: Int,
    ) : FindReplaceAllOutcome

    data object NoMatch : FindReplaceAllOutcome

    /** The expansion was refused before the output was allocated. */
    data class RefusedTooLarge(val attemptedUtf16Length: Long) : FindReplaceAllOutcome
}

/**
 * Literal matcher over one immutable String snapshot.
 *
 * The scanner holds no mutable search state between calls: every public method
 * starts from the same `text`/`query`/`options` snapshot, so a search can never
 * race a newer draft revision. `Cursor` is a private single-pass iterator used
 * to avoid allocating a match array for count/navigation/replace-all.
 *
 * Matching is synchronous because the draft is already in RAM. The size guard
 * in [replaceAll] is an ALLOCATION ceiling for one expansion, not an editor
 * cap: ordinary typing, navigation and Replace Current are never limited by
 * it, and a refusal leaves the draft untouched.
 */
class FindScanner(
    val text: String,
    val query: String,
    val options: FindOptions = FindOptions(),
) {

    private val pattern: Pattern? = if (query.isEmpty()) {
        null
    } else {
        Pattern.compile(
            Pattern.quote(query),
            if (options.matchCase) 0 else Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE,
        )
    }

    /** Total number of non-overlapping matches (empty query → 0). */
    fun count(): Int {
        if (pattern == null) return 0
        val cursor = cursor()
        var total = 0
        var match = cursor.nextAtOrAfter(0)
        while (match != null) {
            total += 1
            match = cursor.nextAtOrAfter(match.end)
        }
        return total
    }

    /** First match at or after [from], or null. */
    fun next(from: Int): FindMatch? = cursor().nextAtOrAfter(from)

    /** First match in the snapshot, or null. */
    fun first(): FindMatch? = next(0)

    /** Last match starting strictly before [before], or null. */
    fun previous(before: Int): FindMatch? {
        if (pattern == null || before <= 0) return null
        val cursor = cursor()
        var last: FindMatch? = null
        var match = cursor.nextAtOrAfter(0)
        while (match != null && match.start < before) {
            last = match
            match = cursor.nextAtOrAfter(match.end)
        }
        return last
    }

    /** Last match in the snapshot, or null. */
    fun last(): FindMatch? = previous(Int.MAX_VALUE)

    /** The exact match starting at [start], or null. */
    fun matchAt(start: Int): FindMatch? {
        if (pattern == null || start < 0 || start > text.length) return null
        val match = next(start) ?: return null
        return match.takeIf { it.start == start }
    }

    /**
     * One-pass scan anchored at [anchor] (normally the shared selection
     * start): prefer a match containing the caret, then the first match at or
     * after it, then wrap; a caret at the very end prefers the last match.
     */
    fun scan(anchor: Int): FindScan {
        if (pattern == null) return FindScan(0, null, -1)
        val clamped = anchor.coerceIn(0, text.length)
        val cursor = cursor()
        var total = 0
        var first: FindMatch? = null
        var containing: FindMatch? = null
        var containingAt = -1
        var atOrAfter: FindMatch? = null
        var atOrAfterAt = -1
        var last: FindMatch? = null
        var lastAt = -1
        var match = cursor.nextAtOrAfter(0)
        while (match != null) {
            if (first == null) first = match
            if (containing == null && clamped > match.start && clamped < match.end) {
                containing = match
                containingAt = total
            }
            if (atOrAfter == null && match.start >= clamped) {
                atOrAfter = match
                atOrAfterAt = total
            }
            last = match
            lastAt = total
            total += 1
            match = cursor.nextAtOrAfter(match.end)
        }
        val chosen: FindMatch?
        val chosenAt: Int
        when {
            containing != null -> {
                chosen = containing
                chosenAt = containingAt
            }
            atOrAfter != null -> {
                chosen = atOrAfter
                chosenAt = atOrAfterAt
            }
            clamped >= text.length && last != null -> {
                chosen = last
                chosenAt = lastAt
            }
            else -> {
                chosen = first
                chosenAt = if (first != null) 0 else -1
            }
        }
        return FindScan(total, chosen, chosenAt)
    }

    /** 0-based ordinal of [match] in this snapshot, or -1 when absent. */
    fun ordinalOf(match: FindMatch): Int {
        if (pattern == null) return -1
        val cursor = cursor()
        var ordinal = 0
        var current = cursor.nextAtOrAfter(0)
        while (current != null) {
            if (current.start == match.start && current.end == match.end) return ordinal
            ordinal += 1
            current = cursor.nextAtOrAfter(current.end)
        }
        return -1
    }

    /**
     * First [limit] matches, used only by the visual highlight layer. The
     * count/navigation/replace paths never materialise an unbounded array.
     */
    fun matches(limit: Int): List<FindMatch> {
        if (pattern == null || limit <= 0) return emptyList()
        val result = ArrayList<FindMatch>(minOf(limit, 32))
        val cursor = cursor()
        var match = cursor.nextAtOrAfter(0)
        while (match != null && result.size < limit) {
            result += match
            match = cursor.nextAtOrAfter(match.end)
        }
        return result
    }

    /**
     * Replace exactly [match]. Returns Stale when the range is no longer an
     * exact match of this snapshot (the caller must not edit copied text).
     */
    fun replaceOne(match: FindMatch, replacement: String): FindReplaceOneOutcome {
        if (pattern == null) return FindReplaceOneOutcome.Stale
        val actual = matchAt(match.start) ?: return FindReplaceOneOutcome.Stale
        if (actual.end != match.end) return FindReplaceOneOutcome.Stale
        val newText = buildString(text.length - (match.end - match.start) + replacement.length) {
            append(text, 0, match.start)
            append(replacement)
            append(text, match.end, text.length)
        }
        return FindReplaceOneOutcome.Replaced(
            text = newText,
            caretOffset = match.start + replacement.length,
        )
    }

    /**
     * Replace every non-overlapping match in ONE transform.
     *
     * The output length is computed and guarded before the builder allocates;
     * the result is either a complete replacement, NoMatch, or a typed refusal
     * with the original text untouched. The caret is mapped through the edits
     * so it stays near the same logical position. The second pass is linear and
     * appends the exact replacement text (no `$`/`\` template expansion, no
     * truncation).
     */
    fun replaceAll(replacement: String, caretOffset: Int): FindReplaceAllOutcome {
        if (pattern == null) return FindReplaceAllOutcome.NoMatch
        val safeCaret = caretOffset.coerceIn(0, text.length)
        var total = 0
        var lastEnd = 0
        var outputLength = 0L
        var caret = -1
        var caretMapped = false
        var totalDelta = 0L
        val scanCursor = cursor()
        var match = scanCursor.nextAtOrAfter(0)
        while (match != null) {
            total += 1
            outputLength = checkedAdd(outputLength, (match.start - lastEnd).toLong())
            if (exceedsAllocationGuard(outputLength)) {
                return FindReplaceAllOutcome.RefusedTooLarge(outputLength)
            }
            if (!caretMapped && safeCaret < match.start) {
                caret = (outputLength - (match.start - safeCaret)).toInt()
                caretMapped = true
            }
            outputLength = checkedAdd(outputLength, replacement.length.toLong())
            if (exceedsAllocationGuard(outputLength)) {
                return FindReplaceAllOutcome.RefusedTooLarge(outputLength)
            }
            if (!caretMapped && safeCaret <= match.end) {
                caret = outputLength.toInt()
                caretMapped = true
            }
            if (!caretMapped) {
                totalDelta += replacement.length.toLong() - (match.end - match.start).toLong()
            }
            lastEnd = match.end
            match = scanCursor.nextAtOrAfter(match.end)
        }
        if (total == 0) return FindReplaceAllOutcome.NoMatch
        outputLength = checkedAdd(outputLength, (text.length - lastEnd).toLong())
        if (exceedsAllocationGuard(outputLength)) {
            return FindReplaceAllOutcome.RefusedTooLarge(outputLength)
        }
        if (!caretMapped) {
            caret = (safeCaret + totalDelta).toInt()
        }

        val builder = StringBuilder(outputLength.toInt())
        val buildCursor = cursor()
        var copiedTo = 0
        var copied = buildCursor.nextAtOrAfter(0)
        while (copied != null) {
            builder.append(text, copiedTo, copied.start)
            builder.append(replacement)
            copiedTo = copied.end
            copied = buildCursor.nextAtOrAfter(copied.end)
        }
        builder.append(text, copiedTo, text.length)
        if (builder.length != outputLength.toInt()) {
            // Defensive integrity check: never apply a partially built result.
            return FindReplaceAllOutcome.RefusedTooLarge(builder.length.toLong())
        }
        return FindReplaceAllOutcome.Replaced(
            text = builder.toString(),
            count = total,
            caretOffset = caret.coerceIn(0, builder.length),
        )
    }

    /* ------------------------------- internals ------------------------------- */

    private fun cursor(): Cursor = Cursor()

    /**
     * One matcher reused for a single left-to-right pass. `find(start)`
     * restarts from an explicit offset, so a whole-word rejection can retry at
     * the next code point without allocating a matcher or a range array.
     */
    private inner class Cursor {
        private val matcher: Matcher? = pattern?.matcher(text)

        fun nextAtOrAfter(from: Int): FindMatch? {
            val active = matcher ?: return null
            var start = boundaryAt(from)
            while (start <= text.length) {
                if (!active.find(start)) return null
                val matchStart = active.start()
                val matchEnd = active.end()
                if (matchEnd > matchStart && wholeWordAllowed(matchStart, matchEnd)) {
                    return FindMatch(matchStart, matchEnd)
                }
                start = advanceCodePoint(matchStart)
            }
            return null
        }
    }

    private fun boundaryAt(index: Int): Int {
        val clamped = index.coerceIn(0, text.length)
        if (clamped in 1 until text.length &&
            text[clamped].isLowSurrogate() &&
            text[clamped - 1].isHighSurrogate()
        ) {
            return clamped + 1
        }
        return clamped
    }

    private fun advanceCodePoint(index: Int): Int {
        if (index >= text.length) return text.length + 1
        return index + Character.charCount(text.codePointAt(index))
    }

    private fun wholeWordAllowed(start: Int, end: Int): Boolean {
        if (!options.wholeWord) return true
        // Only enforce a boundary where the MATCH itself is a word character.
        // A punctuation query keeps normal literal semantics instead of being
        // impossible to find in whole-word mode.
        if (isWordCodePoint(text.codePointAt(start))) {
            val before = if (start == 0) null else text.codePointBefore(start)
            if (before != null && isWordCodePoint(before)) return false
        }
        if (isWordCodePoint(text.codePointBefore(end))) {
            val after = if (end >= text.length) null else text.codePointAt(end)
            if (after != null && isWordCodePoint(after)) return false
        }
        return true
    }

    private fun isWordCodePoint(cp: Int): Boolean {
        if (Character.isLetterOrDigit(cp)) return true
        val type = Character.getType(cp)
        return type == Character.LETTER_NUMBER.toInt() ||
            type == Character.OTHER_NUMBER.toInt() ||
            type == Character.NON_SPACING_MARK.toInt() ||
            type == Character.COMBINING_SPACING_MARK.toInt() ||
            type == Character.ENCLOSING_MARK.toInt() ||
            type == Character.CONNECTOR_PUNCTUATION.toInt()
    }

    private fun checkedAdd(current: Long, addition: Long): Long =
        if (addition > 0 && current > Long.MAX_VALUE - addition) Long.MAX_VALUE else current + addition

    /**
     * True only when the candidate output both exceeds the absolute expansion
     * ceiling AND is larger than the draft it would replace. A Replace All
     * that merely shrinks/keeps an already large draft is not artificially
     * capped; every refusal is before the output builder allocates and leaves
     * the input/selection/undo untouched.
     */
    private fun exceedsAllocationGuard(outputLength: Long): Boolean =
        outputLength > MAX_REPLACE_ALL_OUTPUT_UTF16 && outputLength > text.length.toLong()

    companion object {
        /**
         * Defensive ceiling for ONE replace-all EXPANSION (UTF-16 units, about
         * 16 MiB of backing characters). It is intentionally far above normal
         * chat drafts. Normal editing, find navigation and Replace Current are
         * never capped, and a shrink/no-grow replacement is compared against
         * the existing draft length rather than this ceiling. A refusal is
         * typed and leaves the draft/selection untouched.
         */
        const val MAX_REPLACE_ALL_OUTPUT_UTF16: Int = 8 * 1024 * 1024

        /** Bounded highlight window; counts and replacement are never truncated. */
        const val MAX_HIGHLIGHT_MATCHES: Int = 512
    }
}

/**
 * Pure scroll policy for bringing the current real match into the editor's
 * viewport. The UI feeds actual Compose text-layout line bounds and the real
 * ScrollState; this helper only decides the nearest safe offset.
 */
object FindScrollPolicy {
    fun targetOffset(
        matchTop: Float,
        matchBottom: Float,
        scrollOffset: Int,
        viewportHeight: Int,
        maxScroll: Int,
        marginPx: Int,
    ): Int {
        val max = maxScroll.coerceAtLeast(0)
        val current = scrollOffset.coerceIn(0, max)
        if (viewportHeight <= 0) return current
        val margin = marginPx.coerceAtLeast(0).coerceAtMost(viewportHeight / 2)
        val top = matchTop.coerceAtMost(matchBottom)
        val bottom = matchBottom.coerceAtLeast(matchTop)
        val visibleTop = current + margin
        val visibleBottom = current + viewportHeight - margin
        val desired = when {
            top < visibleTop -> top - margin
            bottom > visibleBottom -> bottom - viewportHeight + margin
            else -> current.toFloat()
        }
        return desired.roundToInt().coerceIn(0, max)
    }
}

/** Presentation state owned by the holder (RAM only, never saved to disk). */
@Immutable
data class FindReplaceUiState(
    val isOpen: Boolean = false,
    val query: String = "",
    val replacement: String = "",
    val matchCase: Boolean = false,
    val wholeWord: Boolean = false,
    val totalMatches: Int = 0,
    val currentOrdinal: Int = -1,
    val currentMatch: FindMatch? = null,
    /** Set only when Replace All refused an oversized expansion; the UI shows
     * a concise local message and the draft/selection stay untouched. */
    val replaceAllRefused: Boolean = false,
) {
    val options: FindOptions get() = FindOptions(matchCase, wholeWord)
    val hasMatches: Boolean get() = totalMatches > 0

    /** Redacts the query/replacement from any diagnostic log. */
    override fun toString(): String =
        "FindReplaceUiState(isOpen=$isOpen, queryLength=${query.length}, " +
            "replacementLength=${replacement.length}, matchCase=$matchCase, " +
            "wholeWord=$wholeWord, totalMatches=$totalMatches, " +
            "currentOrdinal=$currentOrdinal, currentMatch=$currentMatch, " +
            "replaceAllRefused=$replaceAllRefused)"
}

/** Result vocabulary for the holder's two replacement actions. */
sealed interface FindReplaceEditResult {
    data class Replaced(val replacements: Int) : FindReplaceEditResult
    data object NoMatch : FindReplaceEditResult
    data object Stale : FindReplaceEditResult
    data class RefusedTooLarge(val attemptedUtf16Length: Long) : FindReplaceEditResult
}
