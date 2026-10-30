// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.network

import com.floe.android.bridge.NetworkDiagnosticsNative

/**
 * Pump transport seam over the delivered [NetworkDiagnosticsNative]
 * declarations. One interface lets the serialized epoch pump run against the
 * real mailbox in production and against a scripted transport in JVM
 * regressions; the pump coordinates with the EXACT production settlement
 * logic either way.
 *
 * Status space (mirrors the Swift exports; see NetworkDiagnosticsNative.kt):
 * 0 ok; -101 stale claim; -102 generation fenced; -105 shape;
 * -106 buffer; -107 oversize; -108 descriptor invalid;
 * -110 claim not claimed; -8xx host/service classifications.
 * A negative [complete] is a terminal classification: the claim was already
 * settled/fenced by the mailbox; the pump NEVER retries or double-settles.
 */
internal interface NetworkDiagnosticsNativeTransport {
    /** 0 = accepted binding for the CURRENT live root epoch. */
    fun bindEpoch(epoch: Long): Int

    /** Blocking wait (clamped by the JNI to 0..1000 ms) for the next claim. */
    fun next(timeoutMillis: Int): Long

    fun describe(claim: Long): ByteArray?

    fun payload(claim: Long): ByteArray?

    /** 1 = the ticket still exists for the CURRENT bound generation. */
    fun isLive(claim: Long): Int

    /** 1 = stop real work and STILL settle exactly once. */
    fun shouldStop(claim: Long): Int

    /** Settle one claim exactly once; 0 or a typed negative (never throws). */
    fun complete(claim: Long, status: Int, value: ByteArray): Int

    /** Exact-epoch teardown (generation retirement). */
    fun close(epoch: Long): Int

    /** Typed mailbox counters JSON (no targets, paths, ids or content). */
    fun stats(): ByteArray?

    /** Actual readiness/capability JSON (bound epoch + visible tool names). */
    fun readiness(): ByteArray?
}

/** Production transport: method-by-method delegation only. */
internal object NativeNetworkDiagnosticsTransport : NetworkDiagnosticsNativeTransport {
    override fun bindEpoch(epoch: Long): Int = NetworkDiagnosticsNative.bindEpoch(epoch)
    override fun next(timeoutMillis: Int): Long = NetworkDiagnosticsNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = NetworkDiagnosticsNative.describe(claim)
    override fun payload(claim: Long): ByteArray? = NetworkDiagnosticsNative.payload(claim)
    override fun isLive(claim: Long): Int = NetworkDiagnosticsNative.isLive(claim)
    override fun shouldStop(claim: Long): Int = NetworkDiagnosticsNative.shouldStop(claim)
    override fun complete(claim: Long, status: Int, value: ByteArray): Int =
        NetworkDiagnosticsNative.complete(claim, status, value)
    override fun close(epoch: Long): Int = NetworkDiagnosticsNative.close(epoch)
    override fun stats(): ByteArray? = NetworkDiagnosticsNative.stats()
    override fun readiness(): ByteArray? = NetworkDiagnosticsNative.readiness()
}
