// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.graphics.Bitmap
import com.floe.android.feature.canvas.CanvasDocument
import com.floe.android.feature.canvas.ui.design.DesignPreviewContent
import com.floe.android.feature.canvas.ui.presentation.CanvasAssetPaths
import com.floe.android.feature.canvas.ui.presentation.CanvasBitmapLoader
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Read-only resolver for the REAL image bytes referenced by a captured design
 * Canvas snapshot.
 *
 * The `canvas.snapshot` JSON carries asset ids/digests, never paths or bytes.
 * This owner therefore:
 *  1. takes the trusted `assetsBasePath` of the CAPTURED native Canvas owner
 *     (the live Canvas editor envelope for the same canvas) and re-proves it
 *     is contained by the CURRENT accepted Root before use;
 *  2. resolves only the captured document's asset relative reference under
 *     that trusted root (safe-path + containment guard);
 *  3. hashes the real file and requires equality with the snapshot digest
 *     (and any node-reference digest) before decoding it;
 *  4. decodes through the EXISTING bounded Canvas bitmap loader.
 *
 * A missing/unverifiable/oversize asset is omitted, so the preview shows the
 * existing honest placeholder. No recorded root, receipt path or JSON-declared
 * path is ever used as authority, no transient Canvas editor session is
 * registered (the live editor token is never replaced) and no Canvas write
 * occurs.
 */
internal class DesignCanvasAssetReader {
    suspend fun readVerifiedBitmaps(
        document: CanvasDocument,
        assets: List<DesignPreviewContent.CanvasSnapshotAsset>,
        trustedRoot: File,
    ): Map<String, Bitmap> = withContext(Dispatchers.IO) {
        val expected = assets.filter {
            it.verified &&
                it.kind.equals(IMAGE_KIND, ignoreCase = true) &&
                it.contentHash != null
        }
        if (expected.isEmpty()) return@withContext emptyMap()
        val references = document.nodes
            .mapNotNull { node -> node.asset?.let { it.id to it } }
            .toMap()
        val bitmaps = LinkedHashMap<String, Bitmap>()
        for (asset in expected) {
            try {
                val reference = references[asset.assetID] ?: continue
                val expectedDigest = asset.contentHash ?: continue
                val referenceDigest = reference.contentHash
                if (referenceDigest != null &&
                    !referenceDigest.equals(expectedDigest, ignoreCase = true)
                ) {
                    continue
                }
                val path = CanvasAssetPaths.resolve(trustedRoot.path, reference) ?: continue
                val file = runCatching { File(path) }.getOrNull() ?: continue
                if (!file.isFile) continue
                val length = file.length()
                if (length <= 0L || length > MAX_ASSET_BYTES) continue
                val declared = asset.byteCount
                if (declared != null && declared > 0L && declared != length) continue
                val digest = sha256(file) ?: continue
                if (!digest.equals(expectedDigest, ignoreCase = true)) continue
                val bitmap = CanvasBitmapLoader.load(path) ?: continue
                bitmaps[asset.assetID] = bitmap
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // One unverifiable asset must not fail the whole scene.
                continue
            }
        }
        bitmaps
    }

    private fun sha256(file: File): String? = try {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_ASSET_BYTES) throw IllegalStateException("assetCap")
                digest.update(buffer, 0, read)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it) }
    } catch (_: Throwable) {
        null
    }

    private companion object {
        const val IMAGE_KIND = "image"
        const val MAX_ASSET_BYTES = 64L * 1024 * 1024
    }
}
