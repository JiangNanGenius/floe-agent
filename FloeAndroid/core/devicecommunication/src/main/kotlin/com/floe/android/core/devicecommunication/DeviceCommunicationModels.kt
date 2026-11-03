// SPDX-License-Identifier: MPL-2.0
//
// C05 device communications — closed value surface.
//
// Every bound is explicit and enforced by the engine, not by UI copy. Bytes
// never grow an unbounded buffer: the TCP/Telnet reader and the BLE/USB
// notification lanes share the same bounded queue, and one model exchange is
// capped well below the 48 KiB trusted-bridge reply budget once base64 is
// applied.

package com.floe.android.core.devicecommunication

import java.util.Locale

/** The four real transports. TCP is raw text/binary; Telnet adds the IAC
 * negotiation layer; BLE is a GATT serial-style endpoint; USB is a real
 * Android USB-host serial port. */
enum class DeviceProtocol {
    TCP,
    TELNET,
    BLE,
    USB;

    val wireName: String get() = name.lowercase(Locale.ROOT)

    companion object {
        fun fromWire(value: String): DeviceProtocol? = entries.firstOrNull {
            it.wireName == value.lowercase(Locale.ROOT)
        }
    }
}

enum class DeviceSessionState {
    CONNECTING,
    CONNECTED,
    CLOSED,
    FAILED;

    val wireName: String get() = name.lowercase(Locale.ROOT)
}

enum class DeviceParity {
    NONE,
    ODD,
    EVEN,
    MARK,
    SPACE;

    val wireName: String get() = name.lowercase(Locale.ROOT)

    companion object {
        fun fromWire(value: String?): DeviceParity? {
            if (value == null) return NONE
            return entries.firstOrNull { it.wireName == value.lowercase(Locale.ROOT) }
        }
    }
}

/** Bounded, user-visible error codes. The same closed set is mirrored by the
 * Swift tool/bridge layer; unknown platform exceptions never become a
 * fabricated success or a raw stack trace. */
enum class DeviceErrorCode(val wire: String) {
    RUNTIME_NOT_INSTALLED("runtimeNotInstalled"),
    STALE_EPOCH("staleEpoch"),
    INVALID_REQUEST("invalidRequest"),
    INVALID_TARGET("invalidTarget"),
    POLICY_DENIED("policyDenied"),
    LOCAL_NETWORK_PERMISSION_REQUIRED("localNetworkPermissionRequired"),
    PERMISSION_REQUIRED("permissionRequired"),
    PERMISSION_DENIED("permissionDenied"),
    BLUETOOTH_UNAVAILABLE("bluetoothUnavailable"),
    BLUETOOTH_DISABLED("bluetoothDisabled"),
    UNSUPPORTED("unsupported"),
    DEVICE_NOT_FOUND("deviceNotFound"),
    DRIVER_NOT_FOUND("driverNotFound"),
    CONNECT_FAILED("connectFailed"),
    CONNECTION_REFUSED("connectionRefused"),
    HOST_NOT_FOUND("hostNotFound"),
    TIMED_OUT("timedOut"),
    IO_FAILED("ioFailed"),
    PROTOCOL_ERROR("protocolError"),
    OPERATION_BUSY("operationBusy"),
    SESSION_LIMIT("sessionLimit"),
    SESSION_NOT_FOUND("sessionNotFound"),
    SESSION_CLOSING("sessionClosing"),
    CLEANUP_INCOMPLETE("cleanupIncomplete"),
    RESPONSE_TOO_LARGE("responseTooLarge"),
    NOT_ATTACHED("notAttached"),
    INPUT_FULL("inputFull"),
    CANCELLED("cancelled"),
    INTERNAL_FAILURE("internalFailure");

    companion object {
        fun fromWire(value: String?): DeviceErrorCode? = entries.firstOrNull { it.wire == value }
    }
}

class DeviceCommunicationException(
    val code: DeviceErrorCode,
    val detail: String? = null,
    val retryable: Boolean = false,
) : Exception(code.wire) {
    /** Stable, bounded classification for a model-facing error body. */
    fun userSafeDetail(): String? = detail
        ?.filter { it.code >= 0x20 || it == '\n' || it == '\t' }
        ?.take(200)
        ?.ifBlank { null }
}

/** One operation's owner. A UI controller uses an opaque random token; a
 * model run uses `tool.<runID>` derived by the Swift tool layer. Neither is
 * accepted from model JSON. */
data class DeviceOwner(
    val token: String,
    val nativeEpoch: Long,
    val taskId: String? = null,
) {
    init {
        require(token.isNotBlank() && token.length <= 128) { "invalid owner token" }
        require(nativeEpoch > 0) { "invalid native epoch" }
    }
}

/** A resolved endpoint. Saved-profile resolution happens in Swift; the
 * engine receives only the concrete destination. */
data class DeviceEndpointSpec(
    val protocol: DeviceProtocol,
    val host: String? = null,
    val port: Int? = null,
    val bleAddress: String? = null,
    val bleServiceUuid: String? = null,
    val bleWriteUuid: String? = null,
    val bleNotifyUuid: String? = null,
    val bleReadUuid: String? = null,
    val usbDeviceName: String? = null,
    val usbPortIndex: Int = 0,
    val baudRate: Int = DEFAULT_BAUD_RATE,
    val dataBits: Int = 8,
    val stopBits: Int = 1,
    val parity: DeviceParity = DeviceParity.NONE,
) {
    companion object {
        const val DEFAULT_BAUD_RATE = 115_200
    }
}

data class DeviceSessionSnapshot(
    val id: String,
    val protocol: DeviceProtocol,
    val endpoint: String,
    val state: DeviceSessionState,
    val bytesIn: Long,
    val bytesOut: Long,
    val createdAtMillis: Long,
    val lastActivityMillis: Long,
    val errorCode: String? = null,
    val errorDetail: String? = null,
    val bleServiceUuid: String? = null,
    val bleMtu: Int? = null,
    val notificationSubscribed: Boolean = false,
    val usbVendorId: Int? = null,
    val usbProductId: Int? = null,
    val usbSerial: String? = null,
) {
    val connected: Boolean get() = state == DeviceSessionState.CONNECTED
}

data class DeviceDrainReport(
    val closed: Boolean,
    val complete: Boolean,
    val pendingBytes: Int,
)

data class DeviceRootStopReport(
    val complete: Boolean,
    val closedSessions: Int,
    val failedSessions: Int,
    val pendingBytes: Int,
)

data class BleScanResult(
    val address: String,
    val name: String?,
    val rssi: Int,
)

data class UsbDeviceInfo(
    val key: String,
    val vendorId: Int,
    val productId: Int,
    val productName: String?,
    val manufacturerName: String?,
    val serialNumber: String?,
    val driverName: String?,
    val portCount: Int,
    val permissionGranted: Boolean,
    val attached: Boolean,
)

data class BleRequirements(
    val supported: Boolean,
    val enabled: Boolean,
    val missingPermissions: List<String>,
    val requiresLocationServices: Boolean,
    val locationServicesEnabled: Boolean,
)

data class DeviceCapabilities(
    val bleSupported: Boolean,
    val bleEnabled: Boolean,
    val bleMissingPermissions: List<String>,
    val usbHostSupported: Boolean,
    val attachedUsbDevices: Int,
    val maximumSessions: Int,
    val maximumReadBytes: Int,
    val maximumWriteBytes: Int,
    val maximumExchangeBytes: Int,
    val sessionIdleTimeoutMillis: Long,
)

object DeviceLimits {
    const val MAXIMUM_SESSIONS = 4
    /** One read/exchange reply page. Kept small because the trusted tool
     * reply carries base64 and must stay under 48 KiB total JSON. */
    const val MAXIMUM_READ_BYTES = 24 * 1024
    const val MAXIMUM_WRITE_BYTES = 32 * 1024
    const val MAXIMUM_EXCHANGE_BYTES = MAXIMUM_READ_BYTES
    const val MAXIMUM_BUFFERED_BYTES = 256 * 1024
    const val MAXIMUM_SCAN_RESULTS = 32
    const val MAXIMUM_USB_DEVICES = 16
    const val MAXIMUM_BLE_WRITE_TOTAL = 16 * 1024
    const val MAXIMUM_USB_WRITE_TOTAL = 16 * 1024
    const val MAXIMUM_TCP_CHUNK = 32 * 1024
    const val CONNECT_TIMEOUT_MILLIS = 15_000L
    const val SESSION_IDLE_TIMEOUT_MILLIS = 30 * 60 * 1000L
    const val READ_LOOP_TIMEOUT_MILLIS = 250
    const val CLOSE_JOIN_TIMEOUT_MILLIS = 2_000L
    const val BLE_OPERATION_TIMEOUT_MILLIS = 15_000L
    const val BLE_DEFAULT_MTU = 23
    const val BLE_MAXIMUM_MTU = 517
    const val BLE_CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
    const val USB_READ_TIMEOUT_MILLIS = 200
    const val USB_WRITE_TIMEOUT_MILLIS = 5_000
    const val USB_DEFAULT_BAUD = 115_200
    const val MAXIMUM_TELNET_SUBNEGOTIATION_BYTES = 4 * 1024
}

/** GATT UUID validation/normalisation. Android accepts short 16/32-bit UUID
 * strings, but persistence and display use the canonical 128-bit form so a
 * saved endpoint can never silently compare differently. */
object GattUuid {
    private val UUID_REGEX = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private const val BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"

    fun normalize(raw: String?): String? {
        val value = raw?.trim() ?: return null
        if (value.isEmpty() || value.length > 64) return null
        return when (value.length) {
            4 -> if (value.all { it.isHexDigit() }) "0000${value.lowercase(Locale.ROOT)}$BASE_SUFFIX" else null
            8 -> if (value.all { it.isHexDigit() }) "${value.lowercase(Locale.ROOT)}$BASE_SUFFIX" else null
            36 -> if (UUID_REGEX.matches(value)) value.lowercase(Locale.ROOT) else null
            else -> null
        }
    }

    fun isValid(raw: String?): Boolean = normalize(raw) != null

    private fun Char.isHexDigit(): Boolean =
        this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'
}
