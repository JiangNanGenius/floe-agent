// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.os.SystemClock
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import org.json.JSONArray
import org.json.JSONObject

/**
 * TCP connect diagnostics on the captured Android Network. Each socket is
 * explicitly bound to that Network before connect; no process-global bind is
 * used and a refused/timed-out connect is reported as a TCP observation, not
 * as ICMP or application health.
 */
internal object AndroidTcpProbe {
    suspend fun probe(
        session: AndroidNetworkSession,
        host: String,
        port: Int,
        timeoutMs: Int,
    ): ProbeResult {
        try {
            NetworkTargetPolicy.checkHostPolicy(host)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "The TCP target is not permitted."),
                target = "$host:$port",
            )
        }
        val network = session.activeNetwork ?: return ProbeResult(
            status = ObservationStatus.UNAVAILABLE,
            observations = JSONObject().put("errorCode", "noActiveNetwork").put("port", port),
            limitations = session.snapshot.limitations + "No active network is available for TCP.",
            target = "$host:$port",
        )
        val addresses = try {
            runInterruptible(Dispatchers.IO) { network.getAllByName(host).toList() }
        } catch (cancelled: java.util.concurrent.CancellationException) {
            throw cancelled
        } catch (_: UnknownHostException) {
            return ProbeResult(
                status = ObservationStatus.UNAVAILABLE,
                observations = JSONObject().put("errorCode", "dnsFailure").put("port", port),
                limitations = session.snapshot.limitations +
                    "The target name did not resolve on the captured network.",
                target = "$host:$port",
            )
        } catch (failure: Exception) {
            return ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject()
                    .put("errorCode", "dnsFailure")
                    .put("errorClass", failure.javaClass.simpleName.take(64))
                    .put("port", port),
                limitations = session.snapshot.limitations + "The target name could not be resolved.",
                target = "$host:$port",
            )
        }

        val literals = addresses.mapNotNull { it.hostAddress }
        val local = try {
            NetworkTargetPolicy.checkResolvedAddresses(host, literals)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = if (failure.code == "dnsFailure") {
                    ObservationStatus.UNAVAILABLE
                } else {
                    ObservationStatus.UNSUPPORTED
                },
                observations = JSONObject().put("errorCode", failure.code).put("port", port),
                limitations = listOf(failure.message ?: "A resolved address is not permitted."),
                target = "$host:$port",
            )
        }
        if (local && session.localNetworkPermissionMissing()) {
            return ProbeResult(
                status = ObservationStatus.PERMISSION_REQUIRED,
                observations = JSONObject().put("requiredFor", NetworkMethod.TCP_PROBE.wire).put("port", port),
                limitations = session.snapshot.limitations +
                    "A local-network diagnostic needs the shared ACCESS_LOCAL_NETWORK grant.",
                target = "$host:$port",
                missingPermissions = session.localNetworkMissingPermissions(),
            )
        }

        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        val attempts = JSONArray()
        var connected = false
        var connectTimeMs: Long? = null
        var localAddress: String? = null
        var localPort: Int? = null
        var remoteAddress: String? = null
        var sawTimeout = false
        var sawRefused = false
        var sawError = false

        for (address in addresses) {
            val remaining = deadline - SystemClock.elapsedRealtime()
            if (remaining <= 0L || connected) break
            val socket = Socket()
            session.trackCloseable(socket)
            val started = System.nanoTime()
            var result = "error"
            var errorClass: String? = null
            try {
                network.bindSocket(socket)
                socket.connect(InetSocketAddress(address, port), remaining.toInt().coerceAtLeast(1))
                connected = true
                connectTimeMs = (System.nanoTime() - started) / 1_000_000L
                localAddress = socket.localAddress?.hostAddress
                localPort = socket.localPort
                remoteAddress = socket.inetAddress?.hostAddress
                result = "connected"
            } catch (_: SocketTimeoutException) {
                result = "timeout"
                sawTimeout = true
            } catch (failure: ConnectException) {
                result = "refused"
                sawRefused = true
                errorClass = failure.javaClass.simpleName.take(64)
            } catch (failure: Exception) {
                result = "error"
                sawError = true
                errorClass = failure.javaClass.simpleName.take(64)
            } finally {
                runCatching { socket.close() }
            }
            attempts.put(
                JSONObject()
                    .put("address", address.hostAddress)
                    .put("family", if (address.address.size == 16) "IPv6" else "IPv4")
                    .put("result", result)
                    .put("elapsedMs", (System.nanoTime() - started) / 1_000_000L)
                    .apply { errorClass?.let { put("errorClass", it) } },
            )
        }

        val observations = JSONObject().apply {
            put("port", port)
            put("resolvedAddresses", JSONArray().apply { literals.forEach { put(it) } })
            put("attempts", attempts)
            put("connected", connected)
            put("timeoutBudgetMs", timeoutMs)
            put("refused", sawRefused && !connected)
            connectTimeMs?.let { put("connectTimeMs", it) }
            localAddress?.let { put("localAddress", it) }
            localPort?.let { put("localPort", it) }
            remoteAddress?.let { put("remoteAddress", it) }
        }
        val limitations = ArrayList<String>()
        limitations += "A TCP connect result proves only that the handshake completed or failed; it is not an application-protocol or TLS health check."
        limitations += "No payload is sent and no response is read."
        if (attempts.length() < addresses.size) {
            limitations += "The timeout budget ended before every resolved address was attempted."
        }
        if (connected && attempts.length() > 1) {
            limitations += "Earlier address attempts are retained; a later address succeeded."
        }
        val status = when {
            connected -> ObservationStatus.OK
            attempts.length() == 0 -> ObservationStatus.TIMEOUT
            sawTimeout -> ObservationStatus.TIMEOUT
            sawRefused && !sawError -> ObservationStatus.OK
            else -> ObservationStatus.ERROR
        }
        return ProbeResult(
            status = status,
            observations = observations,
            limitations = limitations,
            target = "$host:$port",
        )
    }
}
