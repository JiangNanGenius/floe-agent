// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NotesEdit

/**
 * Coalesces repeated full-value edits inside one autosave window so a drag or
 * a burst of typing becomes one undoable change instead of hundreds. Ordering
 * of distinct operations is preserved; only the latest value for the same
 * target survives.
 */
public fun coalesceEdits(edits: List<NotesEdit>): List<NotesEdit> {
    if (edits.size <= 1) return edits
    val output = mutableListOf<NotesEdit>()
    val indexByKey = mutableMapOf<String, Int>()
    fun put(key: String?, edit: NotesEdit) {
        if (key == null) {
            output += edit
            return
        }
        val existing = indexByKey[key]
        if (existing != null) {
            output[existing] = edit
        } else {
            indexByKey[key] = output.size
            output += edit
        }
    }
    edits.forEach { edit ->
        val key = when (edit) {
            is NotesEdit.Rename -> "rename"
            is NotesEdit.MoveToNotebook -> "move"
            is NotesEdit.Favorite -> "favorite"
            is NotesEdit.Tags -> "tags"
            is NotesEdit.TextSource -> "textsource:${edit.id}"
            is NotesEdit.UpdatePage -> "page:${edit.page.id}"
            is NotesEdit.Drawing -> "drawing:${edit.pageID}"
            is NotesEdit.UpsertElement -> "element:${edit.pageID}:${edit.element.id}"
            is NotesEdit.UpsertNode -> "node:${edit.node.id}"
            is NotesEdit.UpsertConnection -> "connection:${edit.connection.id}"
            is NotesEdit.MindMapLayout -> "layout"
            is NotesEdit.ReplaceOfficeResource -> "office"
            is NotesEdit.ReplaceMindMap -> "mindmap"
            else -> null
        }
        if (edit is NotesEdit.ReplaceMindMap) {
            // A full map replacement supersedes earlier per-node/connection edits.
            output.removeAll {
                it is NotesEdit.UpsertNode || it is NotesEdit.DeleteBranch ||
                    it is NotesEdit.UpsertConnection || it is NotesEdit.DeleteConnection ||
                    it is NotesEdit.ReplaceMindMap
            }
            indexByKey.clear()
            output += edit
        } else if (edit is NotesEdit.DeletePage) {
            output.removeAll {
                (it is NotesEdit.UpsertElement && it.pageID == edit.pageID) ||
                    (it is NotesEdit.UpdatePage && it.page.id == edit.pageID) ||
                    (it is NotesEdit.Drawing && it.pageID == edit.pageID)
            }
            indexByKey.clear()
            output += edit
        } else {
            put(key, edit)
        }
    }
    return output
}

/** True when a queued batch has no user-visible effect left to apply. */
public fun isEmptyEditList(edits: List<NotesEdit>): Boolean = edits.isEmpty()

public data class NotesEditQueueState(
    public val pending: List<NotesEdit>,
    public val hasPending: Boolean,
    public val estimatedBytes: Int,
    public val needsSplitting: Boolean,
)

public fun queueState(edits: List<NotesEdit>): NotesEditQueueState = NotesEditQueueState(
    pending = edits,
    hasPending = edits.isNotEmpty(),
    estimatedBytes = NotesRequestBudget.estimateBytes(edits),
    needsSplitting = NotesRequestBudget.estimateBytes(edits) > NotesRequestBudget.SAFE_BATCH_BYTES,
)
