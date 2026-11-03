// SPDX-License-Identifier: MPL-2.0
//
// Android decode of a bounded inserted WebP into a PNG for the DERIVED GLB
// only. The source package bytes, media type and digests are never changed;
// the adapter only supplies the texture encoding the pinned glTF reader can
// actually consume.
package com.floe.android.host.cad

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream

internal class C04FloecadAndroidImageDecoder : C04FloecadImageDecoder {
    override fun toPng(bytes: ByteArray, mediaType: String): ByteArray? {
        if (mediaType != "image/webp" || bytes.isEmpty() ||
            bytes.size > C04FloecadLimits.MAX_TEXTURE_BYTES
        ) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        if (width < 1 || height < 1 ||
            width > C04FloecadLimits.MAX_TEXTURE_EDGE ||
            height > C04FloecadLimits.MAX_TEXTURE_EDGE
        ) return null
        var sample = 1
        while (width / sample > C04FloecadLimits.MAX_TEXTURE_EDGE / 2 ||
            height / sample > C04FloecadLimits.MAX_TEXTURE_EDGE / 2
        ) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inScaled = false
        }
        val bitmap = try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        } catch (_: Throwable) {
            null
        } ?: return null
        return try {
            val output = ByteArrayOutputStream()
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) return null
            val png = output.toByteArray()
            if (png.isEmpty() || png.size > C04FloecadLimits.MAX_TEXTURE_BYTES) return null
            if (!looksLikePng(png)) return null
            val check = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(png, 0, png.size, check)
            if (check.outWidth != bitmap.width || check.outHeight != bitmap.height) return null
            png
        } catch (_: Throwable) {
            null
        } finally {
            bitmap.recycle()
        }
    }

    private fun looksLikePng(bytes: ByteArray): Boolean =
        bytes.size > 33 &&
            bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() &&
            bytes[2] == 0x4E.toByte() && bytes[3] == 0x47.toByte() &&
            bytes[12] == 0x49.toByte() && bytes[13] == 0x48.toByte() &&
            bytes[14] == 0x44.toByte() && bytes[15] == 0x52.toByte()
}
