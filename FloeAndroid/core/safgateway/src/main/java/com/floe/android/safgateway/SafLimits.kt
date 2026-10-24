// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

/**
 * Boundaries for streaming and paging. There is deliberately NO default total
 * byte cap: callers must declare `byteLimit` per operation, so an unknown-size
 * file can never be pulled fully into memory or onto disk by accident.
 */
data class SafLimits(
    val chunkBytes: Int = 64 * 1024,
    val maxPageItems: Int = 512,
    val defaultPageItems: Int = 256,
    /** UTF-8 byte cap for a sanitized staging file name (path stays app-owned). */
    val maxStagedNameBytes: Int = 180,
) {
    init {
        require(chunkBytes in 4096..1024 * 1024)
        require(maxPageItems in 1..2048)
        require(defaultPageItems in 1..maxPageItems)
        require(maxStagedNameBytes in 32..255)
    }

    companion object {
        val DEFAULT = SafLimits()
    }
}
