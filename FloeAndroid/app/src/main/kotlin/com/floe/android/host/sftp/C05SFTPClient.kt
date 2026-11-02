// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.sftp/18` bridge. Every call is
// made off the main thread by the App-owned controller. Upload chunks are
// base64-encoded once into the bounded request and dropped immediately.

package com.floe.android.host.sftp

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

internal class C05SFTPClient(
    private val transport: C05SFTPTransport = SwiftC05SFTPTransport,
) {
    private val json = Json { ignoreUnknownKeys = true }

    fun capabilities(): Boolean {
        val response = exchange(request("c05.sftp.capabilities"))
        return response.boolValue("coreReady")
    }

    fun hosts(owner: C05SFTPOwner): List<C05SFTPHost> {
        val response = exchange(request("c05.sftp.hosts") { putOwner(owner) })
        return response.arrayValue("hosts").mapNotNull { (it as? JsonObject)?.let(::parseHost) }
    }

    fun connect(profileID: String, owner: C05SFTPOwner): C05SFTPLane {
        val response = exchange(request("c05.sftp.connect") {
            putOwner(owner)
            put("profileID", profileID)
        })
        return parseLane(response.objectValue("lane") ?: throw invalid("missingLane"))
    }

    fun disconnect(laneID: String, owner: C05SFTPOwner) {
        exchange(request("c05.sftp.disconnect") {
            putOwner(owner)
            put("laneID", laneID)
        })
    }

    fun hostKeyList(owner: C05SFTPOwner): List<C05SFTPChallenge> {
        val response = exchange(request("c05.sftp.hostkey.list") { putOwner(owner) })
        return response.arrayValue("challenges").mapNotNull {
            (it as? JsonObject)?.let(::parseChallenge)
        }
    }

    fun hostKeyApprove(
        challengeID: String,
        accept: Boolean,
        replaceChanged: Boolean,
        owner: C05SFTPOwner,
    ): Boolean {
        val response = exchange(request("c05.sftp.hostkey.approve") {
            putOwner(owner)
            put("challengeID", challengeID)
            put("accept", accept)
            put("replaceChanged", replaceChanged)
        })
        return response.boolValue("trusted")
    }

    fun list(
        laneID: String,
        path: String,
        offset: Int,
        limit: Int,
        owner: C05SFTPOwner,
    ): C05SFTPPage {
        val response = exchange(request("c05.sftp.list") {
            putOwner(owner)
            put("laneID", laneID)
            put("path", path)
            put("offset", offset)
            put("limit", limit)
        })
        return C05SFTPPage(
            path = response.string("path") ?: path,
            canonicalPath = response.string("canonicalPath") ?: path,
            entries = response.arrayValue("entries").mapNotNull {
                (it as? JsonObject)?.let(::parseEntry)
            },
            nextOffset = response.intValue("nextOffset") ?: 0,
            truncated = response.boolValue("truncated"),
        )
    }

    fun stat(laneID: String, path: String, owner: C05SFTPOwner): C05SFTPEntry {
        val response = exchange(request("c05.sftp.stat") {
            putOwner(owner)
            put("laneID", laneID)
            put("path", path)
        })
        return parseEntry(response.objectValue("entry") ?: throw invalid("missingEntry"))
            ?: throw invalid("invalidEntry")
    }

    fun revision(laneID: String, path: String, owner: C05SFTPOwner): C05SFTPEntry {
        val response = exchange(request("c05.sftp.revision") {
            putOwner(owner)
            put("laneID", laneID)
            put("path", path)
        })
        return parseEntry(response.objectValue("entry") ?: throw invalid("missingEntry"))
            ?: throw invalid("invalidEntry")
    }

    fun destinationRevision(
        taskID: String,
        relativePath: String,
        owner: C05SFTPOwner,
    ): C05SFTPRevision {
        val response = exchange(request("c05.sftp.destination.revision") {
            putOwner(owner)
            put("destination", buildJsonObject {
                put("kind", "task")
                put("taskID", taskID)
                put("relativePath", relativePath)
            })
        })
        return C05SFTPRevision(
            exists = response.boolValue("exists"),
            bytes = response.longValue("bytes") ?: 0,
            revision = response.string("revision"),
        )
    }

    fun startDownload(
        laneID: String,
        remotePath: String,
        taskID: String,
        relativePath: String,
        overwrite: Boolean,
        expectedRevision: String?,
        owner: C05SFTPOwner,
    ): C05SFTPTransfer {
        val response = exchange(request("c05.sftp.download.start") {
            putOwner(owner)
            put("laneID", laneID)
            put("remotePath", remotePath)
            put("destination", buildJsonObject {
                put("kind", "task")
                put("taskID", taskID)
                put("relativePath", relativePath)
            })
            put("overwrite", overwrite)
            expectedRevision?.let { put("expectedRevision", it) }
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun startUpload(
        laneID: String,
        remotePath: String,
        displayName: String,
        totalBytes: Long,
        sha256: String?,
        owner: C05SFTPOwner,
    ): C05SFTPTransfer {
        val response = exchange(request("c05.sftp.upload.start") {
            putOwner(owner)
            put("laneID", laneID)
            put("remotePath", remotePath)
            put("displayName", displayName)
            put("totalBytes", totalBytes)
            sha256?.let { put("sha256", it) }
            put("overwrite", false)
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun writeUpload(
        transferID: String,
        offset: Long,
        data: ByteArray,
        owner: C05SFTPOwner,
    ): C05SFTPTransfer {
        val encoded = Base64.getEncoder().encodeToString(data)
        val response = exchange(request("c05.sftp.upload.write") {
            putOwner(owner)
            put("transferID", transferID)
            put("offset", offset)
            put("dataBase64", encoded)
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun finishUpload(
        transferID: String,
        sha256: String,
        owner: C05SFTPOwner,
    ): C05SFTPTransfer {
        val response = exchange(request("c05.sftp.upload.finish") {
            putOwner(owner)
            put("transferID", transferID)
            put("sha256", sha256)
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun transferStatus(transferID: String, owner: C05SFTPOwner): C05SFTPTransfer {
        val response = exchange(request("c05.sftp.transfer.status") {
            putOwner(owner)
            put("transferID", transferID)
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun cancelTransfer(transferID: String, owner: C05SFTPOwner): C05SFTPTransfer {
        val response = exchange(request("c05.sftp.transfer.cancel") {
            putOwner(owner)
            put("transferID", transferID)
        })
        return parseTransfer(response.objectValue("transfer") ?: throw invalid("missingTransfer"))
    }

    fun releaseTransfer(transferID: String, owner: C05SFTPOwner) {
        exchange(request("c05.sftp.transfer.release") {
            putOwner(owner)
            put("transferID", transferID)
        })
    }

    fun rootStop(epoch: Long) {
        exchange(request("c05.sftp.rootStop") { put("expectedEpoch", epoch) })
    }

    private fun request(
        operation: String,
        builder: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit = {},
    ): JsonObject = buildJsonObject {
        put("version", C05_SFTP_VERSION)
        put("operation", operation)
        put("requestID", UUID.randomUUID().toString())
        builder()
    }

    private fun exchange(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (error: Throwable) {
            throw C05SFTPFailure("coreUnavailable", "bridgeUnavailable", retryable = true)
        }
        val objectValue = try {
            json.parseToJsonElement(raw).jsonObject
        } catch (_: Throwable) {
            throw C05SFTPFailure("invalidResponse", "invalidBridgeResponse")
        }
        if ((objectValue["ok"] as? JsonPrimitive)?.contentOrNull != "true") {
            val error = objectValue.string("error")
            val code = when (error) {
                "unsupportedVersion", "unsupportedOperation" -> "needsCoreUpdate"
                else -> objectValue.string("code") ?: error ?: "unknown"
            }
            throw C05SFTPFailure(
                code = code,
                reason = objectValue.string("reason"),
                retryable = objectValue.boolValue("retryable"),
                detail = objectValue.string("detail"),
                retainedPath = objectValue.string("retainedPath"),
                challenge = objectValue.objectValue("challenge")?.let(::parseChallenge),
            )
        }
        val declared = objectValue.string("operation")
        if (declared != null &&
            declared != (request["operation"] as? JsonPrimitive)?.contentOrNull
        ) {
            throw C05SFTPFailure("invalidResponse", "operationMismatch")
        }
        return objectValue
    }

    private fun parseHost(value: JsonObject): C05SFTPHost? {
        val id = value.string("id") ?: return null
        return C05SFTPHost(
            id = id,
            displayName = value.string("displayName") ?: id,
            address = value.string("address") ?: "",
            port = value.intValue("port") ?: 22,
            user = value.string("user") ?: "",
        )
    }

    private fun parseLane(value: JsonObject): C05SFTPLane = C05SFTPLane(
        id = value.requiredString("id"),
        profileID = value.string("profileID") ?: "",
        displayName = value.string("displayName") ?: "SFTP",
        address = value.string("address") ?: "",
        port = value.intValue("port") ?: 22,
        user = value.string("user") ?: "",
        state = value.string("state") ?: "unknown",
        homePath = value.string("homePath") ?: "/",
    )

    private fun parseEntry(value: JsonObject): C05SFTPEntry? {
        val path = value.string("path") ?: return null
        return C05SFTPEntry(
            name = value.string("name") ?: path.substringAfterLast('/'),
            path = path,
            isDirectory = value.boolValue("isDirectory"),
            isSymbolicLink = value.boolValue("isSymbolicLink"),
            bytes = value.longValue("bytes") ?: 0,
            modifiedAt = value.string("modifiedAt"),
            revision = value.string("revision") ?: "",
        )
    }

    private fun parseTransfer(value: JsonObject): C05SFTPTransfer = C05SFTPTransfer(
        id = value.requiredString("id"),
        kind = value.string("kind") ?: "",
        remotePath = value.string("remotePath") ?: "",
        displayName = value.string("displayName") ?: "",
        state = value.string("state") ?: "failed",
        bytesDone = value.longValue("bytesDone") ?: 0,
        totalBytes = value.longValue("totalBytes") ?: 0,
        sha256 = value.string("sha256"),
        errorCode = value.string("errorCode"),
    )

    private fun parseChallenge(value: JsonObject): C05SFTPChallenge = C05SFTPChallenge(
        id = value.requiredString("id"),
        profileID = value.string("profileID") ?: "",
        address = value.string("address") ?: "",
        port = value.intValue("port") ?: 22,
        keyType = value.string("keyType") ?: "",
        fingerprintSHA256 = value.string("fingerprintSHA256") ?: "",
        expectedFingerprintSHA256 = value.string("expectedFingerprintSHA256"),
        changed = value.string("kind") == "changed",
    )

    private fun invalid(reason: String): C05SFTPFailure =
        C05SFTPFailure("invalidResponse", reason)

    private fun kotlinx.serialization.json.JsonObjectBuilder.putOwner(owner: C05SFTPOwner) {
        put("owner", buildJsonObject {
            put("token", owner.token)
            put("nativeEpoch", owner.nativeEpoch)
            owner.taskID?.let { put("taskID", it) }
            put("temporary", owner.temporary)
        })
    }
}

private fun JsonObject.requiredString(key: String): String =
    string(key) ?: throw C05SFTPFailure("invalidResponse", "missing_$key")

internal fun JsonObject.string(key: String): String? =
    (this[key] as? JsonPrimitive)?.contentOrNull

internal fun JsonObject.objectValue(key: String): JsonObject? =
    this[key] as? JsonObject

internal fun JsonObject.arrayValue(key: String): List<kotlinx.serialization.json.JsonElement> =
    (this[key] as? JsonArray) ?: emptyList()

internal fun JsonObject.boolValue(key: String): Boolean =
    (this[key] as? JsonPrimitive)?.contentOrNull == "true"

internal fun JsonObject.intValue(key: String): Int? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toIntOrNull()

internal fun JsonObject.longValue(key: String): Long? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
