// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Trusted App transport for the G09-R2 media render ticket lane
 * (job-b72b2978320e484e). Declarations only — NO business logic lives here.
 *
 * This mirrors the reviewed [OfficeAiNative] pump family exactly: Swift owns
 * the bounded ticket table, every socket/lease/root/digest decision and the
 * exactly-once settlement ([FloeAndroidCore] `G09R2MediaRenderHostMailbox` +
 * `G09R2SnapshotLeases`); the Kotlin transport
 * (`com.floe.android.host.creative.MediaRenderTicketNativeTransport`) claims
 * tickets on its own IO worker, validates the native descriptor/root/lease
 * and dispatches the REAL Media3 work in the later platform module.
 *
 * There is no model-facing route here: no V3 handler key, no tool name and no
 * `floe_bridge_exchange` payload can reach these exports.
 *
 * Status space (additive and disjoint from Office -101..-110):
 *   0 ok; -101 unknown/stale ticket; -102 generation fenced;
 *   -105 invalid shape/token; -106 buffer too small; -107 oversize body;
 *   -108 descriptor invalid; -110 claim mismatch/already settled;
 *   -111 lease expired; -112 output receipt not verified.
 *
 * Bodies:
 *   claim        -> claimed envelope JSON {descriptor, claimToken, claimedAt,
 *                   leaseExpiresAt} (<= 64 KiB), null on bounded timeout;
 *   describe     -> descriptor JSON (<= 64 KiB);
 *   complete     -> platform reply JSON (<= 1 MiB): completed replies MUST
 *                   carry the real verified receipt; failures carry a typed
 *                   code and no receipt.
 */
object MediaRenderNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Privileged media task/project binding ingress. ONLY the App owner may
     * call this with the live accepted Root epoch + full process owner token;
     * the model, a tool payload and a recorded project path can never reach
     * it. The request/reply are bounded JSON; native validates the owner proof
     * and the real task/workspace/project before recording anything.
     */
    external fun selectMediaTaskBinding(
        ownerEpoch: Long,
        ownerToken: String,
        requestJson: String,
    ): String

    /** Remove the explicit association (project id + optional exact binding/
     * task). Same owner-proof gate as selection. */
    external fun revokeMediaTaskBinding(
        ownerEpoch: Long,
        ownerToken: String,
        requestJson: String,
    ): String

    /** Issue the ORIGINAL single-use media proposal grant for the PINNED
     * association's existing proposal/revision. Host-only; no model route. */
    external fun issueMediaProjectGrant(
        ownerEpoch: Long,
        ownerToken: String,
        requestJson: String,
    ): String

    /** Bind the transport to the CURRENT live root epoch (strictly newer).
     * 0 = accepted; -102 = refused (fenced or a generation still draining). */
    external fun bindEpoch(epoch: Long): Int

    /** Prove the real ticket consumer is RUNNING for this exact bound epoch.
     * 0 = refreshed the bounded readiness lease; -102 = stale/fenced. This is
     * deliberately separate from [bindEpoch]: a bind alone never advertises a
     * usable renderer, and the lease expires if claims/heartbeats stop. */
    external fun consumerHeartbeat(epoch: Long): Int

    /** Retire the readiness lease immediately when the platform owner stops
     * the consumer; claimed tickets still settle with their own tokens. */
    external fun consumerStop(epoch: Long): Int

    /** Block up to [timeoutMillis] (clamped 0..5000) for the next ticket.
     * Null on a bounded poll timeout; never an invented ticket. */
    external fun claim(timeoutMillis: Int): ByteArray?

    /** Descriptor JSON for a live ticket, or null when stale/refused. */
    external fun describe(ticketID: String): ByteArray?

    /** 1 = the ticket still exists for the CURRENT bound generation. */
    external fun isLive(ticketID: String): Int

    /** 1 = cancel requested / generation fenced / claim lease expired: stop
     * the real work and still settle exactly once with the claim token. */
    external fun shouldStop(ticketID: String, claimToken: String): Int

    /** Extend the bounded claim lease; 0 = extended, -111 = expired/refused. */
    external fun heartbeat(ticketID: String, claimToken: String): Int

    /** Settle one claimed ticket once. 0 = accepted; -110 = duplicate or
     * mismatched claim token; -112 = completed receipt failed native output
     * verification (the claim stays owned so a truthful failure can settle). */
    external fun complete(ticketID: String, claimToken: String, value: ByteArray): Int

    /** Claimed close / root-drain acknowledgement (exactly once). */
    external fun close(ticketID: String, claimToken: String): Int

    /** Typed mailbox counters JSON (no paths, bytes, identities or content). */
    external fun stats(): ByteArray?

    /** Phase-1 root stop. 0 = drained (safe to retire Root), 1 = owned work
     * remains (cancel/ack each claim; Root stays bound), negative = refused. */
    external fun rootStop(epoch: Long): Int

    /** Pending claimed/queued count for the epoch (0 = drained). */
    external fun drainPending(epoch: Long): Int
}


/** Typed negative status from the privileged media authority JNI. */
class MediaToolAuthorityNativeException(
    val status: Int,
) : IllegalStateException("media_tool_authority_failure")
