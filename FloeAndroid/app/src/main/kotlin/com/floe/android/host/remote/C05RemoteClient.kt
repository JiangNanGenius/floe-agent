// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.remote/9` bridge. Every call is
// made off the main thread by the App-owned controller. No secret body is
// retained; credential bytes are base64-encoded once into the gateway
// request and dropped immediately.

package com.floe.android.host.remote

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal class C05RemoteClient(
    private val transport: C05RemoteTransport = SwiftC05RemoteTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }

    // MARK: - Capability / profile

    fun capabilities(): C05Capabilities {
        val response = exchange(request("c05.capabilities"))
        return C05Capabilities(
            coreReady = response.boolValue("coreReady"),
            epoch = response.longValue("epoch"),
            credentialGatewayReady = response.boolValue("credentialGatewayReady"),
            maximumSessions = response.intValue("maximumSessions") ?: 0,
            maximumPtysPerSession = response.intValue("maximumPTYsPerSession") ?: 0,
            maximumExecsPerSession = response.intValue("maximumExecsPerSession") ?: 0,
            maximumTunnelsPerSession = response.intValue("maximumTunnelsPerSession") ?: 0,
            maximumJumpHops = response.intValue("maximumJumpHops") ?: 0,
            supportsPty = response.boolValue("supportsPTY"),
            supportsExec = response.boolValue("supportsExec"),
            supportsTunnels = response.boolValue("supportsTunnels"),
            modelTools = response.boolValue("modelTools"),
        )
    }

    fun profileList(owner: C05RemoteOwner): List<C05HostSummary> {
        val response = exchange(request("c05.profile.list") { putOwner(owner) })
        return response.arrayValue("hosts").mapNotNull { (it as? JsonObject)?.let(::parseSummary) }
    }

    fun profileGet(profileID: String, owner: C05RemoteOwner): C05HostDetail {
        val response = exchange(request("c05.profile.get") {
            putOwner(owner)
            put("profileID", profileID)
        })
        return parseDetail(response.objectValue("host") ?: throw invalid("missingHost"))
    }

    fun profileSave(payload: C05ProfilePayload, owner: C05RemoteOwner): C05HostDetail {
        val response = exchange(request("c05.profile.save") {
            putOwner(owner)
            put("profile", payload.toJson())
        })
        return parseDetail(response.objectValue("host") ?: throw invalid("missingHost"))
    }

    fun profileDelete(profileID: String, owner: C05RemoteOwner): C05DeleteResult {
        val response = exchange(request("c05.profile.delete") {
            putOwner(owner)
            put("profileID", profileID)
        })
        return C05DeleteResult(
            deleted = response.boolValue("deleted"),
            closedSessions = response.intValue("closedSessions") ?: 0,
            closedTunnels = response.intValue("closedTunnels") ?: 0,
        )
    }

    // MARK: - Credentials

    fun credentialSave(
        account: String,
        synchronizable: Boolean,
        secret: ByteArray,
        owner: C05RemoteOwner,
    ): C05CredentialRef {
        if (secret.isEmpty() || secret.size > MAX_SECRET_BYTES) {
            throw C05RemoteFailure("credentialInvalid", "invalidCredentialSize")
        }
        val encoded = Base64.getEncoder().encodeToString(secret)
        if (encoded.length > 60_000) {
            throw C05RemoteFailure("credentialInvalid", "credentialTooLarge")
        }
        val response = exchange(request("c05.credential.save") {
            putOwner(owner)
            put("credential", buildJsonObject {
                put("keychainAccount", account)
                put("synchronizable", synchronizable)
            })
            put("secretBase64", encoded)
        })
        val ref = response.objectValue("reference") ?: throw invalid("missingCredentialReference")
        return C05CredentialRef(
            keychainAccount = ref.requiredString("keychainAccount"),
            synchronizable = ref.boolValue("synchronizable"),
        )
    }

    fun credentialProbe(reference: C05CredentialRef): Boolean {
        val response = exchange(request("c05.credential.probe") {
            put("credential", credentialJson(reference))
        })
        return response.boolValue("present")
    }

    fun credentialDelete(reference: C05CredentialRef) {
        exchange(request("c05.credential.delete") {
            put("credential", credentialJson(reference))
        })
    }

    // MARK: - Sessions

    fun connect(profileID: String, owner: C05RemoteOwner): C05Session {
        val response = exchange(request("c05.connect") {
            putOwner(owner)
            put("profileID", profileID)
        })
        return parseSession(response.objectValue("session") ?: throw invalid("missingSession"))
    }

    fun sessionList(owner: C05RemoteOwner): List<C05Session> {
        val response = exchange(request("c05.session.list") { putOwner(owner) })
        return response.arrayValue("sessions").mapNotNull { (it as? JsonObject)?.let(::parseSession) }
    }

    fun sessionStatus(sessionID: String, owner: C05RemoteOwner): C05SessionDetail {
        val response = exchange(request("c05.session.status") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return parseSessionDetail(response)
    }

    fun sessionClose(sessionID: String, owner: C05RemoteOwner): C05ShutdownResult {
        val response = exchange(request("c05.session.close") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return C05ShutdownResult(
            closed = response.boolValue("closed"),
            complete = response.boolValue("complete"),
            closedPtys = response.intValue("closedPTYs") ?: 0,
            closedExecs = response.intValue("closedExecs") ?: 0,
            closedTunnels = response.intValue("closedTunnels") ?: 0,
        )
    }

    // MARK: - Host keys

    fun hostKeyList(owner: C05RemoteOwner): List<C05HostKeyChallenge> {
        val response = exchange(request("c05.hostkey.list") { putOwner(owner) })
        return response.arrayValue("challenges").mapNotNull { (it as? JsonObject)?.let(::parseChallenge) }
    }

    fun hostKeyApprove(
        challengeID: String,
        accept: Boolean,
        replaceChanged: Boolean,
        expectedFingerprint: String?,
        owner: C05RemoteOwner,
    ): C05ChallengeApproval {
        val response = exchange(request("c05.hostkey.approve") {
            putOwner(owner)
            put("challengeID", challengeID)
            put("accept", accept)
            put("replaceChanged", replaceChanged)
            expectedFingerprint?.let { put("expectedFingerprint", it) }
        })
        return C05ChallengeApproval(
            trusted = response.boolValue("trusted"),
            changed = response.boolValue("changed"),
            challengeID = response.string("challengeID") ?: challengeID,
            fingerprintSHA256 = response.string("fingerprintSHA256"),
        )
    }

    // MARK: - PTY

    fun ptyOpen(
        sessionID: String,
        term: String,
        columns: Int,
        rows: Int,
        owner: C05RemoteOwner,
    ): C05Pty {
        val response = exchange(request("c05.pty.open") {
            putOwner(owner)
            put("sessionID", sessionID)
            put("term", term)
            put("columns", columns)
            put("rows", rows)
        })
        return parsePty(response.objectValue("pty") ?: throw invalid("missingPty"))
    }

    fun ptyRead(ptyID: String, cursor: Long, maxBytes: Int, owner: C05RemoteOwner): C05PtyPage {
        val response = exchange(request("c05.pty.read") {
            putOwner(owner)
            put("ptyID", ptyID)
            put("cursor", cursor)
            put("maxBytes", maxBytes)
        })
        val encoded = response.string("dataBase64").orEmpty()
        val bytes = if (encoded.isEmpty()) ByteArray(0) else {
            try {
                Base64.getDecoder().decode(encoded)
            } catch (_: IllegalArgumentException) {
                throw invalid("invalidPTYPage")
            }
        }
        return C05PtyPage(
            ptyID = response.string("ptyID") ?: ptyID,
            state = response.string("state") ?: "unknown",
            bytes = bytes,
            nextCursor = response.longValue("nextCursor") ?: cursor,
            lostBytes = response.longValue("lostBytes") ?: 0L,
            totalBytes = response.longValue("totalBytes") ?: 0L,
            rolledOverBytes = response.longValue("rolledOverBytes") ?: 0L,
        )
    }

    fun ptyWrite(ptyID: String, data: ByteArray, owner: C05RemoteOwner): Int {
        if (data.isEmpty()) return 0
        if (data.size > MAX_WRITE_BYTES) throw C05RemoteFailure("invalidRequest", "ptyWriteTooLarge")
        val response = exchange(request("c05.pty.write") {
            putOwner(owner)
            put("ptyID", ptyID)
            put("dataBase64", Base64.getEncoder().encodeToString(data))
        })
        return response.intValue("accepted") ?: data.size
    }

    fun ptyResize(ptyID: String, columns: Int, rows: Int, owner: C05RemoteOwner): C05Pty {
        val response = exchange(request("c05.pty.resize") {
            putOwner(owner)
            put("ptyID", ptyID)
            put("columns", columns)
            put("rows", rows)
        })
        return parsePty(response.objectValue("pty") ?: throw invalid("missingPty"))
    }

    fun ptyClose(ptyID: String, owner: C05RemoteOwner): Boolean {
        val response = exchange(request("c05.pty.close") {
            putOwner(owner)
            put("ptyID", ptyID)
        })
        return response.boolValue("complete")
    }

    fun ptyList(sessionID: String, owner: C05RemoteOwner): List<C05Pty> {
        val response = exchange(request("c05.pty.list") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return response.arrayValue("ptys").mapNotNull { (it as? JsonObject)?.let(::parsePty) }
    }

    // MARK: - Exec

    fun execStart(sessionID: String, command: String, owner: C05RemoteOwner): C05Exec {
        val response = exchange(request("c05.exec.start") {
            putOwner(owner)
            put("sessionID", sessionID)
            put("command", command)
        })
        return parseExec(response.objectValue("exec") ?: throw invalid("missingExec"))
    }

    fun execRead(execID: String, cursor: Long, maxBytes: Int, owner: C05RemoteOwner): C05ExecPage {
        val response = exchange(request("c05.exec.read") {
            putOwner(owner)
            put("execID", execID)
            put("cursor", cursor)
            put("maxBytes", maxBytes)
        })
        val chunks = response.arrayValue("chunks").mapNotNull { element ->
            val objectValue = element as? JsonObject ?: return@mapNotNull null
            val encoded = objectValue.string("dataBase64").orEmpty()
            val bytes = if (encoded.isEmpty()) ByteArray(0) else {
                try {
                    Base64.getDecoder().decode(encoded)
                } catch (_: IllegalArgumentException) {
                    throw invalid("invalidExecPage")
                }
            }
            C05ExecChunk(
                channel = objectValue.string("channel") ?: "stdout",
                data = bytes,
            )
        }
        return C05ExecPage(
            exec = parseExec(response.objectValue("exec") ?: throw invalid("missingExec")),
            chunks = chunks,
            nextCursor = response.longValue("nextCursor") ?: cursor,
            lostBytes = response.longValue("lostBytes") ?: 0L,
        )
    }

    fun execCancel(execID: String, owner: C05RemoteOwner): C05Exec {
        val response = exchange(request("c05.exec.cancel") {
            putOwner(owner)
            put("execID", execID)
        })
        return parseExec(response.objectValue("exec") ?: throw invalid("missingExec"))
    }

    fun execRelease(execID: String, owner: C05RemoteOwner): Boolean {
        val response = exchange(request("c05.exec.release") {
            putOwner(owner)
            put("execID", execID)
        })
        return response.boolValue("released")
    }

    fun execList(sessionID: String, owner: C05RemoteOwner): List<C05Exec> {
        val response = exchange(request("c05.exec.list") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return response.arrayValue("execs").mapNotNull { (it as? JsonObject)?.let(::parseExec) }
    }

    // MARK: - Tunnels

    fun tunnelOpen(
        sessionID: String,
        targetHost: String,
        targetPort: Int,
        owner: C05RemoteOwner,
    ): C05Tunnel {
        val response = exchange(request("c05.tunnel.open") {
            putOwner(owner)
            put("sessionID", sessionID)
            put("targetHost", targetHost)
            put("targetPort", targetPort)
        })
        return parseTunnel(response.objectValue("tunnel") ?: throw invalid("missingTunnel"))
    }

    fun tunnelList(sessionID: String, owner: C05RemoteOwner): List<C05Tunnel> {
        val response = exchange(request("c05.tunnel.list") {
            putOwner(owner)
            put("sessionID", sessionID)
        })
        return response.arrayValue("tunnels").mapNotNull { (it as? JsonObject)?.let(::parseTunnel) }
    }

    fun tunnelStatus(tunnelID: String, owner: C05RemoteOwner): C05Tunnel {
        val response = exchange(request("c05.tunnel.status") {
            putOwner(owner)
            put("tunnelID", tunnelID)
        })
        return parseTunnel(response.objectValue("tunnel") ?: throw invalid("missingTunnel"))
    }

    fun tunnelClose(tunnelID: String, owner: C05RemoteOwner): C05Tunnel {
        val response = exchange(request("c05.tunnel.close") {
            putOwner(owner)
            put("tunnelID", tunnelID)
        })
        return parseTunnel(response.objectValue("tunnel") ?: throw invalid("missingTunnel"))
    }

    // MARK: - Lifecycle

    fun cancelAll(owner: C05RemoteOwner): C05RootStopResult {
        val response = exchange(request("c05.cancelAll") { putOwner(owner) })
        return rootStop(response)
    }

    fun rootStop(expectedEpoch: Long): C05RootStopResult {
        val response = exchange(request("c05.rootStop") {
            put("expectedEpoch", expectedEpoch)
        })
        return rootStop(response)
    }

    // MARK: - Request/response plumbing

    private fun request(
        operation: String,
        builder: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject = buildJsonObject {
        put("version", C05_REMOTE_VERSION)
        put("operation", operation)
        put("requestID", UUID.randomUUID().toString())
        builder()
    }

    private fun exchange(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (error: Throwable) {
            throw C05RemoteFailure("coreUnavailable", "bridgeUnavailable", retryable = true)
        }
        val objectValue = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) {
            throw C05RemoteFailure("invalidResponse", "invalidBridgeResponse")
        }
        if ((objectValue["ok"] as? JsonPrimitive)?.contentOrNull != "true") {
            val error = objectValue.string("error")
            val code = when (error) {
                "unsupportedVersion" -> "needsCoreUpdate"
                "unsupportedOperation" -> "needsCoreUpdate"
                else -> objectValue.string("code") ?: error ?: "unknown"
            }
            val challenge = objectValue.objectValue("challenge")?.let(::parseChallenge)
            throw C05RemoteFailure(
                code = code,
                reason = objectValue.string("reason"),
                retryable = objectValue.boolValue("retryable"),
                detail = objectValue.string("detail"),
                challenge = challenge,
            )
        }
        val declaredOperation = objectValue.string("operation")
        if (declaredOperation != null &&
            declaredOperation != (request["operation"] as? JsonPrimitive)?.contentOrNull
        ) {
            throw C05RemoteFailure("invalidResponse", "operationMismatch")
        }
        return objectValue
    }

    private fun rootStop(response: JsonObject): C05RootStopResult = C05RootStopResult(
        drained = response.boolValue("drained"),
        closedSessions = response.intValue("closedSessions") ?: 0,
        closedPtys = response.intValue("closedPTYs") ?: 0,
        closedExecs = response.intValue("closedExecs") ?: 0,
        closedTunnels = response.intValue("closedTunnels") ?: 0,
    )

    private fun kotlinx.serialization.json.JsonObjectBuilder.putOwner(owner: C05RemoteOwner) {
        put("owner", buildJsonObject {
            put("token", owner.token)
            put("nativeEpoch", owner.nativeEpoch)
            owner.taskID?.let { put("taskID", it) }
            put("temporary", owner.temporary)
        })
    }

    private fun credentialJson(reference: C05CredentialRef): JsonObject = buildJsonObject {
        put("keychainAccount", reference.keychainAccount)
        put("synchronizable", reference.synchronizable)
    }

    private fun invalid(reason: String): C05RemoteFailure =
        C05RemoteFailure("invalidResponse", reason)

    companion object {
        const val MAX_WRITE_BYTES = 32 * 1024
        const val MAX_SECRET_BYTES = 40 * 1024
    }
}

internal data class C05RemoteOwner(
    val token: String,
    val nativeEpoch: Long,
    val taskID: String? = null,
    val temporary: Boolean = false,
)
