// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.sftp

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource

@Composable
fun sftpErrorText(error: SftpErrorUi): String {
    val base = when (error.code) {
        "hostKeyChallenge", "hostKeyChanged" -> stringResource(R.string.sftp_err_host_key)
        "authenticationFailed", "credentialMissing", "credentialInvalid",
        "gatewayUnavailable" -> stringResource(R.string.sftp_err_auth)
        "connectionRefused", "hostNotFound", "timedOut", "networkUnreachable",
        "transportFailed", "laneUnavailable" -> stringResource(R.string.sftp_err_network)
        "laneLimit", "transferLimit", "busy" -> stringResource(R.string.sftp_err_busy)
        "invalidPath", "pathNotFound", "permissionDenied" -> stringResource(R.string.sftp_err_path)
        "destinationExists" -> stringResource(R.string.sftp_err_exists)
        "revisionRequired", "revisionMismatch", "revisionUnverifiable",
        "localConflict" -> stringResource(R.string.sftp_err_revision)
        "fileTooLarge", "emptyFile" -> stringResource(R.string.sftp_err_size)
        "checksumMismatch", "sizeMismatch" -> stringResource(R.string.sftp_err_verify)
        "cancelled" -> stringResource(R.string.sftp_err_cancelled)
        "unsupportedByServer", "protocolIncompatible", "remoteFailure" ->
            stringResource(R.string.sftp_err_protocol)
        "destinationUnavailable" -> stringResource(R.string.sftp_err_destination)
        "runtimeNotInstalled", "staleEpoch", "coreUnavailable" ->
            stringResource(R.string.sftp_unavailable_body)
        else -> stringResource(R.string.sftp_err_generic)
    }
    val detail = if (!error.detail.isNullOrBlank()) " ${error.detail}" else ""
    val recovery = if (error.retainedPath != null) {
        " " + stringResource(R.string.sftp_err_recovery, error.retainedPath!!)
    } else ""
    return base + detail + recovery
}

@Composable
fun sftpBusyText(busy: String): String = when (busy) {
    "connect" -> stringResource(R.string.sftp_busy_connect)
    "list" -> stringResource(R.string.sftp_busy_list)
    "download" -> stringResource(R.string.sftp_busy_download)
    "upload" -> stringResource(R.string.sftp_busy_upload)
    "approve" -> stringResource(R.string.sftp_busy_approve)
    else -> stringResource(R.string.sftp_loading)
}

@Composable
fun sftpNoticeText(token: String): String = when (token) {
    "downloaded" -> stringResource(R.string.sftp_notice_downloaded)
    "uploaded" -> stringResource(R.string.sftp_notice_uploaded)
    "cancelled" -> stringResource(R.string.sftp_notice_cancelled)
    else -> token
}

@Composable
fun sftpTransferStateText(transfer: SftpTransferUi): String = when (transfer.state) {
    "running" -> stringResource(R.string.sftp_state_running)
    "completing" -> stringResource(R.string.sftp_state_completing)
    "completed" -> stringResource(R.string.sftp_state_done)
    "cancelled" -> stringResource(R.string.sftp_state_cancelled)
    else -> stringResource(R.string.sftp_state_failed)
}

@Composable
fun sftpTransferErrorText(code: String): String = when (code) {
    "revisionMismatch", "revisionRequired" -> stringResource(R.string.sftp_err_revision)
    "checksumMismatch", "sizeMismatch" -> stringResource(R.string.sftp_err_verify)
    "destinationExists" -> stringResource(R.string.sftp_err_exists)
    "cancelled" -> stringResource(R.string.sftp_err_cancelled)
    "permissionDenied", "invalidPath", "pathNotFound" -> stringResource(R.string.sftp_err_path)
    "fileTooLarge" -> stringResource(R.string.sftp_err_size)
    else -> stringResource(R.string.sftp_err_generic)
}
