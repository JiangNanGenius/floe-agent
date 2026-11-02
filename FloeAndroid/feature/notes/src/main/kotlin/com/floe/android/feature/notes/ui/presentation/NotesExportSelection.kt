// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NoteDocument
import com.floe.android.feature.notes.NotePage

/**
 * Why a requested export page selection was refused. Each value maps to a
 * typed, user-visible failure in `NotesWorkspaceController`; the selection is
 * never silently enlarged, deduplicated or reordered.
 */
public enum class NotesExportSelectionFailure {
    NO_PAGES,
    EMPTY_SELECTION,
    TOO_MANY_PAGES,
    DUPLICATE_PAGE,
    UNKNOWN_PAGE,
    STALE_REVISION,
}

public sealed interface NotesExportSelectionResult {
    /** Selected pages in the caller's requested order (whole document by default). */
    public data class Ready(public val pages: List<NotePage>) : NotesExportSelectionResult

    public data class Refused(
        public val failure: NotesExportSelectionFailure,
    ) : NotesExportSelectionResult
}

/**
 * Pure page selection for Notes PDF/image export.
 *
 * - `requestedPageIDs == null` selects the whole document in document order.
 * - An explicit list is an ORDERED selection: `[page-3, page-1]` exports page 3
 *   first. Duplicates, blank ids and ids that are not in the freshest document
 *   are refused instead of being dropped or rewritten.
 * - [expectedRevision] is the revision the UI presented to the user. A newer
 *   stored revision (an external edit, page insert/delete or undo) refuses the
 *   export rather than composing stale page identities.
 * - [MAX_PAGES] mirrors `core:notesmedia`'s bounded export planner; the call is
 *   refused before any media/rendering work starts.
 */
public object NotesExportSelection {
    public const val MAX_PAGES: Int = 500

    public fun resolve(
        document: NoteDocument,
        requestedPageIDs: List<String>? = null,
        expectedRevision: Int? = null,
    ): NotesExportSelectionResult {
        if (expectedRevision != null && expectedRevision != document.revision) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.STALE_REVISION)
        }
        val pages = document.pages
        if (pages.isEmpty()) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.NO_PAGES)
        }
        if (requestedPageIDs == null) {
            if (pages.size > MAX_PAGES) {
                return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.TOO_MANY_PAGES)
            }
            return NotesExportSelectionResult.Ready(pages)
        }
        if (requestedPageIDs.isEmpty()) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.EMPTY_SELECTION)
        }
        if (requestedPageIDs.size > MAX_PAGES) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.TOO_MANY_PAGES)
        }
        if (requestedPageIDs.any { it.isBlank() }) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.UNKNOWN_PAGE)
        }
        if (requestedPageIDs.toSet().size != requestedPageIDs.size) {
            return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.DUPLICATE_PAGE)
        }
        val byID = pages.associateBy { it.id }
        val selected = ArrayList<NotePage>(requestedPageIDs.size)
        for (pageID in requestedPageIDs) {
            selected += byID[pageID]
                ?: return NotesExportSelectionResult.Refused(NotesExportSelectionFailure.UNKNOWN_PAGE)
        }
        return NotesExportSelectionResult.Ready(selected)
    }
}
