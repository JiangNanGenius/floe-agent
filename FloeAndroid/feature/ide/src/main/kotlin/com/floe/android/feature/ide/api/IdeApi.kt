// SPDX-License-Identifier: MPL-2.0
//
// Frozen public contract of the :feature:ide renderer/presentation module.
// Main's app-host adapter (B3) implements [IdeHost] against the Swift
// FloeWorkspace authority and pushes [IdeReceiver] events; this module never
// owns durable document truth, task authority, executors or routes. Every
// snapshot, transaction, command and pushed event carries the full owner
// fence (task + workspace + binding generation) plus a native revision token,
// so stale replies can never touch another document/task projection.
package com.floe.android.feature.ide.api

/**
 * Opaque Swift-side revision token (draft/CAS lineage). The module compares
 * it by [opaque] equality only and never parses or invents it.
 */
@JvmInline
public value class NativeRevision(public val opaque: String) {
    override fun toString(): String = opaque
}

/** Full owner fence: every request/reply/event must carry a matching scope. */
public data class IdeOwnerScope(
    public val taskId: String,
    public val workspaceId: String,
    public val bindingGeneration: Long,
)

/** Identity of one openable text document under its exact owning task/workspace. */
public data class IdeDocumentKey(
    public val taskId: String,
    public val workspaceId: String,
    public val documentId: String,
) {
    public val owner: String get() = "$taskId/$workspaceId"
}

/** Immutable export of unconfirmed UI text. This is not a native revision
 * or durability claim; only the host's actual recovery file read-back may
 * acknowledge it. The original document is never overwritten. */
public enum class IdeRecoverySource { REJECTED, PENDING }
public data class IdeRecoveryProjection(
    public val recoveryId: String,
    public val key: IdeDocumentKey,
    public val relativePath: String,
    public val nativeRevision: NativeRevision,
    public val text: String,
    public val composing: Boolean,
    public val source: IdeRecoverySource,
)

/** UTF-16 code-unit offsets over the whole document. Caret when start == end. */
public data class IdeTextSelection(
    public val startUtf16: Int,
    public val endUtf16: Int,
)

/** A half-open-agnostic UTF-16 range [start, end). */
public data class IdeUtf16Range(
    public val startUtf16: Int,
    public val endUtf16: Int,
)

/**
 * Host-supplied capability truth. Absent capabilities render real disabled
 * states in this module — nothing is simulated until a backend is bound.
 */
public data class IdeDocumentCapabilities(
    public val readOnly: Boolean = false,
    public val undo: Boolean = false,
    public val redo: Boolean = false,
    public val save: Boolean = false,
    public val find: Boolean = false,
    public val replace: Boolean = false,
    public val diff: Boolean = false,
    public val run: Boolean = false,
    public val openPreview: Boolean = false,
    public val terminal: Boolean = false,
    public val completion: Boolean = false,
) {
    public companion object {
        /** Safe default: nothing is available until the host says otherwise. */
        public val NONE: IdeDocumentCapabilities = IdeDocumentCapabilities()
    }
}

/**
 * Bounded host-owned content handle. Large document bodies / paste payloads
 * cross the facade (64 KiB) and effect (48 KiB) caps as fragments referenced
 * by this handle; the UI may hold the FULL assembled text in RAM afterwards.
 * A snapshot with [text] == null and a non-null [contentRef] is a LOADING
 * projection until assembly completes — never a truncated success.
 */
public data class IdeContentRef(
    public val handleId: String,
    public val documentKey: IdeDocumentKey,
    public val revision: NativeRevision,
    public val totalUtf16: Long,
    public val fragmentUtf16: Int,
    public val transport: String,
)

/** One delivered fragment of an [IdeContentRef] body. */
public data class IdeContentFragment(
    public val ref: IdeContentRef,
    public val startUtf16: Int,
    public val text: String,
    public val isLast: Boolean,
)

/**
 * Authoritative presentation snapshot. [text] is COMPLETE whenever present;
 * null only while a [contentRef] body is still being streamed. The transient
 * viewport (selection/caret/scroll) rides along when the native side knows it.
 */
public data class IdeDocumentSnapshot(
    public val key: IdeDocumentKey,
    public val revision: NativeRevision,
    public val generation: Long,
    public val text: String?,
    public val fileName: String,
    public val relativePath: String,
    public val languageId: String? = null,
    public val sizeBytes: Long? = null,
    public val readOnly: Boolean = false,
    public val capabilities: IdeDocumentCapabilities = IdeDocumentCapabilities.NONE,
    public val selection: IdeTextSelection? = null,
    public val caretUtf16: Int? = null,
    public val firstVisibleLine: Int? = null,
    public val viewportTopPx: Int? = null,
    public val contentRef: IdeContentRef? = null,
)

/** Why an edit event reached the projection (host policy for undo grouping). */
public enum class IdeEditOrigin { USER_TYPING, USER_IME_COMMIT, USER_PASTE, USER_DELETE, USER_CUT }

/**
 * Versioned edit transaction from view to host. The range is expressed in
 * UTF-16 code units over the document the [expectedRevision] describes;
 * [generation] stamps the snapshot lineage so a stale chain can be fenced.
 */
public data class IdeEditTransaction(
    public val owner: IdeOwnerScope,
    public val documentKey: IdeDocumentKey,
    public val transactionId: String,
    public val expectedRevision: NativeRevision,
    public val generation: Long,
    public val range: IdeUtf16Range,
    public val replacement: String,
    public val origin: IdeEditOrigin,
)

public enum class IdeSaveReason { USER, AUTO, PREVIEW, RUN }

public enum class IdeReplaceScope { CURRENT, ALL }

public enum class IdeCloseDecision { SAVE, DISCARD, CANCEL }

public enum class IdeOpenReason { TREE, SEARCH, TAB_RESTORE }

public enum class IdeConflictChoice { KEEP_LOCAL, USE_REMOTE, KEEP_BOTH }

/**
 * Both versions stay available for recovery presentation until the user
 * resolves; the module never drops either side.
 */
public data class IdeConflictPayload(
    public val documentKey: IdeDocumentKey,
    public val baseText: String?,
    public val localDraftText: String,
    public val remoteText: String,
    public val remoteRevision: NativeRevision,
)

public enum class IdeLoadingState { LOADING, READY, FAILED }

public data class IdeTabDescriptor(
    public val documentId: String,
    public val relativePath: String,
    public val fileName: String,
    public val languageId: String? = null,
    public val readOnly: Boolean = false,
    /** Native dirty truth — the projection never computes this itself. */
    public val dirty: Boolean = false,
    public val loading: IdeLoadingState = IdeLoadingState.READY,
    public val loadingMessage: String? = null,
)

public data class IdeTabsSnapshot(
    public val owner: IdeOwnerScope,
    public val activeDocumentId: String?,
    public val tabs: List<IdeTabDescriptor>,
    public val generation: Long,
)

public data class IdeFileRow(
    public val relativePath: String,
    public val name: String,
    public val isDirectory: Boolean,
    public val sizeBytes: Long? = null,
)

/** Lazy children delivery; [parentRelativePath] null means workspace root. */
public data class IdeTreeChildrenEvent(
    public val owner: IdeOwnerScope,
    public val parentRelativePath: String?,
    public val requestGeneration: Long,
    public val children: List<IdeFileRow>,
    public val error: String? = null,
)

public data class IdeSearchHit(
    public val relativePath: String,
    public val documentId: String? = null,
    /** 0 for a name match; 1-based line for a content match. */
    public val lineNumber: Int,
    public val context: String,
)

public data class IdeWorkspaceSearchResult(
    public val owner: IdeOwnerScope,
    public val query: String,
    public val queryGeneration: Long,
    public val hits: List<IdeSearchHit>,
    public val error: String? = null,
)

public data class IdeDocumentDiffPayload(
    public val documentKey: IdeDocumentKey,
    public val revision: NativeRevision,
    /** Unified diff text (`--- / +++ / @@ / + - space` lines) from the native service. */
    public val unifiedDiff: String,
    public val error: String? = null,
)

public data class IdeFindResult(
    public val documentKey: IdeDocumentKey,
    public val revision: NativeRevision,
    public val query: String,
    public val caseSensitive: Boolean,
    public val wholeWord: Boolean,
    public val hits: List<IdeUtf16Range>,
    public val error: String? = null,
)

public enum class IdeDiagnosticSeverity { ERROR, WARNING, INFO, HINT }

public data class IdeDiagnostic(
    public val id: Long,
    public val range: IdeUtf16Range,
    public val severity: IdeDiagnosticSeverity,
    public val message: String,
    public val detail: String? = null,
)

public data class IdeDiagnosticSnapshot(
    public val documentKey: IdeDocumentKey,
    public val revision: NativeRevision,
    public val items: List<IdeDiagnostic>,
)

public enum class IdeCompletionItemKind { TEXT, METHOD, FUNCTION, FIELD, VARIABLE, CLASS, KEYWORD, SNIPPET, OTHER }

public data class IdeCompletionItem(
    public val label: String,
    public val insertText: String,
    public val detail: String? = null,
    public val kind: IdeCompletionItemKind = IdeCompletionItemKind.TEXT,
)

/**
 * Host completion answer for one selection-request identity. Applied only
 * when [revision] equals the active snapshot revision AND [requestId] is the
 * latest request the presenter issued for that document — older revisions for
 * the same document are rejected outright.
 */
public data class IdeCompletionSnapshot(
    public val documentKey: IdeDocumentKey,
    public val requestId: String,
    public val revision: NativeRevision,
    public val selection: IdeTextSelection,
    public val items: List<IdeCompletionItem>,
)

public enum class IdeErrorCode {
    STALE_REVISION, CONFLICT, READ_ONLY, NOT_FOUND, IO, POLICY, HOST_UNAVAILABLE, UNSUPPORTED, INTERNAL
}

public data class IdeCommandPayload(
    public val kind: Kind,
    public val save: IdeSaveOutcome? = null,
    public val replace: IdeReplaceOutcome? = null,
    public val find: IdeFindResult? = null,
    public val snapshot: IdeDocumentSnapshot? = null,
    public val closedDocumentId: String? = null,
    public val treeChildren: IdeTreeChildrenEvent? = null,
    public val search: IdeWorkspaceSearchResult? = null,
    public val diff: IdeDocumentDiffPayload? = null,
    public val diagnostics: IdeDiagnosticSnapshot? = null,
    public val fragment: IdeContentFragment? = null,
) {
    public enum class Kind { NONE, SAVE, REPLACE, FIND, SNAPSHOT, CLOSED, TREE_CHILDREN, WORKSPACE_SEARCH, DIFF, DIAGNOSTICS, CONTENT_FRAGMENT }

    public companion object {
        public fun none(): IdeCommandPayload = IdeCommandPayload(Kind.NONE)
        public fun of(kind: Kind, block: Builder.() -> Unit): IdeCommandPayload =
            Builder().apply { this.kindForced = kind; block() }.let {
                IdeCommandPayload(kind = it.kindForced, save = it.save, replace = it.replace, find = it.find,
                    snapshot = it.snapshot, closedDocumentId = it.closedDocumentId, treeChildren = it.treeChildren,
                    search = it.search, diff = it.diff, diagnostics = it.diagnostics, fragment = it.fragment)
            }

        public class Builder internal constructor() {
            internal var kindForced: Kind = Kind.NONE
            public var save: IdeSaveOutcome? = null
            public var replace: IdeReplaceOutcome? = null
            public var find: IdeFindResult? = null
            public var snapshot: IdeDocumentSnapshot? = null
            public var closedDocumentId: String? = null
            public var treeChildren: IdeTreeChildrenEvent? = null
            public var search: IdeWorkspaceSearchResult? = null
            public var diff: IdeDocumentDiffPayload? = null
            public var diagnostics: IdeDiagnosticSnapshot? = null
            public var fragment: IdeContentFragment? = null
        }
    }
}

public data class IdeSaveOutcome(
    public val revision: NativeRevision,
    public val conflict: IdeConflictPayload? = null,
)

public data class IdeReplaceOutcome(
    public val replacements: Int,
    public val snapshot: IdeDocumentSnapshot,
)

public sealed interface IdeReplyOutcome {
    /** Native accepted the operation and advanced to a new revision. */
    public data class Acknowledged(public val newRevision: NativeRevision) : IdeReplyOutcome

    /** Native executed and produced a typed payload. */
    public data class Executed(public val payload: IdeCommandPayload) : IdeReplyOutcome

    /** Native rejected the operation. The projection never treats this as success. */
    public data class Failed(public val code: IdeErrorCode, public val message: String) : IdeReplyOutcome

    /** Native authority moved under this view: carries the merged/authoritative snapshot. */
    public data class StaleRevision(public val current: IdeDocumentSnapshot) : IdeReplyOutcome
}

/** Reply for any transactionId/requestId, matching document and generation.
 * [requestId] is null for spontaneous host pushes (e.g. diagnostics, external
 * native changes delivered as a payload without a pending request). */
public data class IdeCommandReply(
    public val requestId: String?,
    public val owner: IdeOwnerScope,
    public val documentKey: IdeDocumentKey?,
    public val outcome: IdeReplyOutcome,
)

/** User intent requests. Every request carries the full owner fence. */
public sealed interface IdeCommandRequest {
    public val requestId: String
    public val owner: IdeOwnerScope
    public val documentKey: IdeDocumentKey?

    /** Explicit typed-path open; the host resolves the native documentId and
     * answers with Executed(SNAPSHOT/snapshot) — the UI never guesses ids. */
    public data class OpenFile(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val relativePath: String,
        public val reason: IdeOpenReason,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey? = null
    }

    public data class Save(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val reason: IdeSaveReason,
    ) : IdeCommandRequest

    public data class Undo(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
    ) : IdeCommandRequest

    public data class Redo(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
    ) : IdeCommandRequest

    public data class Find(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val query: String,
        public val caseSensitive: Boolean,
        public val wholeWord: Boolean,
        public val backwards: Boolean,
        public val fromUtf16: Int?,
    ) : IdeCommandRequest

    public data class Replace(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val query: String,
        public val replacement: String,
        public val caseSensitive: Boolean,
        public val scope: IdeReplaceScope,
        public val expectedRevision: NativeRevision,
        /** Must echo the find UI whole-word intent; the host replaces ONLY
         * matching hits and never guesses (Main API review 2026-10-24).
         * Default false keeps positional call sites compatible. */
        public val wholeWord: Boolean = false,
    ) : IdeCommandRequest

    public data class CloseDocument(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val documentId: String,
        public val decision: IdeCloseDecision,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey? = null
    }

    public data class ReopenDocument(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val documentId: String,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey? = null
    }

    public data class ResolveConflict(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val chosenText: String,
        public val choice: IdeConflictChoice,
    ) : IdeCommandRequest

    public data class Run(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
    ) : IdeCommandRequest

    public data class OpenPreview(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
    ) : IdeCommandRequest

    public data class UpdateSelection(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val selection: IdeTextSelection,
        public val firstVisibleLine: Int,
    ) : IdeCommandRequest

    public data class RequestWorkspaceSearch(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val query: String,
        public val queryGeneration: Long,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey? = null
    }

    public data class ExpandTree(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val parentRelativePath: String?,
        public val requestGeneration: Long,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey? = null
    }

    public data class LoadDiff(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
    ) : IdeCommandRequest

    /** Attachable completion request identity for one caret/selection. The
     * host answers asynchronously through [IdeReceiver.onCompletion]. */
    public data class RequestCompletion(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        override val documentKey: IdeDocumentKey,
        public val selection: IdeTextSelection,
    ) : IdeCommandRequest

    /** Bounded continuation read for a streamed [IdeContentRef] body. */
    public data class RequestContentFragment(
        override val requestId: String,
        override val owner: IdeOwnerScope,
        public val handle: IdeContentRef,
        public val startUtf16: Int,
        public val maxUnits: Int,
    ) : IdeCommandRequest {
        override val documentKey: IdeDocumentKey get() = handle.documentKey
    }
}
