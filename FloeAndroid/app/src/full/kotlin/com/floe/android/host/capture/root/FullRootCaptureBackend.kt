// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture.root

import android.content.Context
import androidx.annotation.Keep
import com.floe.android.core.networkcapture.PcapRecordCounter
import com.floe.android.core.networkcapture.RootCaptureAvailability
import com.floe.android.core.networkcapture.RootCaptureBackend
import com.floe.android.core.networkcapture.RootCaptureProgress
import com.floe.android.core.networkcapture.RootCaptureRequest
import com.floe.android.core.networkcapture.RootCaptureStart
import com.floe.android.rootsystem.PacketCaptureChunk
import com.floe.android.rootsystem.RootResult
import com.floe.android.rootsystem.RootStatus
import com.floe.android.rootsystem.RootSystemModule
import com.floe.android.rootsystem.ipc.RootPacketCaptureClient
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay

/**
 * Full-only genuine root capture adapter.
 *
 * It uses the existing Floe root broker publication and its typed PACKET_CAPTURE
 * operation. It does not use a generic shell, Shizuku manager, `su -c`, Linux
 * guest or arbitrary executable. The helper id is closed (`tcpdump-v1`) and the
 * server requires UID 0 plus a pinned executable in a fixed location.
 *
 * Play has no this class and therefore no root implementation at all; the host
 * loader returns null and reports `playBuild`.
 */
@Keep
class FullRootCaptureBackend(
    context: Context,
) : RootCaptureBackend {

    private val appContext = context.applicationContext ?: context
    private val cancelled = AtomicBoolean(false)
    private val clientRef = AtomicReference<RootPacketCaptureClient?>(null)
    private val activeCapture = AtomicReference<String?>(null)
    private val counter = PcapRecordCounter()
    private val endReason = AtomicReference<String?>(null)

    override fun availability(): RootCaptureAvailability {
        val root = RootSystemModule.rootStatus.value
        if (root !is RootStatus.Enabled) {
            return RootCaptureAvailability.unavailable(
                "rootNotEnabled",
                "Enable Root access in Device access before starting root capture.",
            )
        }
        if (!RootPacketCaptureClient.isRootServicePublished()) {
            return RootCaptureAvailability.unavailable(
                "rootServiceNotAlive",
                "The Full root service is not running. Start it from Device access.",
            )
        }
        return RootCaptureAvailability(
            available = true,
            helperId = RootPacketCaptureClient.HELPER_ID,
            effectiveUid = 0,
        )
    }

    override suspend fun start(
        request: RootCaptureRequest,
        onChunk: (ByteArray, Int, Int) -> Unit,
        onProgress: (RootCaptureProgress) -> Unit,
    ): RootCaptureStart {
        if (RootSystemModule.rootStatus.value !is RootStatus.Enabled) {
            return RootCaptureStart.Unavailable("rootNotEnabled")
        }
        if (!RootPacketCaptureClient.isRootServicePublished()) {
            return RootCaptureStart.Unavailable("rootServiceNotAlive")
        }
        val owner = request.owner
        val taskID = owner.taskId ?: ("ui-capture:" + owner.ownerId.take(96))
        val runID = owner.runId ?: ("ui-capture-run:" + owner.ownerId.take(96))
        val client = RootPacketCaptureClient(
            taskId = taskID,
            runId = runID,
            epoch = owner.nativeEpoch,
            admission = object : RootPacketCaptureClient.Admission {
                override fun allowStart(): Boolean = !cancelled.get()
                override fun isCancelled(): Boolean = cancelled.get()
            },
        )
        clientRef.set(client)
        val started = client.start(
            helperId = request.helper.id,
            interfaceName = request.interfaceName,
            snaplen = 65_535,
            maxBytes = request.config.maxBytes,
            maxMillis = request.config.maxDurationMillis,
        )
        val info = when (started) {
            is RootResult.Ok<*> -> started.value as? com.floe.android.rootsystem.PacketCaptureInfo
                ?: return RootCaptureStart.Failed("capture_reply")
            is RootResult.Denied -> {
                client.close()
                clientRef.compareAndSet(client, null)
                return RootCaptureStart.Unavailable(started.code)
            }
            is RootResult.Unavailable -> {
                client.close()
                clientRef.compareAndSet(client, null)
                return RootCaptureStart.Unavailable(started.code)
            }
            is RootResult.Failed -> {
                client.close()
                clientRef.compareAndSet(client, null)
                return RootCaptureStart.Failed(started.code)
            }
        }
        activeCapture.set(info.captureId)
        if (cancelled.get()) {
            client.stop(info.captureId)
            client.close()
            clientRef.compareAndSet(client, null)
            activeCapture.set(null)
            return RootCaptureStart.Started
        }
        try {
            while (!cancelled.get()) {
                when (val chunk = client.read(info.captureId)) {
                    is RootResult.Ok<*> -> {
                        val value: PacketCaptureChunk = chunk.value as? PacketCaptureChunk
                            ?: return RootCaptureStart.Failed("capture_reply")
                        if (value.bytes.isNotEmpty()) {
                            synchronized(counter) {
                                counter.consume(value.bytes, 0, value.bytes.size)
                            }
                            onChunk(value.bytes, 0, value.bytes.size)
                        }
                        value.endReason?.let { endReason.set(it) }
                        val progress = synchronized(counter) {
                            RootCaptureProgress(
                                bytes = counter.bytes,
                                packets = counter.packets,
                                malformed = counter.isMalformed,
                                endReason = value.endReason?.let(::captureReason),
                            )
                        }
                        onProgress(progress)
                        if (value.done) break
                    }
                    is RootResult.Denied -> {
                        if (cancelled.get()) break
                        return RootCaptureStart.Failed(chunk.code)
                    }
                    is RootResult.Unavailable -> {
                        if (cancelled.get()) break
                        return RootCaptureStart.Unavailable(chunk.code)
                    }
                    is RootResult.Failed -> {
                        client.close()
                        clientRef.compareAndSet(client, null)
                        return RootCaptureStart.Failed(chunk.code)
                    }
                }
                delay(100L)
            }
            return RootCaptureStart.Started
        } finally {
            if (cancelled.get()) {
                runCatching { client.stop(info.captureId) }
            }
            runCatching { client.close() }
            clientRef.compareAndSet(client, null)
            activeCapture.set(null)
        }
    }

    override suspend fun stop(): RootCaptureProgress {
        cancelled.set(true)
        val client = clientRef.getAndSet(null)
        val captureId = activeCapture.getAndSet(null)
        if (client != null && captureId != null) {
            when (val result = client.stop(captureId)) {
                is RootResult.Ok<*> -> (result.value as? PacketCaptureChunk)
                    ?.endReason?.let { endReason.set(it) }
                else -> Unit
            }
            client.close()
        }
        val progress = synchronized(counter) {
            RootCaptureProgress(
                bytes = counter.bytes,
                packets = counter.packets,
                malformed = counter.isMalformed,
                endReason = endReason.get()?.let(::captureReason),
            )
        }
        return progress
    }

    override fun close() {
        cancelled.set(true)
        clientRef.getAndSet(null)?.close()
        activeCapture.set(null)
    }

    private fun captureReason(wire: String): com.floe.android.core.networkcapture.CaptureEndReason = when (wire) {
        "sizeLimit" -> com.floe.android.core.networkcapture.CaptureEndReason.SIZE_LIMIT
        "durationLimit" -> com.floe.android.core.networkcapture.CaptureEndReason.DURATION_LIMIT
        "userStop" -> com.floe.android.core.networkcapture.CaptureEndReason.USER_STOP
        "cancelled" -> com.floe.android.core.networkcapture.CaptureEndReason.USER_STOP
        "serviceStop" -> com.floe.android.core.networkcapture.CaptureEndReason.SERVICE_DESTROYED
        else -> com.floe.android.core.networkcapture.CaptureEndReason.DATA_PLANE_ERROR
    }
}
