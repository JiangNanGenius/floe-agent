// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/**
 * One bounded private IPv4 subnet plan. Address expansion is pure: the
 * platform layer only excludes the device's own captured addresses and then
 * performs bounded TCP connects on the captured Network.
 */
internal data class LanSubnetPlan(
    val cidr: String,
    val networkAddress: String,
    val prefix: Int,
    val addresses: List<String>,
)

/**
 * Frozen network.lanDiscover arguments. serviceTypes is explicit (no hidden
 * default sweep); subnet scan is optional and only reaches RFC1918 addresses
 * in a /24../30 with a bounded host x port attempt count.
 */
internal data class LanDiscoveryRequest(
    val serviceTypes: List<String> = emptyList(),
    val discoveryDurationMs: Int = NetworkLimits.DEFAULT_LAN_DISCOVERY_MS,
    val includeAttributes: Boolean = false,
    val subnet: LanSubnetPlan? = null,
    val ports: List<Int> = emptyList(),
    val tcpConnectTimeoutMs: Int = NetworkLimits.DEFAULT_TCP_CONNECT_TIMEOUT_MS,
    val tcpConcurrency: Int = NetworkLimits.DEFAULT_TCP_CONCURRENCY,
    val timeoutMs: Int = NetworkLimits.DEFAULT_LAN_TIMEOUT_MS,
) {
    val hasMdns: Boolean get() = serviceTypes.isNotEmpty()
    val hasTcp: Boolean get() = subnet != null
}

internal data class LanServiceRecord(
    val serviceName: String,
    val serviceType: String,
    val subtypes: List<String> = emptyList(),
    val hostname: String? = null,
    val addresses: List<String> = emptyList(),
    val port: Int? = null,
    val networkHandle: String? = null,
    val networkMatchesCaptured: Boolean? = null,
    val state: String = "active",
    val resolution: String = "unresolved",
    val resolveErrorCode: Int? = null,
    val resolveError: String? = null,
    val attributes: Map<String, String>? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("serviceName", serviceName.take(128))
        put("serviceType", serviceType.take(64))
        put("subtypes", jsonArray(subtypes.take(8)))
        put("addresses", jsonArray(addresses.take(16)))
        put("state", state)
        put("resolution", resolution)
        hostname?.let { put("hostname", it.take(253)) }
        port?.let { put("port", it) }
        networkHandle?.let { put("networkHandle", it.take(32)) }
        networkMatchesCaptured?.let { put("networkMatchesCaptured", it) }
        resolveErrorCode?.let { put("resolveErrorCode", it) }
        resolveError?.let { put("resolveError", it.take(64)) }
        attributes?.let { values ->
            put(
                "attributes",
                JSONObject().apply {
                    values.entries.take(NetworkLimits.MAX_LAN_ATTRIBUTES).forEach { (key, value) ->
                        put(key.take(NetworkLimits.MAX_LAN_ATTRIBUTE_KEY_CHARS), value)
                    }
                },
            )
        }
    }
}

internal data class LanTypeRecord(
    val serviceType: String,
    val state: String,
    val errorCode: Int? = null,
    val error: String? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("serviceType", serviceType.take(64))
        put("state", state)
        errorCode?.let { put("errorCode", it) }
        error?.let { put("error", it.take(64)) }
    }
}

internal data class LanMdnsSummary(
    val requestedServiceTypes: List<String>,
    val scope: String,
    val networkScoped: Boolean,
    val discoveryDurationMs: Int,
    val elapsedMs: Long,
    val services: List<LanServiceRecord>,
    val perType: List<LanTypeRecord>,
    val filteredForeignNetwork: Int,
    val truncated: Boolean,
    val noReplies: Boolean,
    val multicastLockHeld: Boolean?,
    val stoppedReason: String,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("requestedServiceTypes", jsonArray(requestedServiceTypes))
        put("scope", scope)
        put("networkScoped", networkScoped)
        put("discoveryDurationMs", discoveryDurationMs)
        put("elapsedMs", elapsedMs)
        put("services", JSONArray().apply { services.forEach { put(it.toJson()) } })
        put("serviceCount", services.size)
        put("activeServiceCount", services.count { it.state == "active" })
        put("unresolvedCount", services.count { it.resolution != "resolved" })
        put("lostCount", services.count { it.state == "lost" })
        put("filteredForeignNetwork", filteredForeignNetwork)
        put("truncated", truncated)
        put("noReplies", noReplies)
        multicastLockHeld?.let { put("multicastLockHeld", it) }
        put("perType", JSONArray().apply { perType.forEach { put(it.toJson()) } })
        put("stoppedReason", stoppedReason)
    }
}

internal data class LanTcpOpenPort(
    val address: String,
    val port: Int,
    val connectTimeMs: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("address", address.take(45))
        put("port", port)
        put("connectTimeMs", connectTimeMs)
    }
}

internal data class LanTcpScanSummary(
    val subnetCidr: String,
    val ports: List<Int>,
    val hostCount: Int,
    val excludedSelfAddresses: List<String>,
    val attemptedHosts: Int,
    val plannedAttempts: Int,
    val completedAttempts: Int,
    val openPorts: List<LanTcpOpenPort>,
    val refusedAttempts: Int,
    val timedOutAttempts: Int,
    val errorAttempts: Int,
    val unreachableAttempts: Int,
    val hostsWithResponse: Int,
    val hostsWithOpenPort: Int,
    val truncated: Boolean,
    val stoppedReason: String,
    val cancelled: Boolean,
    val elapsedMs: Long,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("subnetCidr", subnetCidr)
        put("ports", JSONArray().apply { ports.forEach { put(it) } })
        put("hostCount", hostCount)
        put("excludedSelfAddresses", jsonArray(excludedSelfAddresses))
        put("attemptedHosts", attemptedHosts)
        put("plannedAttempts", plannedAttempts)
        put("completedAttempts", completedAttempts)
        put("openPorts", JSONArray().apply { openPorts.forEach { put(it.toJson()) } })
        put("openPortCount", openPorts.size)
        put("refusedAttempts", refusedAttempts)
        put("timedOutAttempts", timedOutAttempts)
        put("errorAttempts", errorAttempts)
        put("unreachableAttempts", unreachableAttempts)
        put("hostsWithResponse", hostsWithResponse)
        put("hostsWithOpenPort", hostsWithOpenPort)
        put("truncated", truncated)
        put("stoppedReason", stoppedReason)
        put("cancelled", cancelled)
        put("elapsedMs", elapsedMs)
    }
}

internal class LanFailure(
    val status: ObservationStatus,
    val code: String,
    message: String? = null,
    val missingPermissions: List<String> = emptyList(),
) : Exception(message ?: code)

/**
 * Pure G07.2 LAN result assembly. Only observed service fields and actual TCP
 * connect outcomes reach the inventory; no guessed host, no content-derived
 * success and no silent continuation after a Network change.
 */
internal object LanDiscoveryResult {
    private val SERVICE_TYPE = Regex("^_[a-z0-9](?:[a-z0-9-]{0,13}[a-z0-9])?\\._(tcp|udp)$")

    fun normalizeServiceType(raw: String): String {
        val value = raw.trim().lowercase(Locale.ROOT)
        if (value.length > 32 || !SERVICE_TYPE.matches(value)) {
            throw RequestParseException(
                "invalidArguments",
                "serviceTypes must be explicit DNS-SD types such as _http._tcp or _ipp._tcp",
            )
        }
        return value
    }

    fun parsePrivateSubnet(raw: String): LanSubnetPlan {
        val value = raw.trim()
        val parts = value.split('/')
        if (parts.size != 2) {
            throw RequestParseException("invalidArguments", "subnetCidr must be an IPv4 CIDR")
        }
        val prefix = parts[1].toIntOrNull()
            ?: throw RequestParseException("invalidArguments", "subnetCidr prefix is invalid")
        if (prefix !in 24..30) {
            throw RequestParseException("invalidArguments", "subnetCidr prefix must be between /24 and /30")
        }
        val base = parseIpv4(parts[0])
            ?: throw RequestParseException("invalidArguments", "subnetCidr is not an IPv4 address")
        val mask = (0xFFFF_FFFFL shl (32 - prefix)) and 0xFFFF_FFFFL
        val network = base and mask
        val broadcast = network or (mask.inv() and 0xFFFF_FFFFL)
        if (network != base) {
            throw RequestParseException("invalidArguments", "subnetCidr host bits must be zero")
        }
        val networkText = formatIpv4(network)
        if (NetworkTargetPolicy.classifyLiteral(networkText) != AddressClass.PRIVATE) {
            throw RequestParseException(
                "invalidArguments",
                "subnetCidr must be an RFC1918 private IPv4 subnet",
            )
        }
        val addresses = ArrayList<String>()
        var cursor = network + 1
        while (cursor < broadcast) {
            addresses += formatIpv4(cursor)
            cursor++
        }
        if (addresses.size > NetworkLimits.MAX_TCP_HOSTS) {
            throw RequestParseException("invalidArguments", "subnetCidr expands beyond 254 hosts")
        }
        return LanSubnetPlan(
            cidr = "$networkText/$prefix",
            networkAddress = networkText,
            prefix = prefix,
            addresses = addresses,
        )
    }

    fun checkAttemptBudget(subnet: LanSubnetPlan, ports: List<Int>) {
        if (ports.isEmpty()) {
            throw RequestParseException("invalidArguments", "ports are required with subnetCidr")
        }
        if (ports.size > NetworkLimits.MAX_TCP_PORTS) {
            throw RequestParseException("invalidArguments", "ports must contain at most 8 entries")
        }
        if (ports.distinct().size != ports.size) {
            throw RequestParseException("invalidArguments", "ports must be unique")
        }
        val attempts = subnet.addresses.size.toLong() * ports.size.toLong()
        if (attempts > NetworkLimits.MAX_TCP_ATTEMPTS) {
            throw RequestParseException(
                "invalidArguments",
                "subnetCidr x ports exceeds the 1024 TCP attempt budget",
            )
        }
    }

    fun excludeSelf(
        subnet: LanSubnetPlan,
        linkAddresses: List<String>,
    ): Pair<List<String>, List<String>> {
        val self = linkAddresses
            .asSequence()
            .map { it.substringBefore('/').trim() }
            .filter { parseIpv4(it) != null }
            .toSet()
        val excluded = subnet.addresses.filter { it in self }
        val remaining = subnet.addresses.filterNot { it in self }
        return remaining to excluded
    }

    fun build(
        request: LanDiscoveryRequest,
        mdns: LanMdnsSummary?,
        tcp: LanTcpScanSummary?,
        networkChanged: Boolean,
        failure: LanFailure? = null,
    ): ProbeResult {
        val observations = JSONObject().apply {
            mdns?.let { put("mdns", it.toJson()) }
            tcp?.let { put("tcp", it.toJson()) }
            put("networkChanged", networkChanged)
            put("noReplies", mdns?.noReplies ?: false)
        }
        val target = request.subnet?.let { "lan:${it.cidr}" } ?: "lan:mdns"
        val limitations = ArrayList<String>()
        limitations += "LAN discovery is a point-in-time observation on the captured network; a device that is asleep, silent or unadvertised is not evidence that it is absent."
        limitations += "Service addresses and ports are reported only from actual DNS-SD resolution; unresolved services keep no address/port."
        limitations += "TCP open ports come only from successful connect handshakes; no payload, banner or protocol is read."
        mdns?.let { summary ->
            if (summary.scope == "unsupportedLegacyApi") {
                limitations += "This API has no Network-scoped NsdManager discovery; mDNS is typed unsupported rather than browsing an unproven system-default route. The bounded TCP subnet scan remains available."
            } else if (summary.scope == "nsdUnavailable") {
                limitations += "NsdManager is unavailable on this device; mDNS is typed unsupported while bounded TCP subnet discovery remains available."
            }
            if (summary.noReplies) {
                limitations += "Discovery completed with zero services for every requested service type (no replies observed)."
            }
            if (summary.truncated) limitations += "Discovery reached the bounded service list or time limit."
            if (summary.filteredForeignNetwork > 0) {
                limitations += "Services observed on a different Network were excluded from the inventory."
            }
        }
        tcp?.let { summary ->
            if (summary.truncated) limitations += "The TCP result reached the bounded open-port list."
            if (summary.stoppedReason == "timeBudget") {
                limitations += "The TCP phase ended at its time budget before every planned attempt completed."
            }
            if (summary.cancelled) limitations += "The TCP phase was cancelled; completed attempts are retained."
        }
        if (networkChanged) {
            limitations += "The captured Network changed while LAN discovery was running; the operation stopped and retained only completed observations."
        }
        if (failure != null) {
            observations.put("errorCode", failure.code)
            failure.message?.takeIf { it.isNotBlank() }?.let { observations.put("message", it.take(300)) }
        }

        val status: ObservationStatus
        val missing: List<String>
        if (failure != null) {
            status = failure.status
            missing = failure.missingPermissions
        } else if (networkChanged) {
            status = ObservationStatus.ERROR
            missing = emptyList()
            observations.put("errorCode", "networkChanged")
        } else if (mdns == null && tcp == null) {
            status = ObservationStatus.ERROR
            missing = emptyList()
            observations.put("errorCode", "noDiscoveryRequested")
        } else {
            val tcpHasWork = tcp != null && (tcp.completedAttempts > 0 || tcp.plannedAttempts == 0)
            val failedTypes = mdns?.perType?.takeIf { types ->
                types.isNotEmpty() && types.all { it.state == "startFailed" }
            }
            if (failedTypes != null && !tcpHasWork) {
                val denied = failedTypes.any { it.errorCode == 7 }
                status = if (denied) ObservationStatus.PERMISSION_REQUIRED else ObservationStatus.UNSUPPORTED
                missing = if (denied) {
                    listOf("android.permission.ACCESS_LOCAL_NETWORK")
                } else {
                    emptyList()
                }
                observations.put(
                    "errorCode",
                    when {
                        denied -> "nsdPermissionDenied"
                        else -> failedTypes.firstNotNullOfOrNull { it.error } ?: "nsdStartFailed"
                    },
                )
            } else if (tcp != null && tcp.cancelled) {
                status = ObservationStatus.CANCELLED
                missing = emptyList()
            } else {
                val mdnsPartial = mdns != null && (
                    mdns.truncated ||
                        mdns.perType.any {
                            it.state == "startFailed" ||
                                it.state == "stopFailed" ||
                                it.state == "startPending"
                        }
                    )
                val tcpPartial = tcp != null && (
                    tcp.truncated ||
                        tcp.stoppedReason == "timeBudget" ||
                        tcp.stoppedReason == "attemptLimit"
                    )
                val anyCompleted = (mdns != null && mdns.perType.any {
                    it.state == "started" || it.state == "stopped"
                }) || tcpHasWork
                val tcpOnlyTimeout = mdns == null && tcp != null &&
                    tcp.completedAttempts == 0 && tcp.stoppedReason == "timeBudget"
                status = when {
                    tcpOnlyTimeout -> ObservationStatus.TIMEOUT
                    (mdnsPartial || tcpPartial) && anyCompleted -> ObservationStatus.PARTIAL
                    (mdnsPartial || tcpPartial) -> ObservationStatus.ERROR
                    else -> ObservationStatus.OK
                }
                missing = emptyList()
                if (failedTypes != null && tcpHasWork) {
                    observations.put(
                        "mdnsErrorCode",
                        if (mdns?.perType?.any { it.errorCode == 7 } == true) {
                            "nsdPermissionDenied"
                        } else {
                            mdns?.perType?.firstNotNullOfOrNull { it.error } ?: "nsdStartFailed"
                        },
                    )
                }
            }
        }

        return ProbeResult(
            status = status,
            observations = observations,
            limitations = limitations,
            target = target,
            missingPermissions = missing,
        )
    }

    private fun parseIpv4(raw: String): Long? {
        val parts = raw.trim().split('.')
        if (parts.size != 4) return null
        var value = 0L
        parts.forEach { part ->
            if (part.isEmpty() || part.length > 3 || part.any { it !in '0'..'9' }) return null
            val number = part.toIntOrNull() ?: return null
            if (number !in 0..255) return null
            if (part.length > 1 && part.startsWith('0')) return null
            value = (value shl 8) or number.toLong()
        }
        return value
    }

    private fun formatIpv4(value: Long): String =
        "${(value ushr 24) and 0xFF}.${(value ushr 16) and 0xFF}.${(value ushr 8) and 0xFF}.${value and 0xFF}"

    fun serviceTypeName(raw: String): String = raw.trim().lowercase(Locale.ROOT)
}
