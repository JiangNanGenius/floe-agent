// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

/**
 * Trusted host bridge for the controlled-browser / local-preview generation
 * (Swift `G04BrowserHostAPI.swift`). Like every other `*Native` seam here,
 * this object only TRANSPORTS bounded bytes and integers across JNI: no
 * browser decision, no path, no policy, no session state lives here.
 *
 * Status space (mirrors G04BrowserHostAPI.swift; additive and disjoint from
 * gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder -4xx and
 * source-host -5xx):
 *   mailbox codes: 0 ok; -101 stale claim; -102 generation fenced;
 *   -105 shape; -106 bufferTooSmall; -107 oversized; -108 descriptor invalid;
 *   -110 double settle;
 *   browser host: -601 notInstalled; -602 unboundEpoch; -603 badJSON;
 *   -604 unknownOperation; -605 hopTimeout; -606 ownerRefused; -699 internal.
 *
 * Threading contract enforced on the Kotlin side (BrowserHostController):
 *   * `next` blocks ONLY the dedicated native-pump thread;
 *   * WebView operations execute on the main looper with exactly-once
 *     replies; loopback socket work executes on transport threads;
 *   * `previewAdjudicate` / `previewReadChunk` / `uiQuery` may block the
 *     calling DEDICATED IO/bridge thread — never the main looper while a
 *     renderer claim is outstanding on the pump;
 *   * `policyAllows` is synchronous-safe from `shouldInterceptRequest`
 *     (pure locked-table decision, no actor hop).
 */
object BrowserNative {
    init { System.loadLibrary("floe_jni") }

    // ---- Mailbox pump (the engine thread's surface) ----

    external fun bindEpoch(epoch: Long): Int
    external fun next(timeoutMillis: Int): Long
    external fun describe(claim: Long): ByteArray?
    external fun payload(claim: Long): ByteArray?
    external fun isLive(claim: Long): Int
    external fun shouldStop(claim: Long): Int
    external fun complete(claim: Long, status: Int, value: ByteArray?): Int
    external fun close(epoch: Long): Int
    external fun boundEpoch(): Long
    external fun stats(): ByteArray?

    // ---- Trusted uplinks (panel/gateway/transport threads) ----

    external fun ingestEvent(json: String): Int
    external fun policyAllows(json: String): Int
    external fun popupQuery(json: String): Int
    external fun downloadRequest(json: String): Int
    external fun uiCall(json: String): Int
    external fun uiQuery(json: String, reply: ByteArray, timeoutMillis: Int): Int
    external fun previewAdjudicate(
        serverId: String,
        requestId: String,
        header: ByteArray?,
        reply: ByteArray,
    ): Int
    external fun previewReadChunk(
        serverId: String,
        requestId: String,
        offset: Int,
        target: ByteArray,
    ): Int
    external fun recoverHandoff(taskId: String, runId: String, epoch: Long): Int
    external fun servicesLive(epoch: Long): Int

    /** Strict-UTF-8 JSON text decode for a claim descriptor (never a
     * replacement-character guess). */
    fun descriptorText(bytes: ByteArray?): String? = bytes?.let {
        runCatching {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(it)).toString()
        }.getOrNull()
    }

    /** Strict-UTF-8 reply decode for `uiQuery` / `previewAdjudicate` buffers
     * (the copied region is exactly `[0, returnedLength)`). */
    fun replyText(reply: ByteArray, length: Int): String? {
        if (length < 0 || length > reply.size) return null
        return descriptorText(reply.copyOfRange(0, length))
    }
}
