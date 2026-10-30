// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import android.net.DnsResolver
import android.net.Network
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import org.json.JSONObject

/**
 * DNS diagnostics on the captured Android Network. API 29+ uses
 * DnsResolver.rawQuery with no local cache lookup/store; API 28 uses the
 * public Network.getAllByName platform resolver. There is no public resolver
 * or default-network fallback.
 */
internal object AndroidDnsLookup {
    private val random = java.security.SecureRandom()

    suspend fun lookup(
        session: AndroidNetworkSession,
        host: String,
        recordType: DnsRecordType,
        timeoutMs: Int,
    ): ProbeResult {
        if (NetworkTargetPolicy.literalAddressClass(host) != null) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("unsupportedReason", "targetIsAddress"),
                limitations = listOf("dnsLookup expects a host name; use ping or tcpProbe for an address literal."),
            )
        }
        try {
            NetworkTargetPolicy.checkHostPolicy(host)
        } catch (failure: TargetPolicyException) {
            return ProbeResult(
                status = ObservationStatus.UNSUPPORTED,
                observations = JSONObject().put("errorCode", failure.code),
                limitations = listOf(failure.message ?: "The DNS target is not permitted."),
            )
        }
        val network = session.activeNetwork ?: return ProbeResult(
            status = ObservationStatus.UNAVAILABLE,
            observations = JSONObject().put("errorCode", "noActiveNetwork"),
            limitations = session.snapshot.limitations + "No active network is available for DNS.",
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            lookupWithDnsResolver(session, network, host, recordType, timeoutMs)
        } else {
            lookupWithPlatformAddresses(session, network, host, recordType, timeoutMs)
        }
    }

    private suspend fun lookupWithDnsResolver(
        session: AndroidNetworkSession,
        network: Network,
        host: String,
        recordType: DnsRecordType,
        timeoutMs: Int,
    ): ProbeResult {
        val types = when (recordType) {
            DnsRecordType.A -> listOf(DnsWire.TYPE_A)
            DnsRecordType.AAAA -> listOf(DnsWire.TYPE_AAAA)
            DnsRecordType.A_AND_AAAA -> listOf(DnsWire.TYPE_A, DnsWire.TYPE_AAAA)
        }
        val started = SystemClock.elapsedRealtime()
        val attempts = ArrayList<QueryAttempt>()
        types.forEach { type ->
            attempts += try {
                QueryAttempt(type, queryRaw(session, network, host, type), null)
            } catch (cancelled: java.util.concurrent.CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                QueryAttempt(type, null, failure)
            }
        }
        val elapsedMs = SystemClock.elapsedRealtime() - started
        val records = attempts.flatMap { it.response?.records.orEmpty() }
        val addresses = records.mapNotNull { it.address }.distinct()
        val responseRcodes = attempts.mapNotNull { it.response?.rcode }
        val firstRcode = responseRcodes.firstOrNull { it != 0 }
            ?: responseRcodes.firstOrNull()
            ?: -1
        val failures = attempts.filter { it.error != null }
        val status = when {
            failures.size == attempts.size -> statusForFailure(failures.first().error)
            failures.isNotEmpty() -> ObservationStatus.PARTIAL
            firstRcode != 0 && firstRcode != 3 -> ObservationStatus.PARTIAL
            else -> ObservationStatus.OK
        }
        val observations = JSONObject().apply {
            put("recordType", recordType.wire)
            put("queryTypes", JSONArray().apply {
                types.forEach { put(DnsWire.typeName(it)) }
            })
            put("resolver", "DnsResolver.rawQuery")
            put("rcode", firstRcode)
            if (firstRcode >= 0) {
                put("rcodeName", DnsWire.rcodeName(firstRcode))
            } else {
                put("rcodeName", "UNKNOWN")
            }
            put("truncated", attempts.any { it.response?.truncated == true })
            put("elapsedMs", elapsedMs)
            put("timeoutMs", timeoutMs)
            put("ttlSupported", true)
            put("answers", answersJson(records))
            put("addresses", JSONArray().apply { addresses.forEach { put(it) } })
            if (failures.isNotEmpty()) {
                put("queryFailures", JSONArray().apply {
                    failures.forEach { attempt ->
                        put(
                            JSONObject()
                                .put("type", DnsWire.typeName(attempt.type))
                                .put("errorCode", failureCode(attempt.error))
                                .put("errorClass", attempt.error?.javaClass?.simpleName ?: "unknown"),
                        )
                    }
                })
            }
        }
        val limitations = ArrayList<String>()
        limitations += "DnsResolver may answer from or populate the system resolver cache; local cache age is not exposed."
        limitations += "Reported TTL values may already be reduced by resolver caching."
        if (attempts.any { it.response?.truncated == true }) {
            limitations += "The DNS response was truncated; TCP fallback is owned by the platform resolver."
        }
        if (failures.isNotEmpty()) {
            limitations += "One or more DNS query types failed; successful answer records are still reported."
        }
        if (addresses.isEmpty() && failures.isEmpty()) {
            limitations += "No A/AAAA addresses were present in the DNS answer."
        }
        return ProbeResult(
            status = status,
            observations = observations,
            limitations = limitations,
            target = host,
        )
    }

    private fun lookupWithPlatformAddresses(
        session: AndroidNetworkSession,
        network: Network,
        host: String,
        recordType: DnsRecordType,
        timeoutMs: Int,
    ): ProbeResult {
        val started = SystemClock.elapsedRealtime()
        val future = try {
            session.api28Resolver.submit(Callable { network.getAllByName(host).toList() })
        } catch (_: RejectedExecutionException) {
            return ProbeResult(
                status = ObservationStatus.CANCELLED,
                observations = JSONObject()
                    .put("recordType", recordType.wire)
                    .put("resolver", "Network.getAllByName")
                    .put("cancelled", true),
                limitations = session.snapshot.limitations + "The API 28 resolver worker is closed.",
                target = host,
            )
        }
        val all = try {
            future.get(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
        } catch (timeout: TimeoutException) {
            future.cancel(true)
            return ProbeResult(
                status = ObservationStatus.TIMEOUT,
                observations = JSONObject()
                    .put("recordType", recordType.wire)
                    .put("resolver", "Network.getAllByName")
                    .put("timeoutMs", timeoutMs)
                    .put("ttlSupported", false),
                limitations = session.snapshot.limitations +
                    "The API 28 platform resolver did not return within the bounded timeout; its daemon worker may finish in the background.",
                target = host,
            )
        } catch (interrupted: InterruptedException) {
            future.cancel(true)
            // Clear the pool thread's interrupt status; this coroutine owns the cancellation.
            Thread.interrupted()
            return ProbeResult(
                status = if (session.isSessionClosed()) {
                    ObservationStatus.CANCELLED
                } else {
                    ObservationStatus.ERROR
                },
                observations = JSONObject()
                    .put("recordType", recordType.wire)
                    .put("resolver", "Network.getAllByName")
                    .put("errorCode", "resolverInterrupted")
                    .put("ttlSupported", false),
                limitations = session.snapshot.limitations + "The API 28 resolver call was interrupted.",
                target = host,
            )
        } catch (cancelled: java.util.concurrent.CancellationException) {
            throw cancelled
        } catch (execution: ExecutionException) {
            val cause = execution.cause
            if (cause is UnknownHostException) {
                return ProbeResult(
                    status = ObservationStatus.UNAVAILABLE,
                    observations = JSONObject()
                        .put("recordType", recordType.wire)
                        .put("resolver", "Network.getAllByName")
                        .put("errorCode", "dnsFailure")
                        .put("ttlSupported", false),
                    limitations = session.snapshot.limitations +
                        "The API 28 platform resolver returned no address; TTL and record-type detail are unavailable.",
                    target = host,
                )
            }
            return ProbeResult(
                status = ObservationStatus.ERROR,
                observations = JSONObject()
                    .put("recordType", recordType.wire)
                    .put("resolver", "Network.getAllByName")
                    .put("errorCode", "dnsFailure")
                    .put("errorClass", cause?.javaClass?.simpleName?.take(64) ?: "unknown")
                    .put("ttlSupported", false),
                limitations = session.snapshot.limitations +
                    "The API 28 platform resolver call failed; no public resolver fallback is used.",
                target = host,
            )
        }
        val selected = when (recordType) {
            DnsRecordType.A -> all.filterIsInstance<Inet4Address>()
            DnsRecordType.AAAA -> all.filterIsInstance<Inet6Address>()
            DnsRecordType.A_AND_AAAA -> all
        }
        val elapsedMs = SystemClock.elapsedRealtime() - started
        val observations = JSONObject().apply {
            put("recordType", recordType.wire)
            put("queryTypes", JSONArray().apply {
                when (recordType) {
                    DnsRecordType.A -> put("A")
                    DnsRecordType.AAAA -> put("AAAA")
                    DnsRecordType.A_AND_AAAA -> { put("A"); put("AAAA") }
                }
            })
            put("resolver", "Network.getAllByName")
            put("rcode", 0)
            put("rcodeName", "NOERROR")
            put("truncated", false)
            put("elapsedMs", elapsedMs)
            put("ttlSupported", false)
            put("answers", addressesJson(selected))
            put("addresses", JSONArray().apply { selected.forEach { put(it.hostAddress) } })
        }
        val limitations = ArrayList<String>()
        limitations += "API 28 Network.getAllByName exposes addresses only; TTL and record-type detail are unavailable."
        limitations += "The API 28 resolver call is bounded by a daemon worker; an interrupted lookup may finish in the background."
        if (selected.isEmpty()) limitations += "The platform resolver returned no address of the requested family."
        return ProbeResult(
            status = ObservationStatus.OK,
            observations = observations,
            limitations = limitations,
            target = host,
        )
    }

    @Suppress("DEPRECATION")
    private suspend fun queryRaw(
        session: AndroidNetworkSession,
        network: Network,
        host: String,
        type: Int,
    ): DnsWire.DnsResponse {
        val id = random.nextInt(65_536)
        val query = DnsWire.encodeQuery(host, type, id)
        return suspendCancellableCoroutine { continuation ->
            val signal = CancellationSignal()
            session.trackAction { runCatching { signal.cancel() } }
            val executor = Executor { command -> command.run() }
            val callback = object : DnsResolver.Callback<ByteArray> {
                override fun onAnswer(answer: ByteArray, rcode: Int) {
                    if (!continuation.isActive) return
                    try {
                        continuation.resume(DnsWire.parseResponse(answer, id))
                    } catch (failure: Throwable) {
                        continuation.resumeWithException(failure)
                    }
                }

                override fun onError(error: DnsResolver.DnsException) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(DnsResolverFailure(error.code))
                    }
                }
            }
            try {
                DnsResolver.getInstance().rawQuery(
                    network,
                    query,
                    DnsResolver.FLAG_NO_CACHE_LOOKUP or DnsResolver.FLAG_NO_CACHE_STORE,
                    executor,
                    signal,
                    callback,
                )
            } catch (failure: Throwable) {
                if (continuation.isActive) continuation.resumeWithException(failure)
            }
            continuation.invokeOnCancellation { runCatching { signal.cancel() } }
        }
    }

    private fun answersJson(records: List<DnsWire.DnsRecord>): JSONArray = JSONArray().apply {
        records.forEach { record ->
            put(
                JSONObject().apply {
                    put("name", record.name)
                    put("type", record.typeName)
                    record.ttlSeconds?.let { put("ttlSeconds", it) }
                    put("value", record.value)
                    record.address?.let { put("address", it) }
                },
            )
        }
    }

    private fun addressesJson(addresses: List<InetAddress>): JSONArray = JSONArray().apply {
        addresses.forEach { address ->
            put(
                JSONObject()
                    .put("type", if (address is Inet6Address) "AAAA" else "A")
                    .put("address", address.hostAddress),
            )
        }
    }

    private fun statusForFailure(failure: Throwable?): ObservationStatus = when (failure) {
        is DnsResolverFailure -> if (failure.code == DnsResolver.ERROR_SYSTEM) {
            ObservationStatus.UNAVAILABLE
        } else {
            ObservationStatus.ERROR
        }
        is UnknownHostException -> ObservationStatus.UNAVAILABLE
        else -> ObservationStatus.ERROR
    }

    private fun failureCode(failure: Throwable?): String = when (failure) {
        is DnsResolverFailure -> "resolverError${failure.code}"
        is UnknownHostException -> "dnsFailure"
        else -> failure?.javaClass?.simpleName ?: "unknown"
    }

    private data class QueryAttempt(
        val type: Int,
        val response: DnsWire.DnsResponse?,
        val error: Throwable?,
    )

    private class DnsResolverFailure(val code: Int) : Exception("DNS resolver error $code")
}
