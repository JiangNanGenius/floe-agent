// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.ui

import com.floe.android.feature.notes.NoteDocumentKind
import com.floe.android.feature.notes.ui.api.NotesOfficeBlankKind

/**
 * Explicit create choices, matching the iOS Library "New" menu:
 * Blank Note, Mind Map, Notebook, then the Office submenu.
 *
 * Import is an action, not a document kind; it never selects a row and
 * never renders an inline name field (iOS launches the file importer
 * directly from the menu). "Import from Floe Workspace" is a separate action
 * owned by the real task-workspace chooser; it is rendered only while the
 * App has wired `NotesHostPorts.workspaceImport`.
 */
internal enum class NotesCreateKind {
    NOTE,
    MIND_MAP,
    NOTEBOOK,
    WORD,
    SHEET,
    SLIDES,
}

internal data class NotesCreateRequest(
    val kind: NotesCreateKind,
    val title: String,
)

/**
 * One modal surface drives the whole create flow. The root menu and the
 * Office submenu are list states; a type selection swaps the SAME sheet to
 * the medium naming form. This keeps a single dialog window (no stacked
 * scrims or two sheets animating over each other) while preserving the iOS
 * "choose type, then name" steps.
 */
internal sealed interface NotesCreateStage {
    data object Closed : NotesCreateStage
    data object Menu : NotesCreateStage
    data object OfficeMenu : NotesCreateStage
    data class Naming(val kind: NotesCreateKind) : NotesCreateStage
}

/** Trim first; whitespace-only names can never be submitted. */
internal fun notesCreateRequest(kind: NotesCreateKind, rawTitle: String): NotesCreateRequest? {
    val title = rawTitle.trim()
    return if (title.isEmpty()) null else NotesCreateRequest(kind, title)
}

/** Document kind for non-Office creation, or null for a notebook/Office type. */
internal fun NotesCreateKind.documentKind(): NoteDocumentKind? = when (this) {
    NotesCreateKind.NOTE -> NoteDocumentKind.NOTEBOOK
    NotesCreateKind.MIND_MAP -> NoteDocumentKind.MIND_MAP
    NotesCreateKind.NOTEBOOK,
    NotesCreateKind.WORD,
    NotesCreateKind.SHEET,
    NotesCreateKind.SLIDES -> null
}

/** Office blank kind for the Office submenu, or null for every other type. */
internal fun NotesCreateKind.officeKind(): NotesOfficeBlankKind? = when (this) {
    NotesCreateKind.WORD -> NotesOfficeBlankKind.WORD
    NotesCreateKind.SHEET -> NotesOfficeBlankKind.SHEET
    NotesCreateKind.SLIDES -> NotesOfficeBlankKind.SLIDES
    NotesCreateKind.NOTE,
    NotesCreateKind.MIND_MAP,
    NotesCreateKind.NOTEBOOK -> null
}
