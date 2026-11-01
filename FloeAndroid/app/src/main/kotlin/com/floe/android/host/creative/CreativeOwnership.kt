// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeLimits
import com.floe.android.feature.canvas.CreativePathGuard
import java.io.File
import java.util.UUID

/**
 * The ACTUAL accepted root + epoch captured from the runtime owner start.
 * Read-only: the host uses it solely to stage bounded import bytes under
 * `FloeAgent/CreativeIncoming`. It is never a second storage authority, and
 * project files/asset roots are always resolved by the native side.
 */
data class CreativeAcceptedRoot(
    val path: String,
    val epoch: Long,
)

data class CreativeStagedAsset(
    val token: String,
    val fileName: String,
    val mimeType: String?,
    val byteCount: Long,
    val sha256: String,
    /** The verified staged copy under the accepted root, for byte inspection. */
    val file: File,
)

internal object CreativeOwnership {
    fun requireLive(accepted: CreativeAcceptedRoot?, liveEpoch: Long?): CreativeAcceptedRoot {
        if (accepted == null || liveEpoch == null || liveEpoch <= 0L ||
            accepted.epoch != liveEpoch) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        return accepted
    }

    fun requireSessionToken(token: String) {
        if (!isValidSessionToken(token)) {
            throw CreativeException("invalidSession", "invalidSessionToken")
        }
    }

    fun isValidSessionToken(token: String): Boolean =
        token.isNotEmpty() && token.length <= CreativeLimits.SESSION_TOKEN_BYTES &&
            token.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }

    fun newStagingToken(sessionToken: String): String {
        requireSessionToken(sessionToken)
        return "$sessionToken.${UUID.randomUUID()}"
    }

    fun incomingDirectory(accepted: CreativeAcceptedRoot): File {
        val root = File(accepted.path).canonicalFile
        require(root.isDirectory || root.mkdirs()) {
            "accepted root is unavailable"
        }
        val directory = File(root, "FloeAgent/CreativeIncoming").canonicalFile
        require(directory.path.startsWith(root.path + File.separator)) {
            "creative staging escapes the accepted root"
        }
        require(directory.isDirectory || directory.mkdirs()) {
            "creative staging is unavailable"
        }
        return directory
    }

    fun stagingFile(accepted: CreativeAcceptedRoot, token: String): File {
        if (!isSafeStagingToken(token)) {
            throw CreativeException("assetStagingInvalid", "invalidStagingToken")
        }
        val directory = incomingDirectory(accepted)
        val target = File(directory, token).canonicalFile
        require(target.path.startsWith(directory.path + File.separator)) {
            "creative staging token escapes its directory"
        }
        return target
    }

    fun isSafeStagingToken(token: String): Boolean =
        token.isNotEmpty() && token.length <= CreativeLimits.STAGING_TOKEN_BYTES &&
            !token.startsWith(".") &&
            token.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }

    fun isSafeRelativePath(path: String?): Boolean = CreativePathGuard.isSafeRelativePath(path)
}
