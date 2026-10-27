// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

/** Proves the ONE requested replacement/insertion at the SAME part from the
 * ACTUAL trusted pre-edit baseline text to the ACTUAL saved part text.
 * Global "contains(wanted)", a changed package hash or an ack alone can never
 * produce a Proven result here: the saved text must equal the baseline with
 * exactly the desired replacement or insertion applied. Bounded so a hostile
 * input cannot drive unbounded searching.
 */
internal sealed class TextDeltaProof {
    data class Proven(val scope: String) : TextDeltaProof()
    data class Unproven(val note: String) : TextDeltaProof()
}

internal object SemanticDelta {

    const val SCOPE_SELECTION_REPLACED = "selectionReplaced"
    const val SCOPE_INSERTED_AT_CURSOR = "insertedAtCursor"
    const val SCOPE_WHOLE_BODY_REPLACED = "wholeBodyReplaced"
    const val SCOPE_TEXT_PRESENT_ONLY = "textPresentOnly"
    const val SCOPE_CELL_REPLACED = "cellReplaced"
    const val SCOPE_CELL_INSERTED = "cellInserted"

    fun proveTextDelta(
        baselineText: String?,
        baselineClipboardText: String?,
        savedText: String,
        priorSelectionText: String?,
        expectedText: String,
    ): TextDeltaProof {
        if (baselineText == null) return TextDeltaProof.Unproven(VerificationNotes.BASELINE_UNVERIFIED)
        val prior = priorSelectionText ?: return TextDeltaProof.Unproven(
            VerificationNotes.PRIOR_SELECTION_MISSING,
        )
        if (prior == expectedText) return TextDeltaProof.Unproven(VerificationNotes.VALUE_UNCHANGED)
        if (prior.isEmpty()) {
            return proveInsertion(baselineText, savedText, expectedText)
        }
        if (savedText == expectedText &&
            (baselineText == prior || baselineClipboardText == prior)
        ) {
            // The alternate DOCX form is an exact, structure-derived Writer
            // clipboard rendering (including list labels), never a relaxed
            // comparison. Partial replacement still uses ONLY baselineText.
            return TextDeltaProof.Proven(SCOPE_WHOLE_BODY_REPLACED)
        }
        return proveReplacement(baselineText, savedText, prior, expectedText)
    }

    /**
     * Exact single-insertion proof from an ACTUAL empty native prior.
     *
     * Only the two real OOXML paste shapes are considered (see
     * [insertionSpans]); each candidate span must reproduce the trusted
     * baseline byte-for-byte when removed once, so every old paragraph
     * survives in order and nothing else moved. Nothing is trimmed, no
     * `contains` is accepted, an extra/absent delimiter stays unproven, and
     * the search stays bounded.
     */
    private fun proveInsertion(
        baselineText: String,
        savedText: String,
        expectedText: String,
    ): TextDeltaProof {
        if (expectedText.isEmpty()) return TextDeltaProof.Unproven(VerificationNotes.VALUE_UNCHANGED)
        val candidates = insertionSpans(savedText, expectedText)
        for ((at, length) in candidates.spans) {
            val without = savedText.substring(0, at) + savedText.substring(at + length)
            if (without == baselineText) return TextDeltaProof.Proven(SCOPE_INSERTED_AT_CURSOR)
        }
        // Honest bounded-work note when the enumeration had to stop early:
        // absence of a proof here is NOT proof of absence.
        if (candidates.truncated) {
            return TextDeltaProof.Unproven(VerificationNotes.DELTA_SEARCH_BOUNDED)
        }
        return TextDeltaProof.Unproven(VerificationNotes.DELTA_NOT_SINGLE_EDIT)
    }

    private class InsertionSpans(
        val spans: List<Pair<Int, Int>>,
        val truncated: Boolean,
    )

    /**
     * Enumerates every (offset, length) span of [savedText] whose removal
     * could be the ONE exact insertion of [expectedText], in the two real
     * OOXML shapes only:
     *
     *  1. INLINE — the text was spliced INSIDE one existing paragraph, so the
     *     bare occurrence is a candidate (the original, unchanged rule).
     *  2. NEW COMPLETE PARAGRAPH/BLOCK — the paste created whole paragraph
     *     leaves. Both part normalizers join paragraph leaves with exactly one
     *     '\n' ([WordText.normalizedBodyText] over `w:p` leaves,
     *     [PptxText.normalizedSlideText] over `a:p` leaves), so the created
     *     run is the inserted text plus ONE adjacent delimiter. The delimiter
     *     variant must be a COMPLETE paragraph run: `'\n' + text` may only END
     *     at end-of-text or immediately before another '\n', and `text + '\n'`
     *     may only START at begin-of-text or immediately after a '\n'.
     *
     * Shape 2's boundary is what keeps an old paragraph SPLIT around the
     * insertion from being proved as an insertion: baseline `"AB"` with saved
     * paragraphs `"A"`/`"xB"` flattens to `"A\nxB"`, and removing `"\nx"`
     * would restore `"AB"` even though the old paragraph no longer exists.
     * Requiring the created run to be whole rejects that (and its `"Ax\nB"`
     * mirror) while a real prepend/middle/append paragraph insertion still
     * proves (Main review 2026-10-28). No trimming, no `contains`, no other
     * shape is enumerated, and the enumeration itself is bounded by
     * [VerificationLimits.MAX_TEXT_OCCURRENCES].
     */
    private fun insertionSpans(savedText: String, expectedText: String): InsertionSpans {
        val cap = VerificationLimits.MAX_TEXT_OCCURRENCES
        val spans = ArrayList<Pair<Int, Int>>()
        val prefixed = "\n$expectedText"
        val suffixed = "$expectedText\n"

        // 1. inline splice inside one existing paragraph.
        var at = savedText.indexOf(expectedText)
        while (at >= 0) {
            // Bounded enumeration: stop and report the cap honestly.
            if (spans.size >= cap) return InsertionSpans(spans, truncated = true)
            spans.add(at to expectedText.length)
            at = savedText.indexOf(expectedText, at + 1)
        }
        // 2a. a whole created run appended after an existing paragraph: the
        // run must END the part text or be followed by another delimiter.
        at = savedText.indexOf(prefixed)
        while (at >= 0) {
            // Bounded enumeration: stop and report the cap honestly.
            if (spans.size >= cap) return InsertionSpans(spans, truncated = true)
            val end = at + prefixed.length
            if (end == savedText.length || savedText[end] == '\n') {
                spans.add(at to prefixed.length)
            }
            at = savedText.indexOf(prefixed, at + 1)
        }
        // 2b. a whole created run inserted before an existing paragraph: the
        // run must START the part text or follow another delimiter.
        at = savedText.indexOf(suffixed)
        while (at >= 0) {
            // Bounded enumeration: stop and report the cap honestly.
            if (spans.size >= cap) return InsertionSpans(spans, truncated = true)
            if (at == 0 || savedText[at - 1] == '\n') {
                spans.add(at to suffixed.length)
            }
            at = savedText.indexOf(suffixed, at + 1)
        }
        return InsertionSpans(spans, truncated = false)
    }

    private fun proveReplacement(
        baselineText: String,
        savedText: String,
        prior: String,
        expectedText: String,
    ): TextDeltaProof {
        var occurrences = 0
        var at = baselineText.indexOf(prior)
        if (at < 0) return TextDeltaProof.Unproven(VerificationNotes.PRIOR_NOT_IN_BASELINE)
        while (at >= 0) {
            if (occurrences >= VerificationLimits.MAX_TEXT_OCCURRENCES) {
                return TextDeltaProof.Unproven(VerificationNotes.DELTA_SEARCH_BOUNDED)
            }
            val transformed = baselineText.substring(0, at) + expectedText +
                baselineText.substring(at + prior.length)
            if (transformed == savedText) return TextDeltaProof.Proven(SCOPE_SELECTION_REPLACED)
            occurrences += 1
            at = baselineText.indexOf(prior, at + 1)
        }
        return TextDeltaProof.Unproven(VerificationNotes.DELTA_NOT_SINGLE_EDIT)
    }

    /** Cell delta: the baseline's ACTUAL persisted value for the same logical
     * address must equal the captured prior selection, and the saved value
     * must already have passed its own exact content proof (checked by the
     * caller). Absent baseline cell with an empty prior counts as insertion.
     */
    fun proveCellDelta(
        baselineDisplay: String?,
        savedDisplay: String?,
        priorSelectionText: String?,
        contentMatches: Boolean,
        baselineCellWasMissing: Boolean,
    ): TextDeltaProof {
        val prior = priorSelectionText ?: return TextDeltaProof.Unproven(
            VerificationNotes.PRIOR_SELECTION_MISSING,
        )
        if (!contentMatches) return TextDeltaProof.Unproven(VerificationNotes.DELTA_NOT_SINGLE_EDIT)
        val baseline = baselineDisplay ?: ""
        if (baseline == savedDisplay) return TextDeltaProof.Unproven(VerificationNotes.VALUE_UNCHANGED)
        if (baseline != prior) return TextDeltaProof.Unproven(VerificationNotes.PRIOR_NOT_IN_BASELINE)
        return if (baselineCellWasMissing && prior.isEmpty()) {
            TextDeltaProof.Proven(SCOPE_CELL_INSERTED)
        } else {
            TextDeltaProof.Proven(SCOPE_CELL_REPLACED)
        }
    }
}
