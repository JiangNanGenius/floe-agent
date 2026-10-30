// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Locale
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SNIServerName
import javax.net.ssl.SSLException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * HTTPS-only first-batch diagnostics.
 *
 * The target name is resolved once on the captured Network, the destination
 * policy is applied to every resolved address, and a TCP socket is then
 * pinned to one verified address. TLS layers the platform default
 * SSLSocketFactory over that socket with the original hostname for SNI and
 * endpoint identification; the platform default HostnameVerifier is checked
 * again after the handshake. This prevents a second HttpsURLConnection DNS
 * resolution from silently rebinding to a metadata address while keeping
 * default trust, hostname verification and the configured VPN route. No
 * global TLS setting is changed and no response body is read.
 */
internal object AndroidHttpsProbe {
    private const val MAX_HEADER_BYTES = 32 * 1024
    private const val MAX_HEADER_LINES = 64
    private const val MAX_HEADER_VALUE_CHARS = 1024
    private val SAFE_RESPONSE_HEADERS = listOf(
        "content-type",
        "content-length",
        "server",
        "date",
        "cache-control",
        "strict-transport-security",
        "via",
        "content-encoding",
    )

    suspend fun probe(
        session: AndroidNetworkSession,
        target: HttpTarget,
        timeoutMs: Int,
        maxRedirects: Int,
    ): ProbeResult {
        if (target.scheme != "https") {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put(
                    "unsupportedReason",
                    if (target.cleartext) "cleartextHttpNotSupported" else "unsupportedScheme",
                ),
                limitations = listOf(
                    if (target.cleartext) {
                        "This batch supports HTTPS diagnostics only; cleartext HTTP is not used."
                    } else {
                        "Only HTTPS diagnostic targets are supported."
                    },
                ),
                target = target.redacted,
            )
        }
        try {
            NetworkTargetPolicy.checkHttpTargetPolicy(target)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "The HTTPS target is not permitted."),
                target = target.redacted,
            )
        }
        val probeStarted = System.nanoTime()
        val chain = HttpRedirectLoop.follow(
            initial = target,
            maxRedirects = maxRedirects,
            timeoutMs = timeoutMs,
            fetcher = AndroidHttpFetcher(session),
            elapsedMillis = { SystemClock.elapsedRealtime() },
        )
        val probeTotalMs = (System.nanoTime() - probeStarted) / 1_000_000L
        return HttpObservationBuilder.build(target, chain, probeTotalMs)
    }

    private class AndroidHttpFetcher(
        private val session: AndroidNetworkSession,
    ) : HttpFetcher {
        override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop = withContext(Dispatchers.IO) {
            val probeStartNanos = System.nanoTime()
            val network = session.activeNetwork
                ?: throw HttpFetchException(ObservationStatus.UNAVAILABLE, "noActiveNetwork")
            val dnsStartNanos = System.nanoTime()
            val addresses = if (NetworkTargetPolicy.literalAddressClass(target.host) != null) {
                listOf(target.host)
            } else {
                try {
                    network.getAllByName(target.host).mapNotNull { it.hostAddress }
                } catch (_: UnknownHostException) {
                    throw HttpFetchException(ObservationStatus.UNAVAILABLE, "dnsFailure")
                } catch (failure: Exception) {
                    throw HttpFetchException(
                        ObservationStatus.ERROR,
                        "dnsFailure",
                        failure.javaClass.simpleName.take(64),
                    )
                }
            }
            val dnsMs = (System.nanoTime() - dnsStartNanos) / 1_000_000L
            val local = try {
                NetworkTargetPolicy.checkResolvedAddresses(target.host, addresses)
            } catch (failure: TargetPolicyException) {
                throw HttpFetchException(failure.statusOrUnsupported(), failure.code, failure.message)
            }
            if (local && session.localNetworkPermissionMissing()) {
                throw HttpFetchException(
                    ObservationStatus.PERMISSION_REQUIRED,
                    "localNetworkPermissionRequired",
                    "A local-network HTTPS diagnostic needs the shared ACCESS_LOCAL_NETWORK grant.",
                    session.localNetworkMissingPermissions(),
                )
            }
            val port = if (target.port > 0) target.port else 443
            var lastFailure: Exception? = null
            addresses.forEach { literal ->
                val remainingMs = timeoutMs - (System.nanoTime() - probeStartNanos) / 1_000_000L
                if (remainingMs <= 0L) return@forEach
                val address = try {
                    java.net.InetAddress.getByName(literal)
                } catch (failure: Exception) {
                    lastFailure = failure
                    return@forEach
                }
                val plain = Socket()
                session.trackCloseable(plain)
                try {
                    network.bindSocket(plain)
                    val tcpStartNanos = System.nanoTime()
                    plain.connect(
                        InetSocketAddress(address, port),
                        remainingMs.toInt().coerceAtLeast(1),
                    )
                    val tcpConnectMs = (System.nanoTime() - tcpStartNanos) / 1_000_000L
                    plain.soTimeout = remainingMs.toInt().coerceAtLeast(1)
                    val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
                    val ssl = factory.createSocket(plain, target.host, port, true) as SSLSocket
                    session.trackCloseable(ssl)
                    try {
                        val tlsStartNanos = System.nanoTime()
                        val parameters = ssl.sslParameters
                        parameters.endpointIdentificationAlgorithm = "HTTPS"
                        if (NetworkTargetPolicy.literalAddressClass(target.host) == null) {
                            runCatching { SNIHostName(target.host) }.getOrNull()?.let { sni ->
                                val names = ArrayList<SNIServerName>()
                                names.add(sni)
                                parameters.serverNames = names
                            }
                        }
                        ssl.sslParameters = parameters
                        ssl.startHandshake()
                        val tlsHandshakeMs = (System.nanoTime() - tlsStartNanos) / 1_000_000L
                        val sessionInfo = ssl.session
                        if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(target.host, sessionInfo)) {
                            throw SSLPeerUnverifiedException("platform default hostname verification failed")
                        }
                        val responseStartNanos = System.nanoTime()
                        val output = ssl.outputStream
                        output.write(buildGetRequest(target, port))
                        output.flush()
                        val head = readHeaders(ssl.inputStream)
                        val responseHeadersMs = (System.nanoTime() - responseStartNanos) / 1_000_000L
                        val safeHeaders = LinkedHashMap<String, String>()
                        SAFE_RESPONSE_HEADERS.forEach { name ->
                            head.headers[name]?.let { value -> safeHeaders[name] = value }
                        }
                        return@withContext HttpHop(
                            target = target,
                            statusCode = head.statusCode,
                            location = head.headers["location"],
                            cipherSuite = sessionInfo.cipherSuite,
                            contentType = head.headers["content-type"],
                            contentLength = head.headers["content-length"]?.toLongOrNull(),
                            headers = safeHeaders,
                            tlsProtocol = sessionInfo.protocol,
                            dnsMs = dnsMs,
                            tcpConnectMs = tcpConnectMs,
                            tlsHandshakeMs = tlsHandshakeMs,
                            responseHeadersMs = responseHeadersMs,
                            totalMs = (System.nanoTime() - probeStartNanos) / 1_000_000L,
                        )
                    } finally {
                        runCatching { ssl.close() }
                    }
                } catch (cancelled: java.util.concurrent.CancellationException) {
                    throw cancelled
                } catch (failure: HttpFetchException) {
                    throw failure
                } catch (failure: Exception) {
                    lastFailure = failure
                } finally {
                    runCatching { plain.close() }
                }
            }
            throw mapFailure(lastFailure)
        }
    }

    private data class HttpResponseHead(
        val statusCode: Int,
        val headers: Map<String, String>,
    )

    private fun buildGetRequest(target: HttpTarget, port: Int): ByteArray {
        val hostHeader = if (target.host.contains(':')) "[${target.host}]" else target.host
        val authority = if (port == 443) hostHeader else "$hostHeader:$port"
        val pathAndQuery = target.path + (target.query?.let { "?$it" } ?: "")
        val request = buildString {
            append("GET ").append(pathAndQuery).append(" HTTP/1.1\r\n")
            append("Host: ").append(authority).append("\r\n")
            append("Accept: */*\r\n")
            append("Connection: close\r\n\r\n")
        }
        return request.toByteArray(Charsets.ISO_8859_1)
    }

    private fun readHeaders(input: InputStream): HttpResponseHead {
        val output = ByteArrayOutputStream(1024)
        val one = ByteArray(1)
        var bytesRead = 0
        var tail = 0
        while (bytesRead < MAX_HEADER_BYTES) {
            val read = input.read(one)
            if (read < 0) break
            output.write(one[0].toInt())
            bytesRead++
            tail = (tail shl 8) or (one[0].toInt() and 0xFF)
            if (tail == 0x0D0A0D0A) break
        }
        if (bytesRead == 0) throw IOException("empty HTTPS response")
        val text = String(output.toByteArray(), Charsets.ISO_8859_1)
        val lines = text.split("\r\n")
        val status = lines.firstOrNull()?.split(' ') ?: emptyList()
        val statusCode = status.getOrNull(1)?.toIntOrNull()
            ?: throw IOException("invalid HTTPS status line")
        val headers = LinkedHashMap<String, String>()
        lines.drop(1).forEach { line ->
            if (line.isEmpty()) return@forEach
            if (headers.size >= MAX_HEADER_LINES) return@forEach
            val separator = line.indexOf(':')
            if (separator <= 0) return@forEach
            val name = line.substring(0, separator).trim().lowercase(Locale.ROOT)
            if (name.isEmpty()) return@forEach
            headers[name] = line.substring(separator + 1).trim().take(MAX_HEADER_VALUE_CHARS)
        }
        return HttpResponseHead(statusCode, headers)
    }

    private fun mapFailure(failure: Exception?): Exception = when (failure) {
        null -> HttpFetchException(ObservationStatus.ERROR, "requestFailed")
        is SocketTimeoutException -> failure
        is UnknownHostException -> HttpFetchException(ObservationStatus.UNAVAILABLE, "dnsFailure")
        is SSLPeerUnverifiedException -> HttpFetchException(
            ObservationStatus.ERROR,
            "tlsHostnameVerificationFailed",
            failure.javaClass.simpleName.take(64),
        )
        is SSLException -> HttpFetchException(
            ObservationStatus.ERROR,
            "tlsFailure",
            failure.javaClass.simpleName.take(64),
        )
        is SecurityException -> HttpFetchException(
            ObservationStatus.PERMISSION_REQUIRED,
            "securityException",
            failure.javaClass.simpleName.take(64),
        )
        else -> HttpFetchException(
            ObservationStatus.ERROR,
            "requestFailed",
            failure.javaClass.simpleName.take(64),
        )
    }

    private fun TargetPolicyException.statusOrUnsupported(): ObservationStatus =
        if (code == "dnsFailure") ObservationStatus.UNAVAILABLE else ObservationStatus.UNSUPPORTED
}
