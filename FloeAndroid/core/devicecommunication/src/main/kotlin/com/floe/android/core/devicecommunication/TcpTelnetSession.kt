// SPDX-License-Identifier: MPL-2.0
//
// A real TCP socket session, optionally wrapped by the incremental Telnet
// codec. The reader owns one bounded queue; writes are serialized against the
// Telnet option replies on the SAME output stream. Close tombstones the
// session, closes the socket (which unblocks the reader), joins the reader and
// reports an honest drain result.

package com.floe.android.core.devicecommunication

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.NoRouteToHostException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal class TcpTelnetSession(
    private val record: DeviceSessionRecord,
    private val host: String,
    private val port: Int,
    private val listener: DeviceTransportListener,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val clock: () -> Long = { System.currentTimeMillis() },
) : DeviceTransport {
    private val protocol = record.protocol
    private val socket = Socket()
    private val outputLock = ReentrantLock()
    private val queue = BoundedByteQueue(DeviceLimits.MAXIMUM_BUFFERED_BYTES)
    private val telnet = if (protocol == DeviceProtocol.TELNET) TelnetCodec() else null
    @Volatile private var closed = false
    private var readerJob: Job? = null
    @Volatile private var readerStopped = false

    suspend fun connect(timeoutMillis: Long) {
        try {
            socket.connect(InetSocketAddress(host, port), timeoutMillis.toInt())
            socket.soTimeout = DeviceLimits.READ_LOOP_TIMEOUT_MILLIS
            socket.tcpNoDelay = true
            socket.keepAlive = true
        } catch (error: Throwable) {
            runCatching { socket.close() }
            throw classify(error)
        }
        listener.onTransportConnected(record)
        readerJob = scope.launch(ioDispatcher) { readLoop() }
    }

    private fun readLoop() {
        val input: InputStream = try {
            socket.getInputStream()
        } catch (error: Throwable) {
            if (!closed) terminate(DeviceSessionState.FAILED, classify(error))
            return
        }
        val buffer = ByteArray(8 * 1024)
        while (!closed) {
            try {
                val count = input.read(buffer)
                if (count < 0) {
                    if (!closed) terminate(DeviceSessionState.CLOSED, null)
                    break
                }
                if (count == 0) continue
                val chunk = buffer.copyOf(count)
                val decoded = telnet
                if (decoded == null) {
                    queue.append(chunk)
                    record.addBytesIn(count.toLong())
                } else {
                    val result = decoded.feed(chunk)
                    if (result.replies.isNotEmpty()) {
                        runCatching {
                            outputLock.withLock {
                                socket.getOutputStream().apply {
                                    write(result.replies)
                                    flush()
                                }
                            }
                        }
                    }
                    if (result.application.isNotEmpty()) {
                        queue.append(result.application)
                        record.addBytesIn(result.application.size.toLong())
                    }
                }
                record.lastActivityMillis = clock()
                listener.onTransportActivity(record)
            } catch (_: SocketTimeoutException) {
                // Bounded read timeout keeps close/reader joins prompt.
            } catch (error: Throwable) {
                if (!closed) terminate(DeviceSessionState.FAILED, classify(error))
                break
            }
        }
        readerStopped = true
    }

    override suspend fun read(maxBytes: Int): ByteArray {
        if (maxBytes <= 0) return ByteArray(0)
        val bytes = queue.drain(minOf(maxBytes, DeviceLimits.MAXIMUM_READ_BYTES))
        if (bytes.isNotEmpty()) record.lastActivityMillis = clock()
        return bytes
    }

    override suspend fun write(bytes: ByteArray): Int {
        if (bytes.isEmpty()) return 0
        if (bytes.size > DeviceLimits.MAXIMUM_WRITE_BYTES) {
            throw DeviceCommunicationException(
                DeviceErrorCode.INVALID_REQUEST,
                "A device write is limited to ${DeviceLimits.MAXIMUM_WRITE_BYTES / 1024} KiB.",
            )
        }
        if (closed || record.state != DeviceSessionState.CONNECTED) {
            throw DeviceCommunicationException(
                DeviceErrorCode.SESSION_CLOSING,
                "The device session is no longer connected.",
                retryable = true,
            )
        }
        try {
            outputLock.withLock {
                val output: OutputStream = socket.getOutputStream()
                output.write(bytes)
                output.flush()
            }
            record.addBytesOut(bytes.size.toLong())
            record.lastActivityMillis = clock()
            listener.onTransportActivity(record)
            return bytes.size
        } catch (error: Throwable) {
            throw classify(error)
        }
    }

    override suspend fun close(): DeviceDrainReport {
        if (closed) {
            return DeviceDrainReport(
                closed = readerStopped,
                complete = readerStopped,
                pendingBytes = queue.bufferedBytes,
            )
        }
        closed = true
        val pending = queue.bufferedBytes
        runCatching { socket.close() }
        val joined = withTimeoutOrNull(DeviceLimits.CLOSE_JOIN_TIMEOUT_MILLIS) {
            readerJob?.join()
            true
        } ?: false
        val complete = joined && readerStopped && socket.isClosed
        queue.clear()
        telnet?.reset()
        if (complete) {
            listener.onTransportTerminated(record, DeviceSessionState.CLOSED, null, null)
        }
        return DeviceDrainReport(closed = socket.isClosed, complete = complete, pendingBytes = pending)
    }

    private fun terminate(state: DeviceSessionState, error: DeviceCommunicationException?) {
        if (closed) return
        closed = true
        runCatching { socket.close() }
        listener.onTransportTerminated(record, state, error?.code, error?.detail)
    }

    private fun classify(error: Throwable): DeviceCommunicationException = when (error) {
        is SecurityException -> DeviceCommunicationException(
            DeviceErrorCode.PERMISSION_REQUIRED,
            "Local network access is required for this destination.",
            retryable = false,
        )
        is UnknownHostException -> DeviceCommunicationException(
            DeviceErrorCode.HOST_NOT_FOUND,
            "The host name could not be resolved.",
            retryable = true,
        )
        is ConnectException -> DeviceCommunicationException(
            DeviceErrorCode.CONNECTION_REFUSED,
            "The host refused the connection.",
            retryable = true,
        )
        is NoRouteToHostException -> DeviceCommunicationException(
            DeviceErrorCode.CONNECT_FAILED,
            "The host is unreachable.",
            retryable = true,
        )
        is SocketTimeoutException -> DeviceCommunicationException(
            DeviceErrorCode.TIMED_OUT,
            "The device operation timed out.",
            retryable = true,
        )
        is IOException -> DeviceCommunicationException(
            DeviceErrorCode.IO_FAILED,
            "The device connection ended.",
            retryable = true,
        )
        else -> DeviceCommunicationException(
            DeviceErrorCode.CONNECT_FAILED,
            "The device connection could not be opened.",
            retryable = true,
        )
    }

    companion object {
        suspend fun openAndConnect(
            record: DeviceSessionRecord,
            host: String,
            port: Int,
            listener: DeviceTransportListener,
            scope: CoroutineScope,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
            clock: () -> Long = { System.currentTimeMillis() },
        ): TcpTelnetSession {
            val session = TcpTelnetSession(record, host, port, listener, scope, ioDispatcher, clock)
            session.connect(DeviceLimits.CONNECT_TIMEOUT_MILLIS)
            return session
        }
    }
}
