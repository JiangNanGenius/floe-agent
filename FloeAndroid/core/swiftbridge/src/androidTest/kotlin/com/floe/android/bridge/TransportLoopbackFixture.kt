// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Instrumentation-owned synthetic HTTP/1.1 fixture for the G02-P3 transport
 * tests. Binds 127.0.0.1 on an ephemeral port (bounded startup, one socket),
 * serves only the registered scripted paths, and records what a real server
 * can observe: request count/headers per path, whether the CLIENT aborted
 * before the scripted body finished (owned-task cancellation / early cap
 * proof), and whether the two-way barrier was opened by the client before
 * the fixture was allowed to write its tail + EOF.
 *
 * Test scope only: never referenced from the library main source set, the
 * App, or any release artifact. No TLS is served here — the fixture is plain
 * loopback HTTP so synthetic transport timing/cancellation is measurable.
 * That is distinct from real HTTPS certificate/hostname/default-trust
 * behaviour, which Main verifies later against actual endpoints.
 */
class TransportLoopbackFixture : Closeable {
    data class Recorded(
        val path: String,
        val headers: Map<String, String>,
        val body: String,
    )

    inner class Exchange(
        val socket: Socket,
        val path: String,
        val headers: Map<String, String>,
        val body: String,
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

        fun sleep(milliseconds: Long) = Thread.sleep(milliseconds)

        val clientGone: Boolean get() = broken || socket.isClosed || fixtureReference.aborted(path)

        private fun writeRaw(data: ByteArray) {
            if (broken) return
            try {
                out.write(data)
                out.flush()
            } catch (error: IOException) {
                broken = true
                markAborted(path)
            }
        }

        private fun markAborted(path: String) = fixtureReference.recordAbort(path)
    }

    private val server = ServerSocket(0, 32, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = server.localPort

    private val handlers = ConcurrentHashMap<String, (Exchange) -> Unit>()
    private val openedTags = ConcurrentHashMap.newKeySet<String>()
    private val barrierOutcome = ConcurrentHashMap<String, Boolean>()
    private val requests = Collections.synchronizedList(mutableListOf<Recorded>())
    private val aborted = ConcurrentHashMap.newKeySet<String>()
    private val completedPaths = ConcurrentHashMap.newKeySet<String>()
    private val sockets = Collections.synchronizedList(mutableListOf<Socket>())
    private val running = AtomicBoolean(false)
    private val threads = Collections.synchronizedList(mutableListOf<Thread>())
    private val fixtureReference = this

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
                    client.soTimeout = 10_000
                } catch (ignored: IOException) {
                }
                sockets.add(client)
                val worker = Thread {
                    try {
                        serve(client)
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
            try {
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
                val rawTarget = pieces[1]
                val path = rawTarget.substringBefore('?')
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
                when (path) {
                    "/open" -> {
                        val tag = rawTarget.substringAfter("tag=", "").substringBefore('&')
                        if (tag.isNotEmpty()) openedTags.add(tag)
                        val exchange = Exchange(socket, path, requestHeaders, "")
                        exchange.headWithLength(204, emptyList(), 0)
                        return
                    }
                    else -> {
                        val handler = handlers[path]
                        if (handler == null) {
                            Exchange(socket, path, requestHeaders, "").headWithLength(404, emptyList(), 0)
                            return
                        }
                        try {
                            handler(Exchange(socket, path, requestHeaders, String(body, Charsets.UTF_8)))
                        } catch (interrupted: InterruptedException) {
                            Thread.currentThread().interrupt()
                        }
                    }
                }
            } catch (error: IOException) {
                return
            }
        }
    }

    fun recordAbort(path: String) {
        aborted.add(path)
    }

    fun recordBarrier(tag: String, opened: Boolean) {
        barrierOutcome[tag] = opened
    }

    /** The scripted response for [path] ran to its normal end (finish + close). */
    fun markCompleted(path: String) {
        completedPaths.add(path)
    }

    fun completedNormally(path: String): Boolean = completedPaths.contains(path)

    fun summary(): String = buildString {
        append("requests=").append(synchronized(requests) { requests.map { it.path } })
        append(" aborted=").append(aborted.toSortedSet())
        append(" completed=").append(completedPaths.toSortedSet())
        append(" barriers=").append(barrierOutcome.toSortedMap())
    }

    fun barrier(tag: String): Boolean? = barrierOutcome[tag]

    fun opened(tag: String): Boolean = openedTags.contains(tag)

    fun aborted(path: String): Boolean = aborted.contains(path)

    fun count(path: String): Int = synchronized(requests) { requests.count { it.path == path } }

    fun headers(path: String): Map<String, String>? =
        synchronized(requests) { requests.firstOrNull { it.path == path }?.headers }

    fun lastBody(path: String): String? =
        synchronized(requests) { requests.lastOrNull { it.path == path }?.body }

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
        500 -> "Internal Server Error"
        else -> "Status"
    }
}
