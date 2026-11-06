// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.IOException
import java.io.InputStream
import kotlin.math.max
import kotlin.math.sqrt

/** Bound decoding by pixels, not by the compressed size of a tall screenshot. */
internal object ReportScreenshot {
    const val INPUT_LIMIT = 64L * 1024 * 1024
    const val OUTPUT_LIMIT = 1024 * 1024
    private const val PIXELS = 4_000_000L
    private const val EDGE = 4096

    fun sampleSize(width: Int, height: Int): Int {
        require(width > 0 && height > 0) { "image_invalid" }
        var sample = 1
        while ((width.toLong() + sample - 1) / sample > EDGE ||
            (height.toLong() + sample - 1) / sample > EDGE ||
            ((width.toLong() + sample - 1) / sample) * ((height.toLong() + sample - 1) / sample) > PIXELS) {
            sample *= 2
        }
        return sample
    }

    fun prepare(input: InputStream, source: File, destination: File): File {
        var bitmap: Bitmap? = null
        try {
            input.use { stream -> source.outputStream().use { output ->
                val buffer = ByteArray(32768)
                var size = 0L
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    size += count
                    if (size > INPUT_LIMIT) throw IOException("image_too_large")
                    output.write(buffer, 0, count)
                }
            } }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(source.path, bounds)
            val options = BitmapFactory.Options().apply {
                inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            bitmap = BitmapFactory.decodeFile(source.path, options) ?: throw IOException("image_invalid")
            // Enforce the final contract even if a device decoder rounds its sample dimensions.
            val scale = minOf(1.0, EDGE.toDouble() / max(bitmap.width, bitmap.height),
                sqrt(PIXELS.toDouble() / (bitmap.width.toLong() * bitmap.height)))
            if (scale < 1.0) {
                val reduced = Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * scale).toInt()),
                    max(1, (bitmap.height * scale).toInt()), true)
                if (reduced !== bitmap) bitmap.recycle()
                bitmap = reduced
            }
            repeat(5) {
                for (quality in intArrayOf(88, 76, 64, 52)) {
                    destination.outputStream().use { output ->
                        if (!bitmap!!.compress(Bitmap.CompressFormat.JPEG, quality, output))
                            throw IOException("image_invalid")
                    }
                    if (destination.length() in 1..OUTPUT_LIMIT.toLong()) return destination
                }
                val current = bitmap!!
                val reduced = Bitmap.createScaledBitmap(current, max(1, current.width * 3 / 4),
                    max(1, current.height * 3 / 4), true)
                if (reduced !== current) current.recycle()
                bitmap = reduced
            }
            throw IOException("image_too_large")
        } catch (error: OutOfMemoryError) {
            destination.delete()
            throw IOException("image_memory", error)
        } catch (error: Exception) {
            destination.delete()
            throw error
        } finally {
            bitmap?.recycle()
            source.delete()
        }
    }
}
