// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

/** Exception-free fault taxonomy crossing the backend seam (no Android types). */
enum class SafBackendFault { REVOKED, GRANT_MISSING, OFFLINE, UNSUPPORTED, NOT_FOUND, CANCELLED, IO, FAILED }

/** Thrown by [SafPlatformBackend] implementations for exceptional provider states. */
class SafBackendFaultException(
    val fault: SafBackendFault,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

/** Typed, actionable public failures. Every one maps to an honest UI limit. */
sealed class SafFailure {
    abstract val code: String

    /** A persisted grant the OS no longer holds (user revoked / moved / provider reset). */
    data object Revoked : SafFailure() { override val code = "revoked" }

    /** No grant ever existed for this URI in either truth source. */
    data object GrantMissing : SafFailure() { override val code = "grant_missing" }

    /**
     * The CURRENT-SESSION grant (explicit system result) has actually expired:
     * the platform probe denies access and no persisted grant replaces it.
     * This is an actionable re-pick request — it never fires while the session
     * grant is still live, and it is NOT re-asked on every operation.
     */
    data class RePickRequired(val detail: String) : SafFailure() { override val code = "re_pick_required" }

    /** Provider process unresponsive/dead: retry after the provider returns, do not re-grant silently. */
    data object ProviderOffline : SafFailure() { override val code = "provider_offline" }

    /** Access exists but lacks the required flag, or the document does not support writing. */
    data object ReadOnly : SafFailure() { override val code = "read_only" }

    /** The provider (or this API on this platform level) cannot do this. `hint` is user-actionable. */
    data class Unsupported(val hint: String) : SafFailure() { override val code = "unsupported" }

    data object Cancelled : SafFailure() { override val code = "cancelled" }

    /** Source bytes changed vs. the expected hash, or the provider disagrees with a reported mutation. */
    data class Conflict(val detail: String) : SafFailure() { override val code = "conflict" }

    data object NotFound : SafFailure() { override val code = "not_found" }

    /** The provider returned an identity we cannot bind to the requested operation. Never guessed. */
    data class AmbiguousIdentity(val detail: String) : SafFailure() { override val code = "ambiguous_identity" }

    /** A bounded stream hit its caller-declared cap. Partial output was NOT promoted as verified. */
    data class SizeLimitExceeded(val limitBytes: Long) : SafFailure() { override val code = "size_limit_exceeded" }

    data class Io(val detail: String) : SafFailure() { override val code = "io" }

    data class Failed(val detail: String) : SafFailure() { override val code = "failed" }
}

/** Public result envelope. `Success` never implies durability claims beyond its payload. */
sealed class SafOutcome<out T> {
    data class Success<T>(val value: T, val note: String? = null) : SafOutcome<T>()
    data class Failure<T>(val failure: SafFailure, val detail: String? = null) : SafOutcome<T>()

    val isSuccess: Boolean get() = this is Success

    companion object {
        fun <T> success(value: T, note: String? = null): SafOutcome<T> = Success(value, note)
        fun <T> failure(f: SafFailure, detail: String? = null): SafOutcome<T> = Failure(f, detail)
    }
}

/** Covariant-safe transform (kept as an extension so `out T` stays legal). */
fun <T, R> SafOutcome<T>.mapValue(transform: (T) -> R): SafOutcome<R> = when (this) {
    is SafOutcome.Success -> SafOutcome.Success(transform(value), note)
    is SafOutcome.Failure -> SafOutcome.Failure(failure, detail)
}

internal fun SafBackendFault.toSafFailure(): SafFailure = when (this) {
    SafBackendFault.REVOKED -> SafFailure.Revoked
    SafBackendFault.GRANT_MISSING -> SafFailure.GrantMissing
    SafBackendFault.OFFLINE -> SafFailure.ProviderOffline
    SafBackendFault.UNSUPPORTED -> SafFailure.Unsupported("the document provider rejected this operation")
    SafBackendFault.NOT_FOUND -> SafFailure.NotFound
    SafBackendFault.CANCELLED -> SafFailure.Cancelled
    SafBackendFault.IO -> SafFailure.Io("stream io error")
    SafBackendFault.FAILED -> SafFailure.Failed("provider failure")
}

// ---------------------------------------------------------------------------
// Cancellation: pure token; the Android backend converts it to a
// CancellationSignal at the platform edge. Workers live on the service IO
// context, never on UI lifetime.
// ---------------------------------------------------------------------------

class SafCancelledException(message: String = "operation cancelled") : RuntimeException(message)

class SafCancelToken {
    private val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
    private val listeners = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()

    val isCancelled: Boolean get() = cancelled.get()

    fun cancel() {
        if (cancelled.compareAndSet(false, true)) {
            listeners.forEach { runCatching { it() } }
        }
    }

    /** Listeners fire immediately when already cancelled; used to link CancellationSignal. */
    fun onCancel(listener: () -> Unit) {
        listeners += listener
        if (isCancelled) runCatching { listener() }
    }

    fun ensureActive() {
        if (isCancelled) throw SafCancelledException()
    }
}

// ---------------------------------------------------------------------------
// Receipts for the working-copy seam. Main/native coordinator owns durability:
// this module keeps the pending-recovery registry IN MEMORY only.
// ---------------------------------------------------------------------------

/** A copy operation result bound to EXACT identities and measured bytes. */
data class CopyReceipt(
    val destination: SafDocumentRef,
    val sourceUri: SafUriRef,
    val sourceSha256: String,
    val destinationSha256: String,
    val bytes: Long,
) {
    val byteIdentical: Boolean get() = sourceSha256 == destinationSha256
}

/** Export through ACTION_CREATE_DOCUMENT-style creation: distinct document, never overwrite. */
data class ExportReceipt(
    val created: SafDocumentRef,
    val bytes: Long,
    val sourceSha256: String,
    val destinationReadbackSha256: String?,
    val readbackVerified: Boolean,
)

/** The recovery original preserved BEFORE any destructive provider write. */
data class RecoveryReceipt(
    val receiptId: String,
    val file: StagedLocalRef,
    val sha256: String,
    val bytes: Long,
    val targetUri: SafUriRef,
    val targetDocumentId: String?,
    val issuedAtMillis: Long,
)

/** Honest write strategies. There is deliberately NO atomic-CAS option. */
enum class SaveStrategy { WRITE_TRUNCATE_NON_ATOMIC, SAVE_AS_SIBLING }

data class SavePolicy(
    /** Default: when replacement atomicity cannot be PROVEN, prefer a non-destructive sibling. */
    val preferSaveAsWhenReplacementNotProven: Boolean = true,
    /** Explicit caller-authorized destructive overwrite of the original document. */
    val allowDestructiveOverwrite: Boolean = false,
    /** Allow the SAVE_AS_SIBLING fallback when overwrite mode is unsupported. */
    val allowSaveAsSibling: Boolean = true,
    /** Hard cap for preserving the original into recovery storage before a destructive write. */
    val recoveryByteLimit: Long = 512L shl 20,
)

sealed class SaveReceipt {
    /** The provider write returned and the read-back hash EQUALS the replacement hash.
     *  The recovery original stays registered until the native coordinator adopts it.
     *  [providerCasGuaranteed] is deliberately a hardcoded false field: a generic
     *  DocumentsProvider cannot guarantee compare-and-swap; the pre-write rehash
     *  narrows the race window, and final consistency authority is the native
     *  coordinator (Main steering 2026-10-24). */
    data class Committed(
        val strategy: SaveStrategy,
        val target: SafDocumentRef,
        val writtenSha256: String,
        val readbackVerified: Boolean,
        val recovery: RecoveryReceipt,
        val providerCasGuaranteed: Boolean = false,
    ) : SaveReceipt()

    /** Non-destructive path: original untouched, new sibling holds the new bytes. */
    data class SaveAsCreated(
        val created: ExportReceipt,
        val originalUntouched: Boolean,
        val reason: String,
    ) : SaveReceipt()

    /** Source bytes changed vs. the expected/prepared hash. NO write was attempted;
     *  recovery retained. [driftRecovery] is set when the drifted CURRENT bytes were
     *  themselves preserved (a third writer's work stays recoverable too). */
    data class Conflict(
        val expectedSha256: String,
        val observedSha256: String,
        val recovery: RecoveryReceipt,
        val driftRecovery: RecoveryReceipt? = null,
    ) : SaveReceipt()

    /** Write attempted with an uncertain or failed result. Original bytes REMAIN in
     *  caller-owned recovery storage; the outcome is never presented as success. */
    data class RecoverableFailure(
        val code: String,
        val recoveryPreserved: RecoveryReceipt?,
        val partialWritePossible: Boolean,
        val reconciliationRequired: Boolean,
    ) : SaveReceipt()
}

/** Result of a move with the truthful copy-then-delete fallback ladder. */
enum class MoveMode { NATIVE_MOVE, VERIFIED_COPY_PLUS_DELETE, VERIFIED_COPY_SOURCE_RETAINED }

data class MoveResult(
    val mode: MoveMode,
    val finalRef: SafDocumentRef?,
    val copy: CopyReceipt?,
    val sourceDeleted: Boolean,
    val note: String,
)
