// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

/**
 * Facts captured around ONE keep-revisions PDF export.
 *
 * The export path is the existing pinned `STAGED_EXPORT` (`saveAs` into a
 * fresh module-private file), which never runs accept/reject and never
 * flushes the working copy. This proof records that structural fact against
 * real observations:
 *
 *  - [workingCopySha256Before] / [workingCopySha256After] are measured from
 *    the actual editable working-copy file. `null` means the file could not
 *    be measured, never "unchanged";
 *  - [revisionMutationEpochBefore] / [revisionMutationEpochAfter] count every
 *    observed accept/reject command (Floe review action or the page's own
 *    UNO command). Equality is the proof that no revision mutation was
 *    dispatched during the export window;
 *  - [sourceUnchanged] is true only when both digests exist and are equal;
 *  - [pdfCarriesEditableRevisions] is always false: a PDF is a rendering,
 *    not an editable revision container. The source OOXML keeps them.
 */
data class OfficeRevisionPdfProof(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val workingCopySha256Before: String?,
    val workingCopyBytesBefore: Long,
    val workingCopySha256After: String?,
    val workingCopyBytesAfter: Long,
    val revisionMutationEpochBefore: Long,
    val revisionMutationEpochAfter: Long,
    val outputSha256: String?,
    val outputBytes: Long,
    val completed: Boolean,
    val completedAtElapsedMs: Long,
) {
    val sourceUnchanged: Boolean?
        get() = if (workingCopySha256Before != null && workingCopySha256After != null) {
            workingCopySha256Before == workingCopySha256After &&
                workingCopyBytesBefore == workingCopyBytesAfter
        } else {
            null
        }

    /** No accept/reject command was observed in the export window. */
    val revisionsPreserved: Boolean
        get() = revisionMutationEpochBefore == revisionMutationEpochAfter

    /** A PDF cannot carry editable tracked-change records. */
    val pdfCarriesEditableRevisions: Boolean get() = false

    /** Stable UI code; never a path. */
    val verdict: String
        get() = when {
            !completed -> "notCreated"
            !revisionsPreserved -> "revisionActionDuringExport"
            sourceUnchanged == true -> "revisionsKeptSourceUnchanged"
            sourceUnchanged == false -> "revisionsKeptSourceChanged"
            else -> "revisionsKeptSourceUnmeasured"
        }
}
