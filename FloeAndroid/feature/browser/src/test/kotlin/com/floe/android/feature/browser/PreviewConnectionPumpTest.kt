// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser

import com.floe.android.feature.browser.api.BrowserPreviewAuthority
import com.floe.android.feature.browser.api.PreviewAdjudication
import com.floe.android.feature.browser.internal.PreviewConnectionPump
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InterruptedIOException
import java.io.SequenceInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Deterministic fake of the Swift-side preview authority: records exactly
 * what bytes the pump forwarded, and serves only what it is told to serve.
 */
private class FakeAuthority(
    var verdict: PreviewAdjudication? = null,
    var adjudicate: ((String, String, ByteArray) -> PreviewAdjudication)? = null,
    var body: ByteArray = ByteArray(0),
    var chunkCapacitySeen: MutableList<Int> = mutableListOf(),
    var throwOnAdjudicate: Boolean = false,
) : BrowserPreviewAuthority {
    var lastHeaderBlock: ByteArray? = null
    var lastServerId: String? = null
    var lastRequestId: String? = null
    var chunkPulls = 0

    override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
        if (throwOnAdjudicate) throw IllegalStateException("bridge down")
        lastServerId = serverId
        lastRequestId = requestId
        lastHeaderBlock = headerBlock
        val supplied = adjudicate?.invoke(serverId, requestId, headerBlock) ?: verdict!!
        return supplied.copy(chunk = supplied.chunk)
    }

    override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int): ByteArray {
        chunkPulls += 1
        chunkCapacitySeen.add(capacity)
        if (offset >= body.size) return ByteArray(0)
        return body.copyOfRange(offset, minOf(offset + capacity, body.size))
    }
}

class PreviewConnectionPumpTest {
    private fun request(vararg lines: String): ByteArray =
        (lines.joinToString("\r\n") + "\r\n\r\n").toByteArray(Charsets.US_ASCII)

    private fun indexOfBytes(haystack: ByteArray, needle: String): Int {
        val n = needle.toByteArray(Charsets.US_ASCII)
        outer@ for (start in 0..haystack.size - n.size) {
            for (offset in n.indices) if (haystack[start + offset] != n[offset]) continue@outer
            return start
        }
        return -1
    }

    @Test
    fun forwardsCompleteHeaderBlockOnly() {
        val authority = FakeAuthority(
            verdict = PreviewAdjudication(
                statusLine = "404 Not Found",
                headers = listOf("Content-Length" to "0"),
                bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
            ),
        )
        val input = ByteArrayInputStream(request("GET /tok/index.html HTTP/1.1", "Host: 127.0.0.1:8080"))
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-1").handle(input, output)
        val forwarded = String(authority.lastHeaderBlock!!, Charsets.US_ASCII)
        assertTrue(forwarded.contains("GET /tok/index.html HTTP/1.1"))
        val text = String(output.toByteArray(), Charsets.US_ASCII)
        assertTrue(text.startsWith("HTTP/1.1 404 Not Found\r\n"))
        assertTrue(text.contains("Content-Length: 0"))
    }

    @Test
    fun parsesOnlyAfterTerminatorArrives() {
        // A fragmented header block: the pump must accumulate until \r\n\r\n
        // arrives, not answer the first segment (the iOS original's rule).
        val authority = FakeAuthority(
            verdict = PreviewAdjudication(
                statusLine = "200 OK",
                headers = listOf("Content-Length" to "4"),
                bodyLength = 4, bodyStart = 0, chunk = "abcd".toByteArray(),
            ),
        )
        val first = "GET /tok/a HTTP/1.".toByteArray(Charsets.US_ASCII)
        val second = "1\r\nHost: 127.0.0.1:1\r\n".toByteArray(Charsets.US_ASCII)
        val third = "\r\n".toByteArray(Charsets.US_ASCII)
        val input = SequenceInputStream(
            java.util.Collections.enumeration(listOf(ByteArrayInputStream(first), ByteArrayInputStream(second), ByteArrayInputStream(third)))
        )
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-2").handle(input, output)
        val text = String(output.toByteArray(), Charsets.US_ASCII)
        assertTrue(text.startsWith("HTTP/1.1 200 OK\r\n"))
        val separator = text.indexOf("\r\n\r\n")
        assertEquals("abcd", text.substring(separator + 4))
        val forwarded = String(authority.lastHeaderBlock!!, Charsets.US_ASCII)
        assertTrue(forwarded.startsWith("GET /tok/a HTTP/1.1"))
    }

    @Test
    fun oversizedHeaderBlockAnswers431WithoutParsing() {
        var called = false
        val authority = object : BrowserPreviewAuthority {
            override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
                called = true
                error("must not be consulted for oversized headers")
            }

            override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int): ByteArray =
                ByteArray(0)
        }
        val filler = "X: " + "a".repeat(2048)
        val payload = StringBuilder("GET / HTTP/1.1\r\n")
        while (payload.length < 65 * 1024) payload.append(filler).append("\r\n")
        val input = ByteArrayInputStream(payload.toString().toByteArray(Charsets.US_ASCII))
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-3", maximumHeaderBytes = 64 * 1024).handle(input, output)
        assertTrue(String(output.toByteArray(), Charsets.US_ASCII).startsWith("HTTP/1.1 431 Request Header Fields Too Large"))
        assertTrue(!called)
    }

    @Test
    fun stalledRequestWithPartialBytesAnswers408() {
        // EOF after partial bytes but before the terminator: original 408
        // deadline semantics surface as an honest timeout answer.
        val authority = FakeAuthority(verdict = PreviewAdjudication("404 Not Found", emptyList(), 0, 0, ByteArray(0)))
        val input = ByteArrayInputStream("GET /tok/ht".toByteArray(Charsets.US_ASCII))
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-4").handle(input, output)
        assertTrue(String(output.toByteArray(), Charsets.US_ASCII).startsWith("HTTP/1.1 408 Request Timeout"))
    }

    @Test
    fun cleanDisconnectBeforeAnyBytesAnswers400() {
        val authority = FakeAuthority(verdict = PreviewAdjudication("404 Not Found", emptyList(), 0, 0, ByteArray(0)))
        val input = object : ByteArrayInputStream(ByteArray(0)) {
            override fun read(): Int = -1
        }
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-5").handle(input, output)
        assertTrue(String(output.toByteArray(), Charsets.US_ASCII).startsWith("HTTP/1.1 400 Bad Request"))
    }

    @Test
    fun streamsOnlyAdmittedBodyBytesThroughBoundedPulls() {
        val full = ByteArray(1000) { (it % 251).toByte() }
        val authority = FakeAuthority(
            verdict = PreviewAdjudication(
                statusLine = "206 Partial Content",
                headers = listOf("Content-Length" to "1000", "Content-Range" to "bytes 0-999/4000"),
                bodyLength = 1000,
                bodyStart = 0,
                chunk = full.copyOfRange(0, 300),
            ),
            body = full,
        )
        val output = ByteArrayOutputStream()
        val pump = PreviewConnectionPump(authority, "lease-6", chunkCapacity = 256)
        pump.handle(ByteArrayInputStream(request("GET /tok/f HTTP/1.1", "Host: 127.0.0.1:9")), output)
        val text = output.toByteArray()
        val separator = indexOfBytes(text, "\r\n\r\n")
        assertTrue(separator > 0)
        val body = text.copyOfRange(separator + 4, text.size)
        assertTrue(body.contentEquals(full))
        // Chunk pulls happened with the configured capacity, not unbounded.
        assertTrue(authority.chunkCapacitySeen.isNotEmpty())
        assertTrue(authority.chunkCapacitySeen.all { it == 256 })
    }

    @Test
    fun authorityBridgeFailureIsHonest503AndServesNoBytes() {
        val authority = FakeAuthority(throwOnAdjudicate = true)
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-7").handle(
            ByteArrayInputStream(request("GET /tok/x HTTP/1.1", "Host: 127.0.0.1:9")),
            output,
        )
        assertTrue(String(output.toByteArray(), Charsets.US_ASCII).startsWith("HTTP/1.1 503 Service Unavailable"))
    }

    @Test
    fun headVerdictSerializesDeclaredLengthWithoutBody() {
        val authority = FakeAuthority(
            verdict = PreviewAdjudication(
                statusLine = "200 OK",
                headers = listOf("Content-Length" to "4096"),
                bodyLength = 0, // HEAD: Swift declared length but no body stream
                bodyStart = 0,
                chunk = ByteArray(0),
            ),
            body = ByteArray(4096),
        )
        val output = ByteArrayOutputStream()
        PreviewConnectionPump(authority, "lease-8").handle(
            ByteArrayInputStream(request("HEAD /tok/x HTTP/1.1", "Host: 127.0.0.1:9")),
            output,
        )
        val text = String(output.toByteArray(), Charsets.US_ASCII)
        assertTrue(text.contains("Content-Length: 4096"))
        assertEquals(0, authority.chunkPulls)
    }

    @Test
    fun headerReadDoesNotParsePartialOnSocketTimeout() {
        // Interrupted reads surface as "no complete request", never a parse.
        val input = object : java.io.FilterInputStream(ByteArrayInputStream("GET /tok/".toByteArray())) {
            override fun read(): Int {
                if (available() == 0) throw InterruptedIOException("5s deadline")
                return super.read()
            }
        }
        val read = PreviewConnectionPump.readHeaderBlock(input, 64 * 1024)
        assertNull(read.block)
        assertTrue(read.sawAnyBytes)
        assertTrue(!read.terminated)
    }
}
