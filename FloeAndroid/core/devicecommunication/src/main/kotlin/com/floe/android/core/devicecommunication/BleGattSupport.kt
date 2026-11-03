// SPDX-License-Identifier: MPL-2.0
//
// Pure BLE GATT bounds and single-flight fencing. Android callbacks arrive on
// binder threads and may be delivered after a disconnect/reconnect; every
// session increments a generation on close and ignores a callback whose
// generation is no longer current. Writes are chunked to the negotiated
// ATT payload (MTU - 3) and the whole call is bounded before any byte is sent.

package com.floe.android.core.devicecommunication

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

data class BleWritePlan(
    val payloadLimit: Int,
    val chunks: List<ByteArray>,
) {
    val totalBytes: Int get() = chunks.sumOf { it.size }
}

object BleGattBounds {
    const val ATT_HEADER_BYTES = 3
    const val MINIMUM_PAYLOAD = 20
    const val MAXIMUM_PAYLOAD = 512
    const val MAXIMUM_CHUNKS = 64

    fun payloadLimit(mtu: Int): Int {
        val usable = mtu.coerceIn(
            DeviceLimits.BLE_DEFAULT_MTU,
            DeviceLimits.BLE_MAXIMUM_MTU,
        ) - ATT_HEADER_BYTES
        return usable.coerceIn(MINIMUM_PAYLOAD, MAXIMUM_PAYLOAD)
    }

    /** Splits a write into exact chunks. Refuses (never truncates) a write
     * over the total or chunk allowance. */
    fun planWrite(
        data: ByteArray,
        mtu: Int,
        maximumTotal: Int = DeviceLimits.MAXIMUM_BLE_WRITE_TOTAL,
    ): BleWritePlan {
        if (data.isEmpty()) throw invalid("Enter data to send.")
        if (data.size > maximumTotal) {
            throw invalid("A BLE write is limited to ${maximumTotal / 1024} KiB.")
        }
        val limit = payloadLimit(mtu)
        val chunkCount = (data.size + limit - 1) / limit
        if (chunkCount > MAXIMUM_CHUNKS) {
            throw invalid("A BLE write is limited to $MAXIMUM_CHUNKS chunks.")
        }
        val chunks = ArrayList<ByteArray>(chunkCount)
        var offset = 0
        while (offset < data.size) {
            val length = minOf(limit, data.size - offset)
            chunks.add(data.copyOfRange(offset, offset + length))
            offset += length
        }
        return BleWritePlan(payloadLimit = limit, chunks = chunks)
    }

    /** Notification body validation: Android may deliver a larger assembly
     * than the configured MTU on some stacks; the queue still bounds it. */
    fun notificationCopy(value: ByteArray?): ByteArray? =
        value?.takeIf { it.isNotEmpty() }?.copyOf()

    private fun invalid(message: String) = DeviceCommunicationException(
        DeviceErrorCode.INVALID_REQUEST,
        message,
    )
}

class GenerationFence(initial: Long = 0L) {
    private val current = AtomicLong(initial)

    fun next(): Long = current.incrementAndGet()

    fun isCurrent(generation: Long): Boolean = current.get() == generation
}

/**
 * Serializes GATT operations for ONE connection. A second caller waits at
 * most [timeoutMillis]; it never runs a read/write concurrently with another
 * GATT operation on the same connection. The generation is checked before and
 * after the lock so a queued operation cannot run on a closed/reconnected
 * session.
 */
class BleOperationSerializer(private val timeoutMillis: Long = DeviceLimits.BLE_OPERATION_TIMEOUT_MILLIS) {
    private val mutex = Mutex()

    suspend fun <T> run(
        generation: Long,
        fence: GenerationFence,
        block: suspend () -> T,
    ): T {
        if (!fence.isCurrent(generation)) throw stale()
        val locked = withTimeoutOrNull(timeoutMillis) {
            mutex.withLock {
                if (!fence.isCurrent(generation)) throw stale()
                block()
            }
        }
        return locked ?: throw DeviceCommunicationException(
            DeviceErrorCode.OPERATION_BUSY,
            "Another Bluetooth operation did not finish. Try again.",
            retryable = true,
        )
    }

    private fun stale() = DeviceCommunicationException(
        DeviceErrorCode.SESSION_NOT_FOUND,
        "The Bluetooth connection is no longer current.",
    )
}
