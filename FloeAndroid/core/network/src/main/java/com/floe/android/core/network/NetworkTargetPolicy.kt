// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/** Broad address class used only for diagnostics policy; never a security claim. */
internal enum class AddressClass {
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

internal class TargetSyntaxException(message: String) : Exception(message)

internal class TargetPolicyException(val code: String, message: String) : Exception(message)

/**
 * A validated HTTPS/HTTP diagnostic target. The URI is the exact parsed target
 * used for the request; `redacted` removes user information and query values
 * so a credential-bearing URL is never echoed into a result or log.
 */
internal data class HttpTarget(
    val uri: URI,
    val scheme: String,
    val host: String,
    val port: Int,
    val path: String,
    val query: String?,
    val cleartext: Boolean,
    val redacted: String,
) {
    fun resolveRedirect(location: String): HttpTarget {
        val resolved = try {
            uri.resolve(location)
        } catch (failure: IllegalArgumentException) {
            throw TargetSyntaxException("invalid redirect target")
        }
        return NetworkTargetPolicy.parseHttpTarget(resolved.toString())
    }
}

/**
 * Pure destination policy shared by DNS/ping/TCP/HTTPS:
 *  - deliberate public and private diagnostics are allowed;
 *  - cloud metadata, unspecified and multicast destinations are refused;
 *  - loopback/private/link-local/CGNAT targets are reported as LOCAL so the
 *    caller can require the existing ACCESS_LOCAL_NETWORK broker.
 * Names are checked literally; callers that resolve a name additionally check
 * every resolved address.
 */
internal object NetworkTargetPolicy {
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

    private val METADATA_IPV6_PREFIXES = listOf(
        byteArrayOf(0xfd.toByte(), 0x00, 0x0e, 0xc2.toByte()),
        byteArrayOf(0xfd.toByte(), 0x20, 0x00, 0xce.toByte()),
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

    /** Syntax-only validation. Target policy is a separate check. */
    fun validateHostSyntax(raw: String): String {
        val value = normalizeHost(raw)
        if (value.isEmpty()) throw TargetSyntaxException("target host is empty")
        if (value.length > NetworkLimits.MAX_HOST_CHARS) {
            throw TargetSyntaxException("target host is longer than 253 characters")
        }
        if (value.contains(':')) {
            if (value.length > 64) throw TargetSyntaxException("IPv6 literal is too long")
            if (!value.matches(Regex("^[0-9A-Fa-f:.%A-Za-z0-9_-]+$"))) {
                throw TargetSyntaxException("invalid IPv6 literal")
            }
            val literal = value.substringBefore('%')
            val parsed = runCatching { InetAddress.getByName(literal) }.getOrNull()
            if (parsed !is Inet6Address && parsed !is Inet4Address) {
                throw TargetSyntaxException("invalid IPv6 literal")
            }
            return value
        }
        val labels = value.split('.')
        if (labels.any { it.isEmpty() }) throw TargetSyntaxException("target host has an empty label")
        val labelPattern = Regex("^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$")
        labels.forEach { label ->
            if (label.length > 63 || !labelPattern.matches(label)) {
                throw TargetSyntaxException("target host contains an invalid label")
            }
        }
        return value
    }

    fun parseHttpTarget(raw: String): HttpTarget {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) throw TargetSyntaxException("URL is empty")
        if (trimmed.length > NetworkLimits.MAX_URL_CHARS) {
            throw TargetSyntaxException("URL is longer than 4096 characters")
        }
        val uri = try {
            URI(trimmed)
        } catch (failure: URISyntaxException) {
            throw TargetSyntaxException("URL is not a valid absolute URI")
        }
        if (!uri.isAbsolute) throw TargetSyntaxException("URL must be absolute")
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
            ?: throw TargetSyntaxException("URL has no scheme")
        if (uri.userInfo != null) throw TargetSyntaxException("URL user information is not permitted")
        val rawHost = uri.host ?: throw TargetSyntaxException("URL has no host")
        val host = normalizeHost(rawHost)
        validateHostSyntax(host)
        val port = uri.port
        if (port == 0 || port > 65_535) throw TargetSyntaxException("URL port is invalid")
        val path = uri.rawPath?.takeIf { it.isNotEmpty() } ?: "/"
        val authority = uri.rawAuthority ?: throw TargetSyntaxException("URL has no authority")
        return HttpTarget(
            uri = uri,
            scheme = scheme,
            host = host,
            port = port,
            path = path,
            query = uri.rawQuery,
            cleartext = scheme == "http",
            redacted = "$scheme://$authority$path",
        )
    }

    fun checkHttpTargetPolicy(target: HttpTarget) {
        if (target.scheme != "https" && target.scheme != "http") {
            throw TargetPolicyException("unsupportedScheme", "only HTTP/HTTPS diagnostics are supported")
        }
        checkHostPolicy(target.host)
    }

    fun checkHostPolicy(host: String) {
        if (isMetadataHostname(host)) {
            throw TargetPolicyException("policyDenied", "cloud metadata destinations are not permitted")
        }
        val literal = literalAddressClass(host) ?: return
        if (isDenied(literal)) {
            throw TargetPolicyException("policyDenied", "metadata/unspecified/multicast destinations are not permitted")
        }
    }

    /**
     * Validates every address a name resolved to. Returns true when at least
     * one address is local (the caller must then consult the shared LAN
     * permission state). Any denied address refuses the whole name.
     */
    fun checkResolvedAddresses(host: String, addresses: List<String>): Boolean {
        checkHostPolicy(host)
        if (addresses.isEmpty()) {
            throw TargetPolicyException("dnsFailure", "the target resolved to no addresses")
        }
        var local = false
        addresses.forEach { literal ->
            val addressClass = classifyLiteral(literal)
            if (isDenied(addressClass)) {
                throw TargetPolicyException(
                    "policyDenied",
                    "a resolved address is a metadata/unspecified/multicast destination",
                )
            }
            if (isLocal(addressClass)) local = true
        }
        return local
    }

    fun isMetadataHostname(host: String): Boolean {
        val value = normalizeHost(host).lowercase(Locale.ROOT)
        if (METADATA_HOSTS.contains(value)) return true
        return value.endsWith(".metadata.google.internal") ||
            value.endsWith(".instance-data.ec2.internal")
    }

    fun literalAddressClass(host: String): AddressClass? {
        val value = normalizeHost(host)
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

    fun classifyLiteral(literal: String): AddressClass = literalAddressClass(literal) ?: AddressClass.UNKNOWN

    fun isDenied(addressClass: AddressClass): Boolean = when (addressClass) {
        AddressClass.METADATA,
        AddressClass.UNSPECIFIED,
        AddressClass.MULTICAST,
        AddressClass.RESERVED,
        -> true

        else -> false
    }

    fun isLocal(addressClass: AddressClass): Boolean = when (addressClass) {
        AddressClass.PRIVATE,
        AddressClass.LOOPBACK,
        AddressClass.LINK_LOCAL,
        AddressClass.CGNAT,
        -> true

        else -> false
    }

    fun isLocalLiteral(literal: String): Boolean = isLocal(classifyLiteral(literal))

    fun redactUrl(raw: String): String = try {
        parseHttpTarget(raw).redacted
    } catch (_: TargetSyntaxException) {
        ""
    }

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

    private fun classifyIpv4(bytes: ByteArray): AddressClass {
        if (bytes.size != 4) return AddressClass.UNKNOWN
        val a = bytes[0].toInt() and 0xFF
        val b = bytes[1].toInt() and 0xFF
        val c = bytes[2].toInt() and 0xFF
        val d = bytes[3].toInt() and 0xFF
        val dotted = "$a.$b.$c.$d"
        if (METADATA_IPV4.contains(dotted)) return AddressClass.METADATA
        if (a == 0) return AddressClass.UNSPECIFIED
        if (a == 127) return AddressClass.LOOPBACK
        if (a == 10) return AddressClass.PRIVATE
        if (a == 172 && b in 16..31) return AddressClass.PRIVATE
        if (a == 192 && b == 168) return AddressClass.PRIVATE
        if (a == 169 && b == 254) return AddressClass.LINK_LOCAL
        if (a == 100 && b in 64..127) return AddressClass.CGNAT
        if (a in 224..239) return AddressClass.MULTICAST
        if (a >= 240) return AddressClass.RESERVED
        if (a == 192 && b == 0 && c == 0) return AddressClass.RESERVED
        return AddressClass.PUBLIC
    }

    private fun classifyIpv6(bytes: ByteArray): AddressClass {
        if (bytes.size != 16) return AddressClass.UNKNOWN
        if (bytes.all { it == 0.toByte() }) return AddressClass.UNSPECIFIED
        if (bytes.take(15).all { it == 0.toByte() } && bytes[15] == 1.toByte()) {
            return AddressClass.LOOPBACK
        }
        METADATA_IPV6_PREFIXES.forEach { prefix ->
            if (bytes.size >= prefix.size && prefix.indices.all { bytes[it] == prefix[it] }) {
                return AddressClass.METADATA
            }
        }
        if ((bytes[0].toInt() and 0xFE) == 0xFC) return AddressClass.PRIVATE
        if ((bytes[0].toInt() and 0xFF) == 0xFE && (bytes[1].toInt() and 0xC0) == 0x80) {
            return AddressClass.LINK_LOCAL
        }
        if ((bytes[0].toInt() and 0xFF) == 0xFF) return AddressClass.MULTICAST
        if (bytes.take(10).all { it == 0.toByte() } &&
            bytes[10] == 0xFF.toByte() && bytes[11] == 0xFF.toByte()
        ) {
            return classifyIpv4(bytes.copyOfRange(12, 16))
        }
        return AddressClass.PUBLIC
    }
}
