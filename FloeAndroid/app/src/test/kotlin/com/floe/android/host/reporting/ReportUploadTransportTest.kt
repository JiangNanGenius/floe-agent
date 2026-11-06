package com.floe.android.host.reporting

import java.io.ByteArrayOutputStream
import java.io.InterruptedIOException
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test

class ReportUploadTransportTest {
    @Test fun completeCallDeadlineStopsAStalledServer() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val listener = thread(isDaemon = true) {
                runCatching { server.accept().use { socket ->
                    socket.soTimeout = 2000
                    while (socket.getInputStream().read() >= 0) { /* no response */ }
                } }
            }
            val client = OkHttpClient.Builder().callTimeout(250, TimeUnit.MILLISECONDS)
                .readTimeout(4, TimeUnit.SECONDS).retryOnConnectionFailure(false).build()
            val start = System.nanoTime()
            val error = assertThrows(InterruptedIOException::class.java) {
                ReportUploadTransport(client).post("http://127.0.0.1:${server.localPort}/report", "{}", emptyList()) { _, _ -> }
            }
            assertTrue(error.message.orEmpty().contains("timeout"))
            assertTrue("Call must not wait for the read deadline", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 2000)
            listener.join(1000)
        }
    }

    @Test fun fourAttachmentsHaveKnownLengthProgressAndIntactUtf8Manifest() {
        val directory = Files.createTempDirectory("floe-report-upload-").toFile()
        try {
            val images = (0..3).map { index -> directory.resolve("$index.jpg").apply { writeBytes(ByteArray(70000) { index.toByte() }) } }
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
                val received = AtomicReference<ByteArray>()
                val serverFailure = AtomicReference<Throwable>()
                val listener = thread(isDaemon = true) {
                    try { server.accept().use { socket ->
                        socket.soTimeout = 3000
                        val input = socket.getInputStream()
                        val header = ByteArrayOutputStream()
                        while (!header.toString("ISO-8859-1").endsWith("\r\n\r\n")) {
                            val byte = input.read(); check(byte >= 0 && header.size() < 8192); header.write(byte)
                        }
                        val length = Regex("(?im)^Content-Length: (\\d+)").find(header.toString("ISO-8859-1"))!!.groupValues[1].toInt()
                        val body = ByteArray(length); var offset = 0
                        while (offset < length) { val n = input.read(body, offset, length - offset); check(n > 0); offset += n }
                        received.set(body)
                        socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".toByteArray())
                    } } catch (error: Throwable) { serverFailure.set(error) }
                }
                val counts = mutableListOf<Pair<Long, Long>>()
                val result = ReportUploadTransport().post("http://127.0.0.1:${server.localPort}/report", "{\"problem\":\"四张截图\"}", images) { done, total -> counts += done to total }
                listener.join(1000); serverFailure.get()?.let { throw AssertionError(it) }
                assertEquals(200 to "{}", result)
                val body = received.get(); assertNotNull(body)
                assertTrue(body.toString(Charsets.UTF_8).contains("四张截图"))
                for (index in 0..3) assertTrue(body.toString(Charsets.UTF_8).contains("filename=\"image-$index.jpg\""))
                assertEquals(0L, counts.first().first)
                assertEquals(body.size.toLong() to body.size.toLong(), counts.last())
                assertTrue(counts.zipWithNext().all { (a, b) -> b.first >= a.first && b.second == a.second })
            }
        } finally { directory.deleteRecursively() }
    }
}
