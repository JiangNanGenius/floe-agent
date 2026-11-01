// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.bridge.MediaRenderNative
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.ClaimedRenderTicket
import com.floe.android.feature.workbench.MediaRenderTicketTransport
import com.floe.android.feature.workbench.RenderTicketDescriptor
import com.floe.android.feature.workbench.RenderTicketReply
import com.floe.android.feature.workbench.RenderTicketStats
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Typed refusal from the bounded render-ticket host lane. */
class MediaRenderTicketException(
    val code: String,
    val detail: String? = null,
) : Exception(detail?.let { "$code: $it" } ?: code)

/**
 * Injectable JNI seam so the transport discipline (claim/stop/heartbeat/
 * complete/close mapping) is unit-testable without loading the native library.
 */
internal interface MediaRenderNativeTransport {
    fun bindEpoch(epoch: Long): Int
    fun consumerHeartbeat(epoch: Long): Int
    fun consumerStop(epoch: Long): Int
    fun claim(timeoutMillis: Int): ByteArray?
    fun describe(ticketID: String): ByteArray?
    fun isLive(ticketID: String): Int
    fun shouldStop(ticketID: String, claimToken: String): Int
    fun heartbeat(ticketID: String, claimToken: String): Int
    fun complete(ticketID: String, claimToken: String, reply: ByteArray): Int
    fun close(ticketID: String, claimToken: String): Int
    fun stats(): ByteArray?
    fun rootStop(epoch: Long): Int
    fun drainPending(epoch: Long): Int
}

internal object JniMediaRenderNativeTransport : MediaRenderNativeTransport {
    override fun bindEpoch(epoch: Long) = MediaRenderNative.bindEpoch(epoch)
    override fun consumerHeartbeat(epoch: Long) = MediaRenderNative.consumerHeartbeat(epoch)
    override fun consumerStop(epoch: Long) = MediaRenderNative.consumerStop(epoch)
    override fun claim(timeoutMillis: Int) = MediaRenderNative.claim(timeoutMillis)
    override fun describe(ticketID: String) = MediaRenderNative.describe(ticketID)
    override fun isLive(ticketID: String) = MediaRenderNative.isLive(ticketID)
    override fun shouldStop(ticketID: String, claimToken: String) =
        MediaRenderNative.shouldStop(ticketID, claimToken)
    override fun heartbeat(ticketID: String, claimToken: String) =
        MediaRenderNative.heartbeat(ticketID, claimToken)
    override fun complete(ticketID: String, claimToken: String, reply: ByteArray) =
        MediaRenderNative.complete(ticketID, claimToken, reply)
    override fun close(ticketID: String, claimToken: String) =
        MediaRenderNative.close(ticketID, claimToken)
    override fun stats() = MediaRenderNative.stats()
    override fun rootStop(epoch: Long) = MediaRenderNative.rootStop(epoch)
    override fun drainPending(epoch: Long) = MediaRenderNative.drainPending(epoch)
}

/**
 * Kotlin adapter for the native-owned bounded render-ticket mailbox.
 *
 * It implements the frozen [MediaRenderTicketTransport] over the closed CABI:
 * claim on an independent IO worker (never the single creative exchange
 * lane), a required claim token on shouldStop/heartbeat/complete/close, and
 * exactly-once settlement. The descriptor/root/lease values are used exactly
 * as the native side issued them — this class never invents a project ID,
 * root, digest, snapshot path or receipt.
 */
internal class MediaRenderTicketNativeTransport(
    private val native: MediaRenderNativeTransport = JniMediaRenderNativeTransport,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : MediaRenderTicketTransport {

    /** Last non-ok native status for honest diagnostics (no content/paths). */
    @Volatile
    var lastStatus: Int = 0
        private set

    /** Exact epoch this transport bound; 0 when unbound. */
    @Volatile
    private var boundEpoch: Long = 0L

    override suspend fun bind(epoch: Long): Boolean = withContext(ioDispatcher) {
        if (epoch <= 0L) return@withContext false
        val status = native.bindEpoch(epoch)
        lastStatus = status
        if (status == 0) boundEpoch = epoch else boundEpoch = 0L
        status == 0
    }

    /**
     * Host-only consumer readiness proof. It is called by the platform owner
     * after the real claim loop starts and before every claim poll; a bind
     * alone never marks the renderer usable. Returns false when the native
     * generation is stale/fenced.
     */
    suspend fun markConsumerReady(epoch: Long): Boolean = withContext(ioDispatcher) {
        if (epoch <= 0L) return@withContext false
        val status = native.consumerHeartbeat(epoch)
        lastStatus = status
        status == 0
    }

    /** Stop refreshing the readiness lease for this exact transport. */
    suspend fun stopConsumer(epoch: Long): Boolean = withContext(ioDispatcher) {
        val ok = if (epoch > 0L) {
            runCatching { native.consumerStop(epoch) }.getOrDefault(-105) == 0
        } else {
            false
        }
        boundEpoch = 0L
        ok
    }

    override suspend fun claim(timeoutMillis: Long): ClaimedRenderTicket? =
        withContext(ioDispatcher) {
            // Refresh the bounded consumer lease on every real poll, so a
            // stalled consumer (not merely an old bind) hides media.project.
            val currentEpoch = boundEpoch
            if (currentEpoch > 0L) {
                runCatching { native.consumerHeartbeat(currentEpoch) }
            }
            val timeout = timeoutMillis.coerceIn(0L, 5000L).toInt()
            val bytes = native.claim(timeout) ?: return@withContext null
            try {
                R2MediaWire.decodeClaimed(bytes)
            } catch (error: CreativeException) {
                throw MediaRenderTicketException(
                    error.code, error.reason ?: "invalidClaimEnvelope")
            }
        }

    override suspend fun describe(ticketID: String): RenderTicketDescriptor? =
        withContext(ioDispatcher) {
            val bytes = native.describe(ticketID) ?: return@withContext null
            try {
                R2MediaWire.decodeDescriptorBytes(bytes)
            } catch (error: CreativeException) {
                throw MediaRenderTicketException(
                    error.code, error.reason ?: "invalidDescriptor")
            }
        }

    override fun isLive(ticketID: String): Boolean = native.isLive(ticketID) == 1

    override suspend fun shouldStop(ticketID: String, claimToken: String): Boolean =
        withContext(ioDispatcher) { native.shouldStop(ticketID, claimToken) == 1 }

    override suspend fun heartbeat(ticketID: String, claimToken: String): Boolean =
        withContext(ioDispatcher) {
            val status = native.heartbeat(ticketID, claimToken)
            lastStatus = status
            status == 0
        }

    override suspend fun complete(
        ticketID: String,
        claimToken: String,
        reply: RenderTicketReply,
    ): Boolean = withContext(ioDispatcher) {
        val body = try {
            R2MediaWire.encodeReply(reply)
        } catch (error: Throwable) {
            throw MediaRenderTicketException("invalidReply", "replyEncodeFailed")
        }
        if (body.size > 1024 * 1024) {
            throw MediaRenderTicketException("responseTooLarge", "replyTooLarge")
        }
        val status = native.complete(ticketID, claimToken, body)
        lastStatus = status
        status == 0
    }

    override suspend fun close(ticketID: String, claimToken: String) {
        val status = withContext(ioDispatcher) { native.close(ticketID, claimToken) }
        lastStatus = status
    }

    override suspend fun stats(): RenderTicketStats = withContext(ioDispatcher) {
        val bytes = native.stats()
            ?: throw MediaRenderTicketException("rendererUnavailable", "statsUnavailable")
        try {
            R2MediaWire.decodeStats(bytes)
        } catch (error: CreativeException) {
            throw MediaRenderTicketException(
                error.code, error.reason ?: "invalidStats")
        }
    }

    /**
     * Phase-1 root stop. TRUE = drained (safe to retire Root); FALSE = the
     * platform still owns claimed/queued tickets and must cancel/ack them
     * with their claim tokens. Never reports drained before real settlement.
     */
    suspend fun beginRootStop(epoch: Long): Boolean = withContext(ioDispatcher) {
        native.rootStop(epoch) == 0
    }

    suspend fun drainPending(epoch: Long): Int = withContext(ioDispatcher) {
        native.drainPending(epoch)
    }
}
