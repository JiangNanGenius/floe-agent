// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager AdbClient.kt at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea. Modification record: no packet
// logging, bounded payload reads and shell output, typed failures, TLS socket
// closed with the plain socket, and no dependency on manager/AndroidX classes.
package moe.shizuku.adb

import moe.shizuku.pairing.AdbIdentity
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import javax.net.ssl.SSLSocket

class AdbClient(
    private val host: String,
    private val port: Int,
    private val identity: AdbIdentity,
    private val connectTimeoutMillis: Int = 10_000,
    private val readTimeoutMillis: Int = 20_000,
) : Closeable {

    sealed interface Failure {
        data class Connect(val code: String) : Failure
        data class Protocol(val code: String) : Failure
        data class Timeout(val operation: String) : Failure
        data class OutputTooLarge(val limit: Int) : Failure
    }

    class AdbFailure(val failure: Failure) : Exception(failure.toString())

    private var socket: Socket? = null
    private var sslSocket: SSLSocket? = null
    private var plainInput: DataInputStream? = null
    private var plainOutput: DataOutputStream? = null
    private var tlsInput: DataInputStream? = null
    private var tlsOutput: DataOutputStream? = null
    private var useTls = false

    private val input: DataInputStream get() = if (useTls) tlsInput!! else plainInput!!
    private val output: DataOutputStream get() = if (useTls) tlsOutput!! else plainOutput!!

    fun connect() {
        try {
            val plain = Socket()
            socket = plain
            plain.connect(java.net.InetSocketAddress(host, port), connectTimeoutMillis)
            plain.tcpNoDelay = true
            plain.soTimeout = readTimeoutMillis
            plainInput = DataInputStream(plain.getInputStream())
            plainOutput = DataOutputStream(plain.getOutputStream())

            write(AdbProtocol.A_CNXN, AdbProtocol.A_VERSION, AdbProtocol.A_MAXDATA, "host::\u0000".toByteArray())
            var message = read()
            if (message.command == AdbProtocol.A_STLS) {
                write(AdbProtocol.A_STLS, AdbProtocol.A_STLS_VERSION, 0, null)
                val tls = identity.sslContext().socketFactory
                    .createSocket(plain, host, port, true) as SSLSocket
                sslSocket = tls
                tls.soTimeout = readTimeoutMillis
                tls.startHandshake()
                tlsInput = DataInputStream(tls.inputStream)
                tlsOutput = DataOutputStream(tls.outputStream)
                useTls = true
                message = read()
            } else if (message.command == AdbProtocol.A_AUTH) {
                write(
                    AdbProtocol.A_AUTH,
                    AdbProtocol.ADB_AUTH_SIGNATURE,
                    0,
                    sign(message.data ?: ByteArray(0)),
                )
                message = read()
                if (message.command != AdbProtocol.A_CNXN) {
                    write(
                        AdbProtocol.A_AUTH,
                        AdbProtocol.ADB_AUTH_RSAPUBLICKEY,
                        0,
                        identity.adbPublicKey,
                    )
                    message = read()
                }
            }
            if (message.command != AdbProtocol.A_CNXN) fail(Failure.Protocol("cnxn"))
        } catch (e: java.net.SocketTimeoutException) {
            fail(Failure.Timeout("connect"))
        } catch (e: java.net.ConnectException) {
            fail(Failure.Connect("connect"))
        } catch (e: java.net.UnknownHostException) {
            fail(Failure.Connect("host"))
        } catch (e: javax.net.ssl.SSLException) {
            fail(Failure.Connect("tls"))
        } catch (e: java.io.IOException) {
            fail(Failure.Connect("io"))
        }
    }

    /** Runs one validated shell command and returns bounded UTF-8 output. */
    fun shellCommand(command: String, maxOutputBytes: Int = 32 * 1024): String {
        require(command.isNotBlank() && command.length <= 4096) { "invalid shell command" }
        require(maxOutputBytes in 1..AdbProtocol.MAX_MESSAGE_BYTES) { "invalid output bound" }
        val collected = java.io.ByteArrayOutputStream()
        val localId = 1
        write(AdbProtocol.A_OPEN, localId, 0, "shell:$command\u0000".toByteArray())
        try {
            var message = read()
            when (message.command) {
                AdbProtocol.A_OKAY -> {
                    while (true) {
                        message = read()
                        val remoteId = message.arg0
                        if (message.command == AdbProtocol.A_WRTE) {
                            val data = message.data
                            if (data != null && data.isNotEmpty()) {
                                if (collected.size() + data.size > maxOutputBytes) {
                                    fail(Failure.OutputTooLarge(maxOutputBytes))
                                }
                                collected.write(data)
                            }
                            write(AdbProtocol.A_OKAY, localId, remoteId, null)
                        } else if (message.command == AdbProtocol.A_CLSE) {
                            write(AdbProtocol.A_CLSE, localId, remoteId, null)
                            break
                        } else {
                            fail(Failure.Protocol("stream"))
                        }
                    }
                }
                AdbProtocol.A_CLSE -> write(AdbProtocol.A_CLSE, localId, message.arg0, null)
                else -> fail(Failure.Protocol("open"))
            }
        } catch (e: java.net.SocketTimeoutException) {
            fail(Failure.Timeout("shell"))
        }
        return String(collected.toByteArray(), Charsets.UTF_8)
    }

    private fun sign(data: ByteArray): ByteArray = identity.signAdbToken(data)

    private fun write(command: Int, arg0: Int, arg1: Int, data: ByteArray?) {
        output.write(AdbMessage(command, arg0, arg1, data).toByteArray())
        output.flush()
    }

    private fun read(): AdbMessage {
        val header = ByteArray(AdbMessage.HEADER_BYTES)
        input.readFully(header)
        val length = (header[12].toInt() and 0xFF) or
            ((header[13].toInt() and 0xFF) shl 8) or
            ((header[14].toInt() and 0xFF) shl 16) or
            ((header[15].toInt() and 0xFF) shl 24)
        if (length < 0 || length > AdbProtocol.MAX_MESSAGE_BYTES) {
            fail(Failure.Protocol("length"))
        }
        val payload = if (length == 0) null else ByteArray(length).also { input.readFully(it) }
        return try {
            AdbMessage.decode(header, payload)
        } catch (e: IllegalArgumentException) {
            fail(Failure.Protocol("message"))
        }
    }

    private fun fail(failure: Failure): Nothing = throw AdbFailure(failure)

    override fun close() {
        for (closeable in listOf(tlsInput, tlsOutput, sslSocket, plainInput, plainOutput, socket)) {
            try {
                closeable?.close()
            } catch (_: Throwable) {
            }
        }
        tlsInput = null
        tlsOutput = null
        sslSocket = null
        plainInput = null
        plainOutput = null
        socket = null
    }
}
