// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pure, JVM-testable contract for the parent-owned approval-notice
 * capability of the embedded Office viewer (G05-R3 office-approval107,
 * 2026-10-28; device evidence: c16 calc-close-context-refusal).
 *
 * Why this exists: while an OWNED document is open, a captured Ask-first
 * approval of the OWNING conversation renders only inline in the chat
 * timeline of the App's main Activity — a surface the full-screen
 * :floe_office viewer Activity completely covers. The only previously
 * visible route back was "Close document", whose correct stale-context
 * retirement then refused the approval before mutation. The viewer therefore
 * gets ONE narrow read-only question: "does MY owning conversation currently
 * hold a captured pending approval?" A positive answer renders as a slim
 * banner whose single action brings the existing chat Activity back to the
 * front (FLAG_ACTIVITY_REORDER_TO_FRONT) WITHOUT closing this document; the
 * user reviews/approves/denies in the EXISTING conversation approval card
 * (the exact same resolve path, unchanged) and returns here with Back. This
 * capability grants nothing, approves nothing, cancels nothing and replays
 * nothing — it only answers the question.
 *
 * Trust model: identical to OfficeCloseAckPolicy — one synchronous Binder
 * endpoint carried ONLY inside the non-exported viewer Activity's own launch
 * Intent (same-UID caller, interface descriptor, fail-closed shape). The
 * parent additionally re-validates the exact current VIEWING operation
 * (opaque incarnation + session token + owner task id) on EVERY query, so a
 * close, settle or replacement answers "not pending" automatically.
 */
object OfficeApprovalNoticePolicy {

    /** Narrow interface token; mismatched callers are rejected fail-closed. */
    const val DESCRIPTOR = "com.floe.android.core.officeengine.ApprovalNotice"

    /** The only transaction this endpoint answers.
     *  Literal value of android.os.IBinder.FIRST_CALL_TRANSACTION, kept here
     *  so this file stays free of Android imports (JVM-testable). */
    const val TRANSACTION_QUERY_PENDING = 1

    /** Viewer launch Intent extras (capability + App-owned review target).
     *  The ComponentName is App-minted (its own MainActivity); the module
     *  never invents a navigation target. */
    const val EXTRA_APPROVAL_NOTICE = "com.floe.android.office.APPROVAL_NOTICE"
    const val EXTRA_REVIEW_COMPONENT = "com.floe.android.office.REVIEW_COMPONENT"

    /** Aligns with OfficeCloseAckPolicy / OfficeRequestShape token bounds. */
    const val MAX_TOKEN_CHARS = 256

    /** Owner task ids are durable host identities (conversation/task UUIDs). */
    const val MAX_OWNER_CHARS = 128

    /** One validated notice query for one exact mount. */
    data class Query(
        val sessionToken: String,
        val viewerIncarnation: Long,
        val ownerTaskId: String,
    )

    /**
     * Fail-closed shape validation of one query payload. Returns null (never
     * throws) for blank/oversized tokens or owner ids, control characters,
     * or a non-positive incarnation.
     */
    fun validateShape(
        token: String?,
        incarnation: Long?,
        ownerTaskId: String?,
    ): Query? = when {
        token.isNullOrEmpty() || token.length > MAX_TOKEN_CHARS ||
            token.any { it.code < 0x20 || it.code == 0x7f } -> null
        incarnation == null || incarnation < 1L -> null
        ownerTaskId.isNullOrEmpty() || ownerTaskId.length > MAX_OWNER_CHARS ||
            ownerTaskId.any { it.code < 0x20 || it.code == 0x7f } -> null
        else -> Query(sessionToken = token, viewerIncarnation = incarnation, ownerTaskId = ownerTaskId)
    }
}
