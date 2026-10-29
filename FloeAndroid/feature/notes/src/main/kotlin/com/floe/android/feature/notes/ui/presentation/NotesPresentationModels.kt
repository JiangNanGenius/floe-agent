// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NoteDocumentSummary
import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.NotesException
import com.floe.android.feature.notes.ui.api.NotesPortFailure
import com.floe.android.feature.notes.ui.api.NotesPortFailureException

/** Library section, mirroring the iOS `SectionFilter` order. */
public enum class NotesLibraryFilter(public val key: String) {
    RECENT("recent"),
    ALL("all"),
    MIND_MAPS("mindMaps"),
    FAVORITES("favorites"),
    TRASH("trash"),
    ;

    public companion object {
        public fun fromKey(value: String?): NotesLibraryFilter =
            entries.firstOrNull { it.key == value } ?: RECENT
    }
}

public enum class NotesSortOrder(public val key: String) {
    UPDATED("updated"),
    CREATED("created"),
    TITLE("title"),
    ;

    public companion object {
        public fun fromKey(value: String?): NotesSortOrder =
            entries.firstOrNull { it.key == value } ?: UPDATED
    }
}

public enum class NotesEditorTool(public val key: String) {
    SELECT("select"),
    TEXT("text"),
    INK("ink"),
    ;

    public companion object {
        public fun fromKey(value: String?): NotesEditorTool =
            entries.firstOrNull { it.key == value } ?: SELECT
    }
}

public enum class NotesSaveStatus {
    /** Last dispatched mutation is committed at the current revision. */
    SAVED,

    /** Local edits are queued; autosave has not dispatched them yet. */
    DIRTY,
    SAVING,

    /** A dispatch failed; the exact pending edits are retained for retry. */
    FAILED,

    /** Revision conflict; pending edits are retained and recovery is explicit. */
    CONFLICT,

    /** New edits are fenced (root stopping/read-only); pending edits are retained. */
    BLOCKED,
}

public enum class NotesLoadStatus { LOADING, READY, FAILED }

public enum class NotesConflictAction { RELOAD, RETRY_WITH_BASE }

/** UI-neutral failure; only known codes are localized by the surface. */
public data class NotesFailure(
    public val code: String,
    public val detail: String? = null,
) {
    public companion object {
        public const val UNEXPECTED = "unexpected"
        public const val CANCELLED = "cancelled"
    }
}

public fun Throwable.toNotesFailure(): NotesFailure = when (this) {
    is NotesPortFailureException -> NotesFailure(failure.code, failure.detail)
    is NotesException -> NotesFailure(code, reason)
    is kotlinx.coroutines.CancellationException -> NotesFailure(NotesFailure.CANCELLED)
    else -> NotesFailure(NotesFailure.UNEXPECTED, message)
}

public fun NotesPortFailure.toNotesFailure(): NotesFailure = NotesFailure(code, detail)

public data class NotesEditConflict(
    public val documentID: String,
    public val baseRevision: Int,
    public val currentRevision: Int? = null,
    public val detail: String? = null,
)

/** Pure list selection used by the library (also the unit-test seam). */
public fun filterAndSortDocuments(
    summaries: List<NoteDocumentSummary>,
    recentDocumentIDs: List<String>,
    filter: NotesLibraryFilter,
    notebookID: String?,
    sort: NotesSortOrder,
    query: String = "",
    searchResults: List<NoteDocumentSummary>? = null,
): List<NoteDocumentSummary> {
    val source = if (query.isNotBlank()) searchResults.orEmpty() else summaries
    val recentOrder = recentDocumentIDs.withIndex().associate { (index, id) -> id to index }
    val searching = query.isNotBlank()
    val filtered = source.filter { document ->
        if (searching) {
            // Search is global: it includes notes outside Recently Opened and
            // the current notebook, while still never mixing in Trash.
            val include = if (filter == NotesLibraryFilter.TRASH) {
                document.deletedAt != null
            } else {
                document.deletedAt == null
            }
            return@filter include
        }
        val matchesFilter = when (filter) {
            NotesLibraryFilter.RECENT -> document.deletedAt == null && recentOrder.containsKey(document.id)
            NotesLibraryFilter.ALL -> document.deletedAt == null
            NotesLibraryFilter.MIND_MAPS -> document.deletedAt == null &&
                document.kind == NoteDocumentKind.MIND_MAP
            NotesLibraryFilter.FAVORITES -> document.deletedAt == null && document.isFavorite
            NotesLibraryFilter.TRASH -> document.deletedAt != null
        }
        if (!matchesFilter) return@filter false
        if (filter == NotesLibraryFilter.TRASH) return@filter true
        notebookID == null || document.notebookID == notebookID
    }
    return when (sort) {
        NotesSortOrder.UPDATED -> filtered.sortedByDescending { it.updatedAt }
        NotesSortOrder.CREATED -> filtered.sortedByDescending { it.createdAt }
        NotesSortOrder.TITLE -> filtered.sortedWith(
            compareBy(String.CASE_INSENSITIVE_ORDER) { it.title },
        )
    }.let { values ->
        if (filter == NotesLibraryFilter.RECENT) {
            values.sortedBy { recentOrder[it.id] ?: Int.MAX_VALUE }
        } else {
            values
        }
    }
}

/** Content-search excerpt around the first case-insensitive match. */
public fun searchSnippet(text: String, query: String, radius: Int = 45): String {
    val trimmed = query.trim()
    if (trimmed.isEmpty()) return text.take(140)
    val index = text.indexOf(trimmed, ignoreCase = true)
    if (index < 0) return text.take(140)
    val start = (index - radius).coerceAtLeast(0)
    val end = (index + trimmed.length + radius * 2).coerceAtMost(text.length)
    return buildString {
        if (start > 0) append('…')
        append(text, start, end)
        if (end < text.length) append('…')
    }
}

/** Counts used by the library filter badges; honest derived values. */
public data class NotesLibraryCounts(
    public val documents: Int = 0,
    public val trashed: Int = 0,
    public val favorites: Int = 0,
    public val notebooks: Int = 0,
    public val mindMaps: Int = 0,
)

public fun countsOf(summaries: List<NoteDocumentSummary>): NotesLibraryCounts =
    NotesLibraryCounts(
        documents = summaries.count { it.deletedAt == null },
        trashed = summaries.count { it.deletedAt != null },
        favorites = summaries.count { it.deletedAt == null && it.isFavorite },
        mindMaps = summaries.count { it.deletedAt == null && it.kind == NoteDocumentKind.MIND_MAP },
    )

/** Cover/summary classification; automatic covers are saved-summary derived. */
public val NoteDocumentSummary.kindLabelKey: String
    get() = when (kind) {
        NoteDocumentKind.NOTEBOOK -> "note"
        NoteDocumentKind.MIND_MAP -> "mindMap"
        NoteDocumentKind.OFFICE -> "office"
        NoteDocumentKind.ENGINEERING -> "engineering"
    }
