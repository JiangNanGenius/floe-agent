// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import com.floe.android.feature.workbench.EnhancementBackendConfiguration
import com.floe.android.host.HostEditorKind
import com.floe.android.host.HostRouteAuthority
import com.floe.android.host.HostUiAdmission
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Enhancer credential mutation — App-host proofs (job-e5e786c723244725,
 * AUTHORED NOTRUN: scripted transport + route-authority/submitter doubles
 * only; no JNI, no device, no real Keystore, no provider call).
 *
 * Pins the ONE sealed secure-ingress save of
 * [CreativeR2EnhancementConfigurationHost]:
 *  * a key Set opens the dedicated closed `enhancer` editor route through
 *    the trusted native route authority (shared UI admission + accepted
 *    Root epoch) and submits the closed `enhancerSave` intent core + key
 *    bytes through the one-shot native ingress;
 *  * the business save wire carries ONLY the opaque `int:v1:` token —
 *    never the key, a base64 key or an account — and the whole exchange is
 *    pinned to the epoch the configuration was loaded under, even when the
 *    epoch provider moves on between load and save;
 *  * a failed/invalid/lost save reply NEVER deletes a credential: the host
 *    has no credential-store delete at all — it only discards the
 *    UNCONSUMED one-shot ingress token (a consumed token's discard is a
 *    native no-op and the committed key stays live);
 *  * a display-name-only edit opens no route, submits no ingress and sends
 *    no token;
 *  * a route-authority refusal or an ingress rejection fails closed BEFORE
 *    any save command is issued.
 */
class EnhancementCredentialMutationTest {
    private class FakeTransport(
        private val responder: (JsonObject) -> String,
    ) : CreativeTransport {
        val requests = CopyOnWriteArrayList<JsonObject>()

        override fun exchange(request: String): String {
            val parsed = Json.parseToJsonElement(request) as JsonObject
            requests.add(parsed)
            return responder(parsed)
        }
    }

    private class FakeRouteAuthority : HostRouteAuthority {
        val opened = java.util.concurrent.atomic.AtomicInteger(0)
        val cleared = java.util.concurrent.atomic.AtomicInteger(0)
        @Volatile var lastKind: HostEditorKind? = null
        @Volatile var lastEditorID: String? = null
        @Volatile var lastUiGeneration: Long = -1
        @Volatile var lastExpectedEpoch: Long = -1
        @Volatile var refuse = false

        override fun open(
            kind: HostEditorKind,
            editorID: String,
            uiGeneration: Long,
            expectedNativeRootEpoch: Long,
        ): String? {
            opened.incrementAndGet()
            lastKind = kind
            lastEditorID = editorID
            lastUiGeneration = uiGeneration
            lastExpectedEpoch = expectedNativeRootEpoch
            return if (refuse) null else ROUTE_TOKEN
        }

        override fun clear(token: String) {
            cleared.incrementAndGet()
        }
    }

    private class FakeSubmitter : CreativeR2EnhancementConfigurationHost.EnhancerSaveIntentSubmitter {
        val calls = java.util.concurrent.atomic.AtomicInteger(0)
        val discarded = CopyOnWriteArrayList<String>()
        @Volatile var lastIntent: String? = null
        @Volatile var lastRoute: String? = null
        @Volatile var lastBytes: ByteArray? = null
        @Volatile var result: CreativeR2EnhancementConfigurationHost.SaveIntentSubmission =
            CreativeR2EnhancementConfigurationHost.SaveIntentSubmission.Accepted(TOKEN)

        override fun submit(
            intentCoreJson: String,
            routeToken: String,
            value: ByteArray,
        ): CreativeR2EnhancementConfigurationHost.SaveIntentSubmission {
            calls.incrementAndGet()
            lastIntent = intentCoreJson
            lastRoute = routeToken
            lastBytes = value.copyOf()
            return result
        }

        override fun discard(token: String) {
            discarded.add(token)
        }
    }

    private companion object {
        const val ENDPOINT = "fal-ai/bytedance-upscaler/upscale/video"
        const val SAVE_ERROR = "enhancerInvalidEndpoint"
        const val ENHANCER_EDITOR_ID = "media.enhancement.superResolution"
        const val ROUTE_TOKEN =
            "rt:v1:0123456789abcdef0123456789abcdef"
        const val TOKEN =
            "int:v1:0123456789abcdef0123456789abcdef"

        fun configuredJson(): String = """
            {"version":6,"schema":"floe.creative/6","ok":true,"configured":true,"displayName":"fal",
             "endpointID":"$ENDPOINT","credentialConfigured":true,
             "legacyProviderProfileReferenced":false}
        """.trimIndent()

        fun unconfiguredJson(): String = """
            {"version":6,"schema":"floe.creative/6","ok":true,"configured":false,"displayName":null,
             "endpointID":"$ENDPOINT","credentialConfigured":false,
             "legacyProviderProfileReferenced":false}
        """.trimIndent()

        /** Explicit-account derivation (compat path), unchanged shape. */
        fun referenceJson(): String = """
            {"version":6,"schema":"floe.creative/6","ok":true,
             "credentialAccount":"${EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT}",
             "opaqueReference":"ref:v1:live"}
        """.trimIndent()

        fun failingSaveJson(): String = """
            {"version":6,"schema":"floe.creative/6","ok":false,"error":"$SAVE_ERROR","retryable":false}
        """.trimIndent()
    }

    private class Fixture(
        val transport: FakeTransport,
        val routes: FakeRouteAuthority,
        val submitter: FakeSubmitter,
        val epoch: AtomicLong,
    )

    private fun fixture(saveOk: Boolean = true): Fixture {
        val epoch = AtomicLong(5L)
        val transport = FakeTransport { request ->
            when (request["operation"]?.jsonPrimitive?.content) {
                "command" -> when (request["action"]?.jsonPrimitive?.content) {
                    "media.enhancement.configuration.get" -> configuredJson()
                    "media.enhancement.configuration.reference" -> referenceJson()
                    "media.enhancement.configuration.save" ->
                        if (saveOk) configuredJson() else failingSaveJson()
                    "media.enhancement.configuration.clear" -> unconfiguredJson()
                    else -> """{"version":6,"schema":"floe.creative/6","ok":false,"error":"unsupportedAction"}"""
                }
                else -> """{"version":6,"schema":"floe.creative/6","ok":false,"error":"unsupportedOperation"}"""
            }
        }
        val routes = FakeRouteAuthority()
        val submitter = FakeSubmitter()
        return Fixture(transport, routes, submitter, epoch)
    }

    private fun host(fixture: Fixture) =
        CreativeR2EnhancementConfigurationHost(
            context = null,
            transport = fixture.transport,
            epochProvider = { fixture.epoch.get() },
            ioDispatcher = Dispatchers.Unconfined,
        ).also {
            it.routeAuthority = fixture.routes
            it.saveIntentSubmitter = fixture.submitter
        }

    @Test
    fun `set save opens enhancer route and submits sealed ingress pinned to load epoch`() =
        runBlocking {
            val f = fixture(saveOk = true)
            val host = host(f)
            HostUiAdmission.resetForTesting()

            val loaded = host.getConfiguration()
            assertTrue(loaded.configured)
            assertEquals(1, f.transport.requests.size)

            // The root moves on before the save: the exchange must stay
            // pinned to the load epoch (5), not the new epoch (6).
            f.epoch.set(6L)
            host.saveConfiguration(
                displayName = null,
                endpointID = ENDPOINT,
                credentialAccount =
                    EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                apiKey = "secret-key",
            )

            assertEquals(1, f.routes.opened.get())
            assertEquals(1, f.submitter.calls.get())
            assertEquals(HostEditorKind.ENHANCER, f.routes.lastKind)
            assertEquals(ENHANCER_EDITOR_ID, f.routes.lastEditorID)
            // The route admission used the pinned epoch and a fresh shared UI
            // generation.
            assertEquals(5L, f.routes.lastExpectedEpoch)
            assertTrue(f.routes.lastUiGeneration > 0)

            // The sealed intent core freezes the closed enhancer subject and
            // the secret-free candidate — never the key.
            val intent = Json.parseToJsonElement(f.submitter.lastIntent!!) as JsonObject
            val subject = intent["subject"]!!.jsonObject
            assertEquals("enhancerSave", subject["kind"]!!.jsonPrimitive.content)
            assertEquals(ENHANCER_EDITOR_ID, subject["id"]!!.jsonPrimitive.content)
            assertEquals("set", intent["intent"]!!.jsonPrimitive.content)
            val candidate = intent["candidate"]!!.jsonObject
            assertEquals(ENHANCER_EDITOR_ID, candidate["id"]!!.jsonPrimitive.content)
            assertEquals(ENDPOINT, candidate["endpointID"]!!.jsonPrimitive.content)
            assertFalse(intent.toString().contains("secret-key"))
            assertFalse(candidate.containsKey("route"))
            // The key bytes reached ONLY the one-shot native ingress buffer.
            assertEquals(ROUTE_TOKEN, f.submitter.lastRoute)
            assertNotNull(f.submitter.lastBytes)
            assertEquals("secret-key", String(f.submitter.lastBytes!!, Charsets.UTF_8))

            assertEquals(2, f.transport.requests.size)
            val saveRequest = f.transport.requests[1]
            assertEquals(
                "media.enhancement.configuration.save",
                saveRequest["action"]?.jsonPrimitive?.content)
            assertEquals(5L, saveRequest["epoch"]?.jsonPrimitive?.content?.toLong())
            // The business wire carries ONLY the opaque token — never the
            // key bytes, a base64 key or an account.
            assertEquals(
                TOKEN,
                saveRequest["payload"]?.jsonObject
                    ?.get("saveIntentToken")?.jsonPrimitive?.content)
            assertFalse(saveRequest.toString().contains("secret-key"))
            assertNull(
                saveRequest["payload"]?.jsonObject
                    ?.get("stagedCredentialAccount"))
        }

    @Test
    fun `failed native save discards ingress token and never deletes a credential`() =
        runBlocking {
            val f = fixture(saveOk = false)
            val host = host(f)
            host.getConfiguration()

            val failure = try {
                host.saveConfiguration(
                    displayName = null,
                    endpointID = ENDPOINT,
                    credentialAccount =
                        EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                    apiKey = "secret-key",
                )
                throw AssertionError("a failed native save must propagate the typed failure")
            } catch (error: CreativeException) {
                error
            }
            assertEquals(SAVE_ERROR, failure.code)
            // The host has NO credential-store delete: it discards only the
            // UNCONSUMED ingress token (a consumed token's discard is a
            // native no-op and the committed key stays live).
            assertEquals(listOf(TOKEN), f.submitter.discarded.toList())
        }

    @Test
    fun `lost save reply after accepted ingress discards token and leaves credentials alone`() =
        runBlocking {
            // The transport loses the save exchange AFTER the sealed ingress
            // was accepted: the native side may already have committed. The
            // host must NOT touch any credential — no delete exists on this
            // host — and must only discard the one-shot token.
            val f = fixture(saveOk = true)
            val losingTransport = object : CreativeTransport {
                override fun exchange(request: String): String {
                    val parsed = Json.parseToJsonElement(request) as JsonObject
                    if (parsed["action"]?.jsonPrimitive?.content ==
                        "media.enhancement.configuration.save"
                    ) {
                        throw RuntimeException("lost reply")
                    }
                    return f.transport.exchange(request)
                }
            }
            val epoch = AtomicLong(5L)
            val routes = FakeRouteAuthority()
            val submitter = FakeSubmitter()
            val host = CreativeR2EnhancementConfigurationHost(
                context = null,
                transport = losingTransport,
                epochProvider = { epoch.get() },
                ioDispatcher = Dispatchers.Unconfined,
            ).also {
                it.routeAuthority = routes
                it.saveIntentSubmitter = submitter
            }
            host.getConfiguration()

            val failure = try {
                host.saveConfiguration(
                    displayName = null,
                    endpointID = ENDPOINT,
                    credentialAccount =
                        EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                    apiKey = "secret-key",
                )
                throw AssertionError("a lost save reply must surface as a typed failure")
            } catch (error: CreativeException) {
                error
            }
            assertEquals("invalidCoreResponse", failure.code)
            assertEquals(listOf(TOKEN), submitter.discarded.toList())
        }

    @Test
    fun `display name only edit opens no route and sends no token`() = runBlocking {
        val f = fixture(saveOk = true)
        val host = host(f)
        host.getConfiguration()

        host.saveConfiguration(
            displayName = "renamed",
            endpointID = ENDPOINT,
            credentialAccount = EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
            apiKey = null,
        )

        assertEquals(0, f.routes.opened.get())
        assertEquals(0, f.submitter.calls.get())
        assertEquals(2, f.transport.requests.size)
        val saveRequest = f.transport.requests[1]
        assertEquals(
            "media.enhancement.configuration.save",
            saveRequest["action"]?.jsonPrimitive?.content)
        assertNull(saveRequest["payload"]?.jsonObject?.get("saveIntentToken"))
    }

    @Test
    fun `route refusal fails closed before any save command`() = runBlocking {
        val f = fixture(saveOk = true)
        f.routes.refuse = true
        val host = host(f)
        host.getConfiguration()

        val failure = try {
            host.saveConfiguration(
                displayName = null,
                endpointID = ENDPOINT,
                credentialAccount =
                    EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                apiKey = "secret-key",
            )
            throw AssertionError("a refused route must fail closed")
        } catch (error: CreativeException) {
            error
        }
        assertEquals("secureSaveUnavailable", failure.code)
        assertEquals(0, f.submitter.calls.get())
        // No save command was ever issued.
        assertEquals(1, f.transport.requests.size)
    }

    @Test
    fun `ingress rejection fails closed before any save command`() = runBlocking {
        val f = fixture(saveOk = true)
        f.submitter.result =
            CreativeR2EnhancementConfigurationHost.SaveIntentSubmission.Rejected(
                "intentUnavailable")
        val host = host(f)
        host.getConfiguration()

        val failure = try {
            host.saveConfiguration(
                displayName = null,
                endpointID = ENDPOINT,
                credentialAccount =
                    EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                apiKey = "secret-key",
            )
            throw AssertionError("an ingress rejection must fail closed")
        } catch (error: CreativeException) {
            error
        }
        assertEquals("secureSaveUnavailable", failure.code)
        assertEquals("intentUnavailable", failure.reason)
        assertEquals(1, f.transport.requests.size)
    }

    @Test
    fun `explicit credentialReference keeps deriving the given account`() =
        runBlocking {
            val f = fixture(saveOk = true)
            val host = host(f)

            val reference = host.credentialReference(
                EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT)

            assertEquals("ref:v1:live", reference)
            assertEquals(1, f.transport.requests.size)
            val request = f.transport.requests[0]
            assertEquals(
                EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
                request["payload"]?.jsonObject
                    ?.get("credentialAccount")?.jsonPrimitive?.content)
        }

    @Test
    fun `revoke pins loaded epoch and issues a single clear`() = runBlocking {
        val f = fixture(saveOk = true)
        val host = host(f)
        host.getConfiguration()

        f.epoch.set(9L)
        val revoked = host.clearConfiguration()

        assertFalse(revoked.configured)
        assertEquals(2, f.transport.requests.size)
        val clearRequest = f.transport.requests[1]
        assertEquals(
            "media.enhancement.configuration.clear",
            clearRequest["action"]?.jsonPrimitive?.content)
        assertEquals(5L, clearRequest["epoch"]?.jsonPrimitive?.content?.toLong())
        assertEquals(0, f.routes.opened.get())
        assertEquals(0, f.submitter.calls.get())
    }

    @Test
    fun `missing epoch refuses before any bridge exchange`() = runBlocking {
        val f = fixture(saveOk = true)
        f.epoch.set(0L)
        val host = host(f)

        val failure = try {
            host.getConfiguration()
            throw AssertionError("a missing epoch must refuse before any exchange")
        } catch (error: CreativeException) {
            error
        }
        assertEquals("staleGeneration", failure.code)
        assertEquals("acceptedRootNotLive", failure.reason)
        assertTrue(f.transport.requests.isEmpty())
    }
}
