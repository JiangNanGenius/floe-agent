// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.Closeable

/**
 * Per-execute platform session. It captures the active Android Network once
 * and uses that exact handle for every measurement in the call; close()
 * aborts owned sockets/connections/signals. Tests replace this seam without
 * touching Android framework classes.
 */
internal interface NetworkSession : Closeable {
    val snapshot: NetworkSnapshot
    val missingPermissions: List<String>

    suspend fun status(): ProbeResult
    suspend fun wifiScan(refresh: Boolean): ProbeResult
    suspend fun dnsLookup(host: String, recordType: DnsRecordType, timeoutMs: Int): ProbeResult
    suspend fun ping(host: String, count: Int, timeoutMs: Int): ProbeResult
    suspend fun tcpProbe(host: String, port: Int, timeoutMs: Int): ProbeResult
    suspend fun http(target: HttpTarget, timeoutMs: Int, maxRedirects: Int): ProbeResult
    suspend fun lanDiscover(request: LanDiscoveryRequest): ProbeResult
    suspend fun speedTest(request: SpeedTestRequest): ProbeResult

    /**
     * Last bounded observation published by an operation that supports
     * partial results. The service merges it into timeout/cancelled envelopes
     * so a stopped speed transfer retains actual bytes instead of being
     * replaced by a generic empty result. Default null preserves the G07.1
     * behavior for every existing method.
     */
    fun partialResult(): ProbeResult? = null
}

internal interface NetworkPlatform {
    fun openSession(request: ParsedRequest): NetworkSession
}

/** The captured Network handle changed or disappeared while an operation ran. */
internal class NetworkChangedException(
    val currentHandle: Long?,
    message: String = "the captured Android Network changed",
) : Exception(message)
