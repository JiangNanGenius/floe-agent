// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.WorkspaceDocumentSurface

/**
 * Conversation artifact direct-preview lane (App side, source stage).
 *
 * job-264 closed the model file-link callback stub by routing Office files to
 * the owned Office viewer and everything else to the Workspace files
 * inspector browser. The user requirement is iOS-parity direct open: tapping
 * a conversation artifact link must open the SELECTED file in its existing
 * typed full-window surface (code workbench / PDF / image / media / CAD /
 * archive / honest typed cover) — never a folder browse and never a second
 * click. This lane carries exactly the two presentation values the host
 * publishes for the root composition:
 *
 *  - [ConversationArtifactPreviewRequest]: one explicit open. It carries ONLY
 *    the already-owned identity (task + workspace + relative path + typed
 *    surface + a monotonically increasing token). It grants no authority: the
 *    native workspace guard still re-validates containment (symlinks
 *    included) before any byte is staged, and every staged viewer re-checks
 *    the captured owner fence through staging AND display.
 *  - [ConversationArtifactOpenFailure]: one honest, dismissible failure note
 *    for a tap whose open could not start. The conversation feature surface
 *    drops the tap's Boolean result, so a silent `false` (or a swallowed
 *    exception) left the user with no feedback at all; this note is the
 *    App-owned truthful counterpart, localized by the shell from [kind].
 *
 * Both are one-shot slots: the most recent tap wins, a late callback of a
 * superseded tap can never publish over a newer one, and dismissal/navigation
 * clears the slot so a stale value can never re-open after its owner left.
 */

/** One explicit conversation-owned typed document open request. */
internal data class ConversationArtifactPreviewRequest(
    val taskID: String,
    val workspaceID: String,
    val relativePath: String,
    val surface: WorkspaceDocumentSurface,
    val token: Long,
    val nativeEpoch: Long,
    val hostGeneration: Long,
    val sessionEpoch: Long,
) {
    val fileName: String get() = relativePath.substringAfterLast('/')

    fun matchesOwner(epoch: Long?, generation: Long, session: Long?): Boolean =
        nativeEpoch == epoch && hostGeneration == generation && sessionEpoch == session

    init {
        require(nativeEpoch > 0) { "native epoch must be positive" }
        require(token > 0) { "token must be positive" }
    }
}

/** The user-presentable class of one artifact-open failure. */
internal enum class ConversationArtifactOpenFailureKind {
    /** The captured task/workspace/epoch/generation retired or the
     *  conversation has no bound workspace. */
    OWNER,

    /** The native workspace guard refused the path (containment/secret). */
    ACCESS,

    /** The file exceeds the bounded preview egress. */
    SIZE,

    /** The single owned viewer slot (Office) is held by another operation. */
    BUSY,

    /** Any other staging/transport refusal. */
    SOURCE,
}

/** One dismissible artifact-open failure (localized by the shell). */
internal data class ConversationArtifactOpenFailure(
    val kind: ConversationArtifactOpenFailureKind,
    val fileName: String,
)

/** Pure mapping from the existing typed refusal codes to the user-presentable
 *  failure class. Deliberately mirrors the Files pane's error vocabulary so
 *  one honest wording exists per refusal family; internal diagnostics stay
 *  out of the banner (details live in the typed preview/cover states). */
internal object ConversationArtifactOpenPolicy {
    fun failureFor(code: String?): ConversationArtifactOpenFailureKind = when (code) {
        "ownerChanged", "ownerUnavailable", "ownerStopping", "retired",
        "epochMismatch", "workspaceUnbound", "superseded", "cancelled",
        -> ConversationArtifactOpenFailureKind.OWNER
        "secretFile", "escapesRoot", "notAdmitted", "invalidTask",
        "invalidBinding", "invalidPath",
        -> ConversationArtifactOpenFailureKind.ACCESS
        "contentTooLarge", "bufferLimit", "tooLarge",
        -> ConversationArtifactOpenFailureKind.SIZE
        "officeBusy", "workspaceBusy", "operationPending", "editorSessionsSaturated",
        -> ConversationArtifactOpenFailureKind.BUSY
        else -> ConversationArtifactOpenFailureKind.SOURCE
    }
}
