// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.Locale

/**
 * Strict, bounded HTTP/1.1 response message-body framing for the G07.2 speed
 * download.
 *
 * Only representation payload bytes cross [SpeedHttpBodyReader.read]. Chunk
 * sizes, chunk extensions, chunk CRLFs, the terminating zero chunk and trailer
 * fields are framing and are never counted as payload. A Content-Length body
 * stops at the declared boundary without waiting for connection EOF, and a body
 * that ends early is reported as truncated instead of being passed off as
 * complete. Malformed, ambiguous or unsupported framing is refused rather than
 * silently mis-counted.
 */
internal object SpeedHttpBodyLimits {
    /** A single chunk larger than this (1 TiB) is refused as oversized. */
    const val MAX_CHUNK_SIZE_BYTES = 1_099_511_627_776L

    const val MAX_CHUNK_SIZE_HEX_DIGITS = 15
    const val MAX_CHUNK_SIZE_LINE_BYTES = 256
    const val MAX_TRAILER_LINE_BYTES = 1024
    const val MAX_TRAILER_TOTAL_BYTES = 8 * 1024
    const val MAX_TRAILER_COUNT = 32
    const val MAX_FRAMING_VALUE_CHARS = 512
}

/**
 * Typed framing failure. [code] is a bounded, stable completion reason that is
 * safe to return as `completionReason`; the message stays internal.
 */
internal class SpeedHttpProtocolException(
    val code: String,
    message: String? = null,
) : IOException(message ?: code)

/** The framing rules that may legally delimit a response body. */
internal sealed class SpeedHttpBodyFraming {
    data class ContentLength(val length: Long) : SpeedHttpBodyFraming()

    data class Chunked(
        val maxChunkBytes: Long = SpeedHttpBodyLimits.MAX_CHUNK_SIZE_BYTES,
    ) : SpeedHttpBodyFraming()

    object CloseDelimited : SpeedHttpBodyFraming()

    /** Status codes that cannot carry a body (1xx, 204, 205, 304). */
    object NoBody : SpeedHttpBodyFraming()

    val declaredContentLength: Long?
        get() = (this as? ContentLength)?.length

    companion object {
        /**
         * Resolve framing from the actual response head. Content-Length is
         * parsed strictly (identical duplicates are accepted, conflicting or
         * unparsable values are refused) and is never used to synthesize body
         * bytes. Transfer-Encoding and Content-Length together are ambiguous
         * framing and are refused.
         */
        fun from(head: SpeedHttpWire.Head): SpeedHttpBodyFraming {
            if (head.statusCode in 100..199 ||
                head.statusCode == 204 ||
                head.statusCode == 205 ||
                head.statusCode == 304
            ) {
                return NoBody
            }
            val transferValues = head.values("transfer-encoding")
            val lengthValues = head.values("content-length")
            if (transferValues.isNotEmpty() && lengthValues.isNotEmpty()) {
                throw SpeedHttpProtocolException(
                    "ambiguousFraming",
                    "response carries both Transfer-Encoding and Content-Length",
                )
            }
            if (transferValues.isNotEmpty()) return transferEncoding(transferValues)
            if (lengthValues.isNotEmpty()) return contentLength(lengthValues)
            return CloseDelimited
        }

        private fun transferEncoding(values: List<String>): SpeedHttpBodyFraming {
            if (values.any { it.length > SpeedHttpBodyLimits.MAX_FRAMING_VALUE_CHARS }) {
                throw SpeedHttpProtocolException(
                    "oversizedHeaders",
                    "Transfer-Encoding value exceeded its bound",
                )
            }
            val codings = values
                .flatMap { it.split(',') }
                .map { it.trim().lowercase(Locale.ROOT) }
            if (codings.isEmpty() || codings.any { it.isEmpty() }) {
                throw SpeedHttpProtocolException(
                    "unsupportedTransferEncoding",
                    "empty transfer coding",
                )
            }
            // Only a single chunked coding is understood. gzip/compress/deflate
            // transfer codings are not decoded here, and stacked chunked
            // codings would make the declared boundary ambiguous.
            if (codings.size != 1 || codings[0] != "chunked") {
                throw SpeedHttpProtocolException(
                    "unsupportedTransferEncoding",
                    "only one chunked transfer coding is supported",
                )
            }
            return Chunked()
        }

        private fun contentLength(values: List<String>): SpeedHttpBodyFraming {
            if (values.any { it.length > SpeedHttpBodyLimits.MAX_FRAMING_VALUE_CHARS }) {
                throw SpeedHttpProtocolException(
                    "oversizedHeaders",
                    "Content-Length value exceeded its bound",
                )
            }
            val tokens = values.flatMap { it.split(',') }.map { it.trim() }
            if (tokens.isEmpty() || tokens.any { it.isEmpty() }) {
                throw SpeedHttpProtocolException(
                    "invalidContentLength",
                    "empty Content-Length value",
                )
            }
            val lengths = tokens.map { token ->
                if (token.any { it !in '0'..'9' }) {
                    throw SpeedHttpProtocolException(
                        "invalidContentLength",
                        "Content-Length is not a bounded decimal length",
                    )
                }
                // Leading zeros are valid; bound the significant digits so the
                // declared length always fits a Long.
                val normalized = token.trimStart('0').ifEmpty { "0" }
                if (normalized.length > 19) {
                    throw SpeedHttpProtocolException(
                        "invalidContentLength",
                        "Content-Length is not a bounded decimal length",
                    )
                }
                normalized.toLongOrNull() ?: throw SpeedHttpProtocolException(
                    "invalidContentLength",
                    "Content-Length is not a bounded decimal length",
                )
            }
            if (lengths.distinct().size != 1) {
                throw SpeedHttpProtocolException(
                    "ambiguousContentLength",
                    "conflicting Content-Length values",
                )
            }
            return ContentLength(lengths[0])
        }
    }
}

/**
 * Reads exactly the representation payload of one HTTP response body.
 *
 * The reader never reads past the declared Content-Length boundary, never
 * returns chunk framing or trailer bytes as payload, and treats premature EOF
 * as a typed truncation failure. Trailer and chunk-line parsing is bounded in
 * line bytes, total bytes and field count. The caller owns the byte/time budget
 * and can simply stop calling [read]; nothing is read speculatively.
 */
internal class SpeedHttpBodyReader(
    private val input: InputStream,
    val framing: SpeedHttpBodyFraming,
) {
    private enum class ChunkState { SIZE, DATA, DATA_CRLF, DONE }

    private var contentLengthRemaining: Long =
        (framing as? SpeedHttpBodyFraming.ContentLength)?.length ?: 0L
    private var chunkRemaining: Long = 0L
    private var chunkState: ChunkState = ChunkState.SIZE
    private var trailerBytes: Int = 0
    private var trailerCount: Int = 0

    /** True only after the complete message body was consumed and validated. */
    var messageComplete: Boolean = false
        private set

    fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (messageComplete) return -1
        return when (framing) {
            is SpeedHttpBodyFraming.ContentLength -> readContentLength(buffer, offset, length)
            is SpeedHttpBodyFraming.Chunked -> readChunked(buffer, offset, length)
            is SpeedHttpBodyFraming.CloseDelimited -> {
                val read = input.read(buffer, offset, length)
                if (read < 0) messageComplete = true
                read
            }
            is SpeedHttpBodyFraming.NoBody -> {
                messageComplete = true
                -1
            }
        }
    }

    private fun readContentLength(buffer: ByteArray, offset: Int, length: Int): Int {
        if (contentLengthRemaining == 0L) {
            messageComplete = true
            return -1
        }
        val want = minOf(length.toLong(), contentLengthRemaining).toInt()
        val read = input.read(buffer, offset, want)
        if (read < 0) {
            throw SpeedHttpProtocolException(
                "truncatedBody",
                "response body ended with $contentLengthRemaining declared bytes missing",
            )
        }
        if (read == 0) return 0
        contentLengthRemaining -= read
        if (contentLengthRemaining == 0L) messageComplete = true
        return read
    }

    private fun readChunked(buffer: ByteArray, offset: Int, length: Int): Int {
        while (true) {
            when (chunkState) {
                ChunkState.SIZE -> {
                    val line = readFramingLine(SpeedHttpBodyLimits.MAX_CHUNK_SIZE_LINE_BYTES)
                    val size = parseChunkSize(line)
                    if (size == 0L) {
                        readTrailers()
                        chunkState = ChunkState.DONE
                        messageComplete = true
                        return -1
                    }
                    chunkRemaining = size
                    chunkState = ChunkState.DATA
                }

                ChunkState.DATA -> {
                    val want = minOf(length.toLong(), chunkRemaining).toInt()
                    val read = input.read(buffer, offset, want)
                    if (read < 0) {
                        throw SpeedHttpProtocolException(
                            "truncatedBody",
                            "chunked body ended inside a chunk",
                        )
                    }
                    if (read == 0) return 0
                    chunkRemaining -= read
                    if (chunkRemaining == 0L) chunkState = ChunkState.DATA_CRLF
                    return read
                }

                ChunkState.DATA_CRLF -> {
                    val carriageReturn = input.read()
                    if (carriageReturn < 0) {
                        throw SpeedHttpProtocolException(
                            "truncatedBody",
                            "chunked body ended before the chunk terminating CRLF",
                        )
                    }
                    if (carriageReturn != '\r'.code) {
                        throw SpeedHttpProtocolException(
                            "invalidChunkFraming",
                            "chunk data is not followed by CRLF",
                        )
                    }
                    val lineFeed = input.read()
                    if (lineFeed < 0) {
                        throw SpeedHttpProtocolException(
                            "truncatedBody",
                            "chunked body ended before the chunk terminating CRLF",
                        )
                    }
                    if (lineFeed != '\n'.code) {
                        throw SpeedHttpProtocolException(
                            "invalidChunkFraming",
                            "chunk data is not followed by CRLF",
                        )
                    }
                    chunkState = ChunkState.SIZE
                }

                ChunkState.DONE -> {
                    messageComplete = true
                    return -1
                }
            }
        }
    }

    private fun readFramingLine(maxBytes: Int): ByteArray {
        val output = ByteArrayOutputStream(minOf(maxBytes, 256))
        while (true) {
            val value = input.read()
            if (value < 0) {
                throw SpeedHttpProtocolException(
                    "truncatedBody",
                    "chunked framing ended before CRLF",
                )
            }
            if (value == '\r'.code) {
                val next = input.read()
                if (next < 0) {
                    throw SpeedHttpProtocolException(
                        "truncatedBody",
                        "chunked framing ended before CRLF",
                    )
                }
                if (next != '\n'.code) {
                    throw SpeedHttpProtocolException(
                        "invalidChunkFraming",
                        "chunked framing line is not CRLF-terminated",
                    )
                }
                return output.toByteArray()
            }
            if (value == '\n'.code) {
                throw SpeedHttpProtocolException(
                    "invalidChunkFraming",
                    "chunked framing line is not CRLF-terminated",
                )
            }
            if (output.size() >= maxBytes) {
                throw SpeedHttpProtocolException(
                    "oversizedChunkFraming",
                    "chunked framing line exceeded $maxBytes bytes",
                )
            }
            output.write(value)
        }
    }

    private fun parseChunkSize(line: ByteArray): Long {
        val text = String(line, Charsets.ISO_8859_1)
        if (text.any { it.code < 0x20 || it.code > 0x7E }) {
            throw SpeedHttpProtocolException(
                "invalidChunkFraming",
                "chunk size line contains non-visible characters",
            )
        }
        val separator = text.indexOf(';')
        val sizeText = if (separator >= 0) text.substring(0, separator) else text
        if (sizeText.isEmpty()) {
            throw SpeedHttpProtocolException("invalidChunkFraming", "missing chunk size")
        }
        if (sizeText.length > SpeedHttpBodyLimits.MAX_CHUNK_SIZE_HEX_DIGITS) {
            throw SpeedHttpProtocolException(
                "oversizedChunkFraming",
                "chunk size has too many hex digits",
            )
        }
        var size = 0L
        for (character in sizeText) {
            val digit = when (character) {
                in '0'..'9' -> character - '0'
                in 'a'..'f' -> character - 'a' + 10
                in 'A'..'F' -> character - 'A' + 10
                else -> throw SpeedHttpProtocolException(
                    "invalidChunkFraming",
                    "chunk size is not hexadecimal",
                )
            }
            size = size * 16L + digit
        }
        val maxChunkBytes = (framing as? SpeedHttpBodyFraming.Chunked)
            ?.maxChunkBytes
            ?: SpeedHttpBodyLimits.MAX_CHUNK_SIZE_BYTES
        if (size > maxChunkBytes) {
            throw SpeedHttpProtocolException(
                "oversizedChunkFraming",
                "chunk size exceeded the bounded maximum",
            )
        }
        return size
    }

    private fun readTrailers() {
        while (true) {
            val line = readFramingLine(SpeedHttpBodyLimits.MAX_TRAILER_LINE_BYTES)
            if (line.isEmpty()) return
            trailerBytes += line.size + 2
            if (trailerBytes > SpeedHttpBodyLimits.MAX_TRAILER_TOTAL_BYTES) {
                throw SpeedHttpProtocolException(
                    "oversizedChunkFraming",
                    "trailer section exceeded its byte bound",
                )
            }
            trailerCount++
            if (trailerCount > SpeedHttpBodyLimits.MAX_TRAILER_COUNT) {
                throw SpeedHttpProtocolException(
                    "oversizedChunkFraming",
                    "trailer field count exceeded its bound",
                )
            }
            validateTrailerLine(line)
        }
    }

    private fun validateTrailerLine(line: ByteArray) {
        val text = String(line, Charsets.ISO_8859_1)
        val separator = text.indexOf(':')
        if (separator <= 0) {
            throw SpeedHttpProtocolException(
                "invalidChunkFraming",
                "trailer field has no name",
            )
        }
        val name = text.substring(0, separator)
        if (name.any { !isTokenCharacter(it) }) {
            throw SpeedHttpProtocolException(
                "invalidChunkFraming",
                "trailer field name is not a token",
            )
        }
        val value = text.substring(separator + 1)
        if (value.any { (it.code < 0x20 && it != '\t') || it.code == 0x7F }) {
            throw SpeedHttpProtocolException(
                "invalidChunkFraming",
                "trailer field value contains a control character",
            )
        }
    }

    private fun isTokenCharacter(character: Char): Boolean =
        character in '0'..'9' ||
            character in 'A'..'Z' ||
            character in 'a'..'z' ||
            character in "!#$%&'*+-.^_`|~"
}
