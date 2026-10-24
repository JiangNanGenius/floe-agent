// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.transport

import com.floe.android.feature.browser.api.BrowserPreviewAuthority
import com.floe.android.feature.browser.internal.PreviewConnectionPump
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Pure loopback transport for one Swift-owned preview lease (decision D4).
 * Binds exactly `127.0.0.1` with an OS-assigned port; every byte of
 * authorization lives in the Swift `LocalPreviewServer` reached through
 * [BrowserPreviewAuthority]. The accept loop is owned by THIS object and is
 * joined on [stop] — no fake detach. View/foreground lifetime never calls
 * start/stop: only the Swift coordinator's owner-leased start/stop does, via
 * Main's JNI bridge.
 *
 * Budgets mirrored from the iOS original plus the Android task contract:
 *  - 64 KiB request header ceiling (pump),
 *  - 5 s header deadline per connection (socket soTimeout),
 *  - 8 concurrent owned connections (over capacity: immediate close, the
 *    browser retries — never an unbounded thread pool),
 *  - 64 KiB streaming chunks,
 *  - one request per connection (Connection: close on every verdict).
 */
public class LoopbackPreviewTransport(
    private val authority: BrowserPreviewAuthority,
    private val serverId: String,
    private val headerDeadlineMillis: Int = 5_000,
    private val maximumConcurrentConnections: Int = 8,
) {
    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    // One lifecycle monitor admits and records a worker BEFORE it starts.
    // stop snapshots after closing admission; no untracked late worker can
    // escape that snapshot. Joins happen outside the monitor.
    private val lifecycle = Any()
    private val connections = LinkedHashMap<Thread, Socket>()
    private val workers = LinkedHashSet<Thread>()
    private var started = false

    /** Bind and accept. Returns the OS-assigned port for the Swift lease
     * record. A second start on the same instance is refused. */
    public fun start(): Int = synchronized(lifecycle) {
        check(!started) { "preview transport already started" }
        started = true
        val bound = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        server = bound
        running.set(true)
        acceptThread = thread(name = "floe-preview-$serverId", isDaemon = true) {
            try {
                while (running.get()) {
                    val accepted = try { bound.accept() } catch (_: IOException) { break }
                    synchronized(lifecycle) {
                        workers.removeAll { !it.isAlive }
                        if (!running.get() || workers.size >= maximumConcurrentConnections) {
                            runCatching { accepted.close() }
                        } else {
                            val worker = thread(start = false, isDaemon = true, name = "floe-preview-conn") {
                                try {
                                    accepted.soTimeout = headerDeadlineMillis
                                    accepted.tcpNoDelay = true
                                    accepted.use { socket ->
                                        PreviewConnectionPump(authority, serverId)
                                            .handle(socket.getInputStream(), socket.getOutputStream())
                                    }
                                } catch (_: Exception) {
                                    // Partial IO is never reported as a completed resource.
                                } finally {
                                    runCatching { accepted.close() }
                                    synchronized(lifecycle) { connections.remove(Thread.currentThread()) }
                                }
                            }
                            connections[worker] = accepted
                            workers.add(worker)
                            try { worker.start() } catch (failure: Throwable) {
                                connections.remove(worker)
                                workers.remove(worker)
                                runCatching { accepted.close() }
                                throw failure
                            }
                        }
                    }
                }
            } finally {
                running.set(false)
                runCatching { bound.close() }
            }
        }
        bound.localPort
    }

    /** Close the listener AND every owned connection, then join within one
     * total budget. False retains all live ownership for another drain;
     * a deadline never claims physical work has stopped. Safe to repeat. */
    public fun stop(joinMillis: Long = 2_000): Boolean {
        val owned = synchronized(lifecycle) {
            running.set(false)
            runCatching { server?.close() }
            connections.values.forEach { runCatching { it.close() } }
            listOfNotNull(acceptThread) + workers.toList()
        }
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(joinMillis.coerceAtLeast(0))
        for (worker in owned) {
            if (worker === Thread.currentThread()) continue
            val remaining = deadline - System.nanoTime()
            if (remaining <= 0) break
            try {
                val millis = remaining / 1_000_000
                val nanos = (remaining % 1_000_000).toInt()
                worker.join(millis, nanos)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return synchronized(lifecycle) {
            val done = owned.none { it.isAlive } && acceptThread?.isAlive != true && connections.isEmpty()
            if (done) { acceptThread = null; server = null; workers.clear() }
            done
        }
    }

    public val isRunning: Boolean
        get() = running.get()
}
