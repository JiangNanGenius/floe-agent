// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

enum class Ipv6Policy(val wire: String) {
    /**
     * No IPv6 route is installed. IPv6 traffic keeps using the underlying
     * network and is not silently routed into a parser that cannot forward it.
     * This is an explicit partial-capture boundary, not full IPv6 capture.
     */
    BYPASS("bypass"),
}

/**
 * Pure VpnService.Builder plan. Only IPv4 routes are representable; the
 * data-plane class applies this plan, and a unit test pins that no IPv6 route
 * can be added by accident.
 */
data class VpnPlan(
    val address: String,
    val prefixLength: Int,
    val mtu: Int,
    val routes: List<String>,
    val dnsServers: List<String> = emptyList(),
    val allowedPackages: List<String> = emptyList(),
    val disallowedPackages: List<String> = emptyList(),
    val sessionName: String,
    val ipv6Policy: Ipv6Policy = Ipv6Policy.BYPASS,
) {
    init {
        require(isIpv4Cidr("$address/$prefixLength")) { "vpn address must be IPv4" }
        require(mtu in CaptureLimits.MIN_MTU..CaptureLimits.MAX_MTU) { "mtu" }
        require(routes.isNotEmpty() && routes.all(::isIpv4Cidr)) {
            "only IPv4 routes are installed; IPv6 is a transparent bypass"
        }
        require(dnsServers.all(::isIpv4Literal)) { "only IPv4 DNS overrides are supported" }
        require(allowedPackages.all { it.isBoundedPackage() }) { "allowed package" }
        require(disallowedPackages.all { it.isBoundedPackage() }) { "disallowed package" }
        require(sessionName.isNotBlank() && sessionName.length <= 64) { "session name" }
    }

    companion object {
        fun fromConfig(config: CaptureConfig, selfPackage: String?, excludeSelf: Boolean = true): VpnPlan =
            VpnPlan(
                address = config.vpnAddress,
                prefixLength = config.vpnAddressPrefix,
                mtu = config.mtu,
                routes = listOf(CaptureLimits.VPN_ROUTE),
                // No DNS override: the system uses the underlying network's
                // DNS. IPv4 queries are captured/forwarded; IPv6 DNS bypasses
                // because no IPv6 route is installed.
                dnsServers = emptyList(),
                disallowedPackages = if (excludeSelf && selfPackage != null) {
                    listOf(selfPackage)
                } else {
                    emptyList()
                },
                sessionName = config.sessionName,
                ipv6Policy = Ipv6Policy.BYPASS,
            )
    }
}

internal fun isIpv4Literal(value: String): Boolean {
    val parts = value.split('.')
    if (parts.size != 4) return false
    return parts.all { part ->
        part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
            part.toIntOrNull()?.let { it in 0..255 } == true
    }
}

internal fun isIpv4Cidr(value: String): Boolean {
    val pieces = value.split('/')
    if (pieces.size != 2) return false
    if (!isIpv4Literal(pieces[0])) return false
    val prefix = pieces[1].toIntOrNull() ?: return false
    return prefix in 0..32
}

private fun String.isBoundedPackage(): Boolean =
    length in 1..255 && matches(Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"))
