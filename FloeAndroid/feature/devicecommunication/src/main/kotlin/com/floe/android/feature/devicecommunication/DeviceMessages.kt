// SPDX-License-Identifier: MPL-2.0
//
// Bilingual user-facing copy for device communications. Internal protocol
// names and raw exception text never reach this surface; every wire code maps
// to an actionable sentence. English and Simplified Chinese stay aligned.

package com.floe.android.feature.devicecommunication

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.floe.android.core.devicecommunication.DeviceErrorCode

@Composable
fun deviceTabLabel(tab: DeviceTab): String = stringResource(
    when (tab) {
        DeviceTab.TCP -> R.string.devices_tabs_tcp
        DeviceTab.TELNET -> R.string.devices_tabs_telnet
        DeviceTab.BLE -> R.string.devices_tabs_ble
        DeviceTab.USB -> R.string.devices_tabs_usb
    },
)

@Composable
fun deviceStateLabel(state: String): String = stringResource(
    when (state) {
        "connecting" -> R.string.devices_state_connecting
        "connected" -> R.string.devices_state_connected
        "closed" -> R.string.devices_state_closed
        else -> R.string.devices_state_failed
    },
)

@Composable
fun deviceErrorText(problem: DeviceProblemUi): String {
    return when (problem.code) {
        DeviceErrorCode.RUNTIME_NOT_INSTALLED.wire -> stringResource(R.string.devices_error_runtime)
        DeviceErrorCode.STALE_EPOCH.wire -> stringResource(R.string.devices_error_stale)
        DeviceErrorCode.INVALID_REQUEST.wire -> stringResource(R.string.devices_error_invalid)
        DeviceErrorCode.INVALID_TARGET.wire -> stringResource(R.string.devices_error_invalid_target)
        DeviceErrorCode.POLICY_DENIED.wire -> stringResource(R.string.devices_error_policy)
        DeviceErrorCode.LOCAL_NETWORK_PERMISSION_REQUIRED.wire ->
            stringResource(R.string.devices_permission_lan)
        DeviceErrorCode.PERMISSION_REQUIRED.wire, DeviceErrorCode.PERMISSION_DENIED.wire ->
            when (problem.context) {
                "ble" -> stringResource(R.string.devices_permission_ble)
                "usb" -> stringResource(R.string.devices_permission_usb)
                "lan" -> stringResource(R.string.devices_permission_lan)
                else -> stringResource(R.string.devices_error_permission)
            }
        DeviceErrorCode.BLUETOOTH_UNAVAILABLE.wire ->
            stringResource(R.string.devices_error_bluetooth_unavailable)
        DeviceErrorCode.BLUETOOTH_DISABLED.wire -> stringResource(R.string.devices_bluetooth_off)
        DeviceErrorCode.UNSUPPORTED.wire -> stringResource(R.string.devices_error_unsupported)
        DeviceErrorCode.DEVICE_NOT_FOUND.wire -> stringResource(R.string.devices_error_device_missing)
        DeviceErrorCode.DRIVER_NOT_FOUND.wire -> stringResource(R.string.devices_error_driver)
        DeviceErrorCode.CONNECT_FAILED.wire -> stringResource(R.string.devices_error_connect)
        DeviceErrorCode.CONNECTION_REFUSED.wire -> stringResource(R.string.devices_error_refused)
        DeviceErrorCode.HOST_NOT_FOUND.wire -> stringResource(R.string.devices_error_host)
        DeviceErrorCode.TIMED_OUT.wire -> stringResource(R.string.devices_error_timeout)
        DeviceErrorCode.IO_FAILED.wire -> stringResource(R.string.devices_error_io)
        DeviceErrorCode.PROTOCOL_ERROR.wire -> stringResource(R.string.devices_error_protocol)
        DeviceErrorCode.OPERATION_BUSY.wire -> stringResource(R.string.devices_error_busy)
        DeviceErrorCode.SESSION_LIMIT.wire -> stringResource(R.string.devices_error_limit)
        DeviceErrorCode.SESSION_NOT_FOUND.wire -> stringResource(R.string.devices_error_session)
        DeviceErrorCode.SESSION_CLOSING.wire -> stringResource(R.string.devices_error_session)
        DeviceErrorCode.CLEANUP_INCOMPLETE.wire -> stringResource(R.string.devices_error_cleanup)
        DeviceErrorCode.RESPONSE_TOO_LARGE.wire -> stringResource(R.string.devices_error_too_large)
        DeviceErrorCode.NOT_ATTACHED.wire -> stringResource(R.string.devices_error_detached)
        DeviceErrorCode.INPUT_FULL.wire -> stringResource(R.string.devices_error_input_full)
        DeviceErrorCode.CANCELLED.wire -> stringResource(R.string.devices_error_cancelled)
        else -> stringResource(R.string.devices_error_generic)
    }
}
