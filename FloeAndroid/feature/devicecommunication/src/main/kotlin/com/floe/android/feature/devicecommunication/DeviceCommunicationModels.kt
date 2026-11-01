// SPDX-License-Identifier: MPL-2.0
//
// C05 device screen projections and pure draft validation. The real socket,
// GATT, USB and permission effects remain in the App-owned controller; the
// screen receives immutable state and emits user intents only.

package com.floe.android.feature.devicecommunication

import com.floe.android.core.devicecommunication.BleRequirements
import com.floe.android.core.devicecommunication.BleScanResult
import com.floe.android.core.devicecommunication.DeviceCommunicationException
import com.floe.android.core.devicecommunication.DeviceEndpointSpec
import com.floe.android.core.devicecommunication.DeviceEndpointValidation
import com.floe.android.core.devicecommunication.DeviceErrorCode
import com.floe.android.core.devicecommunication.DeviceParity
import com.floe.android.core.devicecommunication.DeviceProtocol
import com.floe.android.core.devicecommunication.DeviceSessionSnapshot
import com.floe.android.core.devicecommunication.DeviceSessionState
import com.floe.android.core.devicecommunication.UsbDeviceInfo

enum class DeviceTab(val protocol: DeviceProtocol) {
    TCP(DeviceProtocol.TCP),
    TELNET(DeviceProtocol.TELNET),
    BLE(DeviceProtocol.BLE),
    USB(DeviceProtocol.USB),
}

data class DeviceConnectionUi(
    val id: String,
    val profileId: String,
    val displayName: String,
    val tab: DeviceTab,
    val host: String? = null,
    val port: Int? = null,
    val peripheralAddress: String? = null,
    val serviceUuid: String? = null,
    val writeUuid: String? = null,
    val notifyUuid: String? = null,
)

data class DeviceProfileUi(
    val id: String,
    val displayName: String,
    val connections: List<DeviceConnectionUi>,
)

data class DeviceProblemUi(
    val code: String,
    val detail: String? = null,
    val retryable: Boolean = false,
    /** "ble", "usb" or "lan" when the same wire code needs a concrete
     * permission explanation. Never a raw host value. */
    val context: String? = null,
)

data class DevicePermissionRequestUi(
    val permissions: List<String>,
)

data class DeviceDraft(
    val profileId: String? = null,
    val connectionId: String? = null,
    val tab: DeviceTab = DeviceTab.TCP,
    val displayName: String = "",
    val host: String = "",
    val port: String = "23",
    val peripheralAddress: String = "",
    val serviceUuid: String = "",
    val writeUuid: String = "",
    val notifyUuid: String = "",
    val readUuid: String = "",
    val usbDeviceKey: String = "",
    val usbPortIndex: Int = 0,
    val baudRate: String = "115200",
    val dataBits: Int = 8,
    val stopBits: Int = 1,
    val parity: DeviceParity = DeviceParity.NONE,
) {
    fun toSpecOrNull(): DeviceEndpointSpec? {
        val parsedPort = port.trim().toIntOrNull() ?: return null
        val baud = baudRate.trim().toIntOrNull() ?: return null
        val spec = when (tab) {
            DeviceTab.TCP, DeviceTab.TELNET -> DeviceEndpointSpec(
                protocol = tab.protocol,
                host = host.trim(),
                port = parsedPort,
            )
            DeviceTab.BLE -> DeviceEndpointSpec(
                protocol = DeviceProtocol.BLE,
                bleAddress = peripheralAddress.trim().uppercase(),
                bleServiceUuid = serviceUuid.trim(),
                bleWriteUuid = writeUuid.trim(),
                bleNotifyUuid = notifyUuid.trim().ifBlank { null },
                bleReadUuid = readUuid.trim().ifBlank { null },
            )
            DeviceTab.USB -> DeviceEndpointSpec(
                protocol = DeviceProtocol.USB,
                usbDeviceName = usbDeviceKey.trim(),
                usbPortIndex = usbPortIndex,
                baudRate = baud,
                dataBits = dataBits,
                stopBits = stopBits,
                parity = parity,
            )
        }
        return try {
            DeviceEndpointValidation.validate(spec)
        } catch (_: DeviceCommunicationException) {
            null
        }
    }
}

data class DeviceScreenState(
    val loading: Boolean = true,
    val busy: String? = null,
    val coreReady: Boolean = false,
    val coreUpdateRequired: Boolean = false,
    val profiles: List<DeviceProfileUi> = emptyList(),
    val tab: DeviceTab = DeviceTab.TCP,
    val draft: DeviceDraft = DeviceDraft(),
    val sessions: List<DeviceSessionSnapshot> = emptyList(),
    val activeSessionID: String? = null,
    val consoleRevision: Long = 0L,
    val bleScan: List<BleScanResult> = emptyList(),
    val usbDevices: List<UsbDeviceInfo> = emptyList(),
    val bleRequirements: BleRequirements? = null,
    val usbHostSupported: Boolean? = null,
    val sessionLimit: Int = 4,
    val error: DeviceProblemUi? = null,
    val notice: String? = null,
    val permissionRequest: DevicePermissionRequestUi? = null,
) {
    val activeSession: DeviceSessionSnapshot?
        get() = activeSessionID?.let { id -> sessions.firstOrNull { it.id == id } }
}

data class DeviceCallbacks(
    val onSelectTab: (DeviceTab) -> Unit,
    val onDraftChange: (DeviceDraft) -> Unit,
    val onRefresh: () -> Unit,
    val onSaveConnection: () -> Unit,
    val onDeleteProfile: (String) -> Unit,
    val onOpenProfile: (DeviceProfileUi) -> Unit,
    val onOpenConnection: (DeviceConnectionUi) -> Unit,
    val onOpenSession: (String) -> Unit,
    val onConnect: () -> Unit,
    val onCloseSession: () -> Unit,
    val onSend: (String, Boolean) -> Unit,
    val onConsoleInput: (ByteArray) -> Unit,
    val onConsoleResize: (Int, Int) -> Unit,
    val onScan: () -> Unit,
    val onRefreshUsb: () -> Unit,
    val onRequestUsbPermission: (String) -> Unit,
    val onRequestBlePermissions: (List<String>) -> Unit,
    val onEnableBluetooth: () -> Unit,
    val onDismissError: () -> Unit,
) {
    companion object {
        val None = DeviceCallbacks(
            onSelectTab = {},
            onDraftChange = {},
            onRefresh = {},
            onSaveConnection = {},
            onDeleteProfile = {},
            onOpenProfile = {},
            onOpenConnection = {},
            onOpenSession = {},
            onConnect = {},
            onCloseSession = {},
            onSend = { _, _ -> },
            onConsoleInput = {},
            onConsoleResize = { _, _ -> },
            onScan = {},
            onRefreshUsb = {},
            onRequestUsbPermission = {},
            onRequestBlePermissions = {},
            onEnableBluetooth = {},
            onDismissError = {},
        )
    }
}

/** Pure validation used by both the UI and tests. Returns a stable error code
 * or null. The controller repeats validation at the effect boundary. */
fun DeviceDraft.validationCode(): String? {
    if (displayName.trim().length > 120) return DeviceErrorCode.INVALID_REQUEST.wire
    if (toSpecOrNull() != null) return null
    return when (tab) {
        DeviceTab.TCP, DeviceTab.TELNET -> DeviceErrorCode.INVALID_TARGET.wire
        DeviceTab.BLE -> DeviceErrorCode.INVALID_REQUEST.wire
        DeviceTab.USB -> DeviceErrorCode.INVALID_REQUEST.wire
    }
}

fun DeviceConnectionUi.toDraft(): DeviceDraft = when (tab) {
    DeviceTab.TCP, DeviceTab.TELNET -> DeviceDraft(
        profileId = profileId,
        connectionId = id,
        tab = tab,
        displayName = displayName,
        host = host.orEmpty(),
        port = (port ?: 23).toString(),
    )
    DeviceTab.BLE -> DeviceDraft(
        profileId = profileId,
        connectionId = id,
        tab = tab,
        displayName = displayName,
        peripheralAddress = peripheralAddress.orEmpty(),
        serviceUuid = serviceUuid.orEmpty(),
        writeUuid = writeUuid.orEmpty(),
        notifyUuid = notifyUuid.orEmpty(),
    )
    DeviceTab.USB -> DeviceDraft(
        profileId = profileId,
        connectionId = id,
        tab = tab,
        displayName = displayName,
    )
}

fun DeviceSessionState.labelKey(): String = when (this) {
    DeviceSessionState.CONNECTING -> "connecting"
    DeviceSessionState.CONNECTED -> "connected"
    DeviceSessionState.CLOSED -> "closed"
    DeviceSessionState.FAILED -> "failed"
}

fun DeviceParity.displayKey(): String = name.lowercase()
