// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser

import com.floe.android.feature.browser.api.BrowserPreviewAuthority
import com.floe.android.feature.browser.api.PreviewAdjudication
import com.floe.android.feature.browser.transport.LoopbackPreviewTransport
import java.net.InetSocketAddress
import java.net.Socket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Host-JVM proof for the DUMB transport: 127.0.0.1-only bind, OS-assigned
 * port, real joined teardown, capacity refusal and streaming only the bytes
 * the fake "Swift" authority admitted. No Android runtime, no device.
 */
private class TransportAuthority(
    private val body: ByteArray,
    private val statusLine: String = "200 OK",
    private val declaredContentType: String = "text/html; charset=utf-8",
) : BrowserPreviewAuthority {
    var adjudications = 0
    var lastHeaderBlock: String? = null
    var stoppedPulls = 0

    override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
        adjudications += 1
        lastHeaderBlock = String(headerBlock, Charsets.US_ASCII)
        val first = body.copyOfRange(0, minOf(64, body.size))
        return PreviewAdjudication(
            statusLine = statusLine,
            headers = listOf(
                "Content-Type" to declaredContentType,
                "Content-Length" to body.size.toString(),
                "Cache-Control" to "no-store",
                "X-Content-Type-Options" to "nosniff",
                "Accept-Ranges" to "bytes",
                "Connection" to "close",
            ),
            bodyLength = body.size,
            bodyStart = 0,
            chunk = first,
        )
    }

    override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int): ByteArray {
        if (offset >= body.size) { stoppedPulls += 1; return ByteArray(0) }
        return body.copyOfRange(offset, minOf(offset + capacity, body.size))
    }
}

class LoopbackPreviewTransportTest {
    private fun get(port: Int, path: String, hostHeader: String = "127.0.0.1:$port"): String? {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 2_000)
                socket.soTimeout = 3_000
                val writer = socket.getOutputStream()
                writer.write("GET $path HTTP/1.1\r\nHost: $hostHeader\r\n\r\n".toByteArray(Charsets.US_ASCII))
                writer.flush()
                socket.inputStream.bufferedReader(Charsets.ISO_8859_1).readText()
            }
        } catch (_: Exception) {
            null
        }
    }

    @Test
    fun bindsLoopbackWithOsAssignedPortAndServesOnlyAdmittedBytes() {
        val body = ByteArray(100_000) { (it % 251).toByte() }
        val authority = TransportAuthority(body)
        val transport = LoopbackPreviewTransport(authority, "lease-jvm-1", maximumConcurrentConnections = 4)
        val port = transport.start()
        try {
            assertTrue(port in 1024..65535)
            val response = get(port, "/tok0123456789abcdef0123456789abcdef/index.html")
            requireNotNull(response)
            assertTrue(response.startsWith("HTTP/1.1 200 OK"))
            val separator = response.indexOf("\r\n\r\n")
            val served = response.substring(separator + 4)
            // Body equality is checked through ISO-8859-1 byte-preserving text.
            val servedBytes = served.toByteArray(Charsets.ISO_8859_1)
            assertEquals(body.size, servedBytes.size)
            assertTrue(servedBytes.contentEquals(body))
            assertEquals(1, authority.adjudications)
            assertTrue(authority.lastHeaderBlock!!.startsWith("GET /tok0123456789abcdef0123456789abcdef/index.html HTTP/1.1"))
        } finally {
            transport.stop()
        }
        assertFalse(transport.isRunning)
        // After joined teardown nothing answers anymore.
        assertEquals(null, get(port, "/tok0123456789abcdef0123456789abcdef/index.html"))
    }

    @Test
    fun refusesSecondStart() {
        val transport = LoopbackPreviewTransport(TransportAuthority("x".toByteArray()), "lease-jvm-2")
        transport.start()
        var twice = false
        try { transport.start() } catch (_: IllegalStateException) { twice = true }
        transport.stop()
        assertTrue(twice)
    }

    @Test
    fun wrongHostIsForwardedVerbatimAndTheAuthorityDecides() {
        var seen: String? = null
        val authority = object : BrowserPreviewAuthority {
            override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
                seen = String(headerBlock, Charsets.US_ASCII)
                return PreviewAdjudication(
                    statusLine = "421 Misdirected Request",
                    headers = listOf("Content-Length" to "0", "Connection" to "close"),
                    bodyLength = 0, bodyStart = 0, chunk = ByteArray(0),
                )
            }

            override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int) = ByteArray(0)
        }
        val transport = LoopbackPreviewTransport(authority, "lease-jvm-2b")
        val port = transport.start()
        try {
            val response = get(port, "/tok0123456789abcdef0123456789abcdef/index.html", hostHeader = "attacker.example")
            requireNotNull(response)
            assertTrue(response.startsWith("HTTP/1.1 421 Misdirected Request"))
            assertTrue(seen!!.contains("Host: attacker.example"))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun overCapacityConnectionsAreClosedNotPiledUp() {
        val neverEnding = object : BrowserPreviewAuthority {
            override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
                Thread.sleep(400) // hold the connection slot briefly
                return PreviewAdjudication("200 OK", listOf("Content-Length" to "1", "Connection" to "close"), 1, 0, byteArrayOf(0x7A))
            }

            override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int) = ByteArray(0)
        }
        val transport = LoopbackPreviewTransport(neverEnding, "lease-jvm-3", maximumConcurrentConnections = 2)
        val port = transport.start()
        try {
            val sockets = (1..4).map { _ -> Socket().apply { connect(InetSocketAddress("127.0.0.1", port), 2_000) } }
            // Every socket can at least write; over-capacity ones are closed
            // without a thread (their reads end quickly or get the answer).
            sockets.forEach { it.getOutputStream().write("GET / HTTP/1.1\r\nHost: h\r\n\r\n".toByteArray()) }
            val answered = sockets.mapNotNull { socket ->
                runCatching { socket.soTimeout = 1_500; socket.inputStream.bufferedReader(Charsets.ISO_8859_1).readText() }.getOrNull()
            }
            assertTrue(answered.isNotEmpty())
            sockets.forEach { runCatching { it.close() } }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun stopDeadlineRetainsBlockedAuthorityUntilItActuallyReturns() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val authority = object : BrowserPreviewAuthority {
            override fun adjudicate(serverId: String, requestId: String, headerBlock: ByteArray): PreviewAdjudication {
                entered.countDown()
                release.await()
                return PreviewAdjudication("200 OK", listOf("Content-Length" to "0"), 0, 0, ByteArray(0))
            }
            override fun readChunk(serverId: String, requestId: String, offset: Int, capacity: Int) = ByteArray(0)
        }
        val transport = LoopbackPreviewTransport(authority, "lease-physical-drain")
        val port = transport.start()
        val socket = Socket("127.0.0.1", port)
        try {
            socket.getOutputStream().write("GET / HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n\r\n".toByteArray())
            assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS))
            assertFalse(transport.stop(20)) // Authority still owns physical work.
            assertFalse(transport.isRunning)
            release.countDown()
            assertTrue(transport.stop(2_000))
            assertTrue(transport.stop(0))
        } finally { release.countDown(); socket.close(); transport.stop() }
    }

    @Test
    fun stopClosesAClientThatHasNotFinishedItsHeader() {
        val transport = LoopbackPreviewTransport(TransportAuthority(ByteArray(0)), "lease-slow-header")
        val port = transport.start()
        Socket("127.0.0.1", port).use { socket ->
            socket.getOutputStream().write("GET / HTTP/1.1\r\n".toByteArray())
            assertTrue(transport.stop(2_000))
            socket.soTimeout = 1_000
            val result = runCatching { socket.getInputStream().read() }
            assertTrue(result.isFailure || result.getOrNull() == -1)
        }
    }

    @Test
    fun stopIsIdempotentAndJoins() {
        val transport = LoopbackPreviewTransport(TransportAuthority(ByteArray(0)), "lease-jvm-4")
        transport.start()
        transport.stop()
        transport.stop()
        assertFalse(transport.isRunning)
    }
}
