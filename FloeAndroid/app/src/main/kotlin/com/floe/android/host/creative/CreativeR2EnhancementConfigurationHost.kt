// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import android.content.Context
import com.floe.android.bridge.SecretGatewayNative
import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.EnhancementBackendConfiguration
import com.floe.android.feature.workbench.WorkbenchR2Limits
import com.floe.android.feature.workbench.WorkbenchEnhancementConfigurationHostApi
import com.floe.android.host.HostEditorKind
import com.floe.android.host.HostRouteAuthority
import com.floe.android.host.HostUiAdmission
import com.floe.android.host.NativeHostRouteAuthority
import com.floe.android.host.isOpaqueHostRouteToken
import com.floe.android.host.isOpaqueIngressToken
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Production App adapter for the super-resolution backend configuration.
 *
 * The typed row crosses `floe.creative/6` as a SECRET-FREE payload; the API
 * key never enters a command, log or saved state. When a key is supplied,
 * the ENTIRE credential exchange rides the ONE ORIGINAL sealed secure
 * ingress — the SAME route authority + one-shot vault slot the
 * provider/MCP/web-search editors use:
 *
 *  1. this host opens the dedicated closed `enhancer` editor route through
 *     the native route authority ([HostRouteAuthority]) under the App-wide
 *     shared UI admission ([HostUiAdmission]) and the accepted Root epoch;
 *  2. it freezes the closed intent core (subject.kind = `enhancerSave`, the
 *     exact editor identity, intent `set`, the secret-free candidate) and
 *     submits the key bytes through `SecretGatewayNative
 *     .submitHostSaveIntent` — the existing C/JNI buffer ingress — which
 *     stores key + candidate + route binding in ONE bounded vault slot and
 *     returns the opaque one-shot `int:v1:` handle;
 *  3. the save command carries ONLY that opaque handle (never the key, never
 *     a base64 key, never an account); the native side consumes the lease
 *     with the exact `enhancerSave` subject and performs the single original
 *     vault capture + immutable rotation (row persisted LAST, previous
 *     credential retired through the original vault delete).
 *
 * The App host NEVER writes or deletes a credential itself. In particular an
 * unknown/failed/lost save reply after a successful native commit must NEVER
 * trigger a key deletion: the host only discards the UNCONSUMED one-shot
 * ingress token (a consumed token's discard is a native no-op and the
 * committed key stays live), and the UI re-reads the configuration instead
 * of resubmitting key writes. Actual failed commits leave the previous
 * configuration AND credential byte-identical on the native side, which
 * durably retires the unreferenced new credential itself.
 *
 * Epoch pinning: the whole save/revoke exchange is pinned to the epoch the
 * retained configuration was loaded under, and every bridge call in the
 * exchange carries that same epoch. A root switch refuses stale below
 * instead of applying an old settings draft/key to a newly selected root,
 * and the native route admission re-reads the accepted Root epoch under its
 * own lock before binding.
 *
 * Revocation is the single native `media.enhancement.configuration.clear`:
 * the native side retires the credential through the original vault delete
 * (metadata delete first, durable cleanup intent, targeted gateway delete,
 * conditional completion) and reports an incomplete cleanup truthfully, so
 * no orphan key can survive a successful revoke and no failed revoke drops
 * its only ownership record.
 *
 * No ProviderProfile is created anywhere: the enhancer backend stays out of
 * the general provider/model surfaces.
 */
class CreativeR2EnhancementConfigurationHost(
    context: Context?,
    private val transport: CreativeTransport = SwiftCreativeTransport,
    private val epochProvider: () -> Long?,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : WorkbenchEnhancementConfigurationHostApi {

    private val exchangeMutex = Mutex()
    /** Epoch the retained configuration was loaded under (0 = not yet). */
    private val loadedEpoch = AtomicLong(0L)

    // ---------------------------------------------------------------- seams
    // The trusted native route authority and the sealed ingress submitter are
    // replaceable in-module ONLY so JVM fixtures exercise the real controller
    // wiring without the native library; production never replaces them.

    /** One sealed enhancer save submission: closed core + key bytes. */
    internal interface EnhancerSaveIntentSubmitter {
        fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): SaveIntentSubmission

        /** Best-effort zero+free of one UNCONSUMED one-shot ingress token. */
        fun discard(token: String)
    }

    internal sealed interface SaveIntentSubmission {
        data class Accepted(val token: String) : SaveIntentSubmission
        data class Rejected(val code: String) : SaveIntentSubmission
    }

    internal object NativeEnhancerSaveIntentSubmitter : EnhancerSaveIntentSubmitter {
        override fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): SaveIntentSubmission = try {
            val token = SecretGatewayNative.submitHostSaveIntent(
                intentCoreJson, routeToken, value)
            if (token == null) SaveIntentSubmission.Rejected("intentRejected")
            else SaveIntentSubmission.Accepted(token)
        } catch (t: Throwable) {
            SaveIntentSubmission.Rejected("intentUnavailable")
        }

        override fun discard(token: String) {
            try {
                SecretGatewayNative.discardSaveIntent(token)
            } catch (t: Throwable) {
                // The one-shot LIVE slot still expires natively; no UI secret.
            }
        }
    }

    /** Test seam only; production is [NativeEnhancerSaveIntentSubmitter]. */
    internal var saveIntentSubmitter: EnhancerSaveIntentSubmitter =
        NativeEnhancerSaveIntentSubmitter

    /** Trusted native route authority (App-wide shared UI admission). */
    internal var routeAuthority: HostRouteAuthority = NativeHostRouteAuthority

    override suspend fun getConfiguration(): EnhancementBackendConfiguration =
        withContext(ioDispatcher) {
            exchangeMutex.withLock {
                val epoch = requireEpoch()
                val configuration = decodeConfiguration(
                    command("media.enhancement.configuration.get", buildJsonObject {},
                        epoch))
                loadedEpoch.set(epoch)
                configuration
            }
        }

    override suspend fun credentialReference(credentialAccount: String): String =
        withContext(ioDispatcher) {
            exchangeMutex.withLock {
                referenceLocked(credentialAccount, requireEpoch())
            }
        }

    override suspend fun saveConfiguration(
        displayName: String?,
        endpointID: String,
        credentialAccount: String,
        apiKey: String?,
    ): EnhancementBackendConfiguration = withContext(ioDispatcher) {
        exchangeMutex.withLock {
            val epoch = pinnedEpoch()
            var saveIntentToken: String? = null
            var routeToken: String? = null
            try {
                if (apiKey != null) {
                    val bytes = apiKey.toByteArray(Charsets.UTF_8)
                    try {
                        if (bytes.isEmpty() || bytes.size > MAX_KEY_BYTES) {
                            throw CreativeException("invalidPayload", "enhancerKeyTooLarge")
                        }
                        // ONE sealed native ingress: open the dedicated closed
                        // enhancer editor route under the shared UI admission +
                        // accepted Root epoch, then freeze the closed intent core
                        // and submit the key bytes through the existing C/JNI
                        // buffer ingress. The native seam injects the live route
                        // pair; the key bytes are zeroed after the call.
                        val generation = HostUiAdmission.nextGeneration()
                        val opened = routeAuthority.open(
                            HostEditorKind.ENHANCER, ENHANCER_EDITOR_ID,
                            generation, epoch)
                        if (!isOpaqueHostRouteToken(opened.orEmpty())) {
                            throw CreativeException(
                                "secureSaveUnavailable", "enhancerRouteUnavailable",
                                retryable = true)
                        }
                        routeToken = opened
                        when (val submission = saveIntentSubmitter.submit(
                            buildSetIntentJson(displayName, endpointID), requireNotNull(opened), bytes)) {
                            is SaveIntentSubmission.Rejected -> throw CreativeException(
                                "secureSaveUnavailable", submission.code, retryable = true)
                            is SaveIntentSubmission.Accepted -> {
                                if (!isOpaqueIngressToken(submission.token)) {
                                    throw CreativeException(
                                        "invalidCoreResponse", "enhancerIntentTokenInvalid")
                                }
                                saveIntentToken = submission.token
                            }
                        }
                    } finally {
                        bytes.fill(0)
                    }
                }
                decodeConfiguration(
                    command("media.enhancement.configuration.save", buildJsonObject {
                        put("displayName", displayName)
                        put("endpointID", endpointID)
                        // Advisory only: the native side binds the sealed
                        // ingress / the current owned row, never this value.
                        put("credentialAccount", credentialAccount)
                        // The business wire carries ONLY the opaque one-shot
                        // handle — never the key, a base64 key or an account.
                        if (saveIntentToken != null) {
                            put("saveIntentToken", saveIntentToken)
                        }
                    }, epoch))
            } catch (failure: Throwable) {
                // A failed/invalid/lost save reply can follow an ACTUAL
                // native commit: NEVER delete a credential here. Discard only
                // the UNCONSUMED one-shot ingress token — a consumed token's
                // discard is a native no-op and the committed key stays live;
                // the user re-reads the configuration to confirm.
                discardSaveIntentToken(saveIntentToken)
                throw failure
            } finally {
                routeToken?.let { clearRoute(it) }
            }
        }
    }

    override suspend fun clearConfiguration(): EnhancementBackendConfiguration =
        withContext(ioDispatcher) {
            exchangeMutex.withLock {
                // Revoke is pinned to the same epoch as the retained
                // configuration: a root switch since the load refuses
                // stale instead of clearing a root the user is not looking
                // at.
                decodeConfiguration(
                    command("media.enhancement.configuration.clear", buildJsonObject {},
                        pinnedEpoch()))
            }
        }

    // MARK: - Exchange

    /**
     * The epoch pinned for a whole save/revoke exchange: the epoch the
     * retained configuration was loaded under. Falls back to the live
     * epoch only when nothing was loaded in this process yet (revoke before
     * any load targets the current root, which is the only root that
     * exists for this process).
     */
    private fun pinnedEpoch(): Long {
        val loaded = loadedEpoch.get()
        if (loaded > 0L) return loaded
        return requireEpoch()
    }

    private fun requireEpoch(): Long {
        val epoch = epochProvider()
            ?: throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        if (epoch <= 0L) {
            throw CreativeException(
                "staleGeneration", "acceptedRootNotLive", retryable = true)
        }
        return epoch
    }

    private suspend fun referenceLocked(credentialAccount: String, epoch: Long): String {
        val response = command("media.enhancement.configuration.reference", buildJsonObject {
            put("credentialAccount", credentialAccount)
        }, epoch)
        return response.string("opaqueReference")
            ?: throw CreativeException("invalidResponse", "missingCredentialReference")
    }

    /** Caller holds [exchangeMutex] and has pinned [epoch]. */
    private suspend fun command(action: String, payload: JsonObject, epoch: Long): JsonObject {
        val request = R2MediaWire.request(
            operation = "command",
            requestID = CreativeWire.newRequestID(),
            epoch = epoch,
            action = action,
            payload = payload).toString()
        if (request.toByteArray(Charsets.UTF_8).size >
            WorkbenchR2Limits.BRIDGE_REQUEST_BYTES) {
            throw CreativeException("requestTooLarge", "enhancementConfigRequestTooLarge")
        }
        val raw = try {
            transport.exchange(request)
        } catch (error: CreativeException) {
            throw error
        } catch (error: Throwable) {
            throw CreativeException(
                "invalidCoreResponse", "bridgeExchangeFailed", retryable = true)
        }
        if (raw.toByteArray(Charsets.UTF_8).size >
            WorkbenchR2Limits.BRIDGE_RESPONSE_BYTES) {
            throw CreativeException("responseTooLarge", "enhancementConfigResponseTooLarge")
        }
        return R2MediaWire.response(raw)
    }

    // MARK: - Sealed ingress helpers

    /**
     * The closed intent core for one enhancer key Set: subject.kind =
     * `enhancerSave` + the exact editor identity, intent `set`, and the
     * secret-free frozen candidate (id/displayName/endpointID). The route
     * pair is injected natively at submit; the key bytes ride the separate
     * bounded value buffer and never enter this JSON.
     */
    private fun buildSetIntentJson(displayName: String?, endpointID: String): String {
        val root = linkedMapOf<String, JsonElement>(
            "subject" to JsonObject(
                mapOf(
                    "kind" to JsonPrimitive(ENHANCER_SAVE_SUBJECT_KIND),
                    "id" to JsonPrimitive(ENHANCER_EDITOR_ID),
                ),
            ),
            "intent" to JsonPrimitive("set"),
            "candidate" to buildJsonObject {
                put("id", ENHANCER_EDITOR_ID)
                if (displayName != null) put("displayName", displayName)
                put("endpointID", endpointID)
            },
        )
        return JsonObject(root).toString()
    }

    /** Exact-ownership native close of this editor's own route handle. */
    private fun clearRoute(token: String) {
        try {
            routeAuthority.clear(token)
        } catch (t: Throwable) {
            // A failed close is a no-op against the exact-ownership rule;
            // the binding dies with its Root epoch anyway.
        }
    }

    /**
     * Cleanup of an UNCONSUMED native ingress token after a failed/rejected/
     * unknown save or a cancellation. A consumed token's discard is a native
     * no-op and the committed key stays live. No secret/candidate is ever
     * read here.
     */
    private fun discardSaveIntentToken(token: String?) {
        if (token == null) return
        try {
            saveIntentSubmitter.discard(token)
        } catch (t: Throwable) {
            // Best-effort; the LIVE slot still expires natively.
        }
    }

    // MARK: - Decode

    /** [R2MediaWire.response] already threw on any non-ok envelope. */
    private fun decodeConfiguration(value: JsonObject): EnhancementBackendConfiguration {
        return EnhancementBackendConfiguration(
            configured = value.bool("configured") ?: false,
            displayName = value.string("displayName"),
            endpointID = value.string("endpointID")
                ?: EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT.let {
                    // Unreachable for a well-formed native reply; refuse to
                    // guess rather than persist a wrong endpoint.
                    throw CreativeException("invalidResponse", "missingEnhancerEndpoint")
                },
            credentialConfigured = value.bool("credentialConfigured") ?: false,
            legacyProviderProfileReferenced =
                value.bool("legacyProviderProfileReferenced") ?: false,
        )
    }

    private companion object {
        /** The dedicated closed enhancer save subject kind. */
        const val ENHANCER_SAVE_SUBJECT_KIND = "enhancerSave"
        /**
         * The ONE enhancer settings editor identity (route-admission
         * subject id + frozen candidate id). Matches the native
         * `G09R2EnhancerCredentialPurpose.coordinationAccount`; never a
         * credential account, never gateway-addressed.
         */
        const val ENHANCER_EDITOR_ID = "media.enhancement.superResolution"
        const val MAX_KEY_BYTES = 65_536
    }
}
