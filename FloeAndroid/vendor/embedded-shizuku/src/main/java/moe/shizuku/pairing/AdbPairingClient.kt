// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager AdbPairingClient.kt at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea. Modification record: no protocol or
// peer-info logging, bounded reads, explicit public/API-30 exporter injection,
// pairing code held in RAM and wiped, typed outcomes instead of exceptions.
package moe.shizuku.pairing

import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ConnectException
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket

class AdbPairingClient(
    private val host: String,
    private val port: Int,
    private val pairingCode: CharArray,
    private val identity: AdbIdentity,
    private val exporter: KeyingMaterialExporter = KeyingMaterialExporters.forDevice(),
    private val connectTimeoutMillis: Int = 10_000,
    private val readTimeoutMillis: Int = 15_000,
) : Closeable {

    sealed interface Outcome {
        data object Success : Outcome
        data object InvalidCode : Outcome
        data class Unsupported(val code: String) : Outcome
        data object Timeout : Outcome
        data class TransportError(val code: String) : Outcome
        data class ProtocolError(val code: String) : Outcome
    }

    private var socket: Socket? = null
    private var sslSocket: SSLSocket? = null
    private var input: DataInputStream? = null
    private var output: DataOutputStream? = null

    fun pair(): Outcome {
        if (host.isBlank() || port !in 1..65535) return Outcome.TransportError("endpoint")
        if (pairingCode.size != CODE_LENGTH || pairingCode.any { it !in '0'..'9' }) {
            return Outcome.ProtocolError("pairing_code")
        }

        var context: NativePairingContext? = null
        var codeBytes: ByteArray? = null
        var keyMaterial: ByteArray? = null
        var password: ByteArray? = null
        return try {
            connect()
            keyMaterial = exporter.export(
                sslSocket ?: return Outcome.TransportError("tls"),
                KeyingMaterialExporters.ADB_LABEL,
                null,
                KeyingMaterialExporters.ADB_LENGTH,
            )
            codeBytes = String(pairingCode).toByteArray(Charsets.UTF_8)
            password = ByteArray(codeBytes.size + keyMaterial.size)
            codeBytes.copyInto(password, 0)
            keyMaterial.copyInto(password, codeBytes.size)

            context = NativePairingContext.create(password) ?: return Outcome.Unsupported("spake2")
            exchangeMessages(context)
            exchangePeerInfo(context)
            Outcome.Success
        } catch (e: InvalidPairingCode) {
            Outcome.InvalidCode
        } catch (e: UnsupportedOperationException) {
            Outcome.Unsupported(e.message ?: "unsupported")
        } catch (e: SocketTimeoutException) {
            Outcome.Timeout
        } catch (e: ConnectException) {
            Outcome.TransportError("connect")
        } catch (e: UnknownHostException) {
            Outcome.TransportError("host")
        } catch (e: SSLException) {
            Outcome.TransportError("tls")
        } catch (e: IllegalArgumentException) {
            Outcome.ProtocolError("wire")
        } catch (e: java.io.EOFException) {
            Outcome.ProtocolError("eof")
        } catch (e: java.io.IOException) {
            Outcome.TransportError("io")
        } catch (e: Throwable) {
            Outcome.ProtocolError("internal")
        } finally {
            password?.fill(0)
            codeBytes?.fill(0)
            keyMaterial?.fill(0)
            context?.close()
            close()
        }
    }

    private fun connect() {
        val plain = Socket()
        socket = plain
        plain.connect(java.net.InetSocketAddress(host, port), connectTimeoutMillis)
        plain.tcpNoDelay = true
        plain.soTimeout = readTimeoutMillis
        val tls = identity.sslContext().socketFactory
            .createSocket(plain, host, port, true) as SSLSocket
        sslSocket = tls
        tls.soTimeout = readTimeoutMillis
        tls.startHandshake()
        input = DataInputStream(tls.inputStream)
        output = DataOutputStream(tls.outputStream)
    }

    private fun exchangeMessages(context: NativePairingContext) {
        val message = context.message
        if (message.isEmpty() || message.size > PairingWire.MAX_PAYLOAD_BYTES) {
            throw IllegalArgumentException("spake2 message size")
        }
        writePacket(PairingWire.TYPE_SPAKE2, message)
        val header = readHeader() ?: throw IllegalArgumentException("spake2 header")
        if (header.type != PairingWire.TYPE_SPAKE2) throw IllegalArgumentException("spake2 type")
        val theirMessage = ByteArray(header.payloadBytes)
        input!!.readFully(theirMessage)
        if (!context.initCipher(theirMessage)) throw IllegalArgumentException("spake2 verify")
    }

    private fun exchangePeerInfo(context: NativePairingContext) {
        val record = PairingWire.encodePeerInfo(
            PairingWire.PEER_TYPE_RSA_PUBLIC_KEY,
            identity.adbPublicKey,
        )
        val encrypted = context.encrypt(record)
            ?: throw IllegalStateException("peer encrypt")
        if (encrypted.isEmpty() || encrypted.size > PairingWire.MAX_PAYLOAD_BYTES) {
            throw IllegalArgumentException("peer payload")
        }
        writePacket(PairingWire.TYPE_PEER_INFO, encrypted)

        val header = readHeader() ?: throw IllegalArgumentException("peer header")
        if (header.type != PairingWire.TYPE_PEER_INFO) throw IllegalArgumentException("peer type")
        val theirCipher = ByteArray(header.payloadBytes)
        input!!.readFully(theirCipher)
        val plain = context.decrypt(theirCipher) ?: throw InvalidPairingCode()
        try {
            when (val peer = PairingWire.decodePeerInfo(plain)) {
                is PairingWire.PeerInfoResult.Ok -> Unit
                is PairingWire.PeerInfoResult.Rejected -> throw IllegalArgumentException(peer.code)
            }
        } finally {
            plain.fill(0)
        }
    }

    private fun writePacket(type: Byte, payload: ByteArray) {
        output!!.write(PairingWire.encodeHeader(type, payload.size))
        output!!.write(payload)
        output!!.flush()
    }

    private fun readHeader(): PairingWire.Header? {
        val bytes = ByteArray(PairingWire.HEADER_BYTES)
        input!!.readFully(bytes)
        return when (val result = PairingWire.decodeHeader(bytes)) {
            is PairingWire.DecodeResult.Ok -> result.header
            is PairingWire.DecodeResult.Rejected -> throw IllegalArgumentException(result.code)
        }
    }

    override fun close() {
        try {
            input?.close()
        } catch (_: Throwable) {
        }
        try {
            output?.close()
        } catch (_: Throwable) {
        }
        try {
            sslSocket?.close()
        } catch (_: Throwable) {
        }
        try {
            socket?.close()
        } catch (_: Throwable) {
        }
        input = null
        output = null
        sslSocket = null
        socket = null
    }

    private class InvalidPairingCode : Exception()

    companion object {
        const val CODE_LENGTH = 6
    }
}
