// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

/**
 * Bounded image sampling rule for verified design previews.
 *
 * The Android bitmap factory must never allocate a full-resolution bitmap for
 * an extreme aspect ratio: EITHER dimension has to be bounded before the real
 * decode. The previous loop used `&&`, so a 4000x100 image stayed at sample 1
 * and allocated 400k+ pixels even though the width was already over the cap.
 * Pixels are also capped independently, and the decoded callback still checks
 * the real `Bitmap.byteCount` before it is shown.
 */
internal object DesignImageBounds {
    const val MAX_IMAGE_PIXELS = 16_000_000L
    const val MAX_IMAGE_DIMENSION = 2048
    const val MAX_IMAGE_BITMAP_BYTES = 32 * 1024 * 1024

    /**
     * Power-of-two sample size that bounds BOTH decoded dimensions. Returns 1
     * for an already-bounded image; callers must reject non-positive bounds
     * and pixel counts over [MAX_IMAGE_PIXELS] before calling this.
     */
    fun sampleSize(width: Int, height: Int): Int {
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        // `sample` doubles until EITHER dimension fits. A dimension this
        // large cannot be produced by any supported decoder; refusing is
        // safer than letting the shift path run past the bound.
        while (width / sample > MAX_IMAGE_DIMENSION ||
            height / sample > MAX_IMAGE_DIMENSION
        ) {
            if (sample > MAX_SAMPLE) return 0
            sample *= 2
        }
        return sample
    }

    private const val MAX_SAMPLE = 1 shl 20
}
