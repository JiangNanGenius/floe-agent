// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted App transport for native-retained network (WebDAV/SMB) workspace
 * mounts. No model command, no caller-selected file root, no provider
 * credential in any signature, no permission flag.
 *
 * Status space (mirrors G04NetworkWorkspaceHostAPI.swift; additive -6xx,
 * DISJOINT from gateway -1xx, runtime-owner -2xx, attachment -3xx,
 * skills-folder -4xx and provider source-host -5xx):
 *   0 ok; -105 shape; -106 buffer too small;
 *   -601 notInstalled; -602 generationFenced; -603 sessionUnknown;
 *   -604 stateConflict; -605 identityRefused; -606 mountUnknown;
 *   -607 pathRefused; -608 providerFailed; -609 credentialRefused;
 *   -610 saturated; -611 hopTimeout; -612 diskFull; -613 sizeExceeded;
 *   -614 transitionRefused; -699 internal.
 * JSON replies ({"ok":1|0,...}) are written into the caller-provided
 * ByteArray and the function returns the copied length (>=0) or a typed
 * negative status; a body with "ok":0 carries the actionable errorCode
 * token. Credential password bytes cross ONLY through [credStage] (one-shot
 * native RAM ticket; nothing ever returns them). */
object NetworkWorkspaceNative {
    init { System.loadLibrary("floe_jni") }

    /** Stage one secret body into the live generation's credential lease.
     * Returns a positive one-shot ticket or a typed negative status. */
    external fun credStage(epoch: Long, data: ByteArray, offset: Int, length: Int): Long

    /** Honest abandon of an unconsumed staged secret. */
    external fun credAbort(ticket: Long): Int

    external fun mountPage(
        epoch: Long, taskID: String, workspaceID: String, reply: ByteArray,
    ): Int

    /** Create a mount. Empty name/rootPath/username = absent; readOnly flag
     * is explicit; credentialTicket 0 = none (anonymous), >0 = staged
     * secret captured on a successful actual probe. */
    external fun mountAdd(
        epoch: Long, taskID: String, workspaceID: String, name: String, transport: String,
        endpoint: String, rootPath: String, username: String, readOnly: Boolean,
        credentialTicket: Long, reply: ByteArray,
    ): Int

    /** Edit a mount. credentialTicket: >0 rotate (capture-first: the old
     * ref is revoked only after the new probe succeeds), 0 keep, -1 clear. */
    external fun mountUpdate(
        epoch: Long, taskID: String, workspaceID: String, mountID: String, name: String,
        transport: String, endpoint: String, rootPath: String, username: String,
        readOnly: Boolean, credentialTicket: Long, reply: ByteArray,
    ): Int

    external fun mountProbe(
        epoch: Long, taskID: String, workspaceID: String, mountID: String, reply: ByteArray,
    ): Int

    /** Cancel REQUEST for this mount's live operations + retire the retained
     * transport admission; the durable config stays. */
    external fun mountDisconnect(
        epoch: Long, taskID: String, workspaceID: String, mountID: String, reply: ByteArray,
    ): Int

    external fun mountRemove(
        epoch: Long, taskID: String, workspaceID: String, mountID: String,
        forgetCredential: Boolean, reply: ByteArray,
    ): Int

    external fun browse(
        epoch: Long, taskID: String, workspaceID: String, mountID: String,
        path: String, reply: ByteArray,
    ): Int

    external fun stat(
        epoch: Long, taskID: String, workspaceID: String, mountID: String,
        path: String, reply: ByteArray,
    ): Int

    /** Positive = opaque operation ticket; negative = typed status. */
    external fun opImport(
        epoch: Long, taskID: String, workspaceID: String, mountID: String,
        remotePath: String, logicalPath: String, recursive: Boolean, conflict: String,
    ): Long

    external fun opExport(
        epoch: Long, taskID: String, workspaceID: String, mountID: String,
        logicalPath: String, remotePath: String, policy: String,
    ): Long

    /** The durable journal-47 replacement ladder for one network source. */
    external fun opSave(epoch: Long, taskID: String, workspaceID: String, sourceID: String): Long

    /** Decide ONE unfinished receipt from the CURRENT provider bytes only. */
    external fun opReconcile(
        epoch: Long, taskID: String, workspaceID: String, recoveryID: String,
    ): Long

    external fun opStatus(ticket: Long, reply: ByteArray): Int

    /** Cancel is a REQUEST; the operation settles through its own physical
     * IO and only then reaches a terminal state. */
    external fun opCancel(ticket: Long): Int

    /** Refuses (-604) while the operation is not terminal. */
    external fun opClose(ticket: Long): Int

    /** Metadata-only durable network source rows (journal 47). */
    external fun sourcePage(
        epoch: Long, workspaceID: String, afterID: String, limit: Int, reply: ByteArray,
    ): Int

    /** Typed counters JSON only (no paths, bytes, identities). */
    external fun hostStats(reply: ByteArray): Int
}
