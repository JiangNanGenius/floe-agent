// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia

import com.floe.android.feature.workbench.CreativeProjectContext

/**
 * Native-issued, stable recovery scope for one accepted project/storage/origin
 * owner. This is deliberately separate from the frozen
 * `WorkbenchMediaPlatform` port and from `WorkbenchEpochOwner`:
 *
 *  * `WorkbenchEpochOwner.mediaRootPath(epoch)` is the accepted base root; an
 *    export journal lives under the PROJECT root, which may be a child of that
 *    base. Using the base root to find a journal after process death is the
 *    defect this port exists to remove.
 *  * `CreativeProjectContext.sessionToken` identifies an editor session, not a
 *    durable project owner. A new authorized editor session must be able to
 *    recover the same project's journal, while a foreign project/storage/origin
 *    owner must not.
 *
 * The implementation MUST validate the session token, project, storage layer
 * and origin against native truth, and MUST return the exact existing project
 * media root (never a caller path, first project or convenience directory).
 * `ownerKey` is an opaque native identity for the accepted project/storage/
 * origin generation: it must be stable across editor sessions for the same
 * durable owner, and must change when the native project identity is recreated
 * or moved to a different owner. It is not a credential.
 */
data class RecoveryOwnerGrant(
    /** Current accepted native epoch for this context. Must be live/current. */
    val epoch: Long,
    /** Exact native-issued project media root, never a caller-supplied path. */
    val mediaRootPath: String,
    /** Accepted native project id; must equal the request context. */
    val projectID: String,
    /** Canonical native storage scope (for example app-owned/workspace:<id>). */
    val storageKey: String,
    /** Stable native owner identity for this project/storage/origin generation. */
    val ownerKey: String,
    /** Canonical native origin scope, or null when the request has no origin. */
    val originKey: String? = null,
)

sealed interface RecoveryRootDecision {
    data class Accepted(val grant: RecoveryOwnerGrant) : RecoveryRootDecision

    data class Refused(
        val code: String,
        val reason: String,
        val retryable: Boolean = false,
    ) : RecoveryRootDecision
}

/**
 * Required native recovery authority. There is intentionally no default,
 * no-op or path-based implementation: the App adapter must supply a real native
 * proof, and a refusal is surfaced as the typed R2 error code.
 *
 * The call is a bounded native mailbox/store lookup, not a creative-lane
 * blocking round trip. It is made on:
 *  * export acceptance (before the journal is written and before snapshot
 *    bytes are read);
 *  * every active job status/cancel/observe lookup (so a new editor session is
 *    reauthorized and the job's accepted epoch/root is re-proved);
 *  * every recovery status/observe lookup.
 */
interface WorkbenchRecoveryAuthority {
    suspend fun resolveRecoveryRoot(context: CreativeProjectContext): RecoveryRootDecision
}

/** One owned lifecycle activity that reads project/source/output bytes. */
enum class MediaLifecycleKind(val wire: String) {
    PLAYBACK("playback"),
    EXPORT("export"),
    PREVIEW("preview"),
}

/**
 * Pin request for actual Media3/codec/file IO. The platform acquires the pin
 * BEFORE handing the immutable snapshot to a player/encoder/renderer, and
 * releases it only after the actual worker/player has stopped. A pin is not
 * the render-ticket claim protocol; tickets keep their existing native
 * claim-token pin and this port is not called for them.
 */
data class MediaLifecyclePinRequest(
    val context: CreativeProjectContext,
    val kind: MediaLifecycleKind,
    /** Accepted native epoch that owns the pinned root. */
    val epoch: Long,
    /** Canonical project media root already accepted by the lease authority. */
    val mediaRootPath: String,
    /** Export/preview attempt id, or the playback binding attempt id. */
    val attemptID: String,
    /** Export job id when the pin belongs to a service-owned export. */
    val jobID: String? = null,
)

/** Native-issued pin acknowledgement. Exactly one successful release is allowed. */
data class MediaLifecyclePin(
    val pinToken: String,
    val epoch: Long,
    val mediaRootPath: String,
    val projectID: String,
    val kind: MediaLifecycleKind,
    val attemptID: String,
)

sealed interface MediaLifecyclePinDecision {
    data class Pinned(val pin: MediaLifecyclePin) : MediaLifecyclePinDecision

    data class Refused(
        val code: String,
        val reason: String,
        val retryable: Boolean = false,
    ) : MediaLifecyclePinDecision
}

/**
 * Required native lifetime pin/release authority for direct playback, export
 * and image-preview IO. `pin` must validate the live epoch, accepted root,
 * project and session, then increment the native lease/refcount. `release`
 * must be idempotent and returns true only when the native pin is actually
 * gone; false means the ownership reference is retained and the session must
 * report an outstanding/unknown pin instead of telling Root it may unbind.
 */
interface WorkbenchMediaLifecycleAuthority {
    suspend fun pin(request: MediaLifecyclePinRequest): MediaLifecyclePinDecision

    suspend fun release(pin: MediaLifecyclePin): Boolean
}
