// SPDX-License-Identifier: MPL-2.0
//
// Endpoint preflight shared by the App controller and the model-tool pump.
// Validation is deterministic and content-bounded; it never performs DNS,
// opens a socket, requests permission or mutates a saved profile.

package com.floe.android.core.devicecommunication

object DeviceEndpointValidation {
    fun validate(spec: DeviceEndpointSpec): DeviceEndpointSpec = when (spec.protocol) {
        DeviceProtocol.TCP, DeviceProtocol.TELNET -> validateText(spec)
        DeviceProtocol.BLE -> validateBle(spec)
        DeviceProtocol.USB -> validateUsb(spec)
    }

    fun validateText(spec: DeviceEndpointSpec): DeviceEndpointSpec {
        val host = DeviceTargetPolicy.validateHost(spec.host ?: "")
        val port = DeviceTargetPolicy.validatePort(spec.port ?: 0)
        DeviceTargetPolicy.checkPolicy(host)
        return spec.copy(host = host, port = port)
    }

    fun validateBle(spec: DeviceEndpointSpec): DeviceEndpointSpec {
        val address = spec.bleAddress?.trim()?.uppercase()
            ?: throw invalid("Choose a Bluetooth device.")
        if (!MAC_REGEX.matches(address)) throw invalid("The Bluetooth address is invalid.")
        val service = GattUuid.normalize(spec.bleServiceUuid)
            ?: throw invalid("Enter the GATT service UUID.")
        val write = GattUuid.normalize(spec.bleWriteUuid)
            ?: throw invalid("Enter the GATT write characteristic UUID.")
        val notify = spec.bleNotifyUuid?.takeIf { it.isNotBlank() }?.let {
            GattUuid.normalize(it) ?: throw invalid("Enter a valid GATT notify characteristic UUID.")
        }
        val read = spec.bleReadUuid?.takeIf { it.isNotBlank() }?.let {
            GattUuid.normalize(it) ?: throw invalid("Enter a valid GATT read characteristic UUID.")
        }
        return spec.copy(
            bleAddress = address,
            bleServiceUuid = service,
            bleWriteUuid = write,
            bleNotifyUuid = notify,
            bleReadUuid = read,
        )
    }

    fun validateUsb(spec: DeviceEndpointSpec): DeviceEndpointSpec {
        val name = spec.usbDeviceName?.trim() ?: ""
        if (name.isEmpty() || name.length > 256 || name.any { it.code < 0x20 }) {
            throw invalid("Choose an attached USB serial device.")
        }
        if (spec.usbPortIndex !in 0..15) throw invalid("The USB serial port is invalid.")
        if (spec.baudRate !in 50..4_000_000) throw invalid("Enter a baud rate from 50 to 4000000.")
        if (spec.dataBits !in 5..8) throw invalid("Choose 5 to 8 data bits.")
        if (spec.stopBits !in 1..2) throw invalid("Choose 1 or 2 stop bits.")
        return spec.copy(usbDeviceName = name)
    }

    private val MAC_REGEX = Regex("^([0-9A-F]{2}:){5}[0-9A-F]{2}$")

    private fun invalid(message: String) = DeviceCommunicationException(
        DeviceErrorCode.INVALID_REQUEST,
        message,
    )
}
