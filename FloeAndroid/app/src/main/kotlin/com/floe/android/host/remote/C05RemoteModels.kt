// SPDX-License-Identifier: MPL-2.0
//
// C05 trusted-host client values. These are parsed from the closed
// `floe.remote/9` wire; they never contain a secret body.

package com.floe.android.host.remote

import com.floe.android.bridge.SwiftCore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.put
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

internal const val C05_REMOTE_VERSION = 9

internal fun interface C05RemoteTransport {
    fun exchange(request: String): String
}

internal object SwiftC05RemoteTransport : C05RemoteTransport {
    override fun exchange(request: String): String = SwiftCore.exchange(request)
}

internal class C05RemoteFailure(
    val code: String,
    val reason: String? = null,
    val retryable: Boolean = false,
    val detail: String? = null,
    val challenge: C05HostKeyChallenge? = null,
) : Exception(code)

internal data class C05CredentialRef(
    val keychainAccount: String,
    val synchronizable: Boolean,
)

internal data class C05Auth(
    val kind: String,
    val keyType: String?,
    val credential: C05CredentialRef?,
)

internal data class C05JumpHop(
    val address: String,
    val port: Int,
    val user: String,
    val auth: C05Auth,
)

internal data class C05VncEndpoint(
    val id: String,
    val displayName: String,
    val transport: String,
    val host: String,
    val port: Int,
    val passwordRef: C05CredentialRef?,
)

internal data class C05AuxConnection(
    val id: String,
    val displayName: String,
    val kind: String,
    val host: String?,
    val port: Int?,
    val bluetoothPeripheralID: String?,
    val bluetoothServiceUUID: String?,
    val bluetoothWriteCharacteristicUUID: String?,
    val bluetoothNotifyCharacteristicUUID: String?,
)

internal data class C05HostSummary(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val auth: C05Auth,
    val deviceKind: String,
    val isRemoteExecutionEnvironment: Boolean,
    val hostKeyPolicy: String,
    val pinnedFingerprint: String?,
    val allowsLegacyAlgorithms: Boolean,
    val jumpHopCount: Int,
    val vncEndpointCount: Int,
    val auxiliaryConnectionCount: Int,
)

internal data class C05HostDetail(
    val summary: C05HostSummary,
    val jumpChain: List<C05JumpHop>,
    val vncEndpoints: List<C05VncEndpoint>,
    val auxiliaryConnections: List<C05AuxConnection>,
)

internal data class C05HostKeyChallenge(
    val id: String,
    val profileID: String,
    val address: String,
    val port: Int,
    val keyType: String,
    val fingerprintSHA256: String,
    val expectedFingerprintSHA256: String?,
    val kind: String,
    val createdAt: String,
    val expiresAt: String,
) {
    val changed: Boolean get() = kind == "changed"
}

internal data class C05ChallengeApproval(
    val trusted: Boolean,
    val changed: Boolean,
    val challengeID: String,
    val fingerprintSHA256: String?,
)

internal data class C05DeleteResult(
    val deleted: Boolean,
    val closedSessions: Int,
    val closedTunnels: Int,
)

internal data class C05ShutdownResult(
    val closed: Boolean,
    val complete: Boolean,
    val closedPtys: Int,
    val closedExecs: Int,
    val closedTunnels: Int,
)

internal data class C05RootStopResult(
    val drained: Boolean,
    val closedSessions: Int,
    val closedPtys: Int,
    val closedExecs: Int,
    val closedTunnels: Int,
)

internal data class C05Session(
    val id: String,
    val profileID: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val state: String,
    val transportConnected: Boolean,
    val createdAt: String,
    val lastActivityAt: String,
    val ptyCount: Int,
    val execCount: Int,
    val tunnelCount: Int,
)

internal data class C05Pty(
    val id: String,
    val sessionID: String,
    val state: String,
    val columns: Int,
    val rows: Int,
    val totalBytes: Long,
    val rolledOverBytes: Long,
)

internal data class C05PtyPage(
    val ptyID: String,
    val state: String,
    val bytes: ByteArray,
    val nextCursor: Long,
    val lostBytes: Long,
    val totalBytes: Long,
    val rolledOverBytes: Long,
) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

internal data class C05Exec(
    val id: String,
    val sessionID: String,
    val state: String,
    val stdoutBytes: Long,
    val stderrBytes: Long,
    val rolledOverBytes: Long,
    val exitCode: Int?,
    val remoteOutcomeUnknown: Boolean,
)

internal data class C05ExecChunk(val channel: String, val data: ByteArray) {
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

internal data class C05ExecPage(
    val exec: C05Exec,
    val chunks: List<C05ExecChunk>,
    val nextCursor: Long,
    val lostBytes: Long,
)

internal data class C05Tunnel(
    val id: String,
    val sessionID: String,
    val targetHost: String,
    val targetPort: Int,
    val localHost: String,
    val localPort: Int?,
    val state: String,
    val acceptedConnections: Int,
    val activeConnections: Int,
    val bytesToRemote: Long,
    val bytesFromRemote: Long,
    val lastErrorCode: String?,
)

internal data class C05SessionDetail(
    val session: C05Session,
    val ptys: List<C05Pty>,
    val execs: List<C05Exec>,
    val tunnels: List<C05Tunnel>,
)

internal data class C05Capabilities(
    val coreReady: Boolean,
    val epoch: Long?,
    val credentialGatewayReady: Boolean,
    val maximumSessions: Int,
    val maximumPtysPerSession: Int,
    val maximumExecsPerSession: Int,
    val maximumTunnelsPerSession: Int,
    val maximumJumpHops: Int,
    val supportsPty: Boolean,
    val supportsExec: Boolean,
    val supportsTunnels: Boolean,
    val modelTools: Boolean,
)

internal data class C05ProfilePayload(
    val id: String,
    val displayName: String,
    val address: String,
    val port: Int,
    val user: String,
    val auth: C05Auth,
    val jumpChain: List<C05JumpHop>,
    val hostKeyPolicy: String,
    val pinnedFingerprint: String?,
    val allowsLegacyAlgorithms: Boolean,
    val deviceKind: String,
    val isRemoteExecutionEnvironment: Boolean,
    val vncEndpoints: List<C05VncEndpoint>,
    val auxiliaryConnections: List<C05AuxConnection>,
)

// MARK: - JSON helpers

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() && it != "null" }

internal fun JsonObject.requiredString(key: String): String =
    string(key) ?: throw C05RemoteFailure("invalidResponse", "missing_$key")

internal fun JsonObject.intValue(key: String): Int? =
    (this[key] as? JsonPrimitive)?.intOrNull

internal fun JsonObject.longValue(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull

internal fun JsonObject.boolValue(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.booleanOrNull ?: false

internal fun JsonObject.objectValue(key: String): JsonObject? =
    (this[key] as? JsonObject)

internal fun JsonObject.arrayValue(key: String): JsonArray =
    (this[key] as? JsonArray) ?: JsonArray(emptyList())

internal fun JsonElement.asObjectOrNull(): JsonObject? = this as? JsonObject

internal fun JsonObject.parseCredential(key: String): C05CredentialRef? {
    val obj = objectValue(key) ?: return null
    return C05CredentialRef(
        keychainAccount = obj.requiredString("keychainAccount"),
        synchronizable = obj.boolValue("synchronizable"),
    )
}

internal fun parseAuth(obj: JsonObject): C05Auth = C05Auth(
    kind = obj.requiredString("kind"),
    keyType = obj.string("keyType"),
    credential = obj.parseCredential("credential"),
)

internal fun parseChallenge(obj: JsonObject): C05HostKeyChallenge = C05HostKeyChallenge(
    id = obj.requiredString("id"),
    profileID = obj.requiredString("profileID"),
    address = obj.requiredString("address"),
    port = obj.intValue("port") ?: 22,
    keyType = obj.requiredString("keyType"),
    fingerprintSHA256 = obj.requiredString("fingerprintSHA256"),
    expectedFingerprintSHA256 = obj.string("expectedFingerprintSHA256"),
    kind = obj.string("kind") ?: "firstUse",
    createdAt = obj.string("createdAt") ?: "",
    expiresAt = obj.string("expiresAt") ?: "",
)

internal fun parseSummary(obj: JsonObject): C05HostSummary {
    val authObject = obj.objectValue("auth") ?: JsonObject(emptyMap())
    return C05HostSummary(
        id = obj.requiredString("id"),
        displayName = obj.requiredString("displayName"),
        // VNC-only profiles deliberately have no SSH address/user/port.
        address = obj.string("address") ?: "",
        port = obj.intValue("port") ?: 0,
        user = obj.string("user") ?: "",
        auth = parseAuth(authObject),
        deviceKind = obj.string("deviceKind") ?: "unspecified",
        isRemoteExecutionEnvironment = obj.boolValue("isRemoteExecutionEnvironment"),
        hostKeyPolicy = obj.string("hostKeyPolicy") ?: "trustOnFirstUse",
        pinnedFingerprint = obj.string("pinnedFingerprintSHA256"),
        allowsLegacyAlgorithms = obj.boolValue("allowsLegacyAlgorithms"),
        jumpHopCount = obj.intValue("jumpHopCount") ?: 0,
        vncEndpointCount = obj.intValue("vncEndpointCount") ?: 0,
        auxiliaryConnectionCount = obj.intValue("auxiliaryConnectionCount") ?: 0,
    )
}

internal fun parseJump(obj: JsonObject): C05JumpHop = C05JumpHop(
    address = obj.requiredString("address"),
    port = obj.intValue("port") ?: 22,
    user = obj.requiredString("user"),
    auth = parseAuth(obj.objectValue("auth") ?: JsonObject(emptyMap())),
)

internal fun parseVnc(obj: JsonObject): C05VncEndpoint = C05VncEndpoint(
    id = obj.requiredString("id"),
    displayName = obj.string("displayName") ?: "VNC",
    transport = obj.string("transport") ?: "sshTunnel",
    host = obj.string("host") ?: "localhost",
    port = obj.intValue("port") ?: 5900,
    passwordRef = obj.parseCredential("passwordRef"),
)

internal fun parseAux(obj: JsonObject): C05AuxConnection = C05AuxConnection(
    id = obj.requiredString("id"),
    displayName = obj.string("displayName") ?: "",
    kind = obj.string("kind") ?: "tcp",
    host = obj.string("host"),
    port = obj.intValue("port"),
    bluetoothPeripheralID = obj.string("bluetoothPeripheralID"),
    bluetoothServiceUUID = obj.string("bluetoothServiceUUID"),
    bluetoothWriteCharacteristicUUID = obj.string("bluetoothWriteCharacteristicUUID"),
    bluetoothNotifyCharacteristicUUID = obj.string("bluetoothNotifyCharacteristicUUID"),
)

internal fun parseDetail(obj: JsonObject): C05HostDetail = C05HostDetail(
    summary = parseSummary(obj),
    jumpChain = obj.arrayValue("jumpChain").mapNotNull { (it as? JsonObject)?.let(::parseJump) },
    vncEndpoints = obj.arrayValue("vncEndpoints").mapNotNull { (it as? JsonObject)?.let(::parseVnc) },
    auxiliaryConnections = obj.arrayValue("auxiliaryConnections").mapNotNull {
        (it as? JsonObject)?.let(::parseAux)
    },
)

internal fun parseSession(obj: JsonObject): C05Session = C05Session(
    id = obj.requiredString("id"),
    profileID = obj.requiredString("profileID"),
    displayName = obj.string("displayName") ?: "",
    address = obj.string("address") ?: "",
    port = obj.intValue("port") ?: 22,
    user = obj.string("user") ?: "",
    state = obj.string("state") ?: "unknown",
    transportConnected = obj.boolValue("transportConnected"),
    createdAt = obj.string("createdAt") ?: "",
    lastActivityAt = obj.string("lastActivityAt") ?: "",
    ptyCount = obj.intValue("ptyCount") ?: 0,
    execCount = obj.intValue("execCount") ?: 0,
    tunnelCount = obj.intValue("tunnelCount") ?: 0,
)

internal fun parsePty(obj: JsonObject): C05Pty = C05Pty(
    id = obj.requiredString("id"),
    sessionID = obj.requiredString("sessionID"),
    state = obj.string("state") ?: "unknown",
    columns = obj.intValue("columns") ?: 80,
    rows = obj.intValue("rows") ?: 24,
    totalBytes = obj.longValue("totalBytes") ?: 0L,
    rolledOverBytes = obj.longValue("rolledOverBytes") ?: 0L,
)

internal fun parseExec(obj: JsonObject): C05Exec = C05Exec(
    id = obj.requiredString("id"),
    sessionID = obj.requiredString("sessionID"),
    state = obj.string("state") ?: "unknown",
    stdoutBytes = obj.longValue("stdoutBytes") ?: 0L,
    stderrBytes = obj.longValue("stderrBytes") ?: 0L,
    rolledOverBytes = obj.longValue("rolledOverBytes") ?: 0L,
    exitCode = obj.intValue("exitCode"),
    remoteOutcomeUnknown = obj.boolValue("remoteOutcomeUnknown"),
)

internal fun parseTunnel(obj: JsonObject): C05Tunnel = C05Tunnel(
    id = obj.requiredString("id"),
    sessionID = obj.requiredString("sessionID"),
    targetHost = obj.requiredString("targetHost"),
    targetPort = obj.intValue("targetPort") ?: 0,
    localHost = obj.string("localHost") ?: "127.0.0.1",
    localPort = obj.intValue("localPort"),
    state = obj.string("state") ?: "unknown",
    acceptedConnections = obj.intValue("acceptedConnections") ?: 0,
    activeConnections = obj.intValue("activeConnections") ?: 0,
    bytesToRemote = obj.longValue("bytesToRemote") ?: 0L,
    bytesFromRemote = obj.longValue("bytesFromRemote") ?: 0L,
    lastErrorCode = obj.string("lastErrorCode"),
)

internal fun parseSessionDetail(obj: JsonObject): C05SessionDetail {
    val session = parseSession(obj.objectValue("session") ?: JsonObject(emptyMap()))
    return C05SessionDetail(
        session = session,
        ptys = obj.arrayValue("ptys").mapNotNull { (it as? JsonObject)?.let(::parsePty) },
        execs = obj.arrayValue("execs").mapNotNull { (it as? JsonObject)?.let(::parseExec) },
        tunnels = obj.arrayValue("tunnels").mapNotNull { (it as? JsonObject)?.let(::parseTunnel) },
    )
}

internal fun authJson(auth: C05Auth, builder: kotlinx.serialization.json.JsonObjectBuilder) {
    builder.put("kind", auth.kind)
    auth.keyType?.let { builder.put("keyType", it) }
    auth.credential?.let { ref ->
        builder.put("credential", kotlinx.serialization.json.buildJsonObject {
            put("keychainAccount", ref.keychainAccount)
            put("synchronizable", ref.synchronizable)
        })
    }
}

internal fun jumpJson(hop: C05JumpHop): JsonObject = kotlinx.serialization.json.buildJsonObject {
    put("address", hop.address)
    put("port", hop.port)
    put("user", hop.user)
    put("auth", kotlinx.serialization.json.buildJsonObject { authJson(hop.auth, this) })
}

internal fun vncJson(endpoint: C05VncEndpoint): JsonObject = kotlinx.serialization.json.buildJsonObject {
    put("id", endpoint.id)
    put("displayName", endpoint.displayName)
    put("transport", endpoint.transport)
    put("host", endpoint.host)
    put("port", endpoint.port)
    endpoint.passwordRef?.let { ref ->
        put("passwordRef", kotlinx.serialization.json.buildJsonObject {
            put("keychainAccount", ref.keychainAccount)
            put("synchronizable", ref.synchronizable)
        })
    }
}

internal fun auxJson(connection: C05AuxConnection): JsonObject = kotlinx.serialization.json.buildJsonObject {
    put("id", connection.id)
    put("displayName", connection.displayName)
    put("kind", connection.kind)
    connection.host?.let { put("host", it) }
    connection.port?.let { put("port", it) }
    connection.bluetoothPeripheralID?.let { put("bluetoothPeripheralID", it) }
    connection.bluetoothServiceUUID?.let { put("bluetoothServiceUUID", it) }
    connection.bluetoothWriteCharacteristicUUID?.let { put("bluetoothWriteCharacteristicUUID", it) }
    connection.bluetoothNotifyCharacteristicUUID?.let { put("bluetoothNotifyCharacteristicUUID", it) }
}

internal fun C05ProfilePayload.toJson(): JsonObject = kotlinx.serialization.json.buildJsonObject {
    put("id", id)
    put("displayName", displayName)
    put("address", address)
    put("port", port)
    put("user", user)
    put("auth", kotlinx.serialization.json.buildJsonObject { authJson(auth, this) })
    put("jumpChain", kotlinx.serialization.json.buildJsonArray { jumpChain.forEach { add(jumpJson(it)) } })
    put("hostKeyPolicy", kotlinx.serialization.json.buildJsonObject {
        put("kind", hostKeyPolicy)
        if (hostKeyPolicy == "pinned") {
            put("fingerprintSHA256", pinnedFingerprint ?: "")
        }
    })
    put("allowsLegacyAlgorithms", allowsLegacyAlgorithms)
    put("deviceKind", deviceKind)
    put("isRemoteExecutionEnvironment", isRemoteExecutionEnvironment)
    put("vncEndpoints", kotlinx.serialization.json.buildJsonArray { vncEndpoints.forEach { add(vncJson(it)) } })
    put("auxiliaryConnections", kotlinx.serialization.json.buildJsonArray {
        auxiliaryConnections.forEach { add(auxJson(it)) }
    })
}
