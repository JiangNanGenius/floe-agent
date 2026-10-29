// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.state

import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NotesEdit

/**
 * Page edits shared by PDF and image imports.
 *
 * A new notebook is created with one native placeholder page. The first PDF
 * page must REPLACE that placeholder instead of being inserted after it;
 * otherwise page 1 is an empty cover and every PDF page is shifted by one.
 * The remaining pages use absolute final positions, so the caller may apply
 * the edit list in bounded chunks without recomputing indices.
 */
internal fun importedNotebookPageEdits(
    placeholderPageID: String?,
    pages: List<NotePage>,
): List<NotesEdit> {
    if (pages.isEmpty()) return emptyList()
    return buildList {
        val first = pages.first()
        if (placeholderPageID != null) {
            add(NotesEdit.UpdatePage(first.copy(id = placeholderPageID)))
            pages.drop(1).forEachIndexed { offset, page ->
                add(NotesEdit.InsertPage(page, index = 1 + offset))
            }
        } else {
            pages.forEachIndexed { index, page ->
                add(NotesEdit.InsertPage(page, index = index))
            }
        }
    }
}
