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

    private fun proveInsertion(
        baselineText: String,
        savedText: String,
        expectedText: String,
    ): TextDeltaProof {
        if (expectedText.isEmpty()) return TextDeltaProof.Unproven(VerificationNotes.VALUE_UNCHANGED)
        var occurrences = 0
        var at = savedText.indexOf(expectedText)
        while (at >= 0) {
            if (occurrences >= VerificationLimits.MAX_TEXT_OCCURRENCES) {
                return TextDeltaProof.Unproven(VerificationNotes.DELTA_SEARCH_BOUNDED)
            }
            val without = savedText.substring(0, at) + savedText.substring(at + expectedText.length)
            if (without == baselineText) return TextDeltaProof.Proven(SCOPE_INSERTED_AT_CURSOR)
            occurrences += 1
            at = savedText.indexOf(expectedText, at + 1)
        }
        return TextDeltaProof.Unproven(VerificationNotes.DELTA_NOT_SINGLE_EDIT)
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
