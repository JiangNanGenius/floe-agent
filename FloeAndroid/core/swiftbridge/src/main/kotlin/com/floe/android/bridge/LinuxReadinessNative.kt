// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * G03-R3 trusted-host surface for the LIVE Linux readiness ingress /
 * invalidation authority (job-3d39b56695c44bd2).
 *
 * The host owner calls `ingest` ONLY with facts it PROVED itself (real
 * PackageManager/Binder/rootfs/engine evidence for the CURRENT accepted
 * Root epoch — the native side cross-checks the live mailbox generation,
 * the distinct runtime UID against this process's own UID, and reads the
 * workspace-mapping receipt back from the ORIGINAL engine tree). Fields
 * stay false until every fact is accepted for the live generation; a
 * default-constructed state means unqualified, exactly as before.
 *
 * Field names (closed set): runtimeUidBoundary | engineConnected |
 * mailboxEpoch | rootfsInstalled | workspaceMappingSynced |
 * leaseAuthorityQualified | singleWorkloadAcknowledged.
 *
 * Proof JSON per field (bounded; <=4 KiB):
 *  runtimeUidBoundary: {"runtimeUID":<int != this process UID, >=0>,
 *    "certificateDigest":"<64hex>","packageVersion":"<token>",
 *    "binderIdentity":"<token>"} — ANCHORS the generation to one verified
 *    peer; a later boundary fact with a different identity is refused.
 *  engineConnected:    {"binderIdentity":"<same peer token>",
 *    "engineProtocolVersion":"<token>"}
 *  mailboxEpoch:       {} — cross-checked against the LIVE mailbox bind
 *    (a CLOSED mailbox refuses here, not only in derived state)
 *  rootfsInstalled:    {"receiptDigest":"<64hex>","rootfsVersion":"<token>"}
 *  workspaceMappingSynced: {"receiptDigest":"<64hex>"} — digest of an
 *    actual terminal index Core reads back from the accepted transfer tree
 *    whose marker proves the SAME live epoch (never a flag, never an old
 *    generation's receipt)
 *  leaseAuthorityQualified: {"receiptDigest":"<64hex>"}
 *  singleWorkloadAcknowledged: {"contractVersion":"<token>"}
 *
 * `invalidate` removes facts on lost/unqualified evidence, failed map,
 * disconnect or stop; facts NEVER auto-restore. `resumeAdmissions` is the
 * explicit same-generation re-admission after a suspend (readiness still
 * requires full re-ingestion afterwards). Reply JSON:
 * {"ok":true,...} or {"ok":false,"code":"..."}.
 * Model JSON is never an ingress: there is no V3 key here.
 */
object LinuxReadinessNative {
    init { System.loadLibrary("floe_jni") }
    external fun ingest(field: String, epoch: Long, proof: ByteArray): ByteArray?
    /** field null or "*" invalidates the whole set; reason is bounded ASCII. */
    external fun invalidate(field: String?, reason: String): ByteArray?
    external fun status(): ByteArray?
    /** 0 accepted; -105 refused. Never restores facts by itself. */
    external fun resumeAdmissions(epoch: Long): Int
    /**
     * First-use activation AFTER the full real fact set for the CURRENT
     * accepted epoch is ingested (including the workspaceMappingSynced
     * receipt from the NON-EXECUTING workspace preflight). Runs the
     * ORIGINAL registration gates once; refuses without fabricating
     * qualification. Reply JSON:
     * {"ok":true,"shellRegistered":bool,"jobsPublishAttempted":true}
     * or {"ok":false,"code":"epochNotBound"|"readinessNotIngressed"}.
     */
    external fun activateRegistration(epoch: Long): ByteArray?
}
