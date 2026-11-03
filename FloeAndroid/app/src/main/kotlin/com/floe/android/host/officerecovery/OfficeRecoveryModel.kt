// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officerecovery

import com.floe.android.core.officeengine.OfficeSaveReceipt
import com.floe.android.core.officeengine.OfficeSaveState
import com.floe.android.core.officeengine.OfficeSaveOperation
import com.floe.android.safgateway.PickRequestSpec

/**
 * Durable, bounded recoverability ledger for App-owned Office EDIT working
 * copies and module-verified STAGED_EXPORT outputs (C08 OFC-SAVE-REOPEN).
 *
 * WHAT THIS IS: a private record of the bytes the App already owns after a
 * provider/workspace/run-output stage, of the module's real OUTPUT_READY
 * verification, and of the ONE SAF save transaction the App attempted for
 * them. It is deliberately NOT an authority: no field here opens a file,
 * grants a URI, claims an original, or proves a save. Every action that
 * reads/writes bytes re-validates the live path against the App-owned roots,
 * re-hashes the actual file and (for a destination) re-checks the live
 * platform grant.
 *
 * WHAT THIS IS NOT: a mirror of the engine's session state. The engine's
 * private working copy is the file handed to it; a module verified output is
 * a separate staged artifact. A working copy alone is NEVER a completed user
 * save.
 */

/** Journal schema. A future incompatible shape bumps this and fails closed. */
internal const val OFFICE_RECOVERY_SCHEMA = 1

/** Where the recoverable bytes came from. No enum variant is authority. */
internal enum class OfficeRecoveryRoute { PROVIDER, WORKSPACE, RUN_OUTPUT }

/**
 * Honest operation state of ONE recoverable candidate.
 *
 *  - EDITING: the user had an editable copy open; no module-verified output
 *    is known yet. Only the working copy is recoverable.
 *  - EXPORT_READY: a module OUTPUT_READY (magic/length/SHA verified) exists.
 *    Saving is still a user action.
 *  - TRANSFERRING: a destination was accepted and the App began the write.
 *    This is persisted BEFORE the provider is touched. Process loss here is
 *    UNCERTAIN on the next start — never silently retried.
 *  - UNCERTAIN: a destination may contain a partial or complete copy that
 *    has not been verified. Nothing is retried automatically.
 *  - SAVED: the exact destination bytes were read back and matched.
 *  - CLOSED_UNSAVED: the viewer closed with the kit reporting modified bytes
 *    and no verified save; the working copy remains recoverable.
 *  - CLOSED_CLEAN: the viewer closed without a reported modification and
 *    without a verified output. Retained for bounded retention only; it is
 *    not surfaced as an interrupted save.
 *  - DISCARDED: the user explicitly discarded the owned retained artifacts.
 */
internal enum class OfficeRecoveryPhase {
    EDITING,
    EXPORT_READY,
    TRANSFERRING,
    UNCERTAIN,
    SAVED,
    CLOSED_UNSAVED,
    CLOSED_CLEAN,
    DISCARDED,
}

/** Actual on-disk state of one referenced artifact, measured now. */
internal enum class OfficeRecoveryFileState { AVAILABLE, MISSING, CORRUPT, UNTRUSTED }

/** Result of the explicit "is the original still the same?" probe. */
internal enum class OfficeRecoveryOriginalState { UNCHANGED, CHANGED, UNAVAILABLE, NOT_APPLICABLE }

/**
 * One durable recovery record. All paths are App-owned canonical candidates;
 * they are re-validated before any read/delete. [sourceSha256]/[sourceBytes]
 * describe the immutable input snapshot (which may already have been
 * removed); they are fingerprints, not a claim that the original is
 * unchanged.
 */
internal data class OfficeRecoveryCandidate(
    val id: String,
    val createdAtMillis: Long,
    val updatedAtMillis: Long,
    val phase: OfficeRecoveryPhase,
    val route: OfficeRecoveryRoute,
    val displayName: String,
    val format: String,
    val ownerTaskId: String? = null,
    val workspaceId: String? = null,
    val nativeEpoch: String? = null,
    val hostGeneration: String? = null,
    val sourceLogicalPath: String? = null,
    val sourceId: String? = null,
    val sourceRevision: String? = null,
    /** Provider original identity, used ONLY for alias refusal/live probing. */
    val originalUri: String? = null,
    val originalDocumentId: String? = null,
    val sourceSha256: String,
    val sourceBytes: Long,
    val workingCopyPath: String,
    val workingCopyBaseSha256: String,
    val workingCopyBaseBytes: Long,
    /** Working-copy base when the CURRENT verified output was produced. */
    val outputWorkingCopyBaseSha256: String? = null,
    /** Working-copy base certified by the last VERIFIED destination save. */
    val savedWorkingCopySha256: String? = null,
    val outputPath: String? = null,
    val outputSha256: String? = null,
    val outputBytes: Long = 0L,
    val outputFormat: String? = null,
    val outputOpId: String? = null,
    val outputNativeGeneration: Long = 0L,
    /** Exact destination the App was allowed to write in the last attempt. */
    val destinationUri: String? = null,
    /** True only after a full destination read-back equality. */
    val destinationVerified: Boolean = false,
    val destinationSha256: String? = null,
    val destinationBytes: Long = 0L,
    val attemptCount: Int = 0,
    val lastErrorCode: String? = null,
    val dirtyAtClose: Boolean? = null,
    /** Session token of the module mount this candidate belongs to (never authority). */
    val originSessionToken: String? = null,
) {
    val hasVerifiedOutput: Boolean
        get() = outputPath != null && outputSha256 != null && outputBytes in 1..MAX_OFFICE_RECOVERY_BYTES

    val hasWorkingCopy: Boolean get() = workingCopyPath.isNotBlank()

    /** Fields the UI may show; no path/URI leaks into ordinary copy. */
    fun materialLimitations(): List<OfficeRecoveryLimitation> {
        val items = ArrayList<OfficeRecoveryLimitation>(4)
        items += OfficeRecoveryLimitation.ONLY_DISK_WRITTEN_BYTES
        if (!hasVerifiedOutput) items += OfficeRecoveryLimitation.WORKING_COPY_ONLY
        if (phase == OfficeRecoveryPhase.UNCERTAIN || phase == OfficeRecoveryPhase.TRANSFERRING) {
            items += OfficeRecoveryLimitation.DESTINATION_UNCERTAIN
        }
        items += OfficeRecoveryLimitation.NEVER_OVERWRITES_ORIGINAL
        return items
    }
}

/** Stable limitation keys; localized by the UI, never rendered as raw paths. */
internal enum class OfficeRecoveryLimitation {
    ONLY_DISK_WRITTEN_BYTES,
    WORKING_COPY_ONLY,
    DESTINATION_UNCERTAIN,
    NEVER_OVERWRITES_ORIGINAL,
    ORIGINAL_CHANGED,
    ORIGINAL_UNAVAILABLE,
    UNSAVED_AFTER_SAVE,
    MISSING_OR_CORRUPT,
}

/** Exact verified source handed to the Save-Copy lane for a recovery export. */
internal data class OfficeRecoveryVerifiedSource(
    val path: String,
    val sha256: String,
    val bytes: Long,
    val format: String,
)

/** Host half of a recovery export: the picker request is pure data. */
internal sealed class OfficeRecoveryPrepareOutcome {
    data class Ready(val requestId: String, val spec: PickRequestSpec) : OfficeRecoveryPrepareOutcome()
    data class Refused(val code: String) : OfficeRecoveryPrepareOutcome()
}

/** Terminal outcome of a recovery export transaction (App-side, typed). */
internal sealed class OfficeRecoveryExportOutcome {
    abstract val requestId: String

    data class Saved(
        override val requestId: String,
        val destinationUri: String,
        val sha256: String,
        val bytes: Long,
    ) : OfficeRecoveryExportOutcome()

    data class Uncertain(
        override val requestId: String,
        val destinationUri: String?,
        val code: String,
    ) : OfficeRecoveryExportOutcome()

    data class Failed(
        override val requestId: String,
        val code: String,
    ) : OfficeRecoveryExportOutcome()

    data class Cancelled(
        override val requestId: String,
        val code: String,
    ) : OfficeRecoveryExportOutcome()

    /** A late/foreign callback that cannot name the prepared request. */
    data class Stale(
        override val requestId: String,
        val reason: String,
    ) : OfficeRecoveryExportOutcome()
}

/** Why the recovery effect is launching a system picker. */
internal enum class OfficeRecoveryLaunchPurpose { EXPORT, REAUTHORIZE }

/** Result of re-checking an uncertain destination under a live grant. */
internal sealed class OfficeRecoveryDestinationCheck {
    data class Verified(val sha256: String, val bytes: Long) : OfficeRecoveryDestinationCheck()
    data class Differs(val observedBytes: Long?, val observedSha256: String?, val reason: String) :
        OfficeRecoveryDestinationCheck()
    data class GrantRequired(val reason: String) : OfficeRecoveryDestinationCheck()
    data class Unavailable(val reason: String) : OfficeRecoveryDestinationCheck()
}

/** App-owned handler for recovery export transactions (implemented by OfficeSaveCopyHost). */
internal interface OfficeRecoveryExportPort {
    fun prepare(candidate: OfficeRecoveryCandidate, source: OfficeRecoveryVerifiedSource): OfficeRecoveryPrepareOutcome
    fun deliver(requestId: String, uriString: String?, resultFlags: Int, callback: (OfficeRecoveryExportOutcome) -> Unit): Boolean
    fun cancel(requestId: String)
    fun hasActiveFor(candidateId: String): Boolean
    fun isSessionBusy(sessionToken: String): Boolean
    fun checkDestination(uriString: String, expectedSha256: String, expectedBytes: Long): OfficeRecoveryDestinationCheck
    /** Prepare an OPEN_DOCUMENT re-authorisation for the EXACT uncertain destination. */
    fun prepareDestinationReauthorization(candidate: OfficeRecoveryCandidate): OfficeRecoveryPrepareOutcome
    /** Accept the actual re-pick and verify the SAME destination identity/bytes. */
    fun deliverDestinationReauthorization(
        requestId: String,
        uriString: String?,
        resultFlags: Int,
        expectedUri: String,
        expectedSha256: String,
        expectedBytes: Long,
    ): OfficeRecoveryDestinationCheck
    /** Provider original probe under a LIVE grant; never trusts the URI string alone. */
    fun probeOriginal(uriString: String, expectedSha256: String, expectedBytes: Long): OfficeRecoveryOriginalState
}

/** Host half of "open the retained working copy in the existing Office viewer". */
internal interface OfficeRecoveryOpenPort {
    fun open(
        candidate: OfficeRecoveryCandidate,
        observedSha256: String,
        observedBytes: Long,
    ): OfficeRecoveryOpenResult

    /** Candidate currently mounted by an Office session in this process, if any. */
    fun activeCandidateId(): String?

    fun probeOriginal(candidate: OfficeRecoveryCandidate): OfficeRecoveryOriginalState
}

internal sealed class OfficeRecoveryOpenResult {
    data class Accepted(val sessionToken: String) : OfficeRecoveryOpenResult()
    data class Refused(val code: String) : OfficeRecoveryOpenResult()
}

/** Save transaction facts persisted at settlement; no URI/path is authority. */
internal data class OfficeRecoverySaveFacts(
    val saved: Boolean,
    val uncertain: Boolean,
    val code: String?,
    val destinationUri: String?,
    val destinationSha256: String?,
    val destinationBytes: Long,
)

/**
 * The only durable transitions the Save-Copy handoff may perform. Implemented
 * by OfficeRecoveryJournal; a null sink preserves the pre-recovery behavior
 * byte-for-byte for tests/older callers.
 */
internal interface OfficeRecoveryJournalSink {
    /** Re-read verified working-copy facts after FLUSHED/UNMODIFIED. */
    fun recordFlush(candidateId: String, workingCopySha256: String, workingCopyBytes: Long)

    /** Persist a module-verified OUTPUT_READY BEFORE it can reach the picker. */
    fun recordOutputReady(candidateId: String, receipt: OfficeSaveReceipt): Boolean

    /** Persist TRANSFERRING + exact target BEFORE the provider is touched. */
    fun markTransferStarted(candidateId: String, opId: String, targetUri: String): Boolean

    /** Persist the honest App-side settlement. */
    fun settleSave(candidateId: String, opId: String, facts: OfficeRecoverySaveFacts)
}

/** One row the recovery sheet can render. */
internal data class OfficeRecoveryView(
    val id: String,
    val displayName: String,
    val format: String,
    val phase: OfficeRecoveryPhase,
    val updatedAtMillis: Long,
    val workingCopy: OfficeRecoveryFileState,
    val workingCopySha256: String?,
    val workingCopyBytes: Long,
    val workingCopyChangedSinceBase: Boolean,
    val output: OfficeRecoveryFileState,
    val outputBytes: Long,
    val canOpen: Boolean,
    val canExport: Boolean,
    val canCheckDestination: Boolean,
    val canProbeOriginal: Boolean,
    val canDiscard: Boolean,
    val destinationVerified: Boolean,
    /** Null until the user runs the explicit original probe. */
    val originalState: OfficeRecoveryOriginalState?,
    val limitations: List<OfficeRecoveryLimitation>,
    val lastErrorCode: String?,
    val dirtyAtClose: Boolean?,
) {
    val unresolved: Boolean
        get() = phase != OfficeRecoveryPhase.SAVED &&
            phase != OfficeRecoveryPhase.CLOSED_CLEAN &&
            phase != OfficeRecoveryPhase.DISCARDED
}

/** Picker launch the effect must perform exactly once per request id. */
internal data class OfficeRecoveryExportLaunch(
    val requestId: String,
    val candidateId: String,
    val spec: PickRequestSpec,
    val purpose: OfficeRecoveryLaunchPurpose = OfficeRecoveryLaunchPurpose.EXPORT,
)

/** One immutable UI projection. */
internal data class OfficeRecoveryState(
    val loading: Boolean = true,
    val visible: Boolean = false,
    val selectedId: String? = null,
    val candidates: List<OfficeRecoveryView> = emptyList(),
    val busyId: String? = null,
    /** Stable copy key, never a path/URI/exception string. */
    val message: String? = null,
    val launch: OfficeRecoveryExportLaunch? = null,
)

/** Maximum byte size shared with the Office input/output caps. */
internal const val MAX_OFFICE_RECOVERY_BYTES: Long = 256L * 1024 * 1024

/** Supported verified output formats for Save Copy. */
internal val OFFICE_RECOVERY_FORMATS: Set<String> = setOf("docx", "xlsx", "pptx", "pdf")

/** Concrete document MIME offered to CREATE_DOCUMENT. */
internal val OFFICE_RECOVERY_MIME_BY_FORMAT: Map<String, String> = mapOf(
    "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "pdf" to "application/pdf",
)

/** Parses the bounded viewer-result descriptors for OUTPUT_READY receipts only. */
internal fun outputReadyReceipts(descriptors: List<String>): List<OfficeSaveReceipt> =
    descriptors.mapNotNull { line ->
        OfficeSaveReceipt.fromDescriptorLine(line)?.takeIf {
            it.operation == OfficeSaveOperation.STAGED_EXPORT &&
                it.state == OfficeSaveState.OUTPUT_READY &&
                it.outputDocumentPath != null &&
                it.outputSha256 != null &&
                it.outputBytes in 1..MAX_OFFICE_RECOVERY_BYTES &&
                it.format?.lowercase()?.let { format -> format in OFFICE_RECOVERY_FORMATS } == true
        }
    }
