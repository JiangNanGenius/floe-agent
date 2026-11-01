// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture.root

import android.content.Context
import androidx.annotation.Keep
import com.floe.android.core.networkcapture.CaptureLimits
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
import com.floe.android.rootsystem.server.RootCaptureHelper
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Full-only genuine root capture adapter.
 *
 * The executable is the packaged, digest-verified helper from this signed
 * Full APK (see [RootCaptureHelper]); no arbitrary path/URL/command is used.
 * A natural helper end is reported only after every byte was read and the
 * client/process/file owner settled. A stop timeout keeps the same client and
 * capture id alive so the next RootStop retries the real drain before Root can
 * retire.
 */
@Keep
class FullRootCaptureBackend(
    context: Context,
) : RootCaptureBackend {

    private val appContext = context.applicationContext ?: context
    private val lock = Any()
    private val cancelled = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private val clientRef = AtomicReference<RootPacketCaptureClient?>(null)
    private val activeCapture = AtomicReference<String?>(null)
    private val chunkSink = AtomicReference<((ByteArray, Int, Int) -> Unit)?>(null)
    private val counterRef = AtomicReference(PcapRecordCounter())
    private val endReason = AtomicReference<String?>(null)

    /**
     * True between publishing the client and the start loop returning. A stop
     * must never claim `drainProven` while a start may still publish its
     * capture id; the next attempt joins/stops that exact client.
     */
    private val startInFlight = AtomicBoolean(false)
    @Volatile
    private var helperStatus: RootCaptureHelper.Status? = null

    private fun helper(): RootCaptureHelper.Status =
        helperStatus ?: RootCaptureHelper.appPreflight(appContext).also { helperStatus = it }

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
        val helper = helper()
        if (!helper.available) {
            return RootCaptureAvailability.unavailable(
                helper.code ?: "helperUnavailable",
                helper.message ?: "The verified root capture helper is not packaged.",
            )
        }
        return RootCaptureAvailability(
            available = true,
            helperId = RootPacketCaptureClient.HELPER_ID,
            helperPath = helper.path?.takeIf { it.length <= 256 },
            helperSha256 = helper.sha256,
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
        val helper = helper()
        if (!helper.available) {
            return RootCaptureStart.Unavailable(helper.code ?: "helperUnavailable")
        }
        synchronized(lock) {
            if (clientRef.get() != null) return RootCaptureStart.Failed("capture_active")
            // A stop issued for THIS start is handled by the stop() attempt and
            // by the service's start-job join; this reset must not carry a
            // previous capture's stop flag into a new explicit start.
            cancelled.set(false)
            stopRequested.set(false)
            endReason.set(null)
            counterRef.set(PcapRecordCounter())
            chunkSink.set(onChunk)
            startInFlight.set(true)
        }
        try {
            val owner = request.owner
            val taskID = owner.taskId ?: ("ui-capture:" + owner.ownerId.take(96))
            val runID = owner.runId ?: ("ui-capture-run:" + owner.ownerId.take(96))
            val client = RootPacketCaptureClient(
                taskId = taskID,
                runId = runID,
                epoch = owner.nativeEpoch,
                admission = object : RootPacketCaptureClient.Admission {
                    // A normal stop keeps the grant alive for the tail drain;
                    // only an explicit close/revoke is a hard cancellation
                    // fence.
                    override fun allowStart(): Boolean = !cancelled.get()
                    override fun isCancelled(): Boolean = cancelled.get()
                },
            )
            clientRef.set(client)
            val started = client.start(
                helperId = request.helper.id,
                interfaceName = request.interfaceName,
                snaplen = CaptureLimits.SNAPLEN,
                maxBytes = request.config.maxBytes,
                maxMillis = request.config.maxDurationMillis,
            )
            val info = when (started) {
                is RootResult.Ok<*> -> started.value as? com.floe.android.rootsystem.PacketCaptureInfo
                    ?: return failAndClose(client, "capture_reply")
                is RootResult.Denied -> return failAndClose(client, started.code)
                is RootResult.Unavailable -> return failAndClose(client, started.code)
                is RootResult.Failed -> return failAndClose(client, started.code)
            }
            activeCapture.set(info.captureId)
            if (stopRequested.get() || cancelled.get()) {
                // The service will call stop(); keep the client/capture id so
                // the drain can read the tail and prove the process exit.
                return RootCaptureStart.Started
            }
            while (true) {
                if (stopRequested.get() || cancelled.get()) {
                    // A stop request owns the drain from here. Do not close or
                    // revoke the client under RootPacketCaptureService.
                    return RootCaptureStart.Started
                }
                when (val chunk = client.read(info.captureId)) {
                    is RootResult.Ok<*> -> {
                        val value: PacketCaptureChunk = chunk.value as? PacketCaptureChunk
                            ?: return failAndClose(client, "capture_reply")
                        if (value.bytes.isNotEmpty()) {
                            writeChunk(value.bytes)
                        }
                        value.endReason?.let { endReason.set(it) }
                        val progress = progress(value.endReason?.let(::captureReason))
                        onProgress(progress)
                        if (value.done) {
                            activeCapture.set(null)
                            runCatching { client.close() }
                            clientRef.compareAndSet(client, null)
                            chunkSink.set(null)
                            return RootCaptureStart.Completed(progress.copy(drainProven = true))
                        }
                    }
                    is RootResult.Denied -> {
                        if (cancelled.get()) return RootCaptureStart.Started
                        return failAndClose(client, chunk.code)
                    }
                    is RootResult.Unavailable -> {
                        if (cancelled.get()) return RootCaptureStart.Started
                        return failAndClose(client, chunk.code)
                    }
                    is RootResult.Failed -> return failAndClose(client, chunk.code)
                }
                delay(100L)
            }
        } catch (_: CancellationException) {
            // Service scope destruction: the retained drain owns the exact
            // client/capture id; keep the chunk sink and grant untouched.
            return RootCaptureStart.Started
        } catch (_: Throwable) {
            val client = clientRef.get()
            return if (client != null) {
                failAndClose(client, "capture_io")
            } else {
                RootCaptureStart.Failed("capture_io")
            }
        } finally {
            startInFlight.set(false)
        }
    }

    /**
     * Stop and drain the exact capture started above. Returns only after the
     * server proves process exit and all remaining bytes were consumed (or a
     * real timeout, in which case the client/capture id stay owned).
     */
    override suspend fun stop(): RootCaptureProgress {
        // Request stop/drain without flipping the hard cancellation fence:
        // the client must still be allowed to read the helper's tail bytes.
        stopRequested.set(true)
        val client = clientRef.get()
        val captureId = activeCapture.get()
        if (client == null) {
            // No client exists. A start loop that has not returned yet may
            // still publish one, so this is not a proven drain.
            return progress(endReason.get()?.let(::captureReason))
                .copy(drainProven = !startInFlight.get())
        }
        if (captureId == null) {
            // The client exists but its start reply/capture id is still in
            // flight. Keep the same client; the next attempt stops it.
            return progress(endReason.get()?.let(::captureReason)).copy(drainProven = false)
        }
        val stopped = withTimeoutOrNull(CAPTURE_STOP_BUDGET_MILLIS) {
            when (val result = client.stop(captureId)) {
                is RootResult.Ok<*> -> {
                    val chunk = result.value as? PacketCaptureChunk
                    if (chunk != null) {
                        chunk.endReason?.let { endReason.set(it) }
                        if (chunk.done) {
                            drainCompleted(client)
                            return@withTimeoutOrNull true
                        }
                    }
                }
                is RootResult.Denied -> return@withTimeoutOrNull false
                is RootResult.Unavailable -> return@withTimeoutOrNull false
                is RootResult.Failed -> return@withTimeoutOrNull false
            }
            // `-U` tcpdump can write the final records between the last read
            // and stop. Read until the server reports done, which is only
            // after the helper process is dead and the file was fully read.
            while (true) {
                val chunk = client.read(captureId)
                when (chunk) {
                    is RootResult.Ok<*> -> {
                        val value = chunk.value as? PacketCaptureChunk ?: break
                        if (value.bytes.isNotEmpty()) writeChunk(value.bytes)
                        value.endReason?.let { endReason.set(it) }
                        if (value.done) {
                            drainCompleted(client)
                            return@withTimeoutOrNull true
                        }
                    }
                    is RootResult.Denied -> break
                    is RootResult.Unavailable -> break
                    is RootResult.Failed -> break
                }
                delay(100L)
            }
            false
        }
        val result = progress(endReason.get()?.let(::captureReason))
        if (stopped == true) return result.copy(drainProven = true)
        // Keep clientRef/activeCapture: the same process/session is retried by
        // a later stop; the staging artifact remains open to the service.
        return result.copy(drainProven = false)
    }

    override fun close() {
        cancelled.set(true)
        val client = clientRef.getAndSet(null)
        activeCapture.set(null)
        chunkSink.set(null)
        runCatching { client?.close() }
    }

    private fun drainCompleted(client: RootPacketCaptureClient) {
        activeCapture.set(null)
        clientRef.compareAndSet(client, null)
        chunkSink.set(null)
        runCatching { client.close() }
    }

    private fun writeChunk(bytes: ByteArray) {
        val sink = chunkSink.get() ?: return
        val counter = counterRef.get()
        synchronized(counter) {
            sink(bytes, 0, bytes.size)
            counter.consume(bytes, 0, bytes.size)
        }
    }

    private fun progress(reason: com.floe.android.core.networkcapture.CaptureEndReason?): RootCaptureProgress {
        val counter = counterRef.get()
        return synchronized(counter) {
            RootCaptureProgress(
                bytes = counter.bytes,
                packets = counter.packets,
                malformed = counter.isMalformed,
                endReason = reason,
            )
        }
    }

    private fun failAndClose(client: RootPacketCaptureClient, code: String): RootCaptureStart {
        // Once a real capture id exists, the helper may still own its process
        // and output. Keep the client for RootPacketCaptureService.stop() so
        // the drain can prove the exit; never close/revoke under a live helper.
        if (activeCapture.get() != null) {
            return if (code.startsWith("root") || code.startsWith("service")) {
                RootCaptureStart.Unavailable(code)
            } else {
                RootCaptureStart.Failed(code)
            }
        }
        chunkSink.set(null)
        clientRef.compareAndSet(client, null)
        runCatching { client.close() }
        return if (code.startsWith("root") || code.startsWith("service")) {
            RootCaptureStart.Unavailable(code)
        } else {
            RootCaptureStart.Failed(code)
        }
    }

    private fun captureReason(wire: String): com.floe.android.core.networkcapture.CaptureEndReason = when (wire) {
        "sizeLimit" -> com.floe.android.core.networkcapture.CaptureEndReason.SIZE_LIMIT
        "durationLimit" -> com.floe.android.core.networkcapture.CaptureEndReason.DURATION_LIMIT
        "userStop" -> com.floe.android.core.networkcapture.CaptureEndReason.USER_STOP
        "cancelled" -> com.floe.android.core.networkcapture.CaptureEndReason.USER_STOP
        "serviceStop" -> com.floe.android.core.networkcapture.CaptureEndReason.SERVICE_DESTROYED
        "stopTimeout" -> com.floe.android.core.networkcapture.CaptureEndReason.STOP_TIMEOUT
        else -> com.floe.android.core.networkcapture.CaptureEndReason.DATA_PLANE_ERROR
    }

    private companion object {
        /** Stop destroy/wait + tail read must fit inside this real budget. */
        const val CAPTURE_STOP_BUDGET_MILLIS = 12_000L
    }
}
