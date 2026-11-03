// SPDX-License-Identifier: MPL-2.0
//
// Platform TLS socket for the C06 mail lane.
//
// Trust and hostname verification are the Android platform's: the default
// SSLSocketFactory and the app's network-security configuration are used
// unchanged, and endpointIdentificationAlgorithm = "HTTPS" makes the
// handshake fail on a certificate/name mismatch. There is deliberately NO
// trust-all manager, no hostname-verifier override and no plaintext fallback.
// STARTTLS wraps the SAME already-connected socket after the protocol has
// verified the server's STARTTLS/STLS response; Swift refuses to upgrade if
// any protocol byte was already buffered.

package com.floe.android.host.mail

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

internal object MailTransportStatus {
    const val OK = 0
    const val CANCELLED = -1201
    const val TIMED_OUT = -1202
    const val CONNECTION_FAILED = -1203
    const val TLS_FAILED = -1204
    const val HOSTNAME_MISMATCH = -1205
    const val IO_FAILED = -1206
    const val CLOSED = -1207
    const val TOO_LARGE = -1208
    const val TRANSPORT_UNAVAILABLE = -1209
    const val PROTOCOL_VIOLATION = -1210
    const val INTERNAL_FAILURE = -1211
    const val BUSY = -1212
    const val LOCAL_NETWORK_REQUIRED = -1213
}

internal interface MailSocket {
    /** TLS/STARTTLS handshake on the current raw socket. */
    fun upgradeTls()
    /** At most [maxBytes]; null means the peer closed cleanly. */
    fun readSome(maxBytes: Int): ByteArray?
    fun writeAll(data: ByteArray)
    fun close()
}

internal fun interface MailSocketFactory {
    fun open(
        host: String,
        port: Int,
        implicitTls: Boolean,
        connectTimeoutMillis: Int,
        handshakeTimeoutMillis: Int,
    ): MailSocket
}

internal class PlatformMailSocketFactory : MailSocketFactory {
    override fun open(
        host: String,
        port: Int,
        implicitTls: Boolean,
        connectTimeoutMillis: Int,
        handshakeTimeoutMillis: Int,
    ): MailSocket {
        val plain = Socket()
        try {
            plain.tcpNoDelay = true
            plain.soTimeout = handshakeTimeoutMillis
            plain.connect(InetSocketAddress(host, port), connectTimeoutMillis)
            val socket = PlatformMailSocket(plain, host, port, handshakeTimeoutMillis)
            if (implicitTls) socket.upgradeTls()
            socket.setReadTimeout()
            return socket
        } catch (error: Throwable) {
            try { plain.close() } catch (_: IOException) {}
            throw error
        }
    }
}

private class PlatformMailSocket(
    private val plain: Socket,
    private val host: String,
    private val port: Int,
    private val handshakeTimeoutMillis: Int,
) : MailSocket {
    private var tls: SSLSocket? = null
    private var input: InputStream = plain.getInputStream()
    private var output: OutputStream = plain.getOutputStream()
    private var closed = false

    override fun upgradeTls() {
        check(tls == null) { "already_tls" }
        val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
        val socket = factory.createSocket(plain, host, port, true) as SSLSocket
        socket.useClientMode = true
        val protocols = socket.supportedProtocols.filter { it == "TLSv1.3" || it == "TLSv1.2" }
        if (protocols.isEmpty()) {
            try { socket.close() } catch (_: IOException) {}
            throw IOException("tls_protocol_unavailable")
        }
        socket.enabledProtocols = protocols.toTypedArray()
        socket.soTimeout = handshakeTimeoutMillis
        val parameters = socket.sslParameters
        parameters.endpointIdentificationAlgorithm = "HTTPS"
        socket.sslParameters = parameters
        socket.startHandshake()
        tls = socket
        input = socket.inputStream
        output = socket.outputStream
        plain.soTimeout = READ_TIMEOUT_MILLIS
        socket.soTimeout = READ_TIMEOUT_MILLIS
    }

    fun setReadTimeout() {
        plain.soTimeout = READ_TIMEOUT_MILLIS
        tls?.soTimeout = READ_TIMEOUT_MILLIS
    }

    override fun readSome(maxBytes: Int): ByteArray? {
        if (closed) throw IOException("closed")
        val size = maxBytes.coerceIn(1, MAX_READ_CHUNK)
        val buffer = ByteArray(size)
        val count = try {
            input.read(buffer)
        } catch (timeout: SocketTimeoutException) {
            return ByteArray(0)
        }
        if (count < 0) return null
        return buffer.copyOf(count)
    }

    override fun writeAll(data: ByteArray) {
        if (closed) throw IOException("closed")
        output.write(data)
        output.flush()
    }

    override fun close() {
        if (closed) return
        closed = true
        val tlsSocket = tls
        tls = null
        try { tlsSocket?.close() } catch (_: IOException) {}
        try { plain.close() } catch (_: IOException) {}
    }

    companion object {
        const val MAX_READ_CHUNK = 64 * 1024
        const val READ_TIMEOUT_MILLIS = 250
    }
}
