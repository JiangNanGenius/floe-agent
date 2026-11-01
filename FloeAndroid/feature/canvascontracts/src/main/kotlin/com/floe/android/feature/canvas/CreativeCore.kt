// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas

import java.io.File
import java.util.UUID

/**
 * Shared G09 creative runtime identity used by both Canvas and media
 * contracts. It carries no storage path and no task/run identity: direct UI
 * editing never fabricates an AI chat or environment.
 */
data class CreativeBinding(
    val epoch: Long,
    val bound: Boolean,
    val rootFingerprint: String? = null,
)

enum class CreativeAvailability {
    /** The native v5 handler and the accepted storage generation are live. */
    Available,

    /** The installed native core predates floe.creative/5; update the core. */
    NeedsCoreUpdate,

    /** The accepted runtime generation is not live yet. */
    WaitingForRuntime,

    /** Any other typed failure (storage, incompatibility, I/O). */
    Unavailable,
}

data class CreativeServiceStatus(
    val availability: CreativeAvailability,
    val boundEpoch: Long? = null,
    val schema: String? = null,
    val actions: List<String> = emptyList(),
    val requestMaxBytes: Int = 0,
    val responseMaxBytes: Int = 0,
    val canvasSchemaVersion: Int = 0,
    val mediaSchemaVersion: Int = 0,
    val reason: String? = null,
)

/**
 * Typed host failure. Codes mirror the native `floe.creative/5` codes; a
 * consumer must never fall back to an in-memory/temp project store when a
 * call fails.
 */
class CreativeException(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
    cause: Throwable? = null,
) : Exception(reason?.let { "$code: $it" } ?: code, cause)

/**
 * Actual source/owner context supplied by the existing file/workspace route
 * when it exists. It is provenance, NOT storage permission: it is validated
 * against the accepted composition and persisted, but it never selects a
 * root. No AI task/run/environment is invented for a direct UI edit.
 */
data class CreativeOriginContext(
    val kind: String,
    val ownerID: String? = null,
    val environmentID: String? = null,
) {
    companion object {
        const val STANDALONE = "standalone"
        const val FILES = "files"
        const val WORKSPACE = "workspace"
        const val CANVAS = "canvas"
        const val CHAT = "chat"
        val ALL = setOf(STANDALONE, FILES, WORKSPACE, CANVAS, CHAT)

        fun standalone(): CreativeOriginContext = CreativeOriginContext(STANDALONE)
    }

    fun isValid(): Boolean = kind in ALL &&
        (ownerID == null || ownerID.length in 36..36) &&
        (environmentID == null ||
            (environmentID.isNotEmpty() && environmentID.length <= 128))
}

/**
 * Explicit storage layer. `AppOwned` is the direct-UI default; `Workspace`
 * names a REAL existing workspace row. Storage is deliberately independent
 * of [CreativeOriginContext]: a chat/canvas/files-owned edit may use an
 * app-owned working copy. `environmentID` is never a storage root.
 */
sealed interface CreativeStorageLayer {
    data object AppOwned : CreativeStorageLayer
    data class Workspace(val workspaceID: String) : CreativeStorageLayer
}

object CreativeLimits {
    const val REQUEST_BYTES = 65_536
    const val RESPONSE_BYTES = 16 * 1024 * 1024
    const val CANVAS_PROJECT_BYTES = 15 * 1024 * 1024
    const val MEDIA_PROJECT_BYTES = 8 * 1024 * 1024
    const val ASSET_BYTES = 64 * 1024 * 1024
    const val BATCH_OPERATIONS = 100
    const val MEDIA_COMMANDS = 64
    const val NAME_BYTES = 120
    const val SESSION_TOKEN_BYTES = 128
    const val STAGING_TOKEN_BYTES = 200
    const val RECOVERY_OPERATIONS = 512
    const val LIBRARY_ENTRIES = 500
}

/**
 * Pure path guard shared by host and UI. It is NOT a storage authority: the
 * native side re-resolves and re-validates every path against the accepted
 * root/workspace. It only rejects obvious escapes before a request is made.
 */
object CreativePathGuard {
    fun isSafeRelativePath(path: String?): Boolean {
        if (path == null) return true
        if (path.isEmpty() || path.length > 1024) return false
        if (path.startsWith("/") || path.startsWith("\\")) return false
        if (path.contains('\\') || path.contains('\u0000')) return false
        val components = path.split('/')
        if (components.isEmpty()) return false
        return components.all { it.isNotEmpty() && it != "." && it != ".." }
    }

    fun resolveUnder(rootPath: String, relativePath: String): String? {
        if (!isSafeRelativePath(relativePath)) return null
        val root = File(rootPath).normalize()
        val target = File(root, relativePath).normalize()
        val prefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
        return target.path.takeIf { it.startsWith(prefix) }
    }
}

object CreativeSessionTokens {
    fun newToken(): String = UUID.randomUUID().toString()

    fun isValid(token: String): Boolean =
        token.isNotEmpty() && token.length <= CreativeLimits.SESSION_TOKEN_BYTES &&
            token.all { it.isLetterOrDigit() || it == '-' || it == '_' || it == '.' }
}
