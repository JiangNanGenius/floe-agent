// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * G05-R2 typed save/export contract (public API for the App host stage).
 *
 * Honesty rules baked into these types (Main decisions 2026-10-26):
 *  - A native receipt is NEVER an App commit. `FLUSHED`/`OUTPUT_READY`
 *    attest only that the pinned engine wrote bytes to a MODULE-OWNED file
 *    (the mutable working copy or a private staged output) and that the
 *    module re-read and digested those bytes. The authoritative
 *    Workspace/SAF commit (APP_ORIGINAL_COMMITTED / SaveCopy acceptance)
 *    happens later in the App's existing file-transaction services; this
 *    module never writes a user/provider original and never claims it did.
 *  - JNI saveAs/postUnoCommand returning void is never success by itself;
 *    success requires the real producer callbacks (unocommandresult for
 *    `.uno:Save`, SaveResult.hpp semantics) plus post-write file
 *    verification. No sleep/stable-size polling is ever a success proof.
 *  - Missing acknowledgement before mount end, or an ack whose bytes cannot
 *    be re-verified, is `UNKNOWN`/`FAILED` — conservative, with the working
 *    copy and every previously confirmed output retained.
 */

/** What the host asked the engine to do. */
enum class OfficeSaveOperation {
    /**
     * In-place save of the loaded document, which in an EDIT session is the
     * separately owned MUTABLE WORKING COPY staged by the App (never an R1
     * immutable snapshot, never a provider original). Uses the real
     * `save dontTerminateEdit=1 ...` protocol message; proof is the kit's
     * `.uno:Save` unocommandresult plus a digest re-read of the working copy.
     */
    WORKING_COPY_FLUSH,

    /**
     * Save-a-copy/export through the pinned synchronous JNI
     * `saveAs(fileUri, format, options)` into a fresh module-owned private
     * output file, then bounded verification (regular file, 1..256 MiB,
     * whole-file digest read, format magic). The receipt hands the App the
     * exact path/sha/bytes; the App owns any further destination grant and
     * commit (Main's SaveCopy ladder). Options are never "TakeOwnership":
     * the loaded document identity does not move.
     */
    STAGED_EXPORT,
}

/** Terminal (or interim) state of one save operation. */
enum class OfficeSaveState {
    /** Accepted and queued on the serialized control lane; nothing written yet. */
    SUBMITTED,

    /** WORKING_COPY_FLUSH: native ack success==true AND the working copy re-read/digested. */
    FLUSHED,

    /** WORKING_COPY_FLUSH: native answered "unmodified" — nothing was written; not a failure. */
    UNMODIFIED,

    /** STAGED_EXPORT: JNI saveAs returned AND the output file passed full verification. */
    OUTPUT_READY,

    /** The producer reported failure, or post-write verification failed. Nothing new is claimed. */
    FAILED,

    /** Cancelled before any native/IO work started (only honest pre-dispatch cancel). */
    CANCELLED,

    /**
     * Dispatched but no acknowledgement arrived before the bounded window or
     * before mount end/process loss. Outcome genuinely unknown: the App must
     * NOT treat it as committed nor as certainly-not-written; the working
     * copy and prior outputs are retained for recovery.
     */
    UNKNOWN,

    /** Refused without touching the engine (busy, wrong state, bad shape, session ending). */
    REJECTED,
}

/** Why an operation was rejected/failed (diagnostic; user copy lives in the App/UI layer). */
enum class OfficeSaveFailureCode {
    /** Another WORKING_COPY_FLUSH for this mount is still awaiting its native ack. */
    FLUSH_ALREADY_IN_FLIGHT,

    /**
     * A previous flush for this mount lost its ack (timeout/collision), so a
     * stale `.uno:Save` callback could still arrive; new flushes are refused
     * for this mount rather than risk attributing a late old callback to a
     * new operation. STAGED_EXPORT is unaffected (synchronous artifact proof).
     */
    STALE_ACK_QUARANTINE,

    /** The mount is not in an editable-ready state (preview, still opening, closing, degraded). */
    NOT_EDITABLE,

    /** Session token/generation did not match the exact live mount. */
    SESSION_MISMATCH,

    /** The mount is closing/closed or the process is being reclaimed. */
    SESSION_ENDING,

    /** Shape validation failed (opId/format/name/options out of bounds). */
    INVALID_REQUEST,

    /** The producer answered success==false (result string carried in message). */
    NATIVE_REJECTED,

    /** A native `error: cmd=save|storage kind=savefailed` frame arrived for the pending flush. */
    NATIVE_ERROR,

    /** An autosave-stamped ack collided with the pending host flush; attribution is impossible. */
    AUTOSAVE_ACK_COLLISION,

    /** Another STAGED_EXPORT is already running on the serialized control lane. */
    EXPORT_ALREADY_IN_FLIGHT,

    /** Native acked success but the working copy could not be re-read/digested. */
    ACK_WITHOUT_VERIFIABLE_BYTES,

    /** Export output missing or not a regular file after JNI returned. */
    OUTPUT_MISSING,

    /** Export output empty (0 bytes) after JNI returned. */
    OUTPUT_EMPTY,

    /** Export output exceeded the 256 MiB module cap. */
    OUTPUT_TOO_LARGE,

    /** Export output magic bytes did not match the requested format family. */
    OUTPUT_TYPE_MISMATCH,

    /** Export output could not be fully read for digesting. */
    OUTPUT_UNREADABLE,

    /** No ack within the bounded window (see OfficeSaveState.UNKNOWN). */
    TIMEOUT_WITHOUT_ACK,

    /** No ack before the mount ended / process was lost (see OfficeSaveState.UNKNOWN). */
    MOUNT_ENDED_WITHOUT_ACK,

    /** Cancel honoured before dispatch. */
    CANCELLED_BEFORE_DISPATCH,

    /** The App host did not supply a save-target picker Intent (handoff unavailable). */
    HOST_TARGET_UNAVAILABLE,

    /** The user cancelled the system save-target picker. */
    PICKER_CANCELLED,

    /** Module-internal fault (executor rejection, IO on staging directory, ...). */
    INTERNAL,
}

/**
 * One typed save/export result, keyed to the exact operation, session,
 * mount generation and (for exports) format. Immutable once issued; the
 * engine issues exactly one terminal receipt per accepted operation plus
 * the initial SUBMITTED acknowledgement.
 *
 * Field honesty:
 *  - [expectedBaseSha256] is the staged working-copy digest the engine
 *    verified at OPEN time — the base an App CAS/commit can compare against.
 *  - [workingCopySha256]/[workingCopyBytes] are re-read AFTER a flush ack
 *    (FLUSHED/UNMODIFIED), never cached pre-save values.
 *  - [outputDocumentPath]/[outputSha256]/[outputBytes] exist only for
 *    OUTPUT_READY and point at a module-owned private file inside the app
 *    data area that the App process can read directly (same UID).
 *  - [attestation] names the exact proof used, for logs/handoffs, e.g.
 *    "uno-ack+working-copy-digest" or "jni-saveas-sync+output-verified".
 */
data class OfficeSaveReceipt(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val operation: OfficeSaveOperation,
    val state: OfficeSaveState,
    val format: String?,
    val suggestedName: String?,
    val expectedBaseSha256: String?,
    val workingCopySha256: String?,
    val workingCopyBytes: Long,
    val outputDocumentPath: String?,
    val outputSha256: String?,
    val outputBytes: Long,
    val failure: OfficeSaveFailureCode?,
    val message: String?,
    val cancelRequested: Boolean,
    val attestation: String,
    val submittedAtElapsedMs: Long,
    val completedAtElapsedMs: Long,
) {
    /**
     * Bounded flat descriptor for Activity-result extras (the App reads it
     * back without any live engine binding). Pipe-separated, fixed field
     * order; every field is charset-validated at ingress so '|' cannot
     * appear inside one. Empty optionals serialize as '-'.
     */
    fun descriptorLine(): String = listOf(
        opId,
        operation.name,
        state.name,
        format ?: "-",
        outputDocumentPath ?: "-",
        outputSha256 ?: "-",
        outputBytes.toString(),
        workingCopySha256 ?: "-",
        workingCopyBytes.toString(),
        failure?.name ?: "-",
        completedAtElapsedMs.toString(),
    ).joinToString("|")

    companion object {
        /** Parses one [descriptorLine]; null when the shape is wrong (fail-closed). */
        fun fromDescriptorLine(line: String): OfficeSaveReceipt? {
            val f = line.split('|')
            if (f.size != 11) return null
            val operation = runCatching { OfficeSaveOperation.valueOf(f[1]) }.getOrNull() ?: return null
            val state = runCatching { OfficeSaveState.valueOf(f[2]) }.getOrNull() ?: return null
            val failure = f[9].takeIf { it != "-" }?.let {
                runCatching { OfficeSaveFailureCode.valueOf(it) }.getOrNull()
            }
            return OfficeSaveReceipt(
                opId = f[0],
                sessionToken = "",
                generation = 0L,
                operation = operation,
                state = state,
                format = f[3].takeIf { it != "-" },
                suggestedName = null,
                expectedBaseSha256 = null,
                workingCopySha256 = f[7].takeIf { it != "-" },
                workingCopyBytes = f[8].toLongOrNull() ?: return null,
                outputDocumentPath = f[4].takeIf { it != "-" },
                outputSha256 = f[5].takeIf { it != "-" },
                outputBytes = f[6].toLongOrNull() ?: return null,
                failure = failure,
                message = null,
                cancelRequested = false,
                attestation = "descriptor",
                submittedAtElapsedMs = 0L,
                completedAtElapsedMs = f[10].toLongOrNull() ?: return null,
            )
        }
    }
}

/**
 * One host-requested save/export operation. Construct through
 * [OfficeSaveRequest.of] so the pure shape rules run at the call site;
 * cross-process submission re-validates on the engine side (fail-closed).
 */
data class OfficeSaveRequest(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val operation: OfficeSaveOperation,
    /** STAGED_EXPORT only: pinned producer format token (see [OfficeRequestPolicy.EXPORT_FORMATS]). */
    val format: String?,
    /** STAGED_EXPORT only: inert LOKit filter options passthrough (never "TakeOwnership"). */
    val options: String?,
    /** Inert label for the host save-target handoff (never joined into paths). */
    val suggestedName: String?,
    /**
     * WORKING_COPY_FLUSH only. false (default) forces a real write
     * (`dontSaveIfUnmodified=0`) so an explicit user save deterministically
     * produces FLUSHED (or an honest failure); true mirrors the official
     * autosave hint and may answer UNMODIFIED.
     */
    val saveIfUnmodified: Boolean,
) {
    companion object {
        const val MAX_OP_ID_CHARS = 64
        const val MAX_OPTIONS_CHARS = 1024

        /** Validating factory; see [OfficeRequestPolicy.validateSaveRequestShape]. */
        fun of(
            opId: String,
            sessionToken: String,
            generation: Long,
            operation: OfficeSaveOperation,
            format: String? = null,
            options: String? = null,
            suggestedName: String? = null,
            saveIfUnmodified: Boolean = false,
        ): Result<OfficeSaveRequest> {
            OfficeRequestPolicy.validateSaveRequestShape(
                opId, sessionToken, generation, operation, format, options, suggestedName,
            )?.let { return Result.failure(it) }
            return Result.success(
                OfficeSaveRequest(
                    opId = opId,
                    sessionToken = sessionToken,
                    generation = generation,
                    operation = operation,
                    format = format?.lowercase(java.util.Locale.ROOT),
                    options = options,
                    suggestedName = suggestedName,
                    saveIfUnmodified = saveIfUnmodified,
                ),
            )
        }
    }
}

/**
 * Live editing/save projection for one exact mount, delivered through
 * [OfficeEngineService.OfficeEngineListener.onEditState] and readable
 * cross-process via [OfficeEngineCommands.readState]. All fields are
 * observed native/page facts, never inferred readiness:
 *  - [documentModified] mirrors the kit's `statechanged:` for
 *    `.uno:ModifiedStatus` (null until the first real frame arrives);
 *  - [undoState]/[redoState] carry the RAW `statechanged:` state strings for
 *    `.uno:Undo`/`.uno:Redo` (chrome information; [commandEnabled] is a
 *    best-effort reading, never a capability proof);
 *  - [editPermissionEstablished] is true only after the real native
 *    permission witnesses for this mount completed (see OfficeEngineService).
 */
data class OfficeEditState(
    val sessionToken: String,
    val generation: Long,
    val stateName: String,
    val editRequested: Boolean,
    val pageEditMode: Boolean,
    val editPermissionEstablished: Boolean,
    val documentModified: Boolean?,
    val undoState: String?,
    val redoState: String?,
) {
    companion object {
        /** Best-effort chrome reading of a raw `statechanged:` state string. */
        fun commandEnabled(rawState: String?): Boolean =
            rawState == "true" || rawState == "enabled" || rawState == "checked"
    }
}

/**
 * App→module settlement of one Save-Copy handoff (Main integration decision
 * 2026-10-26). The module's OUTPUT_READY receipt is a PRIVATE staged
 * artifact, and a picker-result acceptance means only "accepted for
 * processing" — the honest terminal outcome of a Save Copy exists only after
 * the App's real provider write + readback, and it flows back through this
 * narrow fenced seam so the foreground viewer can display the truth:
 *  - COPY_SAVED: the App committed and read back the copy at its destination;
 *  - COPY_FAILED: the App's transaction failed (working copy + staged output
 *    remain retained for retry);
 *  - COPY_CANCELLED: the App-side flow was cancelled after acceptance.
 * The module never derives these verdicts itself and never treats its own
 * receipts or a picker acceptance as a save completion.
 */
enum class OfficeHostSaveVerdict { COPY_SAVED, COPY_FAILED, COPY_CANCELLED }

data class OfficeHostSaveSettlement(
    val opId: String,
    val sessionToken: String,
    val generation: Long,
    val verdict: OfficeHostSaveVerdict,
    /** Inert diagnostic text from the App transaction (bounded). */
    val message: String?,
    val settledAtElapsedMs: Long,
)
