// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.SystemClock
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SNIServerName
import javax.net.ssl.SSLException
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * G07.2 explicitly budgeted HTTPS throughput diagnostics.
 *
 * The destination is user-supplied, HTTPS-only, resolved once on the captured
 * Network, checked by the existing destination policy, and reached through a
 * socket pinned to a verified address with platform default TLS trust and
 * hostname verification. No redirects, cookies, Authorization headers, app
 * proxy, cleartext or user file are used. Byte counts come from actual reads
 * or writes, never from Content-Length. The download body is de-framed with
 * [SpeedHttpBodyReader] so bounded Content-Length, chunked sizes/extensions/
 * CRLFs/trailers and close-delimited EOF contribute no payload bytes and a
 * malformed or truncated frame is reported as an error instead of being
 * counted. The measurement interval includes the blocking first measured I/O
 * and ends at the last measured byte.
 */
internal object AndroidSpeedTest {
    private const val RESERVED_TAIL_MS = 300L
    private const val TRANSFER_CHUNK_BYTES = 64 * 1024
    private const val WATCHDOG_POLL_MS = 250L

    private data class ResolvedTarget(
        val target: HttpTarget,
        val addresses: List<InetAddress>,
        val dnsMs: Long,
        val local: Boolean,
    )

    private data class TlsConnection(
        val ssl: SSLSocket,
        val tcpConnectMs: Long,
        val tlsHandshakeMs: Long,
        val tlsProtocol: String?,
        val cipherSuite: String?,
    )

    suspend fun run(session: AndroidNetworkSession, request: SpeedTestRequest): ProbeResult {
        val network = session.activeNetwork ?: return SpeedTestResult.build(
            request = request,
            download = null,
            upload = null,
            networkChanged = false,
            failure = SpeedTestFailure(
                ObservationStatus.UNAVAILABLE,
                "noActiveNetwork",
                "No active network is available for a speed test.",
            ),
            metered = session.snapshot.metered,
            proxyHost = session.snapshot.httpProxyHost,
            proxyPort = session.snapshot.httpProxyPort,
        )
        val metered = session.snapshot.metered
        val proxyHost = session.snapshot.httpProxyHost
        val proxyPort = session.snapshot.httpProxyPort
        if (metered == true && !request.allowMetered) {
            return SpeedTestResult.build(
                request = request,
                download = null,
                upload = null,
                networkChanged = false,
                failure = SpeedTestFailure(
                    ObservationStatus.UNSUPPORTED,
                    "meteredNetworkDisallowed",
                    "The captured network is metered and allowMetered was not set.",
                ),
                metered = metered,
                proxyHost = proxyHost,
                proxyPort = proxyPort,
            )
        }

        val targets = buildList {
            if (request.direction.includesDownload) request.downloadTarget?.let { add(it) }
            if (request.direction.includesUpload) request.uploadTarget?.let { add(it) }
        }
        for (target in targets) {
            if (target.scheme != "https") {
                val code = if (target.cleartext) "cleartextHttpNotSupported" else "unsupportedScheme"
                return SpeedTestResult.build(
                    request = request,
                    download = null,
                    upload = null,
                    networkChanged = false,
                    failure = SpeedTestFailure(
                        ObservationStatus.UNSUPPORTED,
                        code,
                        "Only explicit HTTPS speed-test endpoints are supported.",
                    ),
                    metered = metered,
                    proxyHost = proxyHost,
                    proxyPort = proxyPort,
                )
            }
            try {
                NetworkTargetPolicy.checkHttpTargetPolicy(target)
            } catch (failure: TargetPolicyException) {
                return SpeedTestResult.build(
                    request = request,
                    download = null,
                    upload = null,
                    networkChanged = false,
                    failure = SpeedTestFailure(
                        ObservationStatus.UNSUPPORTED,
                        failure.code,
                        failure.message,
                    ),
                    metered = metered,
                    proxyHost = proxyHost,
                    proxyPort = proxyPort,
                )
            }
        }

        val downloadResolved = try {
            if (request.direction.includesDownload) {
                request.downloadTarget?.let { resolveTarget(session, network, it) }
            } else {
                null
            }
        } catch (failure: SpeedTestFailure) {
            return SpeedTestResult.build(
                request, null, null, false, failure,
                metered, proxyHost, proxyPort,
            )
        }
        val uploadResolved = try {
            if (request.direction.includesUpload) {
                request.uploadTarget?.let { resolveTarget(session, network, it) }
            } else {
                null
            }
        } catch (failure: SpeedTestFailure) {
            return SpeedTestResult.build(
                request, null, null, false, failure,
                metered, proxyHost, proxyPort,
            )
        }

        if (session.hasCapturedNetworkChanged()) {
            return SpeedTestResult.build(
                request, null, null, true,
                metered = metered, proxyHost = proxyHost, proxyPort = proxyPort,
            )
        }

        val deadline = SystemClock.elapsedRealtime() + request.timeoutMs - RESERVED_TAIL_MS
        var download: SpeedTransferResult? = null
        var upload: SpeedTransferResult? = null
        var networkChanged = false
        try {
            if (request.direction.includesDownload && downloadResolved != null) {
                download = measureDownload(session, network, request, downloadResolved, deadline)
                networkChanged = download.networkChanged
                session.publishPartial(
                    SpeedTestResult.build(
                        request, download, null, networkChanged,
                        metered = metered, proxyHost = proxyHost, proxyPort = proxyPort,
                    ),
                )
                if (networkChanged) {
                    return SpeedTestResult.build(
                        request, download, null, true,
                        metered = metered, proxyHost = proxyHost, proxyPort = proxyPort,
                    )
                }
            }
            if (request.direction.includesUpload && uploadResolved != null) {
                upload = measureUpload(session, network, request, uploadResolved, deadline)
                networkChanged = networkChanged || upload.networkChanged
                session.publishPartial(
                    SpeedTestResult.build(
                        request, download, upload, networkChanged,
                        metered = metered, proxyHost = proxyHost, proxyPort = proxyPort,
                    ),
                )
            }
        } catch (changed: NetworkChangedException) {
            networkChanged = true
        } catch (cancelled: CancellationException) {
            throw cancelled
        }

        return SpeedTestResult.build(
            request, download, upload, networkChanged,
            metered = metered, proxyHost = proxyHost, proxyPort = proxyPort,
        )
    }

    private suspend fun resolveTarget(
        session: AndroidNetworkSession,
        network: android.net.Network,
        target: HttpTarget,
    ): ResolvedTarget {
        val localName = target.host.endsWith(".local", ignoreCase = true) ||
            NetworkTargetPolicy.isLocalLiteral(target.host)
        if (localName && session.localNetworkPermissionMissing()) {
            throw SpeedTestFailure(
                ObservationStatus.PERMISSION_REQUIRED,
                "localNetworkPermissionRequired",
                "A local-network speed endpoint needs the shared ACCESS_LOCAL_NETWORK grant.",
                session.localNetworkMissingPermissions(),
            )
        }
        val started = System.nanoTime()
        val addresses = try {
            if (NetworkTargetPolicy.literalAddressClass(target.host) != null) {
                listOf(InetAddress.getByName(target.host))
            } else {
                withContext(Dispatchers.IO) { network.getAllByName(target.host).toList() }
            }
        } catch (_: UnknownHostException) {
            throw SpeedTestFailure(
                ObservationStatus.UNAVAILABLE,
                "dnsFailure",
                "The speed-test endpoint did not resolve on the captured network.",
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            throw SpeedTestFailure(
                ObservationStatus.ERROR,
                "dnsFailure",
                "The speed-test endpoint could not be resolved (${failure.javaClass.simpleName.take(64)}).",
            )
        }
        val dnsMs = (System.nanoTime() - started) / 1_000_000L
        val literals = addresses.mapNotNull { it.hostAddress }
        val local = try {
            NetworkTargetPolicy.checkResolvedAddresses(target.host, literals)
        } catch (failure: TargetPolicyException) {
            throw SpeedTestFailure(
                status = if (failure.code == "dnsFailure") {
                    ObservationStatus.UNAVAILABLE
                } else {
                    ObservationStatus.UNSUPPORTED
                },
                code = failure.code,
                message = failure.message,
            )
        }
        if (local && session.localNetworkPermissionMissing()) {
            throw SpeedTestFailure(
                ObservationStatus.PERMISSION_REQUIRED,
                "localNetworkPermissionRequired",
                "A local-network speed endpoint needs the shared ACCESS_LOCAL_NETWORK grant.",
                session.localNetworkMissingPermissions(),
            )
        }
        return ResolvedTarget(target, addresses, dnsMs, local)
    }

    private suspend fun measureDownload(
        session: AndroidNetworkSession,
        network: android.net.Network,
        request: SpeedTestRequest,
        resolved: ResolvedTarget,
        deadline: Long,
    ): SpeedTransferResult {
        val started = SystemClock.elapsedRealtime()
        val phases = LinkedHashMap<String, Long>()
        phases["dnsMs"] = resolved.dnsMs
        val connection = try {
            connect(session, network, resolved, deadline, phases)
        } catch (failure: SpeedTestFailure) {
            return failureResult(
                resolved.target,
                failure,
                started,
                phases,
                "responseBodyBytesRead",
            )
        }
        val networkChanged = AtomicBoolean(false)
        val durationExpired = AtomicBoolean(false)
        val meter = SpeedMeter(request.warmupBytes.toLong())
        val buffer = ByteArray(TRANSFER_CHUNK_BYTES)
        var completion = "inProgress"
        var contentComplete = false
        var clientStopped = false
        var contentLength: Long? = null
        var contentEncoding: String? = null
        var httpStatus: Int? = null
        var framingFailure = false
        val input = connection.ssl.inputStream
        try {
            val output = connection.ssl.outputStream
            output.write(SpeedHttpWire.downloadRequest(resolved.target, portOf(resolved.target)))
            output.flush()
            val headerStart = System.nanoTime()
            val head = SpeedHttpWire.readHead(input)
            phases["responseHeadersMs"] = (System.nanoTime() - headerStart) / 1_000_000L
            httpStatus = head.statusCode
            contentLength = head.contentLength()
            contentEncoding = head.contentEncoding()
            when {
                head.statusCode in 300..399 -> {
                    completion = "redirectNotFollowed"
                    return transferResult(
                        resolved, ObservationStatus.UNSUPPORTED, started, phases, meter,
                        completion, false, false, httpStatus, contentLength, contentEncoding,
                        connection, networkChanged = false, payloadMeaning = "responseBodyBytesRead",
                    )
                }
                head.statusCode !in 200..299 -> {
                    completion = "httpStatusError"
                    return transferResult(
                        resolved, ObservationStatus.ERROR, started, phases, meter,
                        completion, false, false, httpStatus, contentLength, contentEncoding,
                        connection, networkChanged = false, payloadMeaning = "responseBodyBytesRead",
                    )
                }
                head.statusCode == 204 || head.statusCode == 205 -> {
                    completion = "emptyResponse"
                    return transferResult(
                        resolved, ObservationStatus.ERROR, started, phases, meter,
                        completion, false, false, httpStatus, contentLength, contentEncoding,
                        connection, networkChanged = false, payloadMeaning = "responseBodyBytesRead",
                    )
                }
            }
            // Framing is checked only when a body will actually be read. A
            // malformed or ambiguous frame is refused before any byte can be
            // mistaken for payload; no body byte is inferred from headers.
            val body = try {
                val framing = SpeedHttpBodyFraming.from(head)
                contentLength = framing.declaredContentLength ?: contentLength
                SpeedHttpBodyReader(input, framing)
            } catch (failure: SpeedHttpProtocolException) {
                completion = failure.code
                framingFailure = true
                return transferResult(
                    resolved, ObservationStatus.ERROR, started, phases, meter,
                    completion, false, false, httpStatus, contentLength, contentEncoding,
                    connection, networkChanged = false, payloadMeaning = "responseBodyBytesRead",
                )
            }
            val durationEnd = SystemClock.elapsedRealtime() + request.durationBudgetMs
            connection.ssl.soTimeout = request.durationBudgetMs + 1_000
            withTransferWatchdog(
                session = session,
                ssl = connection.ssl,
                durationEnd = durationEnd,
                networkChanged = networkChanged,
                durationExpired = durationExpired,
            ) {
                while (true) {
                    val remainingTotal = request.maxBytesPerDirection.toLong() - meter.payloadBytes
                    if (remainingTotal <= 0L) {
                        completion = "byteBudget"
                        clientStopped = true
                        break
                    }
                    val remainingWarmup = request.warmupBytes.toLong() - meter.warmupCompletedBytes
                    val toReadLong = minOf(
                        buffer.size.toLong(),
                        remainingTotal,
                        if (remainingWarmup > 0L) remainingWarmup else Long.MAX_VALUE,
                    )
                    val toRead = toReadLong.toInt()
                    if (remainingWarmup <= 0L) meter.beginMeasuredIo(System.nanoTime())
                    val read = try {
                        body.read(buffer, 0, toRead)
                    } catch (_: SocketTimeoutException) {
                        completion = if (durationExpired.get()) "timeBudget" else "ioFailure"
                        clientStopped = true
                        break
                    } catch (failure: SpeedHttpProtocolException) {
                        when {
                            networkChanged.get() -> completion = "networkChanged"
                            durationExpired.get() -> completion = "timeBudget"
                            else -> {
                                completion = failure.code
                                framingFailure = true
                            }
                        }
                        clientStopped = completion == "networkChanged" || completion == "timeBudget"
                        break
                    } catch (_: IOException) {
                        completion = when {
                            networkChanged.get() -> "networkChanged"
                            durationExpired.get() -> "timeBudget"
                            else -> "ioFailure"
                        }
                        clientStopped = true
                        break
                    }
                    if (read < 0) {
                        completion = "contentComplete"
                        contentComplete = true
                        break
                    }
                    if (read == 0) {
                        if (SystemClock.elapsedRealtime() >= durationEnd) {
                            completion = "timeBudget"
                            clientStopped = true
                            break
                        }
                        continue
                    }
                    val now = System.nanoTime()
                    if (remainingWarmup > 0L) {
                        meter.recordWarmup(read)
                    } else {
                        meter.recordMeasured(read, now)
                    }
                    session.publishPartial(
                        SpeedTestResult.build(
                            request,
                            transferResult(
                                resolved, ObservationStatus.PARTIAL, started, phases, meter,
                                "inProgress", false, true, httpStatus, contentLength, contentEncoding,
                                connection, networkChanged.get(), "responseBodyBytesRead",
                            ),
                            null,
                            networkChanged.get(),
                            metered = session.snapshot.metered,
                            proxyHost = session.snapshot.httpProxyHost,
                            proxyPort = session.snapshot.httpProxyPort,
                        ),
                    )
                    // A Content-Length body can complete exactly at the byte
                    // cap; stopping there is completion, not truncation.
                    if (body.messageComplete) {
                        completion = "contentComplete"
                        contentComplete = true
                        break
                    }
                    if (SystemClock.elapsedRealtime() >= durationEnd) {
                        completion = "timeBudget"
                        clientStopped = true
                        break
                    }
                    // Stop on the payload byte cap before touching chunk CRLF,
                    // the zero chunk or trailers that follow this byte.
                    if (meter.payloadBytes >= request.maxBytesPerDirection) {
                        completion = "byteBudget"
                        clientStopped = true
                        break
                    }
                }
            }
        } catch (failure: SpeedHttpProtocolException) {
            if (completion == "inProgress") {
                when {
                    networkChanged.get() -> completion = "networkChanged"
                    durationExpired.get() -> completion = "timeBudget"
                    else -> {
                        completion = failure.code
                        framingFailure = true
                    }
                }
                clientStopped = completion == "networkChanged" || completion == "timeBudget"
            }
        } catch (_: IOException) {
            if (completion == "inProgress") {
                completion = when {
                    networkChanged.get() -> "networkChanged"
                    durationExpired.get() -> "timeBudget"
                    else -> "ioFailure"
                }
                clientStopped = true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            meter.finish(System.nanoTime())
            runCatching { connection.ssl.close() }
        }
        val status = when {
            // A malformed or truncated body keeps its actual partial bytes but
            // is never reported as a successful or merely partial transfer.
            framingFailure -> ObservationStatus.ERROR
            completion == "networkChanged" -> ObservationStatus.PARTIAL
            completion == "timeBudget" && meter.measuredBytes == 0L -> ObservationStatus.TIMEOUT
            meter.measuredBytes == 0L -> ObservationStatus.ERROR
            completion == "byteBudget" || completion == "timeBudget" || completion == "ioFailure" ->
                ObservationStatus.PARTIAL
            else -> ObservationStatus.OK
        }
        return transferResult(
            resolved, status, started, phases, meter,
            completion, contentComplete, clientStopped, httpStatus, contentLength, contentEncoding,
            connection, networkChanged.get(), "responseBodyBytesRead",
        )
    }

    private suspend fun measureUpload(
        session: AndroidNetworkSession,
        network: android.net.Network,
        request: SpeedTestRequest,
        resolved: ResolvedTarget,
        deadline: Long,
    ): SpeedTransferResult {
        val started = SystemClock.elapsedRealtime()
        val phases = LinkedHashMap<String, Long>()
        phases["dnsMs"] = resolved.dnsMs
        val connection = try {
            connect(session, network, resolved, deadline, phases)
        } catch (failure: SpeedTestFailure) {
            return failureResult(
                resolved.target,
                failure,
                started,
                phases,
                "clientStreamAcceptedBytes",
            )
        }
        val networkChanged = AtomicBoolean(false)
        val durationExpired = AtomicBoolean(false)
        val meter = SpeedMeter(request.warmupBytes.toLong())
        val chunk = SpeedPayload.chunk(TRANSFER_CHUNK_BYTES)
        var completion = "inProgress"
        var contentComplete = false
        var clientStopped = false
        var httpStatus: Int? = null
        var responseBytesRead: Long? = null
        var writeFailed = false
        try {
            val output = connection.ssl.outputStream
            val requestStart = System.nanoTime()
            output.write(
                SpeedHttpWire.uploadRequest(
                    resolved.target,
                    portOf(resolved.target),
                    request.maxBytesPerDirection.toLong(),
                ),
            )
            phases["requestHeadersMs"] = (System.nanoTime() - requestStart) / 1_000_000L
            output.flush()
            connection.ssl.soTimeout = request.durationBudgetMs + 1_000
            val durationEnd = SystemClock.elapsedRealtime() + request.durationBudgetMs
            withTransferWatchdog(
                session = session,
                ssl = connection.ssl,
                durationEnd = durationEnd,
                networkChanged = networkChanged,
                durationExpired = durationExpired,
            ) {
                while (true) {
                    val remainingTotal = request.maxBytesPerDirection.toLong() - meter.payloadBytes
                    if (remainingTotal <= 0L) {
                        completion = "byteBudget"
                        break
                    }
                    val remainingWarmup = request.warmupBytes.toLong() - meter.warmupCompletedBytes
                    val toWrite = minOf(
                        chunk.size.toLong(),
                        remainingTotal,
                        if (remainingWarmup > 0L) remainingWarmup else Long.MAX_VALUE,
                    ).toInt()
                    if (remainingWarmup <= 0L) meter.beginMeasuredIo(System.nanoTime())
                    try {
                        output.write(chunk, 0, toWrite)
                        output.flush()
                    } catch (_: IOException) {
                        writeFailed = true
                        completion = when {
                            networkChanged.get() -> "networkChanged"
                            durationExpired.get() -> "timeBudget"
                            else -> "ioFailure"
                        }
                        clientStopped = true
                        break
                    }
                    val now = System.nanoTime()
                    if (remainingWarmup > 0L) {
                        meter.recordWarmup(toWrite)
                    } else {
                        meter.recordMeasured(toWrite, now)
                    }
                    session.publishPartial(
                        SpeedTestResult.build(
                            request, null,
                            transferResult(
                                resolved, ObservationStatus.PARTIAL, started, phases, meter,
                                "inProgress", false, true, null, null, null,
                                connection, networkChanged.get(), "clientStreamAcceptedBytes",
                                requestContentLength = request.maxBytesPerDirection.toLong(),
                            ),
                            networkChanged.get(),
                            metered = session.snapshot.metered,
                            proxyHost = session.snapshot.httpProxyHost,
                            proxyPort = session.snapshot.httpProxyPort,
                        ),
                    )
                    if (SystemClock.elapsedRealtime() >= durationEnd) {
                        completion = "timeBudget"
                        clientStopped = true
                        break
                    }
                    if (meter.payloadBytes >= request.maxBytesPerDirection) {
                        completion = "byteBudget"
                        break
                    }
                }
            }
            if (!writeFailed && meter.payloadBytes >= request.maxBytesPerDirection) {
                try {
                    output.flush()
                    contentComplete = true
                } catch (_: IOException) {
                    completion = when {
                        networkChanged.get() -> "networkChanged"
                        durationExpired.get() -> "timeBudget"
                        else -> "ioFailure"
                    }
                    clientStopped = true
                    writeFailed = true
                }
                if (!writeFailed) {
                val headerStart = System.nanoTime()
                try {
                    val head = SpeedHttpWire.readHead(connection.ssl.inputStream)
                    phases["responseHeadersMs"] = (System.nanoTime() - headerStart) / 1_000_000L
                    httpStatus = head.statusCode
                    responseBytesRead = 0L
                    when {
                        head.statusCode in 300..399 -> completion = "redirectNotFollowed"
                        head.statusCode !in 200..299 -> completion = "httpStatusError"
                        else -> completion = "byteBudget"
                    }
                } catch (_: IOException) {
                    completion = when {
                        networkChanged.get() -> "networkChanged"
                        durationExpired.get() -> "timeBudget"
                        else -> "ioFailure"
                    }
                    clientStopped = true
                }
                }
            }
        } catch (_: IOException) {
            if (completion == "inProgress") {
                completion = when {
                    networkChanged.get() -> "networkChanged"
                    durationExpired.get() -> "timeBudget"
                    else -> "ioFailure"
                }
                clientStopped = true
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            meter.finish(System.nanoTime())
            runCatching { connection.ssl.close() }
        }
        val status = when {
            completion == "redirectNotFollowed" -> ObservationStatus.UNSUPPORTED
            completion == "networkChanged" -> ObservationStatus.PARTIAL
            completion == "httpStatusError" -> ObservationStatus.ERROR
            completion == "timeBudget" && meter.measuredBytes == 0L -> ObservationStatus.TIMEOUT
            meter.measuredBytes == 0L -> ObservationStatus.ERROR
            completion == "byteBudget" -> ObservationStatus.OK
            else -> ObservationStatus.PARTIAL
        }
        return transferResult(
            resolved, status, started, phases, meter,
            completion, contentComplete, clientStopped, httpStatus, null, null,
            connection, networkChanged.get(), "clientStreamAcceptedBytes",
            requestContentLength = request.maxBytesPerDirection.toLong(),
            responseBytesRead = responseBytesRead,
        )
    }

    private suspend fun connect(
        session: AndroidNetworkSession,
        network: android.net.Network,
        resolved: ResolvedTarget,
        deadline: Long,
        phases: MutableMap<String, Long>,
    ): TlsConnection {
        val target = resolved.target
        val port = portOf(target)
        var lastFailure: Exception? = null
        for (address in resolved.addresses) {
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0L) {
                throw SpeedTestFailure(ObservationStatus.TIMEOUT, "connectTimeout", "The speed test deadline ended before connect.")
            }
            if (session.hasCapturedNetworkChanged()) throw NetworkChangedException(session.currentNetworkHandle())
            val plain = Socket()
            session.trackCloseable(plain)
            var ssl: SSLSocket? = null
            try {
                network.bindSocket(plain)
                val tcpStart = System.nanoTime()
                plain.connect(InetSocketAddress(address, port), remaining.toInt().coerceAtLeast(1))
                phases["tcpConnectMs"] = (System.nanoTime() - tcpStart) / 1_000_000L
                plain.soTimeout = remaining.toInt().coerceAtLeast(1)
                val factory = SSLSocketFactory.getDefault() as SSLSocketFactory
                val tlsSocket = factory.createSocket(plain, target.host, port, true) as SSLSocket
                ssl = tlsSocket
                session.trackCloseable(tlsSocket)
                val tlsStart = System.nanoTime()
                val parameters = tlsSocket.sslParameters
                parameters.endpointIdentificationAlgorithm = "HTTPS"
                if (NetworkTargetPolicy.literalAddressClass(target.host) == null) {
                    runCatching { SNIHostName(target.host) }.getOrNull()?.let { sni ->
                        val names = ArrayList<SNIServerName>()
                        names.add(sni)
                        parameters.serverNames = names
                    }
                }
                tlsSocket.sslParameters = parameters
                tlsSocket.startHandshake()
                phases["tlsHandshakeMs"] = (System.nanoTime() - tlsStart) / 1_000_000L
                val sessionInfo = tlsSocket.session
                if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(target.host, sessionInfo)) {
                    throw SSLPeerUnverifiedException("platform default hostname verification failed")
                }
                return TlsConnection(
                    ssl = tlsSocket,
                    tcpConnectMs = phases["tcpConnectMs"] ?: 0L,
                    tlsHandshakeMs = phases["tlsHandshakeMs"] ?: 0L,
                    tlsProtocol = sessionInfo.protocol,
                    cipherSuite = sessionInfo.cipherSuite,
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: SpeedTestFailure) {
                throw failure
            } catch (failure: Exception) {
                if (session.hasCapturedNetworkChanged()) {
                    throw NetworkChangedException(session.currentNetworkHandle())
                }
                lastFailure = failure
                runCatching { ssl?.close() ?: plain.close() }
            }
        }
        throw mapConnectFailure(lastFailure)
    }

    private suspend fun <T> withTransferWatchdog(
        session: AndroidNetworkSession,
        ssl: SSLSocket,
        durationEnd: Long,
        networkChanged: AtomicBoolean,
        durationExpired: AtomicBoolean,
        block: suspend () -> T,
    ): T = coroutineScope {
        val watcher = launch {
            while (isActive) {
                delay(WATCHDOG_POLL_MS)
                if (session.hasCapturedNetworkChanged()) {
                    networkChanged.set(true)
                    runCatching { ssl.close() }
                    break
                }
                if (SystemClock.elapsedRealtime() >= durationEnd) {
                    durationExpired.set(true)
                    runCatching { ssl.close() }
                    break
                }
            }
        }
        try {
            block()
        } finally {
            withContext(NonCancellable) { watcher.cancelAndJoin() }
        }
    }

    private fun transferResult(
        resolved: ResolvedTarget,
        status: ObservationStatus,
        started: Long,
        phases: Map<String, Long>,
        meter: SpeedMeter,
        completionReason: String,
        contentComplete: Boolean,
        clientStopped: Boolean,
        httpStatus: Int?,
        contentLength: Long?,
        contentEncoding: String?,
        connection: TlsConnection,
        networkChanged: Boolean,
        payloadMeaning: String,
        requestContentLength: Long? = null,
        responseBytesRead: Long? = null,
    ): SpeedTransferResult {
        val elapsed = meter.measurementElapsedMs()
        val rate = SpeedMath.rate(meter.measuredBytes, elapsed)
        val phaseSnapshot = LinkedHashMap(phases)
        elapsed?.let { phaseSnapshot["measurementMs"] = it }
        return SpeedTransferResult(
            endpoint = resolved.target.redacted,
            status = status,
            payloadBytes = meter.payloadBytes,
            measuredBytes = meter.measuredBytes,
            warmupBytes = meter.warmupCompletedBytes,
            measurementElapsedMs = elapsed,
            totalElapsedMs = SystemClock.elapsedRealtime() - started,
            completionReason = completionReason,
            contentComplete = contentComplete,
            clientStopped = clientStopped,
            httpStatus = httpStatus,
            contentLength = contentLength,
            contentEncoding = contentEncoding,
            requestContentLength = requestContentLength,
            responseBytesRead = responseBytesRead,
            networkChanged = networkChanged,
            tlsProtocol = connection.tlsProtocol,
            cipherSuite = connection.cipherSuite,
            phases = phaseSnapshot,
            payloadBytesMeaning = payloadMeaning,
            rate = rate,
        )
    }

    private fun failureResult(
        target: HttpTarget,
        failure: SpeedTestFailure,
        started: Long,
        phases: Map<String, Long>,
        payloadMeaning: String,
    ): SpeedTransferResult = SpeedTransferResult(
        endpoint = target.redacted,
        status = failure.status,
        payloadBytes = 0L,
        measuredBytes = 0L,
        warmupBytes = 0L,
        measurementElapsedMs = null,
        totalElapsedMs = SystemClock.elapsedRealtime() - started,
        completionReason = failure.code,
        contentComplete = false,
        clientStopped = false,
        payloadBytesMeaning = payloadMeaning,
        phases = phases,
        rate = SpeedRate(null, null, false, "noMeasuredBytes"),
    )

    private fun mapConnectFailure(failure: Exception?): SpeedTestFailure = when (failure) {
        null -> SpeedTestFailure(ObservationStatus.ERROR, "connectFailure")
        is SocketTimeoutException -> SpeedTestFailure(
            ObservationStatus.TIMEOUT,
            "connectTimeout",
            "The TLS connection timed out.",
        )
        is SSLPeerUnverifiedException -> SpeedTestFailure(
            ObservationStatus.ERROR,
            "tlsHostnameVerificationFailed",
            failure.javaClass.simpleName.take(64),
        )
        is SSLException -> SpeedTestFailure(
            ObservationStatus.ERROR,
            "tlsFailure",
            failure.javaClass.simpleName.take(64),
        )
        is SecurityException -> SpeedTestFailure(
            ObservationStatus.PERMISSION_REQUIRED,
            "securityException",
            failure.javaClass.simpleName.take(64),
        )
        else -> SpeedTestFailure(
            ObservationStatus.ERROR,
            "connectFailure",
            failure.javaClass.simpleName.take(64),
        )
    }

    private fun portOf(target: HttpTarget): Int = if (target.port > 0) target.port else 443
}
