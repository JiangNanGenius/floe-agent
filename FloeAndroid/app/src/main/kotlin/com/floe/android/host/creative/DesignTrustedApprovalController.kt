// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.canvas.CreativeOriginContext
import com.floe.android.feature.canvas.CreativeStorageLayer
import com.floe.android.feature.canvas.DesignTargetBinding
import com.floe.android.feature.canvas.DesignTargetIdentity
import java.nio.charset.StandardCharsets
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * User's explicit preservation requirements for one RESTRUCTURE. These are
 * edited and confirmed in the trusted design UI; the model bridge never
 * supplies them and no Codable confirmation from model JSON is accepted as
 * authority.
 */
data class DesignPreservationConstraintsModel(
    val content: List<String> = emptyList(),
    val data: List<String> = emptyList(),
    val behavior: List<String> = emptyList(),
    val formatBounds: List<String> = emptyList(),
) {
    fun isEmpty(): Boolean =
        content.isEmpty() && data.isEmpty() && behavior.isEmpty() && formatBounds.isEmpty()
}

enum class DesignTrustedOperation(val wire: String) {
    PROPOSE("propose"),
    FREEZE("freeze"),
    ADOPT("adopt"),
}

/**
 * Native display data returned for one prepared restructure. [token] is an
 * opaque one-shot confirmation token; the App shows exactly these values and
 * asks the user to confirm. There is deliberately no editable authority flag.
 */
data class DesignTrustedConfirmation(
    val token: String,
    val targetKey: String,
    val operationID: String,
    val originalTaskOwnerID: String?,
    val baseRevisionID: String?,
    val preservationDigest: String,
    val preservation: DesignPreservationConstraintsModel,
    val expiresAt: String,
)

/**
 * Privileged owner-proof + design-authority ingress supplied by the App owner.
 * The production implementation resolves the live accepted Root epoch + owner
 * token exactly like the privacy confirmation issuer and calls
 * `DesignAuthorityNative`. The token never enters this controller.
 */
interface DesignAuthorityIssuer {
    /** Returns bounded display JSON or null; may throw a typed JNI refusal. */
    fun prepare(epoch: Long, requestJson: String): String?

    /** Mints the existing single-use grant; returns a native status code. */
    fun confirm(epoch: Long, token: String): Int

    fun revoke(epoch: Long, token: String): Int

    fun retire(epoch: Long): Int
}

/**
 * Typed trusted UI callback for design RESTRUCTURE confirmations.
 *
 * Flow required by the design UI:
 *  1. [prepare] with the exact target binding, operation id, artifact/candidate
 *     and the user's preservation constraints. Native validates the LIVE state
 *     and returns the actual target/base/digest + display constraints.
 *  2. Show that data and ask the user to confirm.
 *  3. [confirm] the opaque token.
 *  4. Call the ordinary DesignHostApi freeze/propose/adopt with the same
 *     operation id. Native burns the grant immediately before the effect.
 *
 * A confirmation is bound to ONE epoch/target/operation/base/digest; it is
 * retired on Root stop and never crosses into a replacement Root.
 */
class DesignTrustedApprovalController(
    private val acceptedRootProvider: () -> CreativeAcceptedRoot?,
    private val epochProvider: () -> Long?,
    private val issuer: DesignAuthorityIssuer?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val json = Json { isLenient = false; ignoreUnknownKeys = true }

    suspend fun prepare(
        binding: DesignTargetBinding,
        operation: DesignTrustedOperation,
        opID: String,
        preservation: DesignPreservationConstraintsModel,
        artifactID: String? = null,
        candidateID: String? = null,
        baseRevisionID: String? = null,
    ): DesignTrustedConfirmation = withContext(ioDispatcher) {
        requireOperation(opID)
        if (preservation.isEmpty()) {
            throw CreativeException(
                "designAuthorityInvalid", "preservationConstraintsRequired")
        }
        val accepted = CreativeOwnership.requireLive(
            acceptedRootProvider(), epochProvider())
        val issued = issuer ?: throw CreativeException(
            "designAuthorityUnavailable", "ownerProofUnavailable")
        val request = encodePrepareRequest(
            binding = binding,
            operation = operation,
            opID = opID,
            preservation = preservation,
            artifactID = artifactID,
            candidateID = candidateID,
            baseRevisionID = baseRevisionID)
        val raw = request.toString()
        if (raw.toByteArray(StandardCharsets.UTF_8).size > MAX_PREPARE_BYTES) {
            throw CreativeException("requestTooLarge", "designAuthorityRequestTooLarge")
        }
        val response = try {
            issued.prepare(accepted.epoch, raw)
        } catch (error: Throwable) {
            throw mapRefusal(error)
        } ?: throw CreativeException(
            "designAuthorityUnavailable", "confirmationUnavailable")
        if (response.toByteArray(StandardCharsets.UTF_8).size > MAX_DISPLAY_BYTES) {
            throw CreativeException("responseTooLarge", "designAuthorityResponseTooLarge")
        }
        decodeConfirmation(response)
    }

    suspend fun confirm(confirmation: DesignTrustedConfirmation): Boolean =
        withContext(ioDispatcher) {
            val accepted = CreativeOwnership.requireLive(
                acceptedRootProvider(), epochProvider())
            val issued = issuer ?: throw CreativeException(
                "designAuthorityUnavailable", "ownerProofUnavailable")
            val status = try {
                issued.confirm(accepted.epoch, confirmation.token)
            } catch (error: Throwable) {
                throw mapRefusal(error)
            }
            requireStatus(status)
            true
        }

    suspend fun revoke(confirmation: DesignTrustedConfirmation) {
        withContext(ioDispatcher) {
            val epoch = epochProvider()?.takeIf { it > 0L } ?: return@withContext
            val issued = issuer ?: return@withContext
            try {
                issued.revoke(epoch, confirmation.token)
            } catch (_: Throwable) {
                // Revoke is best-effort for an explicit UI cancel; the record
                // also expires and is retired with the Root.
            }
        }
    }

    /** Root-stop: clear every prepared/confirmed record for this generation. */
    suspend fun retire() {
        withContext(ioDispatcher) {
            val epoch = epochProvider()?.takeIf { it > 0L } ?: return@withContext
            val issued = issuer ?: return@withContext
            try {
                issued.retire(epoch)
            } catch (_: Throwable) {
                // The native design drain retires its own store as well.
            }
        }
    }

    private fun requireStatus(status: Int) {
        if (status == 0) return
        throw when (status) {
            -120 -> CreativeException(
                "designAuthorityUnavailable", "ownerProofInvalid")
            -121 -> CreativeException(
                "designAuthorityUnavailable", "designAuthorityNotReady")
            -123, -124 -> CreativeException(
                "designAuthorityExpired", "confirmationExpiredOrMissing")
            -125 -> CreativeException(
                "designAuthorityMismatch", "confirmationDoesNotMatchTarget")
            else -> CreativeException(
                "designAuthorityUnavailable", "confirmationRefused")
        }
    }

    private fun mapRefusal(error: Throwable): CreativeException {
        val status = (error as? com.floe.android.bridge.DesignAuthorityNativeException)
            ?.status ?: -105
        return when (status) {
            -120 -> CreativeException(
                "designAuthorityUnavailable", "ownerProofInvalid")
            -121 -> CreativeException(
                "designAuthorityUnavailable", "designAuthorityNotReady")
            -123, -124 -> CreativeException(
                "designAuthorityExpired", "confirmationExpiredOrMissing")
            -125 -> CreativeException(
                "designAuthorityMismatch", "confirmationDoesNotMatchTarget")
            else -> CreativeException(
                "designAuthorityUnavailable", "confirmationRefused")
        }
    }

    private fun requireOperation(opID: String) {
        if (!opID.matches(Regex("[A-Za-z0-9._-]{1,100}"))) {
            throw CreativeException("invalidRequest", "invalidOperationID")
        }
    }

    // MARK: - Encode / decode

    private fun encodePrepareRequest(
        binding: DesignTargetBinding,
        operation: DesignTrustedOperation,
        opID: String,
        preservation: DesignPreservationConstraintsModel,
        artifactID: String?,
        candidateID: String?,
        baseRevisionID: String?,
    ): JsonObject = buildJsonObject {
        put("binding", encodeBinding(binding))
        put("operationKind", operation.wire)
        put("opID", opID)
        artifactID?.let { put("artifactID", it) }
        candidateID?.let { put("candidateID", it) }
        baseRevisionID?.let { put("baseRevisionID", it) }
        putJsonObject("preservation") {
            putJsonArray("content") {
                preservation.content.forEach { add(JsonPrimitive(it)) }
            }
            putJsonArray("data") {
                preservation.data.forEach { add(JsonPrimitive(it)) }
            }
            putJsonArray("behavior") {
                preservation.behavior.forEach { add(JsonPrimitive(it)) }
            }
            putJsonArray("formatBounds") {
                preservation.formatBounds.forEach { add(JsonPrimitive(it)) }
            }
        }
    }

    private fun encodeBinding(binding: DesignTargetBinding): JsonObject =
        buildJsonObject {
            put("target", encodeTarget(binding.target))
            put("storage", encodeStorage(binding.storage))
            binding.origin?.let { put("origin", encodeOrigin(it)) }
            put("sessionToken", binding.sessionToken)
        }

    private fun encodeTarget(target: DesignTargetIdentity): JsonObject =
        buildJsonObject {
            put("kind", target.kind.wire)
            put("ownerID", target.ownerID)
            put("documentID", target.documentID)
            put("sourceID", target.sourceID)
            target.environmentID?.let { put("environmentID", it) }
            target.revision?.let { put("revision", it) }
            target.originConversationID?.let { put("originConversationID", it) }
            target.requestedOutputKind?.let { put("requestedOutputKind", it.wire) }
        }

    private fun encodeStorage(storage: CreativeStorageLayer): JsonObject =
        buildJsonObject {
            when (storage) {
                CreativeStorageLayer.AppOwned -> put("kind", "appOwned")
                is CreativeStorageLayer.Workspace -> {
                    put("kind", "workspace")
                    put("workspaceID", storage.workspaceID)
                }
            }
        }

    private fun encodeOrigin(origin: CreativeOriginContext): JsonObject =
        buildJsonObject {
            put("kind", origin.kind)
            origin.ownerID?.let { put("ownerID", it) }
            origin.environmentID?.let { put("environmentID", it) }
        }

    private fun decodeConfirmation(raw: String): DesignTrustedConfirmation {
        val value = try {
            json.parseToJsonElement(raw) as? JsonObject
        } catch (_: Throwable) {
            null
        } ?: throw CreativeException(
            "invalidCoreResponse", "designAuthorityResponseMalformed")
        val preservation = value.objectValue("preservation")
            ?: throw CreativeException(
                "invalidCoreResponse", "missingPreservation")
        return DesignTrustedConfirmation(
            token = value.string("token")
                ?: throw CreativeException("invalidCoreResponse", "missingConfirmationToken"),
            targetKey = value.string("targetKey")
                ?: throw CreativeException("invalidCoreResponse", "missingTargetKey"),
            operationID = value.string("operationID")
                ?: throw CreativeException("invalidCoreResponse", "missingOperationID"),
            originalTaskOwnerID = value.string("originalTaskOwnerID"),
            baseRevisionID = value.string("baseRevisionID"),
            preservationDigest = value.string("preservationDigest")
                ?: throw CreativeException("invalidCoreResponse", "missingPreservationDigest"),
            preservation = DesignPreservationConstraintsModel(
                content = preservation.strings("content"),
                data = preservation.strings("data"),
                behavior = preservation.strings("behavior"),
                formatBounds = preservation.strings("formatBounds")),
            expiresAt = value.string("expiresAt").orEmpty())
    }

    private fun JsonObject.strings(key: String): List<String> =
        (this[key] as? JsonArray)?.mapNotNull {
            (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content
        }.orEmpty()

    companion object {
        const val MAX_PREPARE_BYTES = 64 * 1024
        const val MAX_DISPLAY_BYTES = 64 * 1024
    }
}
