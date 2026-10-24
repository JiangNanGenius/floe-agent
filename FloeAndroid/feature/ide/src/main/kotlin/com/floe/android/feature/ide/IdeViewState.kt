// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.feature.ide.api.IdeConflictPayload
import com.floe.android.feature.ide.api.IdeDiagnostic
import com.floe.android.feature.ide.api.IdeDocumentSnapshot
import com.floe.android.feature.ide.api.IdeFileRow
import com.floe.android.feature.ide.api.IdeSearchHit
import com.floe.android.feature.ide.api.IdeTabDescriptor
import com.floe.android.feature.ide.api.IdeUtf16Range
import com.floe.android.feature.ide.api.NativeRevision

/** Public presentation state the Compose layers render from. */
public data class IdeViewState(
    public val bindingGeneration: Long,
    public val attached: Boolean = false,
    /** Application owner fence; independent of native file permissions. */
    public val inputAdmissionOpen: Boolean = true,
    /** Host is loading the workspace root. */
    public val bootLoading: Boolean = false,
    public val activeDocumentKey: com.floe.android.feature.ide.api.IdeDocumentKey? = null,
    /** Authoritative active snapshot (text null only while streaming). */
    public val snapshot: IdeDocumentSnapshot? = null,
    /** RAM projection mirror (never a second durable truth). */
    public val mirrorText: String? = null,
    public val documentLoading: Boolean = false,
    public val documentLoadingMessage: String? = null,
    /** Native dirty truth (from host tabs) OR unacked local transactions. */
    public val dirtyLocal: Boolean = false,
    public val pendingTransactionCount: Int = 0,
    public val saveInFlight: Boolean = false,
    /** Last host sync failure shown in the banner (message only, honest). */
    public val syncError: String? = null,
    /** Rejected local tail available for an explicit user restore. */
    public val hasRejectedEdits: Boolean = false,
    public val conflict: IdeConflictPayload? = null,
    public val find: IdeFindBarState = IdeFindBarState(),
    public val diff: IdeDiffState? = null,
    public val diagnostics: List<IdeDiagnostic> = emptyList(),
    public val diagnosticsVersion: Int = 0,
    public val tree: IdeTreeState = IdeTreeState(),
    public val tabs: List<IdeTabItem> = emptyList(),
    public val closeRequest: IdeCloseRequest? = null,
    public val bottomPaneOpen: Boolean = false,
    public val caretLine: Int = 0,
    public val caretColumn: Int = 0,
    public val selectionLengthUtf16: Int = 0,
    /** Bumped every time the editor must apply a selection request (find jump). */
    public val editorSelectionRequestVersion: Int = 0,
    public val editorSelectionRequest: IdeUtf16Range? = null,
    /** Bumped when the adapter should re-run full editor state (tab switch). */
    public val editorResetVersion: Int = 0,
)

public data class IdeTabItem(
    public val descriptor: IdeTabDescriptor,
    public val active: Boolean,
    public val localPending: Boolean,
)

public data class IdeCloseRequest(
    public val documentId: String,
    public val fileName: String,
    public val dirty: Boolean,
)

public data class IdeFindBarState(
    public val open: Boolean = false,
    public val query: String = "",
    public val replacement: String = "",
    public val caseSensitive: Boolean = false,
    public val wholeWord: Boolean = false,
    /** Null until the host answers the current query. */
    public val hitCount: Int? = null,
    public val currentHitIndex: Int = -1,
    public val inFlight: Boolean = false,
    public val error: String? = null,
)

public data class IdeDiffState(
    public val documentId: String,
    public val revision: NativeRevision,
    public val lines: List<IdeDiffLine>,
    public val additions: Int,
    public val removals: Int,
    public val error: String? = null,
)

public enum class IdeDiffLineKind { HEADER, HUNK_HEADER, ADDITION, REMOVAL, CONTEXT }

public data class IdeDiffLine(
    public val text: String,
    public val kind: IdeDiffLineKind,
)

public data class IdeTreeState(
    /** Flattened visible rows for the list. */
    public val rows: List<IdeTreeRow> = emptyList(),
    /** Search mode: non-null while the search query is active. */
    public val searchQuery: String = "",
    public val searchInProgress: Boolean = false,
    public val searchHits: List<IdeSearchHit> = emptyList(),
    public val searchError: String? = null,
    public val rootLoading: Boolean = false,
    public val rootError: String? = null,
)

public data class IdeTreeRow(
    public val file: IdeFileRow,
    public val depth: Int,
    public val expanded: Boolean,
    public val childrenLoading: Boolean,
)
