// SPDX-License-Identifier: MPL-2.0
//
// Owner/epoch-bounded session table. The transport is attached by the engine
// after registration; this class is intentionally free of Android/service
// types so the ownership and limit contract is testable on the JVM.

package com.floe.android.core.devicecommunication

import java.util.UUID

internal class DeviceSessionRecord(
    val id: String,
    val owner: DeviceOwner,
    val protocol: DeviceProtocol,
    val endpoint: String,
    val createdAtMillis: Long,
    val generation: Long,
) {
    @Volatile var lastActivityMillis: Long = createdAtMillis
    @Volatile var state: DeviceSessionState = DeviceSessionState.CONNECTING
    @Volatile var errorCode: String? = null
    @Volatile var errorDetail: String? = null
    @Volatile var bytesIn: Long = 0
    @Volatile var bytesOut: Long = 0
    @Volatile var bleServiceUuid: String? = null
    @Volatile var bleMtu: Int? = null
    @Volatile var notificationSubscribed: Boolean = false
    @Volatile var usbVendorId: Int? = null
    @Volatile var usbProductId: Int? = null
    @Volatile var usbSerial: String? = null
    @Volatile var bleAddress: String? = null
    @Volatile var usbDeviceName: String? = null

    @Synchronized
    fun addBytesIn(count: Long) {
        bytesIn += count
    }

    @Synchronized
    fun addBytesOut(count: Long) {
        bytesOut += count
    }

    fun snapshot(): DeviceSessionSnapshot = DeviceSessionSnapshot(
        id = id,
        protocol = protocol,
        endpoint = endpoint,
        state = state,
        bytesIn = bytesIn,
        bytesOut = bytesOut,
        createdAtMillis = createdAtMillis,
        lastActivityMillis = lastActivityMillis,
        errorCode = errorCode,
        errorDetail = errorDetail,
        bleServiceUuid = bleServiceUuid,
        bleMtu = bleMtu,
        notificationSubscribed = notificationSubscribed,
        usbVendorId = usbVendorId,
        usbProductId = usbProductId,
        usbSerial = usbSerial,
    )
}

internal class DeviceSessionRegistry(
    private val maximumSessions: Int = DeviceLimits.MAXIMUM_SESSIONS,
) {
    private val sessions = LinkedHashMap<String, DeviceSessionRecord>()
    private var generationCounter = 0L

    @Synchronized
    fun register(
        owner: DeviceOwner,
        protocol: DeviceProtocol,
        endpoint: String,
        nowMillis: Long,
    ): DeviceSessionRecord {
        if (sessions.size >= maximumSessions) {
            throw DeviceCommunicationException(
                DeviceErrorCode.SESSION_LIMIT,
                "Close an active device session first.",
            )
        }
        generationCounter += 1
        val record = DeviceSessionRecord(
            id = UUID.randomUUID().toString(),
            owner = owner,
            protocol = protocol,
            endpoint = endpoint,
            createdAtMillis = nowMillis,
            generation = generationCounter,
        )
        sessions[record.id] = record
        return record
    }

    @Synchronized
    fun require(sessionId: String, owner: DeviceOwner, currentEpoch: Long): DeviceSessionRecord {
        val record = sessions[sessionId] ?: throw DeviceCommunicationException(
            DeviceErrorCode.SESSION_NOT_FOUND,
            "The device session is no longer open.",
        )
        if (record.owner.token != owner.token || record.owner.nativeEpoch != owner.nativeEpoch) {
            throw DeviceCommunicationException(
                DeviceErrorCode.SESSION_NOT_FOUND,
                "The device session is not owned by this operation.",
            )
        }
        if (currentEpoch <= 0L || owner.nativeEpoch != currentEpoch) {
            throw DeviceCommunicationException(
                DeviceErrorCode.STALE_EPOCH,
                "The local runtime restarted. Try again.",
            )
        }
        return record
    }

    @Synchronized
    fun find(sessionId: String): DeviceSessionRecord? = sessions[sessionId]

    @Synchronized
    fun list(owner: DeviceOwner, currentEpoch: Long): List<DeviceSessionRecord> {
        if (currentEpoch <= 0L || owner.nativeEpoch != currentEpoch) {
            throw DeviceCommunicationException(DeviceErrorCode.STALE_EPOCH, null)
        }
        return sessions.values
            .filter { it.owner.token == owner.token && it.owner.nativeEpoch == owner.nativeEpoch }
            .toList()
    }

    @Synchronized
    fun remove(sessionId: String): DeviceSessionRecord? = sessions.remove(sessionId)

    @Synchronized
    fun forEpoch(epoch: Long): List<DeviceSessionRecord> =
        sessions.values.filter { it.owner.nativeEpoch == epoch }.toList()

    @Synchronized
    fun all(): List<DeviceSessionRecord> = sessions.values.toList()

    @Synchronized
    fun idleBefore(cutoffMillis: Long): List<DeviceSessionRecord> =
        sessions.values.filter { it.lastActivityMillis < cutoffMillis }.toList()

    @Synchronized
    fun clear(): Int {
        val count = sessions.size
        sessions.clear()
        return count
    }

    @get:Synchronized
    val size: Int
        get() = sessions.size
}
