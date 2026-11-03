// SPDX-License-Identifier: MPL-2.0
//
// C05 SFTP trusted-host client values. Parsed from the closed `floe.sftp/18`
// wire; the only bytes retained are the caller's bounded transfer progress.

package com.floe.android.host.sftp

import com.floe.android.bridge.SwiftCore

internal const val C05_SFTP_VERSION = 18
internal const val C05_SFTP_MAX_CHUNK = 32 * 1024

internal fun interface C05SFTPTransport {
    fun exchange(request: String): String
}

internal object SwiftC05SFTPTransport : C05SFTPTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class C05SFTPFailure(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
    val detail: String? = null,
    val retainedPath: String? = null,
    val challenge: C05SFTPChallenge? = null,
) : Exception(code)

internal data class C05SFTPOwner(
    val token: String,
    val nativeEpoch: Long,
    val taskID: String? = null,
    val temporary: Boolean = false,
)

internal data class C05SFTPChallenge(
    val id: String,
    val profileID: String,
    val address: String,
    val port: Int,
    val keyType: String,
    val fingerprintSHA256: String,
    val expectedFingerprintSHA256: String?,
    val changed: Boolean,
)

internal data class C05SFTPHost(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
)

internal data class C05SFTPLane(
    val id: String,
    val profileID: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val state: String,
    val homePath: String,
)

internal data class C05SFTPEntry(
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val isSymbolicLink: Boolean,
    val bytes: Long,
    val modifiedAt: String?,
    val revision: String,
)

internal data class C05SFTPPage(
    val path: String,
    val canonicalPath: String,
    val entries: List<C05SFTPEntry>,
    val nextOffset: Int,
    val truncated: Boolean,
)

internal data class C05SFTPTransfer(
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

internal data class C05SFTPRevision(
    val exists: Boolean,
    val bytes: Long,
    val revision: String?,
)

internal data class C05SFTPDocument(
    val displayName: String,
    val bytes: Long,
    val uri: android.net.Uri,
)
