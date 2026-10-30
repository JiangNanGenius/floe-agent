// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Trusted App transport for the G07.1 network diagnostics lane.
 * DECLARATIONS ONLY — no business, permission or network logic lives here.
 *
 * Swift owns the bounded ticket table, the request/observation validation and
 * the tool registration ([FloeAndroidCore] `G07NetworkHostMailbox` /
 * `G07NetworkToolBindings` / `G07NetworkComposition`). This seam only lets the
 * App's epoch pump claim a ticket, hand the bounded request JSON to the SAME
 * Application-owned [com.floe.android.core.network.PhoneNetworkService], and
 * settle exactly once. There is no model-facing route here: no V3 handler
 * key, no tool name and no bridge payload can reach these exports.
 *
 * Status space (mirrors the Swift network-diagnostics C ABI; additive and
 * disjoint from gateway -1xx, runtime-owner -2xx, attachment -3xx,
 * skills-folder -4xx, source host -5xx, network workspace/browser -6xx and
 * run-output/git-trust -7xx; authored after auditing the actual Swift/Kotlin
 * ranges):
 *   0 ok; -101 stale claim; -102 generation fenced; -105 shape;
 *   -106 buffer too small; -107 oversize body; -108 descriptor invalid;
 *   -110 claim not claimed (double-settle classification);
 *   -801 notInstalled; -802 serviceUnavailable; -803 requestRefused;
 *   -804 observationInvalid; -805 hopTimeout; -899 internal.
 *
 * Bodies:
 *   describe -> descriptor JSON (<= 2048 B, closed key set);
 *   payload  -> request v1 JSON (<= 16 KiB);
 *   complete status 0 -> NetworkObservationV1 JSON (<= 256 KiB);
 *   complete status 1 -> typed failure {"code":token,"detail":bounded}
 *                        (<= 512 B).
 */
object NetworkDiagnosticsNative {
    init { System.loadLibrary("floe_jni") }

    /** Bind the pump to the CURRENT live root epoch (strictly newer; the
     * Swift export verifies the live root epoch itself and registers the six
     * `network.*` tools on success). 0 = accepted. */
    external fun bindEpoch(epoch: Long): Int

    /** Block up to [timeoutMillis] (clamped 0..1000 in JNI) for the next
     * queued ticket; 0 = none (re-arm). Positive = opaque claim id. */
    external fun next(timeoutMillis: Int): Long

    /** Descriptor JSON for a CLAIMED ticket, or null when stale/refused. */
    external fun describe(claim: Long): ByteArray?

    /** Full request v1 bytes for a claimed ticket, or null on refusal. */
    external fun payload(claim: Long): ByteArray?

    /** 1 = the ticket still exists for the CURRENT bound generation. */
    external fun isLive(claim: Long): Int

    /** 1 = the owning tool call cancelled / generation fenced: stop the real
     * work and STILL settle exactly once via [complete]. */
    external fun shouldStop(claim: Long): Int

    /** Settle one claimed ticket once. status 0 success (observation JSON) or
     * status 1 typed failure ({"code","detail"} <= 512 B). Returns 0 or a
     * typed negative (never throws). */
    external fun complete(claim: Long, status: Int, value: ByteArray): Int

    /** Exact-epoch teardown (generation retirement). */
    external fun close(epoch: Long): Int

    /** Typed mailbox counters JSON (no targets, paths, ids or content). */
    external fun stats(): ByteArray?

    /** Actual readiness/capability JSON (bound epoch + visible tool names). */
    external fun readiness(): ByteArray?

    /** Strict-UTF-8 JSON decode; a replacement-character guess is never
     * accepted for a descriptor, request or observation. */
    fun strictText(bytes: ByteArray?): String? = bytes?.let {
        runCatching {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(it)).toString()
        }.getOrNull()
    }
}
