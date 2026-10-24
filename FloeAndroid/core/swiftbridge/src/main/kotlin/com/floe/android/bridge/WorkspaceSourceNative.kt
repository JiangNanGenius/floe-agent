// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted App transport for native journal-admitted provider IO. No model
 * command, caller-selected file root, provider credential or permission flag.
 *
 * Status space (mirrors G04WorkspaceSourceHostAPI.swift; additive and
 * disjoint from gateway -1xx, runtime-owner -2xx, attachment -3xx and
 * skills-folder -4xx):
 *   0 ok; -105 shape; -106 buffer too small;
 *   -501 notInstalled; -502 generationFenced; -503 sessionUnknown;
 *   -504 stateConflict; -505 identityRefused; -506 sourceMissing;
 *   -507 staleRevision; -508 transitionRefused; -509 sizeExceeded;
 *   -510 aggregateExceeded; -511 diskFull; -512 saturated;
 *   -513 writeFailed; -514 readFailed; -515 digestMismatch;
 *   -516 transportUnavailable; -517 providerFailed; -518 hopTimeout; -599 internal.
 * JSON replies ({"ok":1|0,...}) are written into the caller-provided
 * ByteArray and the function returns the copied length (>=0) or a typed
 * negative status; a body with "ok":0 carries the actionable errorCode token.
 */
object WorkspaceSourceNative {
    init { System.loadLibrary("floe_jni") }
    external fun bindEpoch(epoch: Long): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun payload(claim: Long): ByteArray?
    external fun isLive(claim: Long): Int
    external fun shouldStop(claim: Long): Int
    external fun complete(claim: Long, status: Int, value: ByteArray): Int
    external fun close(epoch: Long): Int
    external fun stats(): ByteArray?

    // ---- Provider source host lane (additive; epoch-fenced) ----

    /** Open one bounded chunked staged ingress. Purpose is the closed token
     * set: "import" | "backup-verify" | "fresh-observe" | "readback" |
     * "export-verify". "" for the optional identity fields = absent.
     * Returns a positive opaque ticket or a typed negative status. */
    external fun stageOpen(
        epoch: Long, taskID: String, workspaceID: String, purpose: String,
        logicalPath: String, sourceReference: String, sourceDocumentID: String, sourceID: String,
    ): Long

    /** Append ONE chunk (<= 64 KiB) to a live, unfrozen stage. */
    external fun stageWrite(ticket: Long, data: ByteArray, offset: Int, length: Int): Int

    /** Flush+fsync+native streaming hash; "import" additionally commits the
     * working copy through the ORIGINAL atomic verified machinery and binds
     * journal 47 in one bounded hop. Reply body: {ok, sha256, bytes,
     * [sourceID, revision]} or {ok:0, errorCode, reason}. */
    external fun stageFinish(ticket: Long, reply: ByteArray): Int

    external fun stageAbort(ticket: Long): Int

    /** Freeze one native working copy for chunked egress. mode: "save"
     * (journal ladder) | "export" (non-destructive send). Positive =
     * ticket; negative = typed status. */
    external fun egressOpen(
        epoch: Long, mode: String, taskID: String, workspaceID: String,
        logicalPath: String, sourceID: String,
    ): Long

    /** {ok, mode, sha256, bytes, logicalPath, recoveryID, [sourceID,
     * sourceRevision, recordedSHA256]} */
    external fun egressInfo(ticket: Long, reply: ByteArray): Int

    /** Copy snapshot bytes at [offset] into [target] (<= 64 KiB array).
     * Returns copied length, 0 = clean EOF, or a typed negative status. */
    external fun egressRead(ticket: Long, offset: Long, target: ByteArray): Int

    /** Native-vs-native digest compare of one finished verification stage
     * against the frozen snapshot. {ok, match, snapshotSHA256,
     * observedSHA256} */
    external fun egressVerify(egressTicket: Long, stageTicket: Long, reply: ByteArray): Int

    external fun egressClose(ticket: Long): Int

    /** Journal phase 1: staged fresh provider backup (native-hashed) must
     * equal the recorded binding digest; creates ONE `prepared` row with the
     * caller gateway receipt identity. */
    external fun savePrepare(saveTicket: Long, backupTicket: Long, receiptToken: String, reply: ByteArray): Int

    /** Journal phase 2: second native observation -> ONE-TIME `writing`. */
    external fun saveClaim(saveTicket: Long, freshTicket: Long, reply: ByteArray): Int

    /** Destructive permit, handed at most once per save session and only to
     * the exact journaled receipt token. 0 = permitted, negative = refused. */
    external fun savePermit(saveTicket: Long, receiptToken: String): Int

    /** Journal phase 3: the streamed provider read-back (native-hashed)
     * decides committed (binding CAS) or conflict. */
    external fun saveSettle(saveTicket: Long, readbackTicket: Long, reply: ByteArray): Int

    /** Honest abandon before any destructive write started. */
    external fun saveRetain(saveTicket: Long, reply: ByteArray): Int

    /** Metadata-only durable source rows page (bootstrap reconciliation). */
    external fun sourcePage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int

    external fun sourceLookup(epoch: Long, workspaceID: String, logicalPath: String, reply: ByteArray): Int

    external fun recoveryPage(epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray): Int

    /** Transport-backed reconcile run (bounded documents). */
    external fun reconcileRun(epoch: Long, workspaceID: String, reply: ByteArray): Int

    /** Staged single-receipt reconcile (>4 MiB counterpart). */
    external fun reconcileStaged(
        epoch: Long, taskID: String, workspaceID: String, recoveryID: String,
        stageTicket: Long, reply: ByteArray,
    ): Int

    /** Typed counters JSON only (no paths, bytes, identities). */
    external fun hostStats(reply: ByteArray): Int
}
