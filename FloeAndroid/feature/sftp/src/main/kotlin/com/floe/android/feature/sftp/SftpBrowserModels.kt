// SPDX-License-Identifier: MPL-2.0
//
// C05 SFTP presentation state. Values are projections of the trusted
// `floe.sftp/18` lane; no widget owns a transport or a file handle.

package com.floe.android.feature.sftp

data class SftpHostUi(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
)

data class SftpLaneUi(
    val id: String,
    val profileID: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val state: String,
    val homePath: String,
)

data class SftpEntryUi(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val isSymbolicLink: Boolean,
    val bytes: Long,
    val modifiedAt: String?,
    val revision: String,
)

data class SftpTransferUi(
    val id: String,
    val kind: String,
    val remotePath: String,
    val displayName: String,
    val state: String,
    val bytesDone: Long,
    val totalBytes: Long,
    val sha256: String?,
    val errorCode: String?,
)

data class SftpChallengeUi(
    val id: String,
    val address: String,
    val port: Int,
    val keyType: String,
    val fingerprint: String,
    val expectedFingerprint: String?,
    val changed: Boolean,
)

data class SftpPendingDownloadUi(
    val entry: SftpEntryUi,
    val localPath: String,
    val existingRevision: String?,
    val bytes: Long,
)

data class SftpErrorUi(
    val code: String,
    val detail: String?,
    val retryable: Boolean,
    val retainedPath: String? = null,
)

data class SftpBrowserUiState(
    val loading: Boolean = false,
    val coreReady: Boolean = false,
    val hosts: List<SftpHostUi> = emptyList(),
    val selectedProfileID: String? = null,
    val lane: SftpLaneUi? = null,
    val path: String = "",
    val entries: List<SftpEntryUi> = emptyList(),
    val truncated: Boolean = false,
    val busy: String? = null,
    val transfer: SftpTransferUi? = null,
    val pendingDownload: SftpPendingDownloadUi? = null,
    val pendingUploadName: String? = null,
    val challenge: SftpChallengeUi? = null,
    val error: SftpErrorUi? = null,
    val notice: String? = null,
)

internal fun sftpBytesText(bytes: Long): String = when {
    bytes >= 1L shl 30 -> "%.1f GB".format(bytes / 1073741824.0)
    bytes >= 1L shl 20 -> "%.1f MB".format(bytes / 1048576.0)
    bytes >= 1L shl 10 -> "%.0f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}
