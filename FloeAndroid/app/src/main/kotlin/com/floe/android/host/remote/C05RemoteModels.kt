// SPDX-License-Identifier: MPL-2.0
//
// C05 trusted-host client values. These are parsed from the closed
// `floe.remote/9` wire; they never contain a secret body.

package com.floe.android.host.remote

import com.floe.android.bridge.SwiftCore
import kotlinx.serialization.json.Json
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
    val object = objectValue(key) ?: return null
    return C05CredentialRef(
        keychainAccount = object.requiredString("keychainAccount"),
        synchronizable = object.boolValue("synchronizable"),
    )
}

internal fun parseAuth(object: JsonObject): C05Auth = C05Auth(
    kind = object.requiredString("kind"),
    keyType = object.string("keyType"),
    credential = object.parseCredential("credential"),
)

internal fun parseChallenge(object: JsonObject): C05HostKeyChallenge = C05HostKeyChallenge(
    id = object.requiredString("id"),
    profileID = object.requiredString("profileID"),
    address = object.requiredString("address"),
    port = object.intValue("port") ?: 22,
    keyType = object.requiredString("keyType"),
    fingerprintSHA256 = object.requiredString("fingerprintSHA256"),
    expectedFingerprintSHA256 = object.string("expectedFingerprintSHA256"),
    kind = object.string("kind") ?: "firstUse",
    createdAt = object.string("createdAt") ?: "",
    expiresAt = object.string("expiresAt") ?: "",
)

internal fun parseSummary(object: JsonObject): C05HostSummary {
    val authObject = object.objectValue("auth") ?: JsonObject(emptyMap())
    return C05HostSummary(
        id = object.requiredString("id"),
        displayName = object.requiredString("displayName"),
        address = object.requiredString("address"),
        port = object.intValue("port") ?: 22,
        user = object.requiredString("user"),
        auth = parseAuth(authObject),
        deviceKind = object.string("deviceKind") ?: "unspecified",
        isRemoteExecutionEnvironment = object.boolValue("isRemoteExecutionEnvironment"),
        hostKeyPolicy = object.string("hostKeyPolicy") ?: "trustOnFirstUse",
        pinnedFingerprint = object.string("pinnedFingerprintSHA256"),
        allowsLegacyAlgorithms = object.boolValue("allowsLegacyAlgorithms"),
        jumpHopCount = object.intValue("jumpHopCount") ?: 0,
        vncEndpointCount = object.intValue("vncEndpointCount") ?: 0,
        auxiliaryConnectionCount = object.intValue("auxiliaryConnectionCount") ?: 0,
    )
}

internal fun parseJump(object: JsonObject): C05JumpHop = C05JumpHop(
    address = object.requiredString("address"),
    port = object.intValue("port") ?: 22,
    user = object.requiredString("user"),
    auth = parseAuth(object.objectValue("auth") ?: JsonObject(emptyMap())),
)

internal fun parseVnc(object: JsonObject): C05VncEndpoint = C05VncEndpoint(
    id = object.requiredString("id"),
    displayName = object.string("displayName") ?: "VNC",
    transport = object.string("transport") ?: "sshTunnel",
    host = object.string("host") ?: "localhost",
    port = object.intValue("port") ?: 5900,
    passwordRef = object.parseCredential("passwordRef"),
)

internal fun parseAux(object: JsonObject): C05AuxConnection = C05AuxConnection(
    id = object.requiredString("id"),
    displayName = object.string("displayName") ?: "",
    kind = object.string("kind") ?: "tcp",
    host = object.string("host"),
    port = object.intValue("port"),
    bluetoothPeripheralID = object.string("bluetoothPeripheralID"),
    bluetoothServiceUUID = object.string("bluetoothServiceUUID"),
    bluetoothWriteCharacteristicUUID = object.string("bluetoothWriteCharacteristicUUID"),
    bluetoothNotifyCharacteristicUUID = object.string("bluetoothNotifyCharacteristicUUID"),
)

internal fun parseDetail(object: JsonObject): C05HostDetail = C05HostDetail(
    summary = parseSummary(object),
    jumpChain = object.arrayValue("jumpChain").mapNotNull { (it as? JsonObject)?.let(::parseJump) },
    vncEndpoints = object.arrayValue("vncEndpoints").mapNotNull { (it as? JsonObject)?.let(::parseVnc) },
    auxiliaryConnections = object.arrayValue("auxiliaryConnections").mapNotNull {
        (it as? JsonObject)?.let(::parseAux)
    },
)

internal fun parseSession(object: JsonObject): C05Session = C05Session(
    id = object.requiredString("id"),
    profileID = object.requiredString("profileID"),
    displayName = object.string("displayName") ?: "",
    address = object.string("address") ?: "",
    port = object.intValue("port") ?: 22,
    user = object.string("user") ?: "",
    state = object.string("state") ?: "unknown",
    transportConnected = object.boolValue("transportConnected"),
    createdAt = object.string("createdAt") ?: "",
    lastActivityAt = object.string("lastActivityAt") ?: "",
    ptyCount = object.intValue("ptyCount") ?: 0,
    execCount = object.intValue("execCount") ?: 0,
    tunnelCount = object.intValue("tunnelCount") ?: 0,
)

internal fun parsePty(object: JsonObject): C05Pty = C05Pty(
    id = object.requiredString("id"),
    sessionID = object.requiredString("sessionID"),
    state = object.string("state") ?: "unknown",
    columns = object.intValue("columns") ?: 80,
    rows = object.intValue("rows") ?: 24,
    totalBytes = object.longValue("totalBytes") ?: 0L,
    rolledOverBytes = object.longValue("rolledOverBytes") ?: 0L,
)

internal fun parseExec(object: JsonObject): C05Exec = C05Exec(
    id = object.requiredString("id"),
    sessionID = object.requiredString("sessionID"),
    state = object.string("state") ?: "unknown",
    stdoutBytes = object.longValue("stdoutBytes") ?: 0L,
    stderrBytes = object.longValue("stderrBytes") ?: 0L,
    rolledOverBytes = object.longValue("rolledOverBytes") ?: 0L,
    exitCode = object.intValue("exitCode"),
    remoteOutcomeUnknown = object.boolValue("remoteOutcomeUnknown"),
)

internal fun parseTunnel(object: JsonObject): C05Tunnel = C05Tunnel(
    id = object.requiredString("id"),
    sessionID = object.requiredString("sessionID"),
    targetHost = object.requiredString("targetHost"),
    targetPort = object.intValue("targetPort") ?: 0,
    localHost = object.string("localHost") ?: "127.0.0.1",
    localPort = object.intValue("localPort"),
    state = object.string("state") ?: "unknown",
    acceptedConnections = object.intValue("acceptedConnections") ?: 0,
    activeConnections = object.intValue("activeConnections") ?: 0,
    bytesToRemote = object.longValue("bytesToRemote") ?: 0L,
    bytesFromRemote = object.longValue("bytesFromRemote") ?: 0L,
    lastErrorCode = object.string("lastErrorCode"),
)

internal fun parseSessionDetail(object: JsonObject): C05SessionDetail {
    val session = parseSession(object.objectValue("session") ?: JsonObject(emptyMap()))
    return C05SessionDetail(
        session = session,
        ptys = object.arrayValue("ptys").mapNotNull { (it as? JsonObject)?.let(::parsePty) },
        execs = object.arrayValue("execs").mapNotNull { (it as? JsonObject)?.let(::parseExec) },
        tunnels = object.arrayValue("tunnels").mapNotNull { (it as? JsonObject)?.let(::parseTunnel) },
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
