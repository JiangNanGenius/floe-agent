// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.devicelink

import android.content.Context
import computer.iroh.Connection
import computer.iroh.Endpoint
import computer.iroh.EndpointAddr
import computer.iroh.EndpointId
import computer.iroh.EndpointOptions
import computer.iroh.IrohAndroid
import computer.iroh.RelayMode
import computer.iroh.SecretKey
import computer.iroh.presetMinimal
import java.net.URI
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** An Iroh device identity. Store its private bytes in the host's credential store. */
class FloeDeviceLinkIdentity(privateKeyBytes: ByteArray) {
    private val privateKey = privateKeyBytes.copyOf()
    val endpointId = SecretKey.fromBytes(privateKey).use { key ->
        key.`public`().use { it.toString() }
    }

    fun privateKeyBytes(): ByteArray = privateKey.copyOf()

    override fun toString(): String = endpointId

    companion object {
        fun generate(): FloeDeviceLinkIdentity = SecretKey.generate().use { key ->
            val bytes = key.toBytes()
            try {
                FloeDeviceLinkIdentity(bytes)
            } finally {
                bytes.fill(0)
            }
        }
    }
}

/** Share these hints through the host's pairing flow. The endpoint ID authenticates the peer. */
data class FloeDeviceLinkAddress(
    val endpointId: String,
    val relayUrl: String? = null,
    val directAddresses: List<String> = emptyList(),
) {
    // Keep the field names and optional relay URL compatible with Swift Codable,
    // which omits a nil relayURL (org.json drops null values the same way).
    fun toJson(): String = JSONObject()
        .put("endpointID", endpointId)
        .put("relayURL", relayUrl)
        .put("directAddresses", JSONArray(directAddresses))
        .toString()

    companion object {
        fun fromJson(json: String): FloeDeviceLinkAddress {
            val objectValue = JSONObject(json)
            val directAddresses = objectValue.getJSONArray("directAddresses")
            require(directAddresses.length() <= MAXIMUM_DIRECT_ADDRESSES)
            return FloeDeviceLinkAddress(
                endpointId = objectValue.get("endpointID") as String,
                relayUrl = if (objectValue.isNull("relayURL")) null else objectValue.get("relayURL") as String,
                directAddresses = List(directAddresses.length()) { directAddresses.get(it) as String },
            )
        }
    }
}

/** Relay selection. [Custom] must be a validated HTTPS URL without credentials or query. */
sealed class FloeDeviceLinkRelay {
    data object PUBLIC_IROH : FloeDeviceLinkRelay()
    data object DISABLED : FloeDeviceLinkRelay()
    data class Custom(val url: String) : FloeDeviceLinkRelay()
}

class FloeDeviceLinkException(val reason: Reason) : IllegalStateException(reason.name) {
    enum class Reason {
        ENDPOINT_CLOSED,
        RELAY_UNAVAILABLE,
        RELAY_NOT_ALLOWED,
        MISSING_ADDRESS,
        TOO_MANY_DIRECT_ADDRESSES,
        SELF_CONNECTION,
        PEER_NOT_AUTHORIZED,
        UNEXPECTED_PROTOCOL,
        EMPTY_PAYLOAD,
        PAYLOAD_TOO_LARGE,
        RESPONSE_ALREADY_USED,
    }
}

/** A host-owned endpoint. Changing peer approvals does not change its address. */
class FloeDeviceLink private constructor(
    private val endpoint: Endpoint,
    private val ownId: String,
    trustedEndpointIds: Set<String>,
    internal val relayUrls: Set<String>,
) {
    private val closed = AtomicBoolean()
    private val trustedPeers = AtomicReference(trustedEndpointIds)

    internal val boundSockets: List<String> get() = endpoint.boundSockets()

    /** The negotiated UDP port, stable across trust-set changes on the same endpoint. */
    val listeningPort: Int?
        get() = boundSockets.firstNotNullOfOrNull { socket ->
            socket.substringAfterLast(':').toIntOrNull()?.takeIf { it in 1..65535 }
        }

    fun address(includeDirectAddresses: Boolean = true): FloeDeviceLinkAddress {
        ensureOpen()
        return endpoint.addr().use { address ->
            FloeDeviceLinkAddress(
                endpointId = ownId,
                relayUrl = address.relayUrl(),
                directAddresses = if (includeDirectAddresses) {
                    address.directAddresses().take(MAXIMUM_DIRECT_ADDRESSES)
                } else {
                    emptyList()
                },
            )
        }
    }

    /** Wait for home relay registration. Cancelling this startup wait closes the endpoint. */
    suspend fun waitForRelayAddress(): FloeDeviceLinkAddress {
        ensureOpen()
        if (relayUrls.isEmpty()) throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_UNAVAILABLE)
        try {
            endpoint.online()
            return address(includeDirectAddresses = false).also {
                if (it.relayUrl !in relayUrls) {
                    throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_UNAVAILABLE)
                }
            }
        } catch (cancelled: CancellationException) {
            runCatching { close() }
            throw cancelled
        }
    }

    suspend fun connect(to: FloeDeviceLinkAddress): FloeDeviceLinkConnection {
        ensureOpen()
        return EndpointId.fromString(to.endpointId).use { peer ->
            val peerId = peer.toString()
            if (peerId == ownId) throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.SELF_CONNECTION)
            if (peerId !in trustedPeers.get()) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.PEER_NOT_AUTHORIZED)
            }
            val directAddresses = to.directAddresses.toList()
            if (directAddresses.size > MAXIMUM_DIRECT_ADDRESSES) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.TOO_MANY_DIRECT_ADDRESSES)
            }
            if (to.relayUrl != null && to.relayUrl !in relayUrls) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_NOT_ALLOWED)
            }
            if (to.relayUrl == null && directAddresses.isEmpty()) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.MISSING_ADDRESS)
            }
            currentCoroutineContext().ensureActive()
            EndpointAddr(peer, to.relayUrl, directAddresses).use { destination ->
                validate(endpoint.connect(destination, ALPN), expectedPeer = peerId)
            }
        }
    }

    /** Swap the approved peers without rebinding; the listening port stays stable. */
    fun replaceTrustedEndpointIDs(values: Set<String>) {
        val peers = values.mapTo(mutableSetOf()) { canonicalEndpointID(it) }
        if (ownId in peers) throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.SELF_CONNECTION)
        trustedPeers.set(peers)
    }

    /** Accept one authenticated connection from the host's listener. */
    suspend fun acceptNext(): FloeDeviceLinkConnection? {
        if (closed.get()) return null
        currentCoroutineContext().ensureActive()
        return endpoint.acceptNext()?.use { incoming ->
            incoming.accept().use { accepting -> validate(accepting.connect()) }
        }
    }

    suspend fun close() {
        if (closed.compareAndSet(false, true)) {
            withContext(NonCancellable) { endpoint.use { it.shutdown() } }
        }
    }

    private fun ensureOpen() {
        if (closed.get() || endpoint.isClosed()) {
            throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.ENDPOINT_CLOSED)
        }
    }

    private suspend fun validate(connection: Connection, expectedPeer: String? = null): FloeDeviceLinkConnection {
        try {
            currentCoroutineContext().ensureActive()
            ensureOpen()
            if (!connection.alpn().contentEquals(ALPN)) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.UNEXPECTED_PROTOCOL)
            }
            val peerId = connection.remoteId().use { it.toString() }
            if (peerId !in trustedPeers.get() || (expectedPeer != null && peerId != expectedPeer)) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.PEER_NOT_AUTHORIZED)
            }
            connection.setMaxConcurrentBiStreams(8uL)
            connection.setMaxConcurrentUniStreams(0uL)
            return FloeDeviceLinkConnection(connection, peerId)
        } catch (error: Exception) {
            runCatching { connection.use { it.close(1, ByteArray(0)) } }
            throw error
        }
    }

    companion object {
        private val ALPN = "floe/device-link/1".encodeToByteArray()

        /** Canonicalize an endpoint ID the same way the peer's address advertised it. */
        fun canonicalEndpointID(value: String): String =
            EndpointId.fromString(value).use { it.toString() }

        suspend fun bind(
            context: Context,
            identity: FloeDeviceLinkIdentity,
            trustedEndpointIds: Set<String>,
            relay: FloeDeviceLinkRelay = FloeDeviceLinkRelay.PUBLIC_IROH,
            bindAddress: String? = null,
        ): FloeDeviceLink {
            val trustedPeers = trustedEndpointIds.mapTo(mutableSetOf()) { peer ->
                canonicalEndpointID(peer)
            }
            if (identity.endpointId in trustedPeers) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.SELF_CONNECTION)
            }
            currentCoroutineContext().ensureActive()
            IrohAndroid.installAndroidContext(context.applicationContext)
            val mode = when (relay) {
                FloeDeviceLinkRelay.PUBLIC_IROH -> RelayMode.defaultMode()
                FloeDeviceLinkRelay.DISABLED -> RelayMode.disabled()
                is FloeDeviceLinkRelay.Custom -> customRelayMode(relay.url)
            }
            return mode.use {
                val relayUrls = it.relayMap().use { map -> map.urls().toSet() }
                val privateKey = identity.privateKeyBytes()
                val endpoint = try {
                    Endpoint.bind(EndpointOptions(
                        preset = presetMinimal(),
                        bindAddr = bindAddress,
                        secretKey = privateKey,
                        alpns = listOf(ALPN),
                        relayMode = it,
                    ))
                } finally {
                    privateKey.fill(0)
                }
                try {
                    currentCoroutineContext().ensureActive()
                    FloeDeviceLink(
                        endpoint = endpoint,
                        ownId = identity.endpointId,
                        trustedEndpointIds = trustedPeers,
                        relayUrls = relayUrls,
                    )
                } catch (failure: Exception) {
                    runCatching { endpoint.close() }
                    throw failure
                }
            }
        }

        private fun customRelayMode(url: String): RelayMode {
            val uri = try {
                URI(url)
            } catch (failure: Exception) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_NOT_ALLOWED)
            }
            if (!uri.scheme.equals("https", ignoreCase = true) || uri.host.isNullOrEmpty() ||
                uri.userInfo != null || uri.query != null || uri.fragment != null) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_NOT_ALLOWED)
            }
            return try {
                RelayMode.customFromUrls(listOf(url))
            } catch (failure: Exception) {
                throw FloeDeviceLinkException(FloeDeviceLinkException.Reason.RELAY_NOT_ALLOWED)
            }
        }
    }
}

private const val MAXIMUM_DIRECT_ADDRESSES = 16
