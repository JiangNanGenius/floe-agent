// SPDX-License-Identifier: MPL-2.0
// G02 native TLS qualification fixture (job-b1709c36b200442c).
//
// Instrumentation-owned synthetic TLS/1.3+ server for the TLS trust probes.
// Unlike TransportLoopbackFixture (plain HTTP timing evidence), this fixture
// TERMINATES TLS with one of the lane-generated SYNTHETIC server
// certificates (test-CA signed good/wrong-SAN/expired, or an entirely
// unknown self-contained CA) and serves plain HTTP/1.1 over the TLS socket
// so the Swift native stack performs a REAL Android TLS handshake against a
// controlled chain. It records exactly what a real server can observe:
// request count and headers per path — that is how the Authorization canary
// forwarding and the MCP zero-target-request assertions are proven.
//
// Test scope only: never referenced from any main source set or release
// artifact. All key material is synthetic fixture material generated in the
// lane; no user or system credential is ever read or installed.
package com.floe.android.bridge

import androidx.test.platform.app.InstrumentationRegistry
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.Socket
import java.security.KeyStore
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLServerSocketFactory

/**
 * TLS loopback fixture bound to 127.0.0.1 on an ephemeral port. [certAsset]
 * selects the synthetic server identity presented during the handshake
 * ("server-good.p12", "server-wrongsan.p12", "server-expired.p12" or
 * "server-unknown.p12" under the `tls-qualification` assets directory).
 */
class TLSLoopbackFixture(certAsset: String) : Closeable {
    data class Recorded(
        val path: String,
        val headers: Map<String, String>,
        val body: String,
    )

    inner class Exchange(
        val socket: Socket,
        val path: String,
        val headers: Map<String, String>,
    ) {
        private val out = BufferedOutputStream(socket.getOutputStream())

        @Volatile private var broken = false

        fun head(status: Int, headers: List<Pair<String, String>>, chunked: Boolean) {
            val text = buildString {
                append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
                for ((name, value) in headers) append(name).append(": ").append(value).append("\r\n")
                if (chunked) append("transfer-encoding: chunked\r\n")
                append("connection: close\r\n\r\n")
            }
            writeRaw(text.toByteArray(Charsets.ISO_8859_1))
        }

        fun headWithLength(status: Int, headers: List<Pair<String, String>>, length: Int) {
            val text = buildString {
                append("HTTP/1.1 ").append(status).append(' ').append(reason(status)).append("\r\n")
                for ((name, value) in headers) append(name).append(": ").append(value).append("\r\n")
                append("content-length: ").append(length).append("\r\n")
                append("connection: close\r\n\r\n")
            }
            writeRaw(text.toByteArray(Charsets.ISO_8859_1))
        }

        fun chunk(data: ByteArray) {
            if (broken) return
            val framing = (Integer.toHexString(data.size) + "\r\n").toByteArray(Charsets.ISO_8859_1)
            writeRaw(framing)
            writeRaw(data)
            writeRaw("\r\n".toByteArray(Charsets.ISO_8859_1))
        }

        fun finishChunked() {
            writeRaw("0\r\n\r\n".toByteArray(Charsets.ISO_8859_1))
        }

        fun raw(data: ByteArray) = writeRaw(data)

        val clientGone: Boolean get() = broken || socket.isClosed

        private fun writeRaw(data: ByteArray) {
            if (broken) return
            try {
                out.write(data)
                out.flush()
            } catch (error: IOException) {
                broken = true
            }
        }
    }

    private val server: SSLServerSocket
    val port: Int get() = server.localPort

    private val handlers = ConcurrentHashMap<String, (Exchange) -> Unit>()
    private val requests = Collections.synchronizedList(mutableListOf<Recorded>())
    private val sockets = Collections.synchronizedList(mutableListOf<Socket>())
    private val running = AtomicBoolean(false)
    private val threads = Collections.synchronizedList(mutableListOf<Thread>())

    init {
        val context = InstrumentationRegistry.getInstrumentation().context
        val password = PASSWORD
        val keyStore = KeyStore.getInstance("PKCS12")
        context.assets.open("tls-qualification/$certAsset").use { input ->
            keyStore.load(input, password)
        }
        val keyManagers = KeyManagerFactory.getInstance(
            KeyManagerFactory.getDefaultAlgorithm())
        keyManagers.init(keyStore, password)
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(keyManagers.keyManagers, null, null)
        val factory = sslContext.serverSocketFactory as SSLServerSocketFactory
        server = factory.createServerSocket(0, 32, InetAddress.getByName("127.0.0.1")) as SSLServerSocket
        server.enabledProtocols = arrayOf("TLSv1.2", "TLSv1.3")
    }

    fun register(path: String, handler: (Exchange) -> Unit) {
        handlers[path] = handler
    }

    fun start() {
        if (!running.compareAndSet(false, true)) return
        val acceptThread = Thread {
            while (running.get()) {
                val client = try {
                    server.accept()
                } catch (error: IOException) {
                    return@Thread
                }
                try {
                    client.soTimeout = 15_000
                } catch (ignored: IOException) {
                }
                sockets.add(client)
                val worker = Thread {
                    try {
                        serve(client)
                    } catch (ignored: Throwable) {
                        // A negative-control client may abort mid-handshake;
                        // that is the PASS condition, not a fixture failure.
                    } finally {
                        try {
                            client.close()
                        } catch (ignored: IOException) {
                        }
                        sockets.remove(client)
                    }
                }
                worker.isDaemon = true
                threads.add(worker)
                worker.start()
            }
        }
        acceptThread.isDaemon = true
        acceptThread.start()
        threads.add(acceptThread)
    }

    private fun serve(socket: Socket) {
        socket.use {
            val input = BufferedInputStream(socket.getInputStream())
            var headBytes = 0
            val headBuffer = java.io.ByteArrayOutputStream()
            var matched = false
            val window = IntArray(4)
            while (headBytes < 65_536) {
                val value = input.read()
                if (value < 0) return
                headBytes += 1
                headBuffer.write(value)
                window[0] = window[1]; window[1] = window[2]; window[2] = window[3]; window[3] = value
                if (window[0] == 13 && window[1] == 10 && window[2] == 13 && window[3] == 10) {
                    matched = true
                    break
                }
            }
            if (!matched) return
            val head = headBuffer.toString(Charsets.ISO_8859_1.name())
            val lines = head.trimEnd('\r', '\n').split("\r\n")
            val requestLine = lines.firstOrNull() ?: return
            val pieces = requestLine.split(' ')
            if (pieces.size < 2) return
            val path = pieces[1].substringBefore('?')
            val requestHeaders = mutableMapOf<String, String>()
            var contentLength = 0
            for (line in lines.drop(1)) {
                val colon = line.indexOf(':')
                if (colon <= 0) continue
                val name = line.substring(0, colon).trim().lowercase()
                val value = line.substring(colon + 1).trim()
                requestHeaders[name] = value
                if (name == "content-length") contentLength = value.toIntOrNull() ?: 0
            }
            val body = ByteArray(contentLength)
            var read = 0
            while (read < contentLength) {
                val count = input.read(body, read, contentLength - read)
                if (count < 0) throw EOFException("truncated body")
                read += count
            }
            requests.add(Recorded(path, requestHeaders, String(body, Charsets.UTF_8)))
            val handler = handlers[path]
            if (handler == null) {
                Exchange(socket, path, requestHeaders).headWithLength(404, emptyList(), 0)
                return
            }
            try {
                handler(Exchange(socket, path, requestHeaders))
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    fun count(path: String): Int =
        synchronized(requests) { requests.count { it.path == path } }

    fun headers(path: String): Map<String, String>? =
        synchronized(requests) { requests.lastOrNull { it.path == path }?.headers }

    fun summary(): String = buildString {
        append("requests=").append(synchronized(requests) { requests.map { it.path } })
    }

    override fun close() {
        running.set(false)
        try {
            server.close()
        } catch (ignored: IOException) {
        }
        val openSockets = synchronized(sockets) { sockets.toList() }
        for (socket in openSockets) {
            try {
                socket.close()
            } catch (ignored: IOException) {
            }
        }
        val snapshot = synchronized(threads) { threads.toList() }
        for (thread in snapshot) {
            thread.interrupt()
        }
        for (thread in snapshot) {
            try {
                thread.join(500)
            } catch (ignored: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        threads.clear()
    }

    private fun reason(status: Int): String = when (status) {
        200 -> "OK"
        204 -> "No Content"
        302 -> "Found"
        401 -> "Unauthorized"
        404 -> "Not Found"
        else -> "Status"
    }

    private companion object {
        val PASSWORD: CharArray = "floetest".toCharArray()
    }
}
