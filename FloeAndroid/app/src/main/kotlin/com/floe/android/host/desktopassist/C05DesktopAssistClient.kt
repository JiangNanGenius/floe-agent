// SPDX-License-Identifier: MPL-2.0
//
// Synchronous client for the trusted `floe.desktopassist/22` host channel.
// The controller calls it off the main thread. It carries secret-free card
// metadata both ways and one bounded one-time secret on create/update only.

package com.floe.android.host.desktopassist

import com.floe.android.feature.desktopassist.DesktopAssistCardUi
import com.floe.android.feature.desktopassist.DesktopAssistHostUi
import com.floe.android.feature.desktopassist.DesktopAssistKinds
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteTransport
import com.floe.android.host.remote.SwiftC05RemoteTransport
import com.floe.android.host.remote.arrayValue
import com.floe.android.host.remote.boolValue
import com.floe.android.host.remote.objectValue
import com.floe.android.host.remote.string
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

internal data class DesktopAssistCapabilities(
    val coreReady: Boolean,
    val epoch: Long?,
    val cardManagementReady: Boolean,
    val linuxShellQualified: Boolean,
)

internal interface DesktopAssistHostPort {
    fun ocrStatus(epoch: Long): Boolean
    fun listCards(epoch: Long): List<DesktopAssistCardUi>
    fun listHosts(epoch: Long): List<DesktopAssistHostUi>
    override fun createCard(
        epoch: Long,
        label: String,
        kind: String,
        secret: String,
        hostID: String?,
    ): DesktopAssistCardUi
    fun updateCard(epoch: Long, id: String, label: String?, secret: String?): DesktopAssistCardUi
    fun deleteCard(epoch: Long, id: String)
}

internal class C05DesktopAssistClient(
    private val transport: C05RemoteTransport = SwiftC05RemoteTransport,
    private val ownerToken: String = UUID.randomUUID().toString(),
) : DesktopAssistHostPort {
    private val json = Json { ignoreUnknownKeys = true }

    fun capabilities(): DesktopAssistCapabilities {
        val response = exchange(request("c05.desktopassist.capabilities"))
        return DesktopAssistCapabilities(
            coreReady = response.boolValue("coreReady"),
            epoch = response["epoch"]?.let { element ->
                (element as? JsonPrimitive)?.contentOrNull?.toLongOrNull()
            },
            cardManagementReady = response.boolValue("cardManagementReady"),
            linuxShellQualified = response.boolValue("linuxShellQualified"),
        )
    }

    override fun ocrStatus(epoch: Long): Boolean =
        exchange(request("c05.desktopassist.ocr.status") {
            putOwner(epoch)
        }).boolValue("linuxShellQualified")

    override fun listCards(epoch: Long): List<DesktopAssistCardUi> {
        val response = exchange(request("c05.desktopassist.cards.list") {
            putOwner(epoch)
        })
        return response.arrayValue("cards").mapNotNull { element ->
            (element as? JsonObject)?.let(::parseCard)
        }
    }

    override fun listHosts(epoch: Long): List<DesktopAssistHostUi> {
        val response = exchange(request("c05.desktopassist.hosts.list") {
            putOwner(epoch)
        })
        return response.arrayValue("hosts").mapNotNull { element ->
            val objectValue = element as? JsonObject ?: return@mapNotNull null
            val id = objectValue.string("id") ?: return@mapNotNull null
            val displayName = objectValue.string("displayName") ?: id
            DesktopAssistHostUi(
                id = id,
                displayName = displayName,
                address = objectValue.string("address") ?: "",
            )
        }
    }

    override fun createCard(
        epoch: Long,
        label: String,
        kind: String,
        secret: String,
        hostID: String?,
    ): DesktopAssistCardUi {
        val response = exchange(request("c05.desktopassist.cards.create") {
            putOwner(epoch)
            put("label", label)
            put("kind", kind)
            put("secret", secret)
            hostID?.let { put("hostID", it) }
        })
        return parseCard(
            response.objectValue("card")
                ?: throw C05RemoteFailure("invalidResponse", "missingCard"),
        )
    }

    override fun updateCard(
        epoch: Long,
        id: String,
        label: String?,
        secret: String?,
    ): DesktopAssistCardUi {
        val response = exchange(request("c05.desktopassist.cards.update") {
            putOwner(epoch)
            put("id", id)
            label?.let { put("label", it) }
            secret?.let { put("secret", it) }
        })
        return parseCard(
            response.objectValue("card")
                ?: throw C05RemoteFailure("invalidResponse", "missingCard"),
        )
    }

    override fun deleteCard(epoch: Long, id: String) {
        exchange(request("c05.desktopassist.cards.delete") {
            putOwner(epoch)
            put("id", id)
        })
    }

    private fun parseCard(objectValue: JsonObject): DesktopAssistCardUi? {
        val id = objectValue.string("id") ?: return null
        return DesktopAssistCardUi(
            id = id,
            reference = objectValue.string("reference") ?: "",
            label = objectValue.string("label") ?: id,
            kind = objectValue.string("kind") ?: DesktopAssistKinds.WEBSITE_PASSWORD,
            hostID = objectValue.string("hostID"),
            typingAllowed = objectValue.boolValue("typingAllowed"),
            updatedAtLabel = objectValue.string("updatedAt"),
        )
    }

    private fun request(
        operation: String,
        block: (kotlinx.serialization.json.JsonObjectBuilder.() -> Unit)? = null,
    ): JsonObject = buildJsonObject {
        put("version", VERSION)
        put("operation", operation)
        put("requestID", UUID.randomUUID().toString())
        block?.invoke(this)
    }

    private fun kotlinx.serialization.json.JsonObjectBuilder.putOwner(epoch: Long) {
        put("owner", buildJsonObject {
            put("token", ownerToken)
            put("nativeEpoch", epoch)
            put("temporary", false)
        })
    }

    private fun exchange(request: JsonObject): JsonObject {
        val raw = try {
            transport.exchange(request.toString())
        } catch (_: Throwable) {
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
                "unsupportedVersion", "unsupportedOperation" -> "needsCoreUpdate"
                else -> objectValue.string("code") ?: error ?: "unknown"
            }
            throw C05RemoteFailure(
                code = code,
                reason = objectValue.string("reason"),
                retryable = objectValue.boolValue("retryable"),
            )
        }
        return objectValue
    }

    companion object {
        const val VERSION = 22
    }
}
