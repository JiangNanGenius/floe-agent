// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeLimits
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns the SAF read → bounded staging lifecycle for Canvas/media assets.
 *
 * A staging token is opaque to features and to the model. The file lives
 * under `<acceptedRoot>/FloeAgent/CreativeIncoming`, is fully fsynced, and is
 * consumed/deleted by the native importer or by an explicit discard. A
 * cancelled/failed import never leaves a committed token, and a token from a
 * stale session/epoch is refused before any read.
 */
internal class CreativeAssetImportController(
    context: Context,
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val liveEpochProvider: () -> Long?,
    private val pump: CreativeSourcePump = CreativeSourcePump(),
) {
    private val resolver: ContentResolver =
        context.applicationContext.contentResolver
    private val staged = ConcurrentHashMap<String, File>()

    suspend fun stage(
        uri: Uri,
        fileName: String,
        mimeType: String?,
        sessionToken: String,
    ): CreativeStagedAsset {
        CreativeOwnership.requireSessionToken(sessionToken)
        if (staged.size >= MAX_STAGED) {
            throw CreativeException("stagingBusy", "tooManyStagedAssets", retryable = true)
        }
        val accepted = CreativeOwnership.requireLive(
            acceptedRootProvider(), liveEpochProvider())
        val token = CreativeOwnership.newStagingToken(sessionToken)
        val target = CreativeOwnership.stagingFile(accepted, token)
        val safeName = safeDisplayName(fileName)
        val input = try {
            resolver.openInputStream(uri)
        } catch (error: Throwable) {
            null
        } ?: throw CreativeException(
            "assetStagingUnavailable", "sourceUnreadable", retryable = true)
        val bytes = try {
            pump.stage(input, target, CreativeLimits.ASSET_BYTES.toLong())
        } finally {
            runCatching { input.close() }
        }
        staged[token] = target
        return CreativeStagedAsset(
            token = token,
            fileName = safeName,
            mimeType = mimeType?.takeIf { it.isNotBlank() },
            byteCount = bytes.byteCount,
            sha256 = bytes.sha256,
            file = target,
        )
    }

    /**
     * Stage a SAF source whose display name/MIME are resolved from the real
     * provider rather than accepted from UI text. `createCanvasFromUri` /
     * `createMediaFromUri` use this: the name is display metadata only and the
     * MIME is a hint — kind/dimensions are measured from the staged bytes.
     */
    suspend fun stage(uri: Uri, sessionToken: String): CreativeStagedAsset {
        val resolved = resolveSourceMetadata(uri)
        return stage(uri, resolved.first, resolved.second, sessionToken)
    }

    private fun resolveSourceMetadata(uri: Uri): Pair<String, String?> {
        val mimeType = runCatching { resolver.getType(uri) }.getOrNull()
        val displayName = runCatching {
            resolver.query(
                uri, arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
            }
        }.getOrNull()
        val fallback = uri.lastPathSegment?.substringAfterLast('/')
        return (displayName ?: fallback ?: "import") to mimeType
    }

    /** Explicit cancel/discard of a token this controller minted. */
    fun discard(token: String) {
        staged.remove(token)?.delete()
    }

    /** Called on Root stop; deletes only this controller's staging files. */
    fun discardAll() {
        for (file in staged.values) file.delete()
        staged.clear()
    }

    private fun safeDisplayName(raw: String): String {
        val name = File(raw).name
            .trim()
            .filter { it.isLetterOrDigit() || it in "-_. ()" }
        if (name.isEmpty()) {
            throw CreativeException("assetStagingInvalid", "invalidFileName")
        }
        return name.take(96)
    }

    private companion object {
        const val MAX_STAGED = 32
    }
}
