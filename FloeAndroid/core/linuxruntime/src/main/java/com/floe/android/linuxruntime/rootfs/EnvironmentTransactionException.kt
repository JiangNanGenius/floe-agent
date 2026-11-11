// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.rootfs

import java.io.IOException

/**
 * Typed, closed-vocabulary refusal/failure of a Linux environment
 * transaction PREPARE stage (N02, job-46036bc8e99f4602). The A5 Samsung
 * API33 evidence showed a 13.6 s transactional start that failed as the
 * fully generic `runtime_start_failed`: every throw point at the tail of
 * [LinuxEnvironmentTransaction.prepare] was a plain `require`/raw
 * `IOException`, so the runtime kernel had no typed token to bind and the
 * host pump legitimately dropped it. This exception makes each prepare
 * stage actionable on the SAME failed-start receipt channel that already
 * exists (kernel `startFailureCode`/`startFailureErrno`, pump
 * re-publication bound to the exact grant/run/epoch, bounded Swift detail
 * below the byte-identical legacy first line) — never a new reader,
 * registry or authority.
 *
 * Refusals retain the historical IllegalArgumentException contract.
 * IO failures retain IOException through the wrapper below. Codes are a FIXED
 * reviewed set; the optional [detail] is a fixed reviewed set of snapshot
 * divergence axes. The [cause] chain may carry the original IOException
 * (including its path text) for debugger inspection only; no Floe log line,
 * receipt field or UI string ever reads it.
 *
 * Vocabulary (stage -> meaning):
 *  - transaction_journal_present: a previous transaction journal is still
 *    durable on this writable layer; an explicit recovery/rollback must run
 *    before any new prepare (was an untyped require).
 *  - transaction_insufficient_space: the file store cannot hold the exact
 *    snapshot plus the reserved headroom (was an untyped require).
 *  - transaction_image_io: walking/hashing the live writable layer failed
 *    with a raw filesystem error (was an untyped raw IOException).
 *  - transaction_snapshot_copy_io: copying the exact snapshot failed
 *    OUTSIDE the copier's own typed vocabulary (marker copy, attribute
 *    restore, durability barrier, directory fsync — raw IOErrors only;
 *    the copier's own RootfsMaterializeException tokens still pass through
 *    unchanged).
 *  - transaction_snapshot_verify_changed: the copied snapshot and/or the
 *    live layer no longer hash to the pre-copy image (was the untyped
 *    "Environment changed during snapshot" require); [detail] names the
 *    bounded divergence axis (entries/bytes/structure/kind/mode/modified/
 *    content/link), never a path.
 *  - transaction_identity_changed: the writable layer's inode identity or
 *    guest marker changed while the snapshot was being taken (was an
 *    untyped require).
 *  - transaction_publish_io: writing the durable journal record failed
 *    (was an untyped raw IOException).
 */
class EnvironmentTransactionException(
    val code: String,
    val detail: String? = null,
    cause: Throwable? = null,
) : IllegalArgumentException("Environment transaction refused: $code", cause) {

    init {
        require(code in CODES) { "Unknown environment transaction code" }
        require(detail == null || detail in DETAILS) { "Unknown environment transaction detail" }
    }

    companion object {
        /** The only tokens that may ever reach a receipt/log. */
        val CODES: Set<String> = setOf(
            "transaction_journal_present",
            "transaction_insufficient_space",
            "transaction_image_io",
            "transaction_snapshot_copy_io",
            "transaction_snapshot_verify_changed",
            "transaction_identity_changed",
            "transaction_publish_io",
        )

        /** Bounded snapshot-divergence axes for the verify stage; counts and
         *  identity comparisons only, never paths, names or content. */
        val DETAILS: Set<String> = setOf(
            "entries", "bytes", "structure", "kind", "mode", "modified", "content", "link",
        )

        internal const val CODE_TRANSACTION_JOURNAL_PRESENT = "transaction_journal_present"
        internal const val CODE_TRANSACTION_INSUFFICIENT_SPACE = "transaction_insufficient_space"
        internal const val CODE_TRANSACTION_IMAGE_IO = "transaction_image_io"
        internal const val CODE_TRANSACTION_SNAPSHOT_COPY_IO = "transaction_snapshot_copy_io"
        internal const val CODE_TRANSACTION_SNAPSHOT_VERIFY_CHANGED = "transaction_snapshot_verify_changed"
        internal const val CODE_TRANSACTION_IDENTITY_CHANGED = "transaction_identity_changed"
        internal const val CODE_TRANSACTION_PUBLISH_IO = "transaction_publish_io"
    }
}

/** Preserve IO recovery callers while carrying only bounded public detail. */
private class EnvironmentTransactionIOException(
    val diagnostic: EnvironmentTransactionException,
) : IOException(diagnostic.message, diagnostic.cause)

internal fun environmentTransactionFailure(
    code: String,
    detail: String? = null,
    cause: Throwable? = null,
): Exception {
    val diagnostic = EnvironmentTransactionException(code, detail, cause)
    return if (cause is IOException) EnvironmentTransactionIOException(diagnostic) else diagnostic
}

fun Throwable.environmentTransactionDiagnostic(): EnvironmentTransactionException? = when (this) {
    is EnvironmentTransactionException -> this
    is EnvironmentTransactionIOException -> diagnostic
    else -> null
}
