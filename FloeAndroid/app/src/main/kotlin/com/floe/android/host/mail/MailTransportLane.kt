// SPDX-License-Identifier: MPL-2.0
//
// App-owned C06 platform transport lane. Swift owns the ticket table and all
// protocol decisions; this lane only claims one ticket at a time, performs
// the real TCP/SSLSocket operation on an IO dispatcher, and settles it once.
// There is no model command, no V3 key and no credential storage here.
//
// The lane is bound to exactly one accepted Root epoch. Root retirement
// closes every socket, joins the workers, and acknowledges `laneClosed` so
// Swift can prove the old generation is drained.

package com.floe.android.host.mail

import com.floe.android.bridge.MailTransportNative
import java.io.IOException
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLException
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

internal data class MailTransportDescriptor(
    val claim: Long,
    val session: Long,
    val operation: String,
    val host: String,
    val port: Int,
    val tls: String,
    val maxBytes: Int,
    val writeLength: Int,
    val timeoutMillis: Int,
) {
    val implicitTls: Boolean get() = tls == "implicitTLS"
}

internal interface MailTransportBridge {
    fun bind(epoch: Long): Int
    fun laneReady(epoch: Long): Int
    fun next(timeoutMillis: Int): Long
    fun describe(claim: Long): String?
    fun takeWrite(claim: Long, length: Int): ByteArray?
    fun complete(claim: Long, status: Int, data: ByteArray?): Int
    fun shouldStop(claim: Long): Boolean
    fun cancelSession(session: Long): Int
    fun closeAll(timeoutMillis: Int): Int
    fun laneClosed(epoch: Long): Int
}

internal object PlatformMailTransportBridge : MailTransportBridge {
    override fun bind(epoch: Long): Int = MailTransportNative.bind(epoch)
    override fun laneReady(epoch: Long): Int = MailTransportNative.laneReady(epoch)
    override fun next(timeoutMillis: Int): Long = MailTransportNative.next(timeoutMillis)
    override fun describe(claim: Long): String? {
        val buffer = ByteArray(2_048)
        val count = MailTransportNative.describe(claim, buffer)
        if (count <= 0 || count > buffer.size) return null
        return String(buffer, 0, count, StandardCharsets.UTF_8)
    }
    override fun takeWrite(claim: Long, length: Int): ByteArray? {
        if (length <= 0 || length > 64 * 1_024) return null
        val buffer = ByteArray(length)
        val count = MailTransportNative.takeWrite(claim, buffer)
        return if (count == length) buffer else null
    }
    override fun complete(claim: Long, status: Int, data: ByteArray?): Int =
        MailTransportNative.complete(claim, status, data, data?.size ?: 0)
    override fun shouldStop(claim: Long): Boolean = MailTransportNative.shouldStop(claim) != 0
    override fun cancelSession(session: Long): Int = MailTransportNative.cancelSession(session)
    override fun closeAll(timeoutMillis: Int): Int = MailTransportNative.closeAll(timeoutMillis)
    override fun laneClosed(epoch: Long): Int = MailTransportNative.laneClosed(epoch)
}

internal class MailTransportLane(
    private val scope: CoroutineScope,
    private val bridge: MailTransportBridge = PlatformMailTransportBridge,
    private val socketFactory: MailSocketFactory = PlatformMailSocketFactory(),
    private val lanGate: C06MailLanGate? = null,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val running = AtomicBoolean(false)
    private val sessions = ConcurrentHashMap<Long, MailSocket>()
    private val jobs = ConcurrentHashMap<Long, Job>()
    private var pollJob: Job? = null
    @Volatile private var epoch: Long = 0

    val isRunning: Boolean get() = running.get()

    fun start(boundEpoch: Long): Boolean {
        if (boundEpoch <= 0) return false
        if (!running.compareAndSet(false, true)) return epoch == boundEpoch
        epoch = boundEpoch
        val bind = bridge.bind(boundEpoch)
        if (bind != 0) {
            running.set(false)
            return false
        }
        if (bridge.laneReady(boundEpoch) != 0) {
            running.set(false)
            return false
        }
        pollJob = scope.launch(ioDispatcher) { pollLoop(boundEpoch) }
        return true
    }

    /** Returns true only when the poller and every claimed operation ended. */
    fun stop(timeoutMillis: Int): Boolean {
        val wasRunning = running.getAndSet(false)
        // Closing the sockets is what unblocks a read/write already in the
        // peer; it is also the actual resource close, not a requested state.
        sessions.values.forEach { it.close() }
        jobs.values.toList().forEach { it.cancel() }
        pollJob?.cancel()
        val finished = runBlocking {
            withTimeoutOrNull(timeoutMillis.coerceIn(250, 10_000).toLong()) {
                pollJob?.join()
                jobs.values.toList().forEach { it.join() }
                true
            } ?: false
        }
        sessions.values.forEach { it.close() }
        sessions.clear()
        if (epoch > 0) bridge.laneClosed(epoch)
        return finished || !wasRunning
    }

    private suspend fun pollLoop(boundEpoch: Long) {
        try {
            while (running.get() && scope.isActive) {
                val claim = bridge.next(100)
                if (claim == -1L) break
                if (claim <= 0L) continue
                val job = scope.launch(ioDispatcher) { handle(claim) }
                jobs[claim] = job
                job.invokeOnCompletion { jobs.remove(claim) }
            }
        } catch (_: Throwable) {
            // A native/lane failure closes the mailbox below; it is never a
            // fake success for a pending operation.
        } finally {
            running.set(false)
            sessions.values.forEach { it.close() }
            runBlocking {
                withTimeoutOrNull(2_500) {
                    jobs.values.toList().forEach { it.join() }
                }
            }
            sessions.values.forEach { it.close() }
            sessions.clear()
            bridge.laneClosed(boundEpoch)
        }
    }

    private suspend fun handle(claim: Long) {
        val descriptor = try {
            bridge.describe(claim)?.let(::parseDescriptor)
        } catch (_: Throwable) {
            null
        }
        if (descriptor == null) {
            settle(claim, MailTransportStatus.PROTOCOL_VIOLATION)
            return
        }
        if (bridge.shouldStop(claim)) {
            closeSession(descriptor.session)
            settle(claim, MailTransportStatus.CANCELLED)
            return
        }
        try {
            when (descriptor.operation) {
                "open" -> {
                    if (lanGate != null && !lanGate.authorize(descriptor.host, descriptor.port)) {
                        settle(claim, MailTransportStatus.LOCAL_NETWORK_REQUIRED)
                        return
                    }
                    if (!running.get() || bridge.shouldStop(claim)) {
                        settle(claim, MailTransportStatus.CANCELLED)
                        return
                    }
                    val socket = socketFactory.open(
                        host = descriptor.host,
                        port = descriptor.port,
                        implicitTls = descriptor.implicitTls,
                        connectTimeoutMillis = 20_000,
                        handshakeTimeoutMillis = 20_000,
                    )
                    if (!running.get() || bridge.shouldStop(claim)) {
                        socket.close()
                        settle(claim, MailTransportStatus.CANCELLED)
                        return
                    }
                    sessions[descriptor.session] = socket
                    settle(claim, MailTransportStatus.OK)
                }
                "upgrade" -> {
                    val socket = sessions[descriptor.session]
                        ?: throw IOException("missing_session")
                    socket.upgradeTls()
                    settle(claim, MailTransportStatus.OK)
                }
                "read" -> {
                    val socket = sessions[descriptor.session]
                        ?: throw IOException("missing_session")
                    val deadline = now() + descriptor.timeoutMillis.coerceIn(1, 60_000)
                    while (true) {
                        if (bridge.shouldStop(claim)) {
                            closeSession(descriptor.session)
                            settle(claim, MailTransportStatus.CANCELLED)
                            return
                        }
                        val chunk = socket.readSome(descriptor.maxBytes)
                        if (chunk == null) {
                            closeSession(descriptor.session)
                            settle(claim, MailTransportStatus.CLOSED)
                            return
                        }
                        if (chunk.isNotEmpty()) {
                            settle(claim, MailTransportStatus.OK, chunk)
                            return
                        }
                        if (now() >= deadline) {
                            closeSession(descriptor.session)
                            settle(claim, MailTransportStatus.TIMED_OUT)
                            return
                        }
                        delay(5)
                    }
                }
                "write" -> {
                    val socket = sessions[descriptor.session]
                        ?: throw IOException("missing_session")
                    val data = bridge.takeWrite(claim, descriptor.writeLength)
                        ?: throw IOException("invalid_payload")
                    socket.writeAll(data)
                    settle(claim, MailTransportStatus.OK)
                }
                "close" -> {
                    closeSession(descriptor.session)
                    settle(claim, MailTransportStatus.OK)
                }
                else -> settle(claim, MailTransportStatus.PROTOCOL_VIOLATION)
            }
        } catch (peer: SSLPeerUnverifiedException) {
            fail(claim, descriptor.session, MailTransportStatus.HOSTNAME_MISMATCH)
        } catch (handshake: SSLException) {
            fail(claim, descriptor.session, MailTransportStatus.TLS_FAILED)
        } catch (timeout: SocketTimeoutException) {
            fail(claim, descriptor.session, MailTransportStatus.TIMED_OUT)
        } catch (cancelled: CancellationException) {
            fail(claim, descriptor.session, MailTransportStatus.CANCELLED)
            throw cancelled
        } catch (security: SecurityException) {
            fail(claim, descriptor.session, MailTransportStatus.LOCAL_NETWORK_REQUIRED)
        } catch (io: IOException) {
            val message = io.message.orEmpty().lowercase()
            val localDenied = message.contains("eperm") ||
                message.contains("operation not permitted") ||
                message.contains("permission denied")
            fail(
                claim,
                descriptor.session,
                if (localDenied) MailTransportStatus.LOCAL_NETWORK_REQUIRED
                else MailTransportStatus.IO_FAILED,
            )
        } catch (_: Throwable) {
            fail(claim, descriptor.session, MailTransportStatus.INTERNAL_FAILURE)
        }
    }

    private fun fail(claim: Long, session: Long, status: Int) {
        closeSession(session)
        settle(claim, status)
    }

    private fun closeSession(session: Long) {
        sessions.remove(session)?.close()
    }

    private fun settle(claim: Long, status: Int, data: ByteArray? = null) {
        bridge.complete(claim, status, data)
    }

    private fun parseDescriptor(text: String): MailTransportDescriptor? {
        val object = Json.parseToJsonElement(text).jsonObject
        val operation = object["op"]?.jsonPrimitive?.content ?: return null
        val claim = object["claim"]?.jsonPrimitive?.long ?: return null
        val session = object["session"]?.jsonPrimitive?.long ?: return null
        val host = object["host"]?.jsonPrimitive?.content ?: return null
        val port = object["port"]?.jsonPrimitive?.int ?: return null
        val tls = object["tls"]?.jsonPrimitive?.content ?: return null
        val maxBytes = object["maxBytes"]?.jsonPrimitive?.int ?: 0
        val writeLength = object["writeLength"]?.jsonPrimitive?.int ?: 0
        val timeoutMillis = object["timeoutMillis"]?.jsonPrimitive?.int ?: 1_000
        if (host.isEmpty() || port !in 1..65535) return null
        return MailTransportDescriptor(
            claim = claim,
            session = session,
            operation = operation,
            host = host,
            port = port,
            tls = tls,
            maxBytes = maxBytes,
            writeLength = writeLength,
            timeoutMillis = timeoutMillis,
        )
    }
}
