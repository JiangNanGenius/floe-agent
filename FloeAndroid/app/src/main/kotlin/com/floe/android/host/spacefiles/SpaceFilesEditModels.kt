// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.SafDocumentRef
import java.io.File

/**
 * Space → Files native editing: one authorized provider document at a time is
 * imported into an app-private writable working copy, handed to a real Android
 * editor with a per-URI write grant, watched, and — only when the working
 * bytes actually changed — written back through the SAME verified two-phase
 * recoverable save the workspace Office lane uses (`SafWorkingCopyService`).
 *
 * Truth rules carried from core/safgateway and the workspace external edit:
 *  - the provider document identity (tree + document id + URI) captured at
 *    import time is the ONLY save-back target; nothing is ever rebuilt from a
 *    display name and no arbitrary host path/URI is accepted;
 *  - the ORIGINAL provider bytes are preserved into caller-owned recovery
 *    storage BEFORE any destructive write, and both versions stay recoverable
 *    on conflict (the recovery file holds the provider version, the working
 *    copy holds the edited version);
 *  - a launched editor is never a saved receipt: only the provider read-back
 *    hash may report committed bytes;
 *  - an unchanged working copy produces no save claim and no provider write;
 *  - grants are per-document session facts re-probed before every IO hop —
 *    never a directory or blanket provider permission.
 */

/** Lifecycle of one editable working-copy session. */
internal enum class SpaceFilesEditPhase {
    /** Imported + handed to an editor (or restored after restart). Nothing owed. */
    EDITING,

    /** The working bytes differ; the verified save-back ladder is running. */
    SAVING,

    /** Verified bytes landed (same source document or an explicit sibling). */
    SAVED,

    /** The provider source drifted before/under the write; both versions kept. */
    CONFLICT,

    /** A write was attempted/uncertain or refused; recovery stays registered. */
    RECOVERABLE_FAILURE,

    /** Closed by the user (or no editor existed). Copies remain on disk. */
    FINISHED,
}

/**
 * One durable edit session. [workingFile] lives under the controller-owned
 * edits root (never a provider path); [target] is the exact provider document
 * this session may write back to.
 */
internal data class SpaceFilesEditSession(
    val id: String,
    val target: SafDocumentRef,
    val name: String,
    val mimeType: String,
    /** Verified SHA-256 the save-back compares against: the provider bytes at
     *  import, updated to the last verified save so continued editing rounds
     *  compare against the provider state actually observed. */
    val baselineSha256: String,
    val baselineBytes: Long,
    val workingFile: File,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val phase: SpaceFilesEditPhase,
    /** Closed-vocabulary machine code (never user-facing copy). */
    val errorCode: String? = null,
    /** Display name of the explicit sibling when the save landed as a new file. */
    val savedSiblingName: String? = null,
    /** Recovery receipt registered while a destructive save-back was attempted. */
    val recoveryReceiptId: String? = null,
)

/** What the composition actually observed when it started ACTION_EDIT. */
internal enum class SpaceFilesEditLaunchResult { LAUNCHED, NO_HANDLER, FAILED }

/** A resolved edit launch; the composition mints the FileProvider URI + intent. */
internal data class SpaceFilesEditLaunch(
    val id: Long,
    val sessionId: String,
    val file: File,
    val mimeType: String,
    val name: String,
)

/** Pure gates for offering/trusting a native edit session. */
internal object SpaceFilesEditPolicy {

    /** Working-copy import + recovery preservation stay bounded. */
    const val EDIT_BYTE_LIMIT = 256L * 1024 * 1024

    /** One editor launch at a time mirrors the workspace external edit. */
    const val MAX_ACTIVE_SESSIONS = 8

    /**
     * A row is editable only when the provider itself advertises write on the
     * exact document, the row is not virtual (no raw byte representation) and
     * the declared size (when known) fits the bounded working-copy budget.
     */
    fun supportsEdit(
        isDirectory: Boolean,
        isVirtual: Boolean,
        canWrite: Boolean,
        sizeBytes: Long?,
    ): Boolean {
        if (isDirectory || isVirtual || !canWrite) return false
        if (sizeBytes != null && sizeBytes > EDIT_BYTE_LIMIT) return false
        return true
    }

    /** Working-copy state vs. the import baseline. */
    enum class WorkingState { UNCHANGED, CHANGED }

    fun workingState(workingSha256: String, baselineSha256: String): WorkingState =
        if (workingSha256 == baselineSha256) WorkingState.UNCHANGED else WorkingState.CHANGED
}
