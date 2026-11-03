// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

/**
 * Memory bound for the owned-output image viewport: the SMALLEST power-of-
 * two sample size that brings BOTH decoded axes within [maxDimensionPx].
 * File-byte caps do not bound decoded pixel memory, so this decision is
 * made BEFORE decode from the bounded header probe only.
 *
 * Pure JVM (no Android types) so the production function itself is directly
 * unit-testable; the Activity only feeds it the probed bounds. Integer
 * division keeps every iteration overflow-safe at any real image size
 * (a reported dimension can never exceed Int range, and `sample` at most
 * doubles past the answer once).
 */
internal fun runOutputImageSampleSize(width: Int, height: Int, maxDimensionPx: Int): Int {
    require(width > 0 && height > 0 && maxDimensionPx > 0) {
        "sample size needs positive dimensions and cap"
    }
    var sample = 1
    while ((width - 1) / sample >= maxDimensionPx || (height - 1) / sample >= maxDimensionPx) {
        require(sample <= Int.MAX_VALUE / 2) { "image cannot fit the sample limit" }
        sample *= 2
    }
    return sample
}
