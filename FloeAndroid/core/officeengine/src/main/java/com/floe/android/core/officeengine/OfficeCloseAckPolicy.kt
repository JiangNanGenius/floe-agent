// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pure, JVM-testable contract for the parent-owned close-intent
 * acknowledgement of the R1 read-only embedded Office viewer.
 *
 * Pinned native contract (release-source androidapp.cpp + the release-owner
 * device close log, Main 2026-10-26): the last-session BYE runs native
 * `closeDocument()`, which blocks on `coolwsdRunningMutex`; the thread
 * holding that mutex is the COOLWSD run loop itself, and the loop ends
 * inside `Util::forcedExit -> std::_exit(0)` (engine log "Forced Exit with
 * code: 0" followed by Zygote "Process <pid> exited cleanly (0)", before
 * the JNI call returns). The native exit therefore bypasses every Java
 * finally/settle/`deliverTerminal`/`Activity.setResult` path: a user close
 * that posts BYE can never deliver the Activity result from the viewer
 * process afterwards.
 *
 * Consequence implemented here (Main decision 2026-10-26):
 *  - the engine acknowledges the user's exact close-intent to the App
 *    (parent) process BEFORE posting the fatal BYE, over a narrow Binder
 *    capability carried only inside the non-exported viewer Activity's own
 *    launch Intent (no new manifest entry, service or permission);
 *  - the parent may suppress its generic open-failure ONLY for a matching,
 *    acknowledged current user close; it never infers `closedCleanly` and
 *    never deletes the retained staged snapshot on that uncertain path;
 *  - an unexpected process death without an owned close-intent stays a
 *    failure, exactly as before.
 */
object OfficeCloseAckPolicy {

    /** Narrow interface token; mismatched callers are rejected fail-closed. */
    const val DESCRIPTOR = "com.floe.android.core.officeengine.CloseAck"

    /** The only transaction this endpoint answers.
     *  Literal value of android.os.IBinder.FIRST_CALL_TRANSACTION, kept here
     *  so this file stays free of Android imports (JVM-testable). */
    const val TRANSACTION_ACK_CLOSE = 1

    /** Viewer launch Intent extras (capability + parent-minted opaque id). */
    const val EXTRA_CLOSE_ACK = "com.floe.android.office.CLOSE_ACK"
    const val EXTRA_VIEWER_INCARNATION = "com.floe.android.office.VIEWER_INCARNATION"

    /**
     * Only genuine user closes are acknowledged (Main decision: "acknowledge
     * only current userclose"). Internal teardown reasons (transport
     * failure, presentation replacement, reclamation) are never acknowledged
     * and their missing results stay failures.
     */
    val USER_CLOSE_REASONS: Set<String> = setOf("page-close", "user-back")

    /** Aligns with OfficeRequestPolicy.validateShape sessionToken bounds. */
    const val MAX_TOKEN_CHARS = 256

    /** One validated close-intent for one exact mount. */
    data class AckRequest(
        val sessionToken: String,
        val generation: Long,
        val viewerIncarnation: Long,
        val reason: String,
    )

    /**
     * Fail-closed shape validation of one acknowledgement payload. Returns
     * null (never throws) for blank/oversized tokens, control characters,
     * non-positive generations/incarnations, or any reason outside the
     * user-close allowlist.
     */
    fun validateShape(
        token: String?,
        generation: Long?,
        incarnation: Long?,
        reason: String?,
    ): AckRequest? = when {
        token.isNullOrEmpty() || token.length > MAX_TOKEN_CHARS ||
            token.any { it.code < 0x20 || it.code == 0x7f } -> null
        generation == null || generation < 1L -> null
        incarnation == null || incarnation < 1L -> null
        reason == null || reason !in USER_CLOSE_REASONS -> null
        else -> AckRequest(
            sessionToken = token,
            generation = generation,
            viewerIncarnation = incarnation,
            reason = reason,
        )
    }

    /** How the parent reads one viewer Activity result (decision table). */
    enum class Interpretation {
        /** Parent admission moved on: settle silently (pre-existing rule). */
        NOT_CURRENT,

        /** Exact result attesting failure == null (engine-delivered truth). */
        CLEAN_CLOSE,

        /** Exact SESSION_CANCELLED result (before-native cancel truth). */
        USER_CANCELLED,

        /** Missing result, or our own reclaim PROCESS_LOST, AFTER an exact
         * acknowledged user close: the close was requested; native exit
         * bypassed Java results. Honest uncertainty: no error report, the
         * staged snapshot is retained. Never implies closedCleanly. */
        OWNED_CLOSE_UNCERTAIN,

        /** Anything else, including unexpected death with no acknowledged
         * close: honest failure ("viewer" error), input retained. */
        REFUSED,
    }

    /**
     * Decision for `OfficePreviewController.onViewerResult`.
     *
     * Invariants (Main decision 2026-10-26):
     *  - `removeInput` is true ONLY for an exact result the engine itself
     *    attested `closedCleanly` — an acknowledgement never sets it;
     *  - a missing result is honest failure unless the close was
     *    acknowledged for this exact incarnation+token;
     *  - `PROCESS_LOST` after an acknowledged close (bounded dedicated-
     *    process watchdog reclaim, preserved timing) is uncertain-closed,
     *    not an open failure.
     */
    fun resolveViewerResult(
        ownerCurrent: Boolean,
        outcomePresent: Boolean,
        exactToken: Boolean,
        failureName: String?,
        closedCleanly: Boolean,
        ackedUserClose: Boolean,
    ): ViewerResolution {
        // Unchanged from the original contract: only an exact clean receipt
        // lets the parent remove an input already handed to the engine.
        val removeInput = outcomePresent && exactToken && closedCleanly
        return when {
            !ownerCurrent -> ViewerResolution(Interpretation.NOT_CURRENT, null, removeInput)
            outcomePresent && exactToken && failureName == null ->
                ViewerResolution(Interpretation.CLEAN_CLOSE, null, removeInput)
            outcomePresent && exactToken && failureName == "SESSION_CANCELLED" ->
                ViewerResolution(Interpretation.USER_CANCELLED, null, removeInput)
            ackedUserClose && (!outcomePresent || (exactToken && failureName == "PROCESS_LOST")) ->
                ViewerResolution(Interpretation.OWNED_CLOSE_UNCERTAIN, null, false)
            else -> ViewerResolution(Interpretation.REFUSED, "viewer", removeInput)
        }
    }

    /** Resolved classification plus the two effects the controller applies. */
    data class ViewerResolution(
        val interpretation: Interpretation,
        val errorKey: String?,
        val removeInput: Boolean,
    )
}
