// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.PickRequestSpec
import com.floe.android.safgateway.SafDocument
import com.floe.android.safgateway.SafDocumentRef
import com.floe.android.safgateway.SafFailure
import com.floe.android.safgateway.SafUriRef
import java.io.File

/**
 * Space → Files: a real Android folder/file manager over the user's own
 * authorized SAF trees. Nothing here is a project, task or workspace id.
 *
 * Identity rules carried from core/safgateway:
 *  - provider `content://` URIs and document ids are exact, opaque identities.
 *    They are never parsed into POSIX paths and never rebuilt by hand.
 *  - a saved root is local METADATA only (name + uri + time). The OS
 *    `persistedUriPermissions` row plus a live permission probe are the only
 *    grant truth, re-read on every catalog load and before every action.
 *  - `size == null` means the provider did not say; it is never coerced to 0.
 */

/** Application-owned saved root metadata. The display name is untrusted text. */
internal data class SpaceFilesRoot(
    val uri: SafUriRef,
    val name: String,
    val savedAtMillis: Long,
)

/** Derived access state for one saved root (OS persisted row + live probe). */
internal enum class SpaceRootAccess {
    /** At least read+write is currently granted. */
    READ_WRITE,

    /** Readable, but the currently granted bits do not include write. */
    READ_ONLY,

    /** Neither truth source grants access: the user must pick it again. */
    REVOKED,
}

internal data class SpaceRootUi(
    val uri: SafUriRef,
    val name: String,
    val savedAtMillis: Long,
    val read: Boolean,
    val write: Boolean,
    /** True only when the OS holds a persisted row for this exact tree. */
    val persisted: Boolean,
) {
    val access: SpaceRootAccess
        get() = when {
            !read && !write -> SpaceRootAccess.REVOKED
            !read -> SpaceRootAccess.REVOKED
            !write -> SpaceRootAccess.READ_ONLY
            else -> SpaceRootAccess.READ_WRITE
        }

    val usable: Boolean get() = access != SpaceRootAccess.REVOKED
}

/**
 * One level of the current folder path. The first entry is always the saved
 * tree root; `documentId == null` there means "the tree's own root document",
 * which is exactly what `SafProviderOperations.listTreePage` accepts.
 */
internal data class SpaceFolderCrumb(
    val documentId: String?,
    val uri: SafUriRef,
    val name: String,
    /** Exact `DIR_SUPPORTS_CREATE` bit of this folder, false when unknown. */
    val canCreateChildren: Boolean,
)

/** One provider child row, capability-gated by its own COLUMN_FLAGS. */
internal data class SpaceFileEntry(
    val name: String,
    val mimeType: String,
    /** Null = the provider did not report a size. Never 0 by default. */
    val sizeBytes: Long?,
    val lastModifiedMillis: Long?,
    val isDirectory: Boolean,
    val isVirtual: Boolean,
    val ref: SafDocumentRef,
    /** Exact per-document provider capabilities (write/rename/delete/copy/move). */
    val canWrite: Boolean,
    val canRename: Boolean,
    val canDelete: Boolean,
    val canCopy: Boolean,
    val canMove: Boolean,
    val canCreateChildren: Boolean,
) {
    val documentId: String? get() = ref.documentId
    val uri: SafUriRef get() = ref.uri
}

/** The current folder's listing plus its honest page state. */
internal data class SpaceRootBrowse(
    val root: SpaceRootUi,
    val path: List<SpaceFolderCrumb>,
    val entries: List<SpaceFileEntry> = emptyList(),
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: SpaceFilesFailure? = null,
    val hasMore: Boolean = false,
    val nextCursorToken: String? = null,
    val initialised: Boolean = false,
) {
    val folder: SpaceFolderCrumb? get() = path.lastOrNull()
    val canGoUp: Boolean get() = path.size > 1
    val canCreateHere: Boolean
        get() = !loading && error?.blocking != true && folder?.canCreateChildren == true &&
            root.access == SpaceRootAccess.READ_WRITE
}

/** A picker request the composition must hand to the system picker verbatim. */
internal data class SpaceRootPick(val incarnation: Long, val spec: PickRequestSpec)

/** What the composition actually observed when it started ACTION_VIEW. */
internal enum class SpaceFilesOpenResult { LAUNCHED, NO_HANDLER, FAILED }

/** A resolved ACTION_VIEW request; the composition performs the Android call. */
internal data class SpaceFilesOpenRequest(
    val id: Long,
    val uri: SafUriRef,
    val mimeType: String,
    val name: String,
)

/** Destination chooser for one pending copy/move. Exact tree + exact folder. */
internal data class SpaceTransfer(
    val operation: SpaceFilesOperation,
    val source: SpaceFileEntry,
    val tree: SafUriRef,
    val rootName: String,
    val path: List<SpaceFolderCrumb>,
    val directories: List<SpaceFileEntry> = emptyList(),
    val loading: Boolean = false,
    val error: SpaceFilesFailure? = null,
    val hasMore: Boolean = false,
    val nextCursorToken: String? = null,
) {
    val folder: SpaceFolderCrumb? get() = path.lastOrNull()
    val canGoUp: Boolean get() = path.size > 1
}

internal enum class SpaceFilesOperation {
    ADD_ROOT,
    REMOVE_ROOT,
    LOAD,
    CREATE_FOLDER,
    CREATE_FILE,
    RENAME,
    DELETE,
    COPY,
    MOVE,
    PREVIEW,
    OPEN,
    EDIT,
}

/** Closed, user-actionable problems. Every one maps to one concise line. */
internal enum class SpaceFilesProblem {
    GRANT_REVOKED,
    GRANT_MISSING,
    RE_PICK_REQUIRED,
    READ_ONLY,
    UNSUPPORTED,
    NOT_FOUND,
    PROVIDER_OFFLINE,
    CONFLICT,
    SIZE_LIMIT,
    AMBIGUOUS,
    CANCELLED,
    INVALID_NAME,
    INVALID_DESTINATION,
    NO_HANDLER,
    BINARY,
    IO,
    FAILED,
}

internal data class SpaceFilesFailure(
    val problem: SpaceFilesProblem,
    /** Raw provider text for an explicitly opened details view; never the headline. */
    val detail: String? = null,
) {
    /** Retrying a pure IO/provider hiccup is meaningful; a revoked grant is not. */
    val retryable: Boolean
        get() = problem == SpaceFilesProblem.IO ||
            problem == SpaceFilesProblem.FAILED ||
            problem == SpaceFilesProblem.PROVIDER_OFFLINE

    /** True when stale rows must not stay on screen (access is gone). */
    val blocking: Boolean
        get() = problem == SpaceFilesProblem.GRANT_REVOKED ||
            problem == SpaceFilesProblem.GRANT_MISSING ||
            problem == SpaceFilesProblem.RE_PICK_REQUIRED ||
            problem == SpaceFilesProblem.READ_ONLY
}

internal fun SafFailure.toSpaceFilesFailure(detail: String? = null): SpaceFilesFailure =
    SpaceFilesFailure(
        problem = when (this) {
            is SafFailure.Revoked -> SpaceFilesProblem.GRANT_REVOKED
            is SafFailure.GrantMissing -> SpaceFilesProblem.GRANT_MISSING
            is SafFailure.RePickRequired -> SpaceFilesProblem.RE_PICK_REQUIRED
            is SafFailure.ProviderOffline -> SpaceFilesProblem.PROVIDER_OFFLINE
            is SafFailure.ReadOnly -> SpaceFilesProblem.READ_ONLY
            is SafFailure.Unsupported -> SpaceFilesProblem.UNSUPPORTED
            is SafFailure.Cancelled -> SpaceFilesProblem.CANCELLED
            is SafFailure.Conflict -> SpaceFilesProblem.CONFLICT
            is SafFailure.NotFound -> SpaceFilesProblem.NOT_FOUND
            is SafFailure.AmbiguousIdentity -> SpaceFilesProblem.AMBIGUOUS
            is SafFailure.SizeLimitExceeded -> SpaceFilesProblem.SIZE_LIMIT
            is SafFailure.Io -> SpaceFilesProblem.IO
            is SafFailure.Failed -> SpaceFilesProblem.FAILED
        },
        detail = detail,
    )

/** Receipt-backed notices. None of these is shown before a real provider answer. */
internal sealed interface SpaceFilesNotice {
    val operation: SpaceFilesOperation

    data class RootAdded(
        val name: String,
        /** The system offered only a session grant (or persistence was refused). */
        val sessionOnly: Boolean,
    ) : SpaceFilesNotice {
        override val operation get() = SpaceFilesOperation.ADD_ROOT
    }

    data class RootRemoved(val name: String) : SpaceFilesNotice {
        override val operation get() = SpaceFilesOperation.REMOVE_ROOT
    }

    data class PickCancelled(val reason: String?) : SpaceFilesNotice {
        override val operation get() = SpaceFilesOperation.ADD_ROOT
    }

    data class PickRejected(val failure: SpaceFilesFailure) : SpaceFilesNotice {
        override val operation get() = SpaceFilesOperation.ADD_ROOT
    }

    data class Completed(
        override val operation: SpaceFilesOperation,
        val name: String,
        val detail: String? = null,
        /** A verified copy exists, but the original was deliberately retained. */
        val sourceRetained: Boolean = false,
    ) : SpaceFilesNotice

    data class Failed(
        override val operation: SpaceFilesOperation,
        val failure: SpaceFilesFailure,
    ) : SpaceFilesNotice

    /** A paged scan lost its held cursor and had to restart from the first page. */
    data class PageReloaded(val folderName: String) : SpaceFilesNotice {
        override val operation get() = SpaceFilesOperation.LOAD
    }
}

/** Bounded in-app preview result (never an editing claim). */
internal sealed interface SpaceFilesPreview {
    val name: String
    val mimeType: String
    val bytes: Long?

    /** EXACT provider document this preview was read from. */
    val ref: SafDocumentRef
    val isVirtual: Boolean

    data class Text(
        override val name: String,
        override val mimeType: String,
        override val bytes: Long?,
        override val ref: SafDocumentRef,
        override val isVirtual: Boolean,
        val text: String,
    ) : SpaceFilesPreview

    data class Image(
        override val name: String,
        override val mimeType: String,
        override val bytes: Long,
        override val ref: SafDocumentRef,
        override val isVirtual: Boolean,
        val file: File,
    ) : SpaceFilesPreview

    data class Unavailable(
        override val name: String,
        override val mimeType: String,
        override val bytes: Long?,
        override val ref: SafDocumentRef,
        override val isVirtual: Boolean,
        val failure: SpaceFilesFailure,
    ) : SpaceFilesPreview
}

internal data class SpaceFilesUiState(
    val catalogLoaded: Boolean = false,
    val roots: List<SpaceRootUi> = emptyList(),
    val browse: SpaceRootBrowse? = null,
    val pick: SpaceRootPick? = null,
    val busy: SpaceFilesOperation? = null,
    val notice: SpaceFilesNotice? = null,
    val transfer: SpaceTransfer? = null,
    val preview: SpaceFilesPreview? = null,
    val previewLoading: Boolean = false,
    val openRequest: SpaceFilesOpenRequest? = null,
    /** Live + restored native-edit sessions (durable destination/reopen). */
    val editSessions: List<SpaceFilesEditSession> = emptyList(),
    /** Pending ACTION_EDIT launch the composition must perform + report. */
    val editLaunch: SpaceFilesEditLaunch? = null,
) {
    val idle: Boolean get() = busy == null
}

/** Persistence seam for saved root METADATA (never grants, never URIs' authority). */
internal interface SpaceFilesRootStore {
    fun read(): List<SpaceFilesRoot>
    fun write(roots: List<SpaceFilesRoot>)
}

/** In-memory store for previews/tests; the App uses SharedPreferences. */
internal class SpaceFilesInMemoryRootStore(
    initial: List<SpaceFilesRoot> = emptyList(),
) : SpaceFilesRootStore {
    private val lock = Any()
    private var roots: List<SpaceFilesRoot> = initial.toList()

    override fun read(): List<SpaceFilesRoot> = synchronized(lock) { roots.toList() }

    override fun write(roots: List<SpaceFilesRoot>) {
        synchronized(lock) { this.roots = roots.toList() }
    }
}

/** Maps one gateway child row to the page model without inventing anything. */
internal fun SafDocument.toSpaceFileEntry(): SpaceFileEntry = SpaceFileEntry(
    name = displayName,
    mimeType = mimeType,
    sizeBytes = (size as? com.floe.android.safgateway.SafSize.Known)?.bytes,
    lastModifiedMillis = lastModifiedMillis,
    isDirectory = mimeType == SafDocument.MIME_DIR,
    isVirtual = isVirtual,
    ref = ref,
    canWrite = capabilities.write,
    canRename = capabilities.rename,
    canDelete = capabilities.delete,
    canCopy = capabilities.copy,
    canMove = capabilities.move,
    canCreateChildren = capabilities.createChildren,
)
