// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import android.content.Context
import com.floe.android.feature.notes.NotesEdit

/**
 * Per-device presentation state only (tabs, last page, zoom, tool). It is NOT
 * document authority: losing it never loses note content, and it never holds
 * unsaved edits. Main should construct [SharedPreferencesNotesPresentationStore]
 * once and pass it in [com.floe.android.feature.notes.ui.api.NotesHostPorts].
 */
public data class NotesWorkspacePreferences(
    public val openDocumentIDs: List<String> = emptyList(),
    public val activeDocumentID: String? = null,
    public val grid: Boolean = true,
    public val filter: String = "recent",
    public val sort: String = "updated",
    public val selectedNotebookID: String? = null,
)

public data class NotesDocumentPreferences(
    public val pageID: String? = null,
    public val zoom: Float = 1f,
    /** 0..1 vertical position inside the active page, restored on reopen. */
    public val scrollFraction: Float = 0f,
    public val tool: String? = null,
    /**
     * Default true: devices without an active stylus must be able to write
     * with a finger on first use. A saved explicit pen-only choice remains
     * false and is never overwritten by this default.
     */
    public val fingerDrawing: Boolean = true,
    public val penColor: String = "#202020",
    public val penWidth: Float = 3f,
)

public interface NotesPresentationStore {
    public fun loadWorkspace(): NotesWorkspacePreferences
    public fun saveWorkspace(preferences: NotesWorkspacePreferences)
    public fun loadDocument(documentID: String): NotesDocumentPreferences
    public fun saveDocument(documentID: String, preferences: NotesDocumentPreferences)
    public fun forgetDocument(documentID: String)
}

/** Test/preview fallback; production integration should use the SharedPreferences store. */
public class InMemoryNotesPresentationStore : NotesPresentationStore {
    private var workspace: NotesWorkspacePreferences = NotesWorkspacePreferences()
    private val documents: MutableMap<String, NotesDocumentPreferences> = mutableMapOf()

    @Synchronized
    override fun loadWorkspace(): NotesWorkspacePreferences = workspace

    @Synchronized
    override fun saveWorkspace(preferences: NotesWorkspacePreferences) {
        workspace = preferences
    }

    @Synchronized
    override fun loadDocument(documentID: String): NotesDocumentPreferences =
        documents[documentID] ?: NotesDocumentPreferences()

    @Synchronized
    override fun saveDocument(documentID: String, preferences: NotesDocumentPreferences) {
        documents[documentID] = preferences
    }

    @Synchronized
    override fun forgetDocument(documentID: String) {
        documents.remove(documentID)
    }
}

/**
 * Real device preference store. It contains no paths, secrets or content, so
 * ordinary SharedPreferences is appropriate; it is cleared with the app's own
 * data and never consulted as document truth.
 */
public class SharedPreferencesNotesPresentationStore(
    context: Context,
) : NotesPresentationStore {
    private val prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    override fun loadWorkspace(): NotesWorkspacePreferences = NotesWorkspacePreferences(
        openDocumentIDs = prefs.getString(KEY_TABS, "")
            ?.split('\n')
            ?.filter { it.isNotBlank() }
            .orEmpty(),
        activeDocumentID = prefs.getString(KEY_ACTIVE, null)?.takeIf { it.isNotBlank() },
        grid = prefs.getBoolean(KEY_GRID, true),
        filter = prefs.getString(KEY_FILTER, "recent") ?: "recent",
        sort = prefs.getString(KEY_SORT, "updated") ?: "updated",
        selectedNotebookID = prefs.getString(KEY_NOTEBOOK, null)?.takeIf { it.isNotBlank() },
    )

    override fun saveWorkspace(preferences: NotesWorkspacePreferences) {
        prefs.edit()
            .putString(KEY_TABS, preferences.openDocumentIDs.joinToString("\n"))
            .putString(KEY_ACTIVE, preferences.activeDocumentID)
            .putBoolean(KEY_GRID, preferences.grid)
            .putString(KEY_FILTER, preferences.filter)
            .putString(KEY_SORT, preferences.sort)
            .putString(KEY_NOTEBOOK, preferences.selectedNotebookID)
            .apply()
    }

    override fun loadDocument(documentID: String): NotesDocumentPreferences {
        val suffix = ".$documentID"
        return NotesDocumentPreferences(
            pageID = prefs.getString(KEY_PAGE + suffix, null)?.takeIf { it.isNotBlank() },
            zoom = prefs.getFloat(KEY_ZOOM + suffix, 1f).coerceIn(0.5f, 3f),
            scrollFraction = prefs.getFloat(KEY_SCROLL + suffix, 0f).coerceIn(0f, 1f),
            tool = prefs.getString(KEY_TOOL + suffix, null),
            // Preserve an explicitly saved pen-only (false) choice; only the
            // absence of a saved preference means finger writing by default.
            fingerDrawing = prefs.getBoolean(KEY_FINGER + suffix, true),
            penColor = prefs.getString(KEY_PEN_COLOR + suffix, "#202020") ?: "#202020",
            penWidth = prefs.getFloat(KEY_PEN_WIDTH + suffix, 3f).coerceIn(0.5f, 32f),
        )
    }

    override fun saveDocument(documentID: String, preferences: NotesDocumentPreferences) {
        val suffix = ".$documentID"
        prefs.edit()
            .putString(KEY_PAGE + suffix, preferences.pageID)
            .putFloat(KEY_ZOOM + suffix, preferences.zoom.coerceIn(0.5f, 3f))
            .putFloat(KEY_SCROLL + suffix, preferences.scrollFraction.coerceIn(0f, 1f))
            .putString(KEY_TOOL + suffix, preferences.tool)
            .putBoolean(KEY_FINGER + suffix, preferences.fingerDrawing)
            .putString(KEY_PEN_COLOR + suffix, preferences.penColor)
            .putFloat(KEY_PEN_WIDTH + suffix, preferences.penWidth.coerceIn(0.5f, 32f))
            .apply()
    }

    override fun forgetDocument(documentID: String) {
        val suffix = ".$documentID"
        prefs.edit()
            .remove(KEY_PAGE + suffix)
            .remove(KEY_ZOOM + suffix)
            .remove(KEY_SCROLL + suffix)
            .remove(KEY_TOOL + suffix)
            .remove(KEY_FINGER + suffix)
            .remove(KEY_PEN_COLOR + suffix)
            .remove(KEY_PEN_WIDTH + suffix)
            .apply()
    }

    private companion object {
        const val FILE = "floe.notes.presentation"
        const val KEY_TABS = "workspace.tabs"
        const val KEY_ACTIVE = "workspace.active"
        const val KEY_GRID = "workspace.grid"
        const val KEY_FILTER = "workspace.filter"
        const val KEY_SORT = "workspace.sort"
        const val KEY_NOTEBOOK = "workspace.notebook"
        const val KEY_PAGE = "document.page"
        const val KEY_ZOOM = "document.zoom"
        const val KEY_SCROLL = "document.scroll"
        const val KEY_TOOL = "document.tool"
        const val KEY_FINGER = "document.finger"
        const val KEY_PEN_COLOR = "document.penColor"
        const val KEY_PEN_WIDTH = "document.penWidth"
    }
}

/* ------------------------------- recovery --------------------------------- */

/**
 * Typed unsaved-edit recovery for a root-epoch change (and for a save that
 * could not be dispatched). These edits were authored by the user and have
 * never been silently truncated; Main may redrive them after the new root is
 * bound. They are not document authority and never replace a saved revision.
 */
public data class NotesPendingRecovery(
    /** The exact source document; recovery never fans out to another note. */
    public val documentID: String,
    public val documentKind: String,
    public val documentTitle: String,
    /** The revision the edits were authored against. */
    public val baseRevision: Int,
    public val requestTitle: String,
    public val edits: List<NotesEdit>,
    public val reasonCode: String,
    public val createdAt: Long,
    /** Stable native retry identity; preserves receipt idempotency on resume. */
    public val requestID: String? = null,
    /** Page-keyed unimported ink bytes, preserved when the root stopped early. */
    public val inkDrafts: Map<String, ByteArray> = emptyMap(),
)

public interface NotesRecoveryStore {
    public fun put(recovery: NotesPendingRecovery)
    public fun remove(documentID: String)
    public fun pending(): List<NotesPendingRecovery>
    public fun clear()
}

/**
 * Process-scoped fallback. It preserves edits across a root epoch change and
 * document switch inside the same process; process-death durability requires
 * an App-owned implementation (see HOST_PORTS.md). It holds typed edits in
 * memory, never on disk, so no note text leaks into preferences.
 */
public class InMemoryNotesRecoveryStore : NotesRecoveryStore {
    private val values = mutableMapOf<String, NotesPendingRecovery>()

    @Synchronized
    override fun put(recovery: NotesPendingRecovery) {
        values[recovery.documentID] = recovery
    }

    @Synchronized
    override fun remove(documentID: String) {
        values.remove(documentID)
    }

    @Synchronized
    override fun pending(): List<NotesPendingRecovery> =
        values.values.sortedBy { it.createdAt }

    @Synchronized
    override fun clear() {
        values.clear()
    }
}
