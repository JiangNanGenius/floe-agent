// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import java.util.Locale

/**
 * Bounded DNS-SD presets shown by the LAN page. The presets are only choices;
 * nothing is discovered until the user starts a check, and only the selected
 * types are sent. The service enforces the same syntax/length bounds again.
 */
object LanServicePresets {
    val all: List<String> = listOf(
        "_http._tcp",
        "_https._tcp",
        "_ipp._tcp",
        "_ipps._tcp",
        "_printer._tcp",
        "_ssh._tcp",
        "_smb._tcp",
        "_airplay._tcp",
        "_raop._tcp",
        "_googlecast._tcp",
    )

    /** One common type is preselected; the check still requires an explicit Start. */
    val defaultSelection: String = "_http._tcp"
}

enum class LanValidationError {
    NO_SELECTION,
    SERVICE_LIMIT,
    SERVICE_FORMAT,
    DISCOVERY_SECONDS,
    SUBNET_FORMAT,
    SUBNET_PRIVATE,
    SUBNET_PREFIX,
    SUBNET_HOST_BITS,
    PORTS_FORMAT,
    PORTS_LIMIT,
    ATTEMPT_BUDGET,
    CONNECT_TIMEOUT,
    CONCURRENCY,
}

/** A validated `network.lanDiscover` request. */
data class LanDiscoveryInput(
    val serviceTypes: List<String> = emptyList(),
    val discoveryDurationMs: Int = 4_000,
    val includeAttributes: Boolean = false,
    val subnetCidr: String? = null,
    val ports: List<Int> = emptyList(),
    val tcpConnectTimeoutMs: Int = 500,
    val tcpConcurrency: Int = 16,
) {
    val hasMdns: Boolean get() = serviceTypes.isNotEmpty()
    val hasTcp: Boolean get() = subnetCidr != null

    /** Bounded whole-operation timeout that always covers the selected modes. */
    val timeoutMs: Int get() = LanDiscoveryPolicy.timeoutMs(this)

    fun problems(): List<LanValidationError> {
        val errors = LinkedHashSet<LanValidationError>()
        if (serviceTypes.size > LanDiscoveryPolicy.MAX_SERVICE_TYPES) errors += LanValidationError.SERVICE_LIMIT
        if (serviceTypes.any { !LanDiscoveryPolicy.isServiceType(it) }) errors += LanValidationError.SERVICE_FORMAT
        if (serviceTypes.distinct().size != serviceTypes.size) errors += LanValidationError.SERVICE_FORMAT
        if (discoveryDurationMs !in 500..15_000) errors += LanValidationError.DISCOVERY_SECONDS
        val cidr = subnetCidr?.let { LanDiscoveryPolicy.parsePrivateSubnet(it) }
        cidr?.error?.let { errors += it }
        if (ports.size > LanDiscoveryPolicy.MAX_PORTS) errors += LanValidationError.PORTS_LIMIT
        if (ports.any { it !in 1..65_535 } || ports.distinct().size != ports.size) {
            errors += LanValidationError.PORTS_FORMAT
        }
        if (cidr?.cidr != null && ports.isEmpty()) errors += LanValidationError.PORTS_FORMAT
        if (cidr?.cidr != null && ports.isNotEmpty() &&
            cidr.hosts.toLong() * ports.size > LanDiscoveryPolicy.MAX_ATTEMPTS
        ) {
            errors += LanValidationError.ATTEMPT_BUDGET
        }
        if (tcpConnectTimeoutMs !in 100..2_000) errors += LanValidationError.CONNECT_TIMEOUT
        if (tcpConcurrency !in 1..32) errors += LanValidationError.CONCURRENCY
        if (!hasMdns && !hasTcp) errors += LanValidationError.NO_SELECTION
        return errors.toList()
    }
}

/** Raw, saveable LAN form fields exactly as the user typed them. */
data class LanDiscoveryFormValues(
    val serviceTypes: Set<String> = setOf(LanServicePresets.defaultSelection),
    val discoverySeconds: String = "4",
    val includeAttributes: Boolean = false,
    val subnetCidr: String = "",
    val ports: String = "",
    val tcpConnectTimeoutMs: String = "500",
    val tcpConcurrency: String = "16",
)

data class LanDiscoveryFormResult(
    val input: LanDiscoveryInput? = null,
    val errors: List<LanValidationError> = emptyList(),
)

data class LanCidrParse(
    val cidr: String? = null,
    val hosts: Int = 0,
    val error: LanValidationError? = null,
)

/**
 * Pure input policy for the LAN page. It mirrors the frozen service bounds but
 * never performs I/O: the only network work happens after [NetworkExecuteCommand]
 * reaches the shared PhoneNetworkService.
 */
object LanDiscoveryPolicy {
    const val MAX_SERVICE_TYPES = 8
    const val MAX_PORTS = 8
    const val MAX_HOSTS = 254
    const val MAX_ATTEMPTS = 1_024
    const val MIN_TIMEOUT_MS = 2_000
    const val MAX_TIMEOUT_MS = 30_000

    private val SERVICE_TYPE =
        Regex("^_[a-z0-9](?:[a-z0-9-]{0,13}[a-z0-9])?\\._(tcp|udp)$")

    fun parse(values: LanDiscoveryFormValues): LanDiscoveryFormResult {
        val errors = LinkedHashSet<LanValidationError>()
        val types = values.serviceTypes
            .map { it.trim().lowercase(Locale.ROOT) }
            .filter { it.isNotEmpty() }
            .distinct()
        if (types.size > MAX_SERVICE_TYPES) errors += LanValidationError.SERVICE_LIMIT
        if (types.any { !isServiceType(it) }) errors += LanValidationError.SERVICE_FORMAT

        val seconds = values.discoverySeconds.trim().toIntOrNull()
        if (seconds == null || seconds !in 1..15) errors += LanValidationError.DISCOVERY_SECONDS

        val subnetRaw = values.subnetCidr.trim()
        val cidr = if (subnetRaw.isEmpty()) null else parsePrivateSubnet(subnetRaw)
        cidr?.error?.let { errors += it }

        val ports = if (values.ports.isBlank()) emptyList() else parsePorts(values.ports)
        if (ports == null) errors += LanValidationError.PORTS_FORMAT
        else if (ports.size > MAX_PORTS) errors += LanValidationError.PORTS_LIMIT
        if (cidr?.cidr != null && ports.isNullOrEmpty()) errors += LanValidationError.PORTS_FORMAT

        val connectTimeout = values.tcpConnectTimeoutMs.trim().toIntOrNull()
        if (connectTimeout == null || connectTimeout !in 100..2_000) {
            errors += LanValidationError.CONNECT_TIMEOUT
        }
        val concurrency = values.tcpConcurrency.trim().toIntOrNull()
        if (concurrency == null || concurrency !in 1..32) {
            errors += LanValidationError.CONCURRENCY
        }

        if (cidr?.cidr == null && types.isEmpty()) errors += LanValidationError.NO_SELECTION
        if (cidr?.cidr != null && ports != null && ports.isNotEmpty() &&
            cidr.hosts.toLong() * ports.size > MAX_ATTEMPTS
        ) {
            errors += LanValidationError.ATTEMPT_BUDGET
        }

        if (errors.isNotEmpty()) return LanDiscoveryFormResult(errors = errors.toList())
        return LanDiscoveryFormResult(
            input = LanDiscoveryInput(
                serviceTypes = types,
                discoveryDurationMs = requireNotNull(seconds) * 1_000,
                includeAttributes = values.includeAttributes,
                subnetCidr = cidr?.cidr,
                ports = ports.orEmpty(),
                tcpConnectTimeoutMs = requireNotNull(connectTimeout),
                tcpConcurrency = requireNotNull(concurrency),
            ),
        )
    }

    fun isServiceType(raw: String): Boolean = SERVICE_TYPE.matches(raw.trim().lowercase(Locale.ROOT))

    /** Splits comma/space/semicolon-separated ports; null means malformed input. */
    fun parsePorts(raw: String): List<Int>? {
        val tokens = raw.split(',', ' ', ';', '\n', '\t').filter { it.isNotBlank() }
        if (tokens.isEmpty()) return emptyList()
        val ports = ArrayList<Int>(tokens.size)
        tokens.forEach { token ->
            val port = token.toIntOrNull() ?: return null
            if (port !in 1..65_535) return null
            ports += port
        }
        if (ports.distinct().size != ports.size) return null
        return ports
    }

    /**
     * Accepts only an explicit RFC1918 IPv4 subnet with /24../30 and zero host
     * bits. There is deliberately no default: the page never sweeps a guessed
     * subnet.
     */
    fun parsePrivateSubnet(raw: String): LanCidrParse {
        val parts = raw.trim().split('/')
        if (parts.size != 2) return LanCidrParse(error = LanValidationError.SUBNET_FORMAT)
        val prefix = parts[1].toIntOrNull()
            ?: return LanCidrParse(error = LanValidationError.SUBNET_FORMAT)
        if (prefix !in 24..30) return LanCidrParse(error = LanValidationError.SUBNET_PREFIX)
        val address = parseIpv4(parts[0])
            ?: return LanCidrParse(error = LanValidationError.SUBNET_FORMAT)
        val mask = (0xFFFF_FFFFL shl (32 - prefix)) and 0xFFFF_FFFFL
        if (address and mask != address) {
            return LanCidrParse(error = LanValidationError.SUBNET_HOST_BITS)
        }
        val network = address and mask
        if (!isPrivate(network)) return LanCidrParse(error = LanValidationError.SUBNET_PRIVATE)
        val hosts = ((1L shl (32 - prefix)) - 2L).toInt()
        return LanCidrParse(cidr = "${formatIpv4(network)}/$prefix", hosts = hosts)
    }

    fun timeoutMs(input: LanDiscoveryInput): Int {
        val duration = input.discoveryDurationMs.coerceIn(500, 15_000)
        val hosts = input.subnetCidr?.let { hostCount(it) } ?: 0L
        val concurrency = input.tcpConcurrency.coerceIn(1, 32)
        val connectTimeout = input.tcpConnectTimeoutMs.coerceIn(100, 2_000)
        val minimum = when {
            input.hasMdns && input.hasTcp -> duration + 2_000
            input.hasMdns -> duration + 1_000
            else -> 2_000
        }
        val attempts = hosts * input.ports.size
        val rounds = if (attempts <= 0L || !input.hasTcp) 0L else (attempts + concurrency - 1) / concurrency
        val estimate = minimum + rounds * connectTimeout
        return estimate.coerceIn(MIN_TIMEOUT_MS.toLong(), MAX_TIMEOUT_MS.toLong()).toInt()
    }

    private fun hostCount(cidr: String): Long {
        val prefix = cidr.substringAfterLast('/').toIntOrNull() ?: return 0L
        if (prefix !in 24..30) return 0L
        return (1L shl (32 - prefix)) - 2L
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

    private fun isPrivate(address: Long): Boolean = when {
        address and 0xFF00_0000L == 0x0A00_0000L -> true
        address and 0xFFF0_0000L == 0xAC10_0000L -> true
        address and 0xFFFF_0000L == 0xC0A8_0000L -> true
        else -> false
    }

    private fun formatIpv4(value: Long): String =
        "${(value ushr 24) and 0xFF}.${(value ushr 16) and 0xFF}." +
            "${(value ushr 8) and 0xFF}.${value and 0xFF}"
}
