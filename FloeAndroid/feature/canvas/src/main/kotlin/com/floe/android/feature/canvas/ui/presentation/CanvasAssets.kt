// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.canvas.ui.presentation

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import com.floe.android.feature.canvas.CanvasAssetReference
import com.floe.android.feature.canvas.CreativePathGuard
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Canonical, contained preview path for one Canvas asset.
 *
 * `CanvasProjectEnvelope.assetsBasePath` is the trusted Materials directory.
 * An asset relative path may legally start with one `Materials/` prefix (the
 * iOS/native stored spelling); exactly one prefix is stripped, never a
 * duplicated one. Nothing else from the project JSON is ever used as a root.
 */
object CanvasAssetPaths {
    fun resolve(assetsBasePath: String, reference: CanvasAssetReference?): String? {
        val relative = reference?.localRelativePath?.takeIf { it.isNotEmpty() } ?: return null
        if (!CreativePathGuard.isSafeRelativePath(relative)) return null
        if (assetsBasePath.isEmpty()) return null
        val normalized = if (relative.startsWith("Materials/")) {
            relative.removePrefix("Materials/")
        } else {
            relative
        }
        if (!CreativePathGuard.isSafeRelativePath(normalized) || normalized.isEmpty()) return null
        return try {
            val root = File(assetsBasePath).canonicalFile
            if (!root.isDirectory) return null
            val target = File(root, normalized).canonicalFile
            val prefix = root.path.trimEnd(File.separatorChar) + File.separatorChar
            target.path.takeIf { it.startsWith(prefix) && File(it).isFile }
        } catch (_: Throwable) {
            null
        }
    }

    /** Display spelling only; never a filesystem authority. */
    fun relativeSpelling(reference: CanvasAssetReference?): String? =
        reference?.localRelativePath
}

/**
 * Bounded preview decoder. Never decodes the full source when a sampled
 * bitmap is enough for an on-screen card; all work runs off the UI thread.
 * The cache holds decoded bitmaps by path/size and never recycles bitmap
 * instances that Compose may still be drawing.
 */
object CanvasBitmapLoader {
    private const val MAX_EDGE = 2048
    private const val MAX_PIXELS = 4_000_000L
    private const val MAX_SAMPLE = 64

    private val cache = object : LruCache<String, Bitmap>(48 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

    suspend fun load(
        assetsBasePath: String,
        reference: CanvasAssetReference?,
    ): Bitmap? = withContext(Dispatchers.IO) {
        val path = CanvasAssetPaths.resolve(assetsBasePath, reference)
            ?: return@withContext null
        load(path)
    }

    suspend fun load(path: String): Bitmap? = withContext(Dispatchers.IO) {
        val key = "$path|$MAX_EDGE"
        synchronized(cache) { cache.get(key) }?.let { if (!it.isRecycled) return@withContext it }
        val decoded = decode(path) ?: return@withContext null
        synchronized(cache) { cache.put(key, decoded) }
        decoded
    }

    fun forget(path: String) {
        synchronized(cache) {
            cache.remove("$path|$MAX_EDGE")
        }
    }

    fun clear() {
        synchronized(cache) { cache.evictAll() }
    }

    private fun decode(path: String): Bitmap? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            BitmapFactory.decodeFile(path, options)
        } catch (_: Throwable) {
            null
        }
    }

    private fun sampleSize(width: Int, height: Int): Int {
        var sample = 1
        while (sample < MAX_SAMPLE) {
            val w = width / sample
            val h = height / sample
            if (w in 1..MAX_EDGE && h in 1..MAX_EDGE &&
                w.toLong() * h.toLong() <= MAX_PIXELS
            ) {
                return sample
            }
            sample *= 2
        }
        return sample
    }
}
