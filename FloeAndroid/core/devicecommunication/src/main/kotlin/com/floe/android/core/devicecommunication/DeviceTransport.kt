// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicecommunication

/** Engine-facing transport seam. Implementations own their platform object
 * (socket/GATT/USB port) and never expose it to the UI or model layer. */
internal interface DeviceTransport {
    suspend fun read(maxBytes: Int): ByteArray

    suspend fun write(bytes: ByteArray): Int

    /** Stops the reader/write lane, closes the platform object and joins its
     * worker within a bound. [DeviceDrainReport.complete] is false when the
     * worker/OS object could not be proven closed. */
    suspend fun close(): DeviceDrainReport
}

/** Transport callbacks into the engine's session record. Callbacks may run on
 * binder/IO threads; they only update bounded metadata. */
internal interface DeviceTransportListener {
    fun onTransportConnected(record: DeviceSessionRecord)

    fun onTransportActivity(record: DeviceSessionRecord)

    fun onTransportTerminated(
        record: DeviceSessionRecord,
        state: DeviceSessionState,
        code: DeviceErrorCode?,
        detail: String?,
    )
}
