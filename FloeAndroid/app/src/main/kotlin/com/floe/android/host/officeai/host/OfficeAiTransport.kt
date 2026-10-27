// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai

import com.floe.android.bridge.OfficeAiNative

/**
 * The pump's transport seam over the delivered [com.floe.android.bridge.OfficeAiNative]
 * declarations (READ-ONLY: the C ABI, JNI TU and the Kotlin declarations are
 * frozen by the terminal source-15 batch). One interface lets the serialized
 * epoch pump run against the real mailbox in production and against a
 * scripted transport in the JVM regressions — the pump coordinates with the
 * EXACT production settlement logic either way.
 *
 * Status space (mirrors the Swift exports): 0 ok; negative typed refusals
 * (-101 stale claim, -102 generation fenced, -105 shape, -106 buffer,
 * -107 oversize, -108 descriptor invalid, -110 claim not claimed).
 * A negative [complete] is a terminal classification: the claim was already
 * settled or fenced by the mailbox, and the pump NEVER retries or
 * double-settles.
 */
internal interface OfficeAiNativeTransport {
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

    /** Typed mailbox counters JSON (no paths, bytes, identities or content). */
    fun stats(): ByteArray?
}

/** The production transport. Method-by-method delegation only — no logic. */
internal object NativeOfficeAiTransport : OfficeAiNativeTransport {
    override fun bindEpoch(epoch: Long): Int = OfficeAiNative.bindEpoch(epoch)
    override fun next(timeoutMillis: Int): Long = OfficeAiNative.next(timeoutMillis)
    override fun describe(claim: Long): ByteArray? = OfficeAiNative.describe(claim)
    override fun payload(claim: Long): ByteArray? = OfficeAiNative.payload(claim)
    override fun isLive(claim: Long): Int = OfficeAiNative.isLive(claim)
    override fun shouldStop(claim: Long): Int = OfficeAiNative.shouldStop(claim)
    override fun complete(claim: Long, status: Int, value: ByteArray): Int =
        OfficeAiNative.complete(claim, status, value)

    override fun close(epoch: Long): Int = OfficeAiNative.close(epoch)
    override fun stats(): ByteArray? = OfficeAiNative.stats()
}
