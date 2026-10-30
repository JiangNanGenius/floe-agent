// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Pure byte-stream fixtures for the strict HTTP response body framing used by
 * the G07.2 speed download. These tests prove that only representation payload
 * bytes are returned and that malformed, ambiguous or truncated framing is
 * refused instead of being counted as a successful transfer.
 */
class SpeedHttpBodyFramingTest {
    @Test
    fun contentLengthStopsAtDeclaredBoundaryWithoutWaitingForEof() {
        // The stream is poisoned after the declared body. A reader that waited
        // for connection EOF or read ahead would throw.
        val stream = PoisonAfterBytesStream(
            bytes(headBlock(headers = listOf("Content-Length: 5")) + "hello"),
        )
        val head = SpeedHttpWire.readHead(stream)
        val framing = SpeedHttpBodyFraming.from(head)
        assertEquals(5L, framing.declaredContentLength!!)
        val reader = SpeedHttpBodyReader(stream, framing)
        val buffer = ByteArray(32)
        assertEquals(5, reader.read(buffer, 0, buffer.size))
        assertEquals("hello", String(buffer, 0, 5, Charsets.ISO_8859_1))
        assertEquals(-1, reader.read(buffer, 0, buffer.size))
        assertTrue(reader.messageComplete)
    }

    @Test
    fun contentLengthPrematureEofIsTruncatedAndRetainsReadBytes() {
        val stream = ByteArrayInputStream(
            bytes(headBlock(headers = listOf("Content-Length: 10")) + "abcd"),
        )
        val head = SpeedHttpWire.readHead(stream)
        val reader = SpeedHttpBodyReader(stream, SpeedHttpBodyFraming.from(head))
        val meter = SpeedMeter(warmupBytes = 0)
        val buffer = ByteArray(8)
        val first = reader.read(buffer, 0, buffer.size)
        assertEquals(4, first)
        meter.recordMeasured(first, 1_000_000L)
        expectCode("truncatedBody") { reader.read(buffer, 0, buffer.size) }
        assertEquals(4L, meter.payloadBytes)
        assertEquals(4L, meter.measuredBytes)
        assertFalse(reader.messageComplete)
    }

    @Test
    fun duplicateIdenticalContentLengthIsAcceptedAndConflictingIsRejected() {
        val parsed = SpeedHttpWire.readHead(
            ByteArrayInputStream(
                bytes(
                    headBlock(
                        headers = listOf(
                            "Content-Length: 5",
                            "Content-Length: 5",
                        ),
                    ),
                ),
            ),
        )
        assertEquals(listOf("5", "5"), parsed.values("content-length"))
        assertEquals(5L, SpeedHttpBodyFraming.from(parsed).declaredContentLength!!)
        assertEquals(
            5L,
            framingOf(headBlock(headers = listOf("Content-Length: 5, 5")))
                .declaredContentLength!!,
        )
        assertEquals(
            5L,
            framingOf(headBlock(headers = listOf("Content-Length: 0005")))
                .declaredContentLength!!,
        )

        expectCode("ambiguousContentLength") {
            framingOf(
                headBlock(
                    headers = listOf(
                        "Content-Length: 5",
                        "Content-Length: 6",
                    ),
                ),
            )
        }
        expectCode("ambiguousContentLength") {
            framingOf(headBlock(headers = listOf("Content-Length: 5, 6")))
        }
    }

    @Test
    fun invalidContentLengthIsRejectedInsteadOfBecomingCloseDelimited() {
        listOf("abc", "-1", "", "5x", "99999999999999999999").forEach { value ->
            expectCode("invalidContentLength") {
                framingOf(headBlock(headers = listOf("Content-Length: $value")))
            }
        }
    }

    @Test
    fun transferEncodingWithContentLengthIsAmbiguousAndRejected() {
        expectCode("ambiguousFraming") {
            framingOf(
                headBlock(
                    headers = listOf(
                        "Transfer-Encoding: chunked",
                        "Content-Length: 5",
                    ),
                ),
            )
        }
    }

    @Test
    fun unsupportedTransferEncodingsAreRejected() {
        listOf("identity", "gzip, chunked", "chunked, chunked", "chunked,").forEach { value ->
            expectCode("unsupportedTransferEncoding") {
                framingOf(headBlock(headers = listOf("Transfer-Encoding: $value")))
            }
        }
    }

    @Test
    fun chunkedBodyWithExtensionsAndTrailersReturnsOnlyPayload() {
        val body = bytes(
            "4;name=value\r\nWiki\r\n" +
                "05\r\npedia\r\n" +
                "0\r\nX-Checksum: abc\r\n\r\n",
        )
        val (head, reader) = readerFor(
            headBlock(headers = listOf("Transfer-Encoding: chunked")),
            body,
        )
        assertEquals(200, head.statusCode)
        assertTrue(reader.framing is SpeedHttpBodyFraming.Chunked)
        assertNull(reader.framing.declaredContentLength)
        assertArrayEquals(bytes("Wikipedia"), drain(reader))
        assertTrue(reader.messageComplete)
    }

    @Test
    fun emptyChunkedBodyCompletesWithoutPayload() {
        val (_, reader) = readerFor(
            headBlock(headers = listOf("Transfer-Encoding: chunked")),
            bytes("0\r\n\r\n"),
        )
        assertArrayEquals(ByteArray(0), drain(reader))
        assertTrue(reader.messageComplete)
    }

    @Test
    fun invalidAndOversizedChunkSizesAreRejected() {
        expectCode("invalidChunkFraming") {
            chunkedReader("zz\r\n").read(ByteArray(8), 0, 8)
        }
        expectCode("invalidChunkFraming") {
            chunkedReader(" 4\r\nWiki\r\n0\r\n\r\n").read(ByteArray(8), 0, 8)
        }
        expectCode("oversizedChunkFraming") {
            chunkedReader("FFFFFFFFFFFFFFFF\r\n").read(ByteArray(8), 0, 8)
        }
        expectCode("oversizedChunkFraming") {
            chunkedReader("10000000001\r\n").read(ByteArray(8), 0, 8)
        }
        expectCode("oversizedChunkFraming") {
            chunkedReader("4;" + "x".repeat(300) + "\r\n").read(ByteArray(8), 0, 8)
        }
    }

    @Test
    fun malformedOrTruncatedChunkFramingIsRejected() {
        val buffer = ByteArray(8)

        val badTerminator = chunkedReader("4\r\nWikiXX5\r\npedia\r\n0\r\n\r\n")
        assertEquals(4, badTerminator.read(buffer, 0, buffer.size))
        expectCode("invalidChunkFraming") {
            badTerminator.read(buffer, 0, buffer.size)
        }

        val truncatedData = chunkedReader("4\r\nWi")
        assertEquals(2, truncatedData.read(buffer, 0, buffer.size))
        expectCode("truncatedBody") {
            truncatedData.read(buffer, 0, buffer.size)
        }
        assertFalse(truncatedData.messageComplete)

        val truncatedTrailer = chunkedReader("0\r\n")
        expectCode("truncatedBody") {
            truncatedTrailer.read(buffer, 0, buffer.size)
        }

        val bareLineFeed = chunkedReader("4\nWiki\r\n0\r\n\r\n")
        expectCode("invalidChunkFraming") {
            bareLineFeed.read(buffer, 0, buffer.size)
        }
    }

    @Test
    fun trailerBoundsAreEnforced() {
        val buffer = ByteArray(8)
        expectCode("oversizedChunkFraming") {
            chunkedReader("0\r\n" + "X-A: b\r\n".repeat(33) + "\r\n")
                .read(buffer, 0, buffer.size)
        }
        expectCode("oversizedChunkFraming") {
            chunkedReader("0\r\nX-Big: " + "a".repeat(1100) + "\r\n\r\n")
                .read(buffer, 0, buffer.size)
        }
        expectCode("oversizedChunkFraming") {
            chunkedReader(
                "0\r\n" + ("X-Pad: " + "a".repeat(900) + "\r\n").repeat(10) + "\r\n",
            ).read(buffer, 0, buffer.size)
        }
        expectCode("invalidChunkFraming") {
            chunkedReader("0\r\nNoColon\r\n\r\n").read(buffer, 0, buffer.size)
        }
    }

    @Test
    fun closeDelimitedBodyReadsUntilEofAndInventsNoLength() {
        val (_, reader) = readerFor(headBlock(), bytes("abcdef"))
        assertEquals(SpeedHttpBodyFraming.CloseDelimited, reader.framing)
        assertNull(reader.framing.declaredContentLength)
        assertArrayEquals(bytes("abcdef"), drain(reader))
        assertTrue(reader.messageComplete)
    }

    @Test
    fun noBodyStatusesHaveNoPayloadEvenWithFramingHeaders() {
        listOf(100, 204, 205, 304).forEach { status ->
            val head = SpeedHttpWire.Head(
                statusCode = status,
                headers = mapOf(
                    "content-length" to "9",
                    "transfer-encoding" to "chunked",
                ),
                headerValues = mapOf(
                    "content-length" to listOf("9"),
                    "transfer-encoding" to listOf("chunked"),
                ),
            )
            val framing = SpeedHttpBodyFraming.from(head)
            assertEquals(SpeedHttpBodyFraming.NoBody, framing)
            val stream = ByteArrayInputStream(bytes("123456789"))
            val reader = SpeedHttpBodyReader(stream, framing)
            assertEquals(-1, reader.read(ByteArray(4), 0, 4))
            assertTrue(reader.messageComplete)
            assertEquals(9, stream.available())
        }
    }

    @Test
    fun responseHeaderBoundsAreEnforced() {
        expectCode("oversizedHeaders") {
            SpeedHttpWire.readHead(
                ByteArrayInputStream(
                    bytes("HTTP/1.1 200 OK\r\nX-Pad: " + "a".repeat(33_000) + "\r\n\r\n"),
                ),
            )
        }

        val tooManyFields = buildString {
            append("HTTP/1.1 200 OK\r\n")
            repeat(65) { index -> append("X-").append(index).append(": v\r\n") }
            append("\r\n")
        }
        expectCode("oversizedHeaders") {
            SpeedHttpWire.readHead(ByteArrayInputStream(bytes(tooManyFields)))
        }

        expectCode("truncatedHeaders") {
            SpeedHttpWire.readHead(
                ByteArrayInputStream(
                    bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"),
                ),
            )
        }

        // Obsolete line folding must not be able to alter a framing header.
        expectCode("malformedHeaders") {
            SpeedHttpWire.readHead(
                ByteArrayInputStream(
                    bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n 0\r\n\r\n"),
                ),
            )
        }

        // A malformed field line must not silently hide Transfer-Encoding and
        // let chunk framing be counted as payload.
        expectCode("malformedHeaders") {
            SpeedHttpWire.readHead(
                ByteArrayInputStream(
                    bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding chunked\r\n\r\n"),
                ),
            )
        }
    }

    @Test
    fun warmupAndByteBudgetCountPayloadOnlyAndStopBeforeTrailers() {
        // A valid chunked message whose bytes after the 8th payload byte are
        // poisoned. The accounting loop below must stop on the byte budget
        // before touching the chunk CRLF, zero chunk or trailer section.
        val stream = PoisonAfterBytesStream(
            bytes(
                headBlock(headers = listOf("Transfer-Encoding: chunked")) +
                    "5\r\n01234\r\n" +
                    "5\r\n567",
            ),
        )
        val head = SpeedHttpWire.readHead(stream)
        val reader = SpeedHttpBodyReader(stream, SpeedHttpBodyFraming.from(head))
        val meter = SpeedMeter(warmupBytes = 3)
        val budget = 8L
        val buffer = ByteArray(4)
        var now = 2_000_000_000L
        while (meter.payloadBytes < budget) {
            val remainingWarmup = 3L - meter.warmupCompletedBytes
            val want = minOf(
                buffer.size.toLong(),
                budget - meter.payloadBytes,
                if (remainingWarmup > 0L) remainingWarmup else Long.MAX_VALUE,
            ).toInt()
            if (remainingWarmup <= 0L) meter.beginMeasuredIo(now)
            val read = reader.read(buffer, 0, want)
            assertTrue("expected payload before the byte budget", read > 0)
            now += 1_000_000L
            if (remainingWarmup > 0L) {
                meter.recordWarmup(read)
            } else {
                meter.recordMeasured(read, now)
            }
        }
        assertEquals(8L, meter.payloadBytes)
        assertEquals(3L, meter.warmupCompletedBytes)
        assertEquals(5L, meter.measuredBytes)
        assertFalse(reader.messageComplete)
    }

    @Test
    fun truncatedFramingErrorKeepsActualBytesAndIsNotReportedOk() {
        val request = SpeedTestRequest(
            direction = SpeedDirection.DOWNLOAD,
            downloadTarget = NetworkTargetPolicy.parseHttpTarget("https://example.com/payload"),
            uploadTarget = null,
        )
        val download = SpeedTransferResult(
            endpoint = "https://example.com/payload",
            status = ObservationStatus.ERROR,
            payloadBytes = 4_096L,
            measuredBytes = 4_096L,
            warmupBytes = 0L,
            measurementElapsedMs = 250L,
            totalElapsedMs = 400L,
            completionReason = "truncatedBody",
            contentComplete = false,
            clientStopped = false,
            httpStatus = 200,
            contentLength = 8_192L,
            payloadBytesMeaning = "responseBodyBytesRead",
            rate = SpeedMath.rate(4_096L, 250L),
        )
        val result = SpeedTestResult.build(
            request, download, null, networkChanged = false,
            metered = false, proxyHost = null, proxyPort = null,
        )
        assertEquals(ObservationStatus.ERROR, result.status)
        val json = result.observations.getJSONObject("download")
        assertEquals(4_096L, json.getLong("payloadBytes"))
        assertEquals("truncatedBody", json.getString("completionReason"))
        assertFalse(json.getBoolean("contentComplete"))
    }

    private fun headBlock(
        statusLine: String = "HTTP/1.1 200 OK",
        headers: List<String> = emptyList(),
    ): String = buildString {
        append(statusLine).append("\r\n")
        headers.forEach { append(it).append("\r\n") }
        append("\r\n")
    }

    private fun readerFor(
        head: String,
        body: ByteArray,
    ): Pair<SpeedHttpWire.Head, SpeedHttpBodyReader> {
        val stream = ByteArrayInputStream(bytes(head) + body)
        val parsed = SpeedHttpWire.readHead(stream)
        return parsed to SpeedHttpBodyReader(stream, SpeedHttpBodyFraming.from(parsed))
    }

    private fun framingOf(head: String): SpeedHttpBodyFraming =
        SpeedHttpBodyFraming.from(SpeedHttpWire.readHead(ByteArrayInputStream(bytes(head))))

    private fun chunkedReader(body: String): SpeedHttpBodyReader =
        readerFor(headBlock(headers = listOf("Transfer-Encoding: chunked")), bytes(body)).second

    private fun bytes(text: String): ByteArray = text.toByteArray(Charsets.ISO_8859_1)

    private fun drain(reader: SpeedHttpBodyReader, bufferSize: Int = 7): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(bufferSize)
        while (true) {
            val read = reader.read(buffer, 0, buffer.size)
            if (read < 0) break
            if (read == 0) continue
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    private fun expectCode(expected: String, block: () -> Unit) {
        try {
            block()
            fail("expected SpeedHttpProtocolException with code $expected")
        } catch (failure: SpeedHttpProtocolException) {
            assertEquals(expected, failure.code)
        }
    }

    /**
     * Serves [allowed] and fails the test on any later read, proving that a
     * bounded reader never waits for EOF or speculatively consumes framing.
     */
    private class PoisonAfterBytesStream(private val allowed: ByteArray) : InputStream() {
        private var index = 0

        override fun read(): Int {
            if (index >= allowed.size) {
                throw AssertionError("read past the declared response body")
            }
            return allowed[index++].toInt() and 0xFF
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (index >= allowed.size) {
                throw AssertionError("read past the declared response body")
            }
            val count = minOf(length, allowed.size - index)
            allowed.copyInto(buffer, offset, index, index + count)
            index += count
            return count
        }
    }
}
