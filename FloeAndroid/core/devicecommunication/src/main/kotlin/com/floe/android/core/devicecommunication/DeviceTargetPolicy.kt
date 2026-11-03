// SPDX-License-Identifier: MPL-2.0
//
// C05 raw-device destination policy.
//
// This is deliberately the SAME narrow policy family used by
// `core/network/NetworkTargetPolicy` (which is module-internal): cloud
// metadata, unspecified and multicast destinations are refused; private,
// loopback, link-local and CGNAT literals are classified LOCAL so the caller
// can consult the existing App `LocalNetworkAccessBroker` on API 37. It is
// used only for TCP/Telnet raw sessions; BLE/USB have no network target.
//
// The policy is not a security sandbox and never replaces a real connect
// result. It prevents an accidental metadata/unspecified connect and keeps
// the LAN-permission decision honest.

package com.floe.android.core.devicecommunication

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.util.Locale

enum class DeviceTargetClass {
    PUBLIC,
    PRIVATE,
    LOOPBACK,
    LINK_LOCAL,
    CGNAT,
    METADATA,
    UNSPECIFIED,
    MULTICAST,
    RESERVED,
    UNKNOWN,
}

object DeviceTargetPolicy {
    private val METADATA_HOSTS = setOf(
        "metadata",
        "metadata.google.internal",
        "metadata.goog",
        "instance-data",
        "instance-data.ec2.internal",
        "metadata.azure.internal",
        "metadata.oraclecloud.com",
        "metadata.packet.net",
        "metadata.hetzner.cloud",
    )

    private val METADATA_IPV4 = setOf(
        "169.254.169.254",
        "169.254.170.2",
        "100.100.100.200",
        "192.0.0.192",
        "168.63.129.16",
        "169.254.169.253",
    )

    fun normalizeHost(raw: String): String {
        var value = raw.trim()
        if (value.startsWith("[") && value.endsWith("]") && value.length > 2) {
            value = value.substring(1, value.length - 1)
        }
        if (value.endsWith(".")) value = value.dropLast(1)
        if (value.contains(':')) value = value.replace("%25", "%")
        return value
    }

    /** Syntax validation for a host name or IP literal (no DNS, no connect). */
    fun validateHost(raw: String): String {
        val value = normalizeHost(raw)
        if (value.isEmpty()) throw invalid("Enter a host name or address.")
        if (value.length > 253) throw invalid("The host is too long.")
        if (value.contains(':')) {
            if (value.length > 64) throw invalid("The IPv6 literal is too long.")
            if (!value.matches(Regex("^[0-9A-Fa-f:.%A-Za-z0-9_-]+$"))) {
                throw invalid("The IPv6 literal contains invalid characters.")
            }
            val literal = value.substringBefore('%')
            val parsed = runCatching { InetAddress.getByName(literal) }.getOrNull()
            if (parsed !is Inet6Address) throw invalid("The IPv6 literal is invalid.")
            return value
        }
        val labels = value.split('.')
        if (labels.any { it.isEmpty() }) throw invalid("The host contains an empty label.")
        val labelPattern = Regex("^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$")
        labels.forEach { label ->
            if (label.length > 63 || !labelPattern.matches(label)) {
                throw invalid("The host contains an invalid label.")
            }
        }
        return value
    }

    fun validatePort(port: Int): Int {
        if (port !in 1..65_535) throw invalid("Enter a port from 1 to 65535.")
        return port
    }

    /** Refuses only clearly non-routable policy categories. Names are checked
     * literally; a name's resolved addresses are the caller's responsibility
     * when it actually connects. */
    fun checkPolicy(host: String) {
        if (isMetadataHostname(host)) {
            throw DeviceCommunicationException(
                DeviceErrorCode.POLICY_DENIED,
                "Cloud metadata destinations are not permitted.",
            )
        }
        val literal = literalClass(host) ?: return
        if (isDenied(literal)) {
            throw DeviceCommunicationException(
                DeviceErrorCode.POLICY_DENIED,
                "Metadata, unspecified and multicast destinations are not permitted.",
            )
        }
    }

    fun isMetadataHostname(raw: String): Boolean {
        val value = normalizeHost(raw).lowercase(Locale.ROOT)
        if (METADATA_HOSTS.contains(value)) return true
        return value.endsWith(".metadata.google.internal") ||
            value.endsWith(".instance-data.ec2.internal")
    }

    /** Cheap UI/pump heuristic mirroring `LocalNetworkAccessBroker`; the real
     * ACCESS_LOCAL_NETWORK authority remains that broker. */
    fun isLocalLikely(raw: String): Boolean {
        val host = runCatching { normalizeHost(raw) }.getOrDefault("")
            .lowercase(Locale.ROOT)
        if (host.isEmpty()) return false
        if (host == "localhost" || host.endsWith(".localhost")) return true
        if (host.endsWith(".local") || host.endsWith(".internal")) return true
        if (!host.contains('.') && !host.contains(':')) return true
        if (host.contains(':')) {
            if (host == "::1") return true
            return host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe80")
        }
        return isLocal(literalClass(host) ?: DeviceTargetClass.UNKNOWN)
    }

    fun literalClass(raw: String): DeviceTargetClass? {
        val value = normalizeHost(raw)
        parseIpv4(value)?.let { return classifyIpv4(it) }
        if (!value.contains(':')) return null
        val literal = value.substringBefore('%')
        return try {
            when (val address = InetAddress.getByName(literal)) {
                is Inet4Address -> classifyIpv4(address.address)
                is Inet6Address -> classifyIpv6(address.address)
                else -> null
            }
        } catch (_: Exception) {
            null
        }
    }

    fun isDenied(targetClass: DeviceTargetClass): Boolean = when (targetClass) {
        DeviceTargetClass.METADATA,
        DeviceTargetClass.UNSPECIFIED,
        DeviceTargetClass.MULTICAST,
        DeviceTargetClass.RESERVED,
        -> true

        else -> false
    }

    fun isLocal(targetClass: DeviceTargetClass): Boolean = when (targetClass) {
        DeviceTargetClass.PRIVATE,
        DeviceTargetClass.LOOPBACK,
        DeviceTargetClass.LINK_LOCAL,
        DeviceTargetClass.CGNAT,
        -> true

        else -> false
    }

    /** Redacts userinfo/query/path noise from a display endpoint. The engine
     * already carries only host/port, but the UI also uses this for labels. */
    fun endpointLabel(protocol: DeviceProtocol, host: String?, port: Int?): String = when (protocol) {
        DeviceProtocol.TCP, DeviceProtocol.TELNET -> {
            val cleanHost = host?.trim()?.take(200) ?: ""
            val cleanPort = port?.takeIf { it in 1..65_535 }
            if (cleanHost.contains(':')) "[$cleanHost]:${cleanPort ?: ""}" else "$cleanHost:${cleanPort ?: ""}"
        }
        DeviceProtocol.BLE -> "BLE"
        DeviceProtocol.USB -> "USB"
    }

    private fun invalid(message: String) = DeviceCommunicationException(
        DeviceErrorCode.INVALID_TARGET,
        message,
    )

    private fun parseIpv4(value: String): ByteArray? {
        val parts = value.split('.')
        if (parts.size != 4) return null
        val bytes = ByteArray(4)
        parts.forEachIndexed { index, part ->
            if (part.isEmpty() || part.length > 3 || part.any { it !in '0'..'9' }) return null
            val number = part.toIntOrNull() ?: return null
            if (number !in 0..255) return null
            if (part.length > 1 && part.startsWith('0')) return null
            bytes[index] = number.toByte()
        }
        return bytes
    }

    private fun classifyIpv4(bytes: ByteArray): DeviceTargetClass {
        if (bytes.size != 4) return DeviceTargetClass.UNKNOWN
        val a = bytes[0].toInt() and 0xFF
        val b = bytes[1].toInt() and 0xFF
        val c = bytes[2].toInt() and 0xFF
        val d = bytes[3].toInt() and 0xFF
        val dotted = "$a.$b.$c.$d"
        if (METADATA_IPV4.contains(dotted)) return DeviceTargetClass.METADATA
        if (a == 0) return DeviceTargetClass.UNSPECIFIED
        if (a == 127) return DeviceTargetClass.LOOPBACK
        if (a == 10) return DeviceTargetClass.PRIVATE
        if (a == 172 && b in 16..31) return DeviceTargetClass.PRIVATE
        if (a == 192 && b == 168) return DeviceTargetClass.PRIVATE
        if (a == 169 && b == 254) return DeviceTargetClass.LINK_LOCAL
        if (a == 100 && b in 64..127) return DeviceTargetClass.CGNAT
        if (a in 224..239) return DeviceTargetClass.MULTICAST
        if (a >= 240) return DeviceTargetClass.RESERVED
        if (a == 192 && b == 0 && c == 0) return DeviceTargetClass.RESERVED
        return DeviceTargetClass.PUBLIC
    }

    private fun classifyIpv6(bytes: ByteArray): DeviceTargetClass {
        if (bytes.size != 16) return DeviceTargetClass.UNKNOWN
        if (bytes.all { it == 0.toByte() }) return DeviceTargetClass.UNSPECIFIED
        if (bytes.take(15).all { it == 0.toByte() } && bytes[15] == 1.toByte()) {
            return DeviceTargetClass.LOOPBACK
        }
        val metadataPrefixes = listOf(
            byteArrayOf(0xfd.toByte(), 0x00, 0x0e, 0xc2.toByte()),
            byteArrayOf(0xfd.toByte(), 0x20, 0x00, 0xce.toByte()),
        )
        metadataPrefixes.forEach { prefix ->
            if (prefix.indices.all { bytes[it] == prefix[it] }) return DeviceTargetClass.METADATA
        }
        if ((bytes[0].toInt() and 0xFE) == 0xFC) return DeviceTargetClass.PRIVATE
        if ((bytes[0].toInt() and 0xFF) == 0xFE && (bytes[1].toInt() and 0xC0) == 0x80) {
            return DeviceTargetClass.LINK_LOCAL
        }
        if ((bytes[0].toInt() and 0xFF) == 0xFF) return DeviceTargetClass.MULTICAST
        if (bytes.take(10).all { it == 0.toByte() } &&
            bytes[10] == 0xFF.toByte() && bytes[11] == 0xFF.toByte()
        ) {
            return classifyIpv4(bytes.copyOfRange(12, 16))
        }
        return DeviceTargetClass.PUBLIC
    }
}
