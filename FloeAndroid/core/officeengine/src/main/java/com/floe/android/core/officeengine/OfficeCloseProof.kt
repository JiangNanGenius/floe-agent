// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/** A sealed engine snapshot, never a save destination or a process-exit receipt.
 * The host must additionally observe this engine's Binder death and verify the
 * owned file again. A timeout or an Activity result cannot replace either fact. */
object OfficeCloseProof {
    const val TRANSACTION_PREPARE_CLOSE = 2
    const val SCHEMA_VERSION = 1

    data class Receipt(
        val close: OfficeCloseAckPolicy.AckRequest,
        val dirtyAtClose: Boolean,
        val discarded: Boolean,
        val sha256: String,
        val bytes: Long,
    )

    fun validate(
        token: String?, generation: Long, incarnation: Long, reason: String?,
        dirtyWord: Int, discardWord: Int, sha256: String?, bytes: Long,
    ): Receipt? {
        val close = OfficeCloseAckPolicy.validateShape(token, generation, incarnation, reason) ?: return null
        if (dirtyWord !in 0..1 || discardWord !in 0..1 ||
            sha256 == null || !sha256.matches(Regex("[0-9a-f]{64}")) ||
            bytes !in 1..(256L * 1024 * 1024)
        ) return null
        return Receipt(close, dirtyWord == 1, discardWord == 1, sha256, bytes)
    }

    /** Kept pure so the real decision is exercised without an Android stub. */
    fun matchesClosedFile(receipt: Receipt, processDead: Boolean, sha256: String?, bytes: Long): Boolean =
        processDead && receipt.sha256 == sha256 && receipt.bytes == bytes

    /** Even an engine-reported clean state cannot discard changed bytes that
     * have no verified destination. Hash equality alone is never close proof. */
    fun hasUnsavedBytes(
        receipt: Receipt, baselineSha256: String?, baselineBytes: Long,
    ): Boolean = receipt.dirtyAtClose || receipt.sha256 != baselineSha256 || receipt.bytes != baselineBytes
}
