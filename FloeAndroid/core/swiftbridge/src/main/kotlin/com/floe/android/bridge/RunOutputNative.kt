// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/** Trusted App transport for the D04 owned run-output reader/egress lane.
 * The App asks for ONE sealed output of ONE conversation it already owns
 * (conversationID + runID + outputID + the ACCEPTED native root epoch);
 * native re-derives the receipt from the run's own durable toolResult
 * records, verifies the snapshot bytes under the trusted artifact root and
 * streams them in bounded chunks. No model command, no caller-supplied
 * receipt JSON, no caller-selected file root, no path or digest argument.
 *
 * Status space (mirrors RunOutputBridgeFacade in
 * G04WorkspaceSourceHostAPI-style discipline; additive and disjoint from
 * gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder -4xx,
 * source host -5xx and network workspace -6xx):
 *   0 ok; -105 shape; -106 buffer too small;
 *   -701 notInstalled; -702 generationFenced; -703 sessionUnknown;
 *   -704 stateConflict; -705 notOwner; -706 receiptMissing;
 *   -707 fileMissing; -708 fileChanged; -709 oversized; -710 rejected;
 *   -711 scanTruncated; -712 leaseRefused (cleanup claim / unbound store);
 *   -713 saturated; -714 hopTimeout; -715 storeUnavailable; -799 internal.
 * JSON replies ({"ok":1|0,...}) are written into the caller-provided
 * ByteArray and the function returns the copied length (>=0) or a typed
 * negative status.
 *
 * Dynamic absence: when the LOADED libFloeAndroidCore does not export this
 * lane (an older Core generation), the first call raises LinkageError; the
 * App consumers map it to typed "unavailable" — never a fabricated product
 * success.
 */
object RunOutputNative {
    init { System.loadLibrary("floe_jni") }

    /** Bounded owned receipt page for one exact (conversation, run) pair.
     * Body: {ok:1, schema:"floe.run-output.list.v1", conversationID, runID,
     * items:[{outputID, producerCallID, producerTool, slot, displayName,
     * mimeType, byteCount, availability}], scanTruncated, truncatedItems,
     * rejectedCount}. availability vocabulary: "available" | "missing" |
     * "changed" | "oversized" | "rejected" (cheap namespace view; the full
     * streamed digest gate runs at [open]). */
    external fun list(epoch: Long, conversationID: String, runID: String, reply: ByteArray): Int

    /** Open one owned egress session: exact persisted receipt lookup, the
     * generation lease, and the FULL streamed verify happen BEFORE any byte
     * is advertised. Positive = opaque ticket; negative = typed status. The
     * lease is held until [close] (or the stale-generation sweep) releases
     * the exact token. */
    external fun open(epoch: Long, conversationID: String, runID: String, outputID: String): Long

    /** Native-verified session facts:
     * {ok:1, schema:"floe.run-output.egress.v1", conversationID, runID,
     * outputID, producerCallID, producerTool, slot, displayName, mimeType,
     * byteCount, sha256, relativePath}. relativePath is the canonical
     * RELATIVE snapshot namespace (display/validation only); no absolute
     * root ever crosses the boundary. */
    external fun info(ticket: Long, reply: ByteArray): Int

    /** Copy snapshot bytes at [offset] into [target] (<= 64 KiB array).
     * Returns copied length, 0 = clean EOF, or a typed negative status. */
    external fun read(ticket: Long, offset: Long, target: ByteArray): Int

    /** Closes the session and releases its exact lease token. Idempotent;
     * MUST be called on every terminal path (finish, error, cancel). */
    external fun close(ticket: Long): Int

    /** Typed counters JSON only (no paths, bytes, identities). */
    external fun stats(reply: ByteArray): Int
}
