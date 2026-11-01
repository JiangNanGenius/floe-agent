// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.remote

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource

/** Localized text for a stable validation/error code. Unknown codes stay
 * generic; no internal reason text is shown to the user. */
@Composable
internal fun remoteMessage(code: String?): String = when (code) {
    "displayNameRequired" -> stringResource(R.string.remote_error_displayNameRequired)
    "displayNameTooLong" -> stringResource(R.string.remote_error_displayNameTooLong)
    "addressRequired" -> stringResource(R.string.remote_error_addressRequired)
    "addressTooLong" -> stringResource(R.string.remote_error_addressTooLong)
    "addressInvalid" -> stringResource(R.string.remote_error_addressInvalid)
    "portInvalid" -> stringResource(R.string.remote_error_portInvalid)
    "userRequired" -> stringResource(R.string.remote_error_userRequired)
    "userTooLong" -> stringResource(R.string.remote_error_userTooLong)
    "authRequired" -> stringResource(R.string.remote_error_authRequired)
    "keyTypeInvalid" -> stringResource(R.string.remote_error_keyTypeInvalid)
    "fingerprintRequired" -> stringResource(R.string.remote_error_fingerprintRequired)
    "fingerprintInvalid" -> stringResource(R.string.remote_error_fingerprintInvalid)
    "hostKeyPolicyInvalid" -> stringResource(R.string.remote_error_hostKeyPolicyInvalid)
    "tunnelHostRequired" -> stringResource(R.string.remote_error_tunnelHostRequired)
    "tunnelHostTooLong" -> stringResource(R.string.remote_error_tunnelHostTooLong)
    "tunnelHostInvalid" -> stringResource(R.string.remote_error_tunnelHostInvalid)
    "tunnelPortInvalid" -> stringResource(R.string.remote_error_tunnelPortInvalid)
    "credentialMissing" -> stringResource(R.string.remote_error_credentialMissing)
    "credentialInvalid" -> stringResource(R.string.remote_error_credentialInvalid)
    "invalidTarget" -> stringResource(R.string.remote_error_invalidTarget)
    "timeout" -> stringResource(R.string.remote_error_timeout)
    "cancelled" -> stringResource(R.string.remote_error_cancelled)
    "needsCoreUpdate" -> stringResource(R.string.remote_error_needsCoreUpdate)
    "authenticationFailed" -> stringResource(R.string.remote_error_authenticationFailed)
    "connectionRefused" -> stringResource(R.string.remote_error_connectionRefused)
    "timedOut" -> stringResource(R.string.remote_error_timedOut)
    "networkUnreachable" -> stringResource(R.string.remote_error_networkUnreachable)
    "hostNotFound" -> stringResource(R.string.remote_error_hostNotFound)
    "transportFailed", "protocolIncompatible" -> stringResource(R.string.remote_error_transportFailed)
    "sessionNotFound", "sessionUnavailable" -> stringResource(R.string.remote_error_sessionNotFound)
    "ptyNotFound" -> stringResource(R.string.remote_error_ptyNotFound)
    "tunnelNotFound" -> stringResource(R.string.remote_error_tunnelNotFound)
    "cleanupIncomplete" -> stringResource(R.string.remote_error_cleanupIncomplete)
    "profileNotFound" -> stringResource(R.string.remote_error_profileNotFound)
    "profileLimit" -> stringResource(R.string.remote_error_profileLimit)
    "profileBusy" -> stringResource(R.string.remote_error_profileBusy)
    "sessionLimit" -> stringResource(R.string.remote_error_sessionLimit)
    "ptyLimit" -> stringResource(R.string.remote_error_ptyLimit)
    "execLimit" -> stringResource(R.string.remote_error_execLimit)
    "tunnelLimit" -> stringResource(R.string.remote_error_tunnelLimit)
    "gatewayUnavailable" -> stringResource(R.string.remote_error_gatewayUnavailable)
    "staleEpoch", "runtimeNotInstalled", "coreUnavailable" -> stringResource(R.string.remote_error_staleEpoch)
    else -> stringResource(R.string.remote_error_unknown)
}

@Composable
internal fun remoteTerminalStatusLabel(code: String): String = when (code) {
    "connected", "running" -> stringResource(R.string.remote_connected)
    "unknown" -> stringResource(R.string.remote_unknown)
    "closing" -> stringResource(R.string.remote_closing)
    "closed" -> stringResource(R.string.remote_closed)
    "outputRolled" -> stringResource(R.string.remote_output_rolled)
    else -> code
}

@Composable
internal fun remoteIssueLabel(code: String): String = when (code) {
    "inputFull" -> stringResource(R.string.remote_input_full)
    "inputTooLarge" -> stringResource(R.string.remote_input_too_large)
    "transport", "hostClosed" -> stringResource(R.string.remote_input_transport)
    "outputRolled" -> stringResource(R.string.remote_output_rolled)
    else -> code
}

@Composable
internal fun remoteExecStateLabel(code: String): String = when (code) {
    "running" -> stringResource(R.string.remote_state_running)
    "exited" -> stringResource(R.string.remote_state_exited)
    "cancelled" -> stringResource(R.string.remote_state_cancelled)
    "unknown" -> stringResource(R.string.remote_unknown)
    else -> code
}

@Composable
internal fun remoteTunnelStateLabel(code: String): String = when (code) {
    "open" -> stringResource(R.string.remote_state_open)
    "closed" -> stringResource(R.string.remote_closed)
    "unknown" -> stringResource(R.string.remote_unknown)
    else -> code
}

@Composable
internal fun remoteSessionStateLabel(state: String, connected: Boolean): String = when {
    state == "connected" && connected -> stringResource(R.string.remote_connected)
    state == "unknown" || (state == "connected" && !connected) -> stringResource(R.string.remote_unknown)
    state == "closing" -> stringResource(R.string.remote_closing)
    state == "closed" -> stringResource(R.string.remote_closed)
    else -> stringResource(R.string.remote_unknown)
}
