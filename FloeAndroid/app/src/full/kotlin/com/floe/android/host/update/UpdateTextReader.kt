// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer

/** Decode only after the bounded response is complete: a network read may
 * end inside any UTF-8 character, regardless of the source's JSON framing. */
internal object UpdateTextReader {
    fun read(input: InputStream, limit: Long, oversized: () -> Nothing): String {
        require(limit in 0..Int.MAX_VALUE.toLong())
        val bytes = ByteArrayOutputStream(minOf(limit, 16_384L).toInt())
        val buffer = ByteArray(16_384)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) oversized()
            bytes.write(buffer, 0, count)
        }
        return Charsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
    }
}
