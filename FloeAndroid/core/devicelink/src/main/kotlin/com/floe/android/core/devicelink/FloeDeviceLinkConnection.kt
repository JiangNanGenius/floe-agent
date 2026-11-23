// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import com.floe.android.core.devicelink.FloeDeviceLinkException.Reason
import computer.iroh.Connection
import computer.iroh.RecvStream
import computer.iroh.SendStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class FloeDeviceLinkPath(
    val kind: Kind,
    val isSelected: Boolean,
    val roundTripMilliseconds: ULong,
    val bytesSent: ULong,
    val bytesReceived: ULong,
) {
    enum class Kind { DIRECT, RELAY, UNKNOWN }
}

/** An authenticated QUIC connection. A request and its response share one bidirectional stream. */
class FloeDeviceLinkConnection internal constructor(
    private val connection: Connection,
    val peerEndpointId: String,
) : AutoCloseable {
    private val closed = AtomicBoolean()

    /** Reports live path selection without exposing the peer's network addresses. */
    fun paths(): List<FloeDeviceLinkPath> = connection.paths().map { path ->
        val kind = when {
            path.isRelay -> FloeDeviceLinkPath.Kind.RELAY
            path.isIp -> FloeDeviceLinkPath.Kind.DIRECT
            else -> FloeDeviceLinkPath.Kind.UNKNOWN
        }
        FloeDeviceLinkPath(
            kind = kind,
            isSelected = path.isSelected,
            roundTripMilliseconds = path.rttMs,
            bytesSent = path.stats.udpTxBytes,
            bytesReceived = path.stats.udpRxBytes,
        )
    }

    suspend fun request(payload: ByteArray): ByteArray {
        validatePayload(payload)
        return perform {
            connection.openBi().use { stream ->
                stream.send().use { write(payload, it) }
                stream.recv().use { read(it) }
            }
        }
    }

    suspend fun receiveRequest(): FloeDeviceLinkRequest = perform {
        connection.acceptBi().use { stream ->
            val payload = stream.recv().use { read(it) }
            FloeDeviceLinkRequest(payload, stream.send(), this)
        }
    }

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            connection.use { it.close(0, ByteArray(0)) }
        }
    }

    // Match the Swift contract: cancellation ends the connection. The host can reconnect and reconcile.
    internal suspend fun <T> perform(operation: suspend () -> T): T {
        currentCoroutineContext().ensureActive()
        try {
            return operation()
        } catch (error: Exception) {
            if (error is CancellationException) runCatching { close() }
            throw error
        }
    }

    companion object {
        const val MAXIMUM_PAYLOAD_BYTES = 1_048_576

        internal fun validatePayload(payload: ByteArray) {
            if (payload.isEmpty()) throw FloeDeviceLinkException(Reason.EMPTY_PAYLOAD)
            if (payload.size > MAXIMUM_PAYLOAD_BYTES) throw FloeDeviceLinkException(Reason.PAYLOAD_TOO_LARGE)
        }

        internal suspend fun write(payload: ByteArray, sender: SendStream) {
            sender.writeAll(payload)
            sender.finish()
        }

        private suspend fun read(receiver: RecvStream): ByteArray =
            receiver.readToEnd(MAXIMUM_PAYLOAD_BYTES.toUInt()).also(::validatePayload)
    }
}

/** One incoming request. Respond once or close to abandon the response. */
class FloeDeviceLinkRequest internal constructor(
    val payload: ByteArray,
    private val sender: SendStream,
    private val connection: FloeDeviceLinkConnection,
) : AutoCloseable {
    private val used = AtomicBoolean()

    suspend fun respond(payload: ByteArray) {
        FloeDeviceLinkConnection.validatePayload(payload)
        if (!used.compareAndSet(false, true)) throw FloeDeviceLinkException(Reason.RESPONSE_ALREADY_USED)
        sender.use { connection.perform { FloeDeviceLinkConnection.write(payload, it) } }
    }

    override fun close() {
        if (used.compareAndSet(false, true)) sender.close()
    }
}
