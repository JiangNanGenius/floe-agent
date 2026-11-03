// SPDX-License-Identifier: MPL-2.0
//
// Trusted RDP binary framebuffer transport. Declarations only: the Swift side
// owns the immutable frame and the epoch/owner fence. Metadata is bounded
// JSON; pixels are copied page-by-page into a Kotlin ByteArray (never base64
// and never a raw pointer held across the JNI boundary).

package com.floe.android.host.rdp

import com.floe.android.host.remote.boolValue
import com.floe.android.host.remote.intValue
import com.floe.android.host.remote.longValue
import com.floe.android.host.remote.requiredString
import com.floe.android.host.remote.string
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject

internal interface C05RDPVideoTransport {
    fun acquire(epoch: Long, ownerToken: String, sessionID: String): ByteArray?
    fun read(
        epoch: Long,
        leaseID: String,
        offset: Long,
        target: ByteArray,
        targetOffset: Int,
        length: Int,
    ): Int
    fun release(epoch: Long, leaseID: String): Int
}

internal object C05RDPVideoNative : C05RDPVideoTransport {
    init { System.loadLibrary("floe_jni") }

    override fun acquire(epoch: Long, ownerToken: String, sessionID: String): ByteArray? =
        nativeAcquire(epoch, ownerToken, sessionID)

    override fun read(
        epoch: Long,
        leaseID: String,
        offset: Long,
        target: ByteArray,
        targetOffset: Int,
        length: Int,
    ): Int = nativeRead(epoch, leaseID, offset, target, targetOffset, length)

    override fun release(epoch: Long, leaseID: String): Int = nativeRelease(epoch, leaseID)

    private external fun nativeAcquire(
        epoch: Long,
        ownerToken: String,
        sessionID: String,
    ): ByteArray?

    private external fun nativeRead(
        epoch: Long,
        leaseID: String,
        offset: Long,
        target: ByteArray,
        targetOffset: Int,
        length: Int,
    ): Int

    private external fun nativeRelease(epoch: Long, leaseID: String): Int
}

internal fun C05RDPVideoTransport.acquireFrame(
    epoch: Long,
    ownerToken: String,
    sessionID: String,
): C05RdpFrameMeta? {
    val raw = acquire(epoch, ownerToken, sessionID) ?: return null
    return try {
        val objectValue = Json.parseToJsonElement(String(raw, Charsets.UTF_8)).jsonObject
        if (!objectValue.boolValue("ok")) return null
        C05RdpFrameMeta(
            leaseID = objectValue.requiredString("leaseID"),
            sessionID = objectValue.string("sessionID") ?: sessionID,
            width = objectValue.intValue("width") ?: 0,
            height = objectValue.intValue("height") ?: 0,
            stride = objectValue.intValue("stride") ?: 0,
            format = objectValue.string("format") ?: "RGBA8888",
            byteCount = objectValue.intValue("byteCount") ?: 0,
            revision = objectValue.longValue("revision") ?: 0L,
        ).takeIf {
            it.width > 0 && it.height > 0 && it.stride == it.width * 4 &&
                it.byteCount == it.width * it.height * 4 &&
                it.byteCount <= C05_RDP_MAX_FRAME_BYTES
        }
    } catch (_: Throwable) {
        null
    }
}

internal fun C05RDPVideoTransport.releaseQuietly(epoch: Long, leaseID: String) {
    runCatching { release(epoch, leaseID) }
}

internal const val C05_RDP_MAX_FRAME_BYTES = 33_554_432
internal const val C05_RDP_MAX_PAGE_BYTES = 64 * 1024
