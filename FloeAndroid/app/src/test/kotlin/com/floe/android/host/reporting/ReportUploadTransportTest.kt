package com.floe.android.host.reporting

import java.io.ByteArrayOutputStream
import java.io.InterruptedIOException
import java.net.InetAddress
import java.net.ServerSocket
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import okhttp3.OkHttpClient
import okhttp3.Call
import okhttp3.EventListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CoroutineDispatcher
import kotlin.coroutines.CoroutineContext
import java.util.concurrent.LinkedBlockingQueue
import org.junit.Assert.*
import org.junit.Test

class ReportUploadTransportTest {
    @Test fun cancelledAttemptCannotPublishAnAlreadyReceivedResponse() = runBlocking {
        val continuations = LinkedBlockingQueue<Runnable>()
        val owner = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) { continuations.add(block) }
        }
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val ended = CountDownLatch(1)
            val listener = thread(isDaemon = true) {
                server.accept().use { socket ->
                    val input = socket.getInputStream()
                    val header = ByteArrayOutputStream()
                    while (!header.toString("ISO-8859-1").endsWith("\r\n\r\n")) {
                        val byte = input.read(); check(byte >= 0); header.write(byte)
                    }
                    val headers = header.toString("ISO-8859-1")
                    val length = Regex("(?i)Content-Length: ([0-9]+)").find(headers)!!.groupValues[1].toInt()
                    var remaining = length
                    val buffer = ByteArray(4096)
                    while (remaining > 0) {
                        val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                        check(count > 0); remaining -= count
                    }
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".toByteArray())
                }
            }
            val client = OkHttpClient.Builder().eventListener(object : EventListener() {
                override fun callEnd(call: Call) { ended.countDown() }
            }).build()
            val attempt = ReportUploadSession()
            val response = async(owner) {
                ReportUploadTransport(client).post("http://127.0.0.1:${server.localPort}/report", "{}", emptyList(), attempt) { _, _ -> }
            }
            try {
                checkNotNull(continuations.poll(3, TimeUnit.SECONDS)).run()
                assertTrue("The HTTP response must actually finish before cancellation", ended.await(3, TimeUnit.SECONDS))
                // HTTP is finished but the owner continuation is still queued.
                // Call.cancel alone cannot revoke that already-received receipt.
                attempt.cancel()
                checkNotNull(continuations.poll(3, TimeUnit.SECONDS)).run()
                assertEquals(200, response.await().first)
                assertFalse(attempt.allowsPublication(attempt, "queued"))
                val replacement = ReportUploadSession()
                assertTrue(replacement.allowsPublication(replacement, "queued"))
                assertFalse(attempt.allowsPublication(replacement, "queued"))
                assertFalse(replacement.allowsPublication(replacement, "failed"))
                listener.join(1000)
            } finally {
                response.cancel()
                while (true) (continuations.poll() ?: break).run()
            }
        }
    }

    @Test fun completeCallDeadlineStopsAStalledServer() = runBlocking {
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
            val error = runCatching {
                ReportUploadTransport(client).post("http://127.0.0.1:${server.localPort}/report", "{}", emptyList()) { _, _ -> }
            }.exceptionOrNull()
            assertTrue(error is InterruptedIOException)
            assertTrue(error!!.message.orEmpty().contains("timeout"))
            assertTrue("Call must not wait for the read deadline", TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 2000)
            listener.join(1000)
        }
    }

    @Test fun fourAttachmentsHaveKnownLengthProgressAndIntactUtf8Manifest() = runBlocking {
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

    @Test fun cancelledWorkerClosesTheActualRequest() = runBlocking {
        verifyCancellation(removeReport = false)
    }

    @Test fun removingOneReportClosesOnlyItsRequest() = runBlocking {
        verifyCancellation(removeReport = true)
    }

    private suspend fun verifyCancellation(removeReport: Boolean) = supervisorScope {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val accepted = CompletableDeferred<Unit>()
            val closed = CompletableDeferred<Unit>()
            val listener = thread(isDaemon = true) {
                try {
                    server.accept().use { socket ->
                        socket.soTimeout = 4000
                        accepted.complete(Unit)
                        while (socket.getInputStream().read() >= 0) { /* deliberately withhold response */ }
                    }
                    closed.complete(Unit)
                } catch (error: Throwable) { closed.completeExceptionally(error) }
            }
            val session = ReportUploadSession()
            val attempt = async {
                ReportUploadTransport().post("http://127.0.0.1:${server.localPort}/report", "{}", emptyList(), session) { _, _ -> }
            }
            withTimeout(2000) { accepted.await() }
            if (removeReport) {
                session.cancel()
                val error = runCatching { withTimeout(2000) { attempt.await() } }.exceptionOrNull()
                assertTrue("Removal must abort the request", error is IOException)
                ReportUploadSession().checkActive() // Other reports retain their own consent/lifecycle.
            } else {
                withTimeout(2000) { attempt.cancelAndJoin() }
                assertTrue(attempt.isCancelled)
            }
            withTimeout(2000) { closed.await() }
            listener.join(1000)
        }
    }

    @Test fun removalDuringPreparationCannotStartHttpLater() = runBlocking {
        val session = ReportUploadSession().apply { cancel() }
        var progress = false
        val error = runCatching {
            ReportUploadTransport().post("http://127.0.0.1:1/report", "{}", emptyList(), session) { _, _ -> progress = true }
        }.exceptionOrNull()
        assertTrue(error is ReportUploadCancelled)
        assertFalse(progress)
    }
}
