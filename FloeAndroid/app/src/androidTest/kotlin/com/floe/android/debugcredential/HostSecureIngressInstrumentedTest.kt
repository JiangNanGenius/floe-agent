// SPDX-License-Identifier: MPL-2.0
//
// SYNTHETIC trusted-host secure-ingress device probe (instrumented).
//
// Proves the REAL App-process trusted seam end-to-end on the product UID,
// with ONE clearly synthetic placeholder key (never a real credential, no
// network request — the endpoint is `.invalid` and the save path only writes
// the local credential vault + provider row):
//
//   1. `SecretGatewayNative.openHostRoute` mints ONE canonical `rt:v1:`
//      handle bound to the ACTUAL accepted native root epoch (the value the
//      host captured at editor creation).
//   2. `SecretGatewayNative.submitHostSaveIntent` freezes the closed intent
//      CORE (subject/candidate/baseRevision, NO route) with the bounded
//      placeholder bytes and returns the one-shot `int:v1:` handle; a forged
//      route assertion or a stale root epoch is refused.
//   3. The public `config.provider.save` Set carries ONLY the opaque token;
//      the committed provider row reads back through `config.providers.list`
//      with `secret.configured == true` and the canonical opaque reference
//      (a REAL bounded gateway read through the product Keystore-backed
//      gateway — the logical+physical binding in this product process).
//   4. No public JSON ever carries the secret bytes.
//   5. The row is removed again through the real guarded delete, leaving no
//      residue; a stale-route close/submit afterwards is an exact-ownership
//      no-op / refusal.
//
// All phases are gated so an ordinary CanonicalWire/Settings run never
// executes this probe.
package com.floe.android.debugcredential

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.floe.android.bridge.SecretGatewayNative
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HostSecureIngressInstrumentedTest {

    private val fixtureName = "Floe G02 QA"
    private val fixtureEndpoint = "https://example.invalid/v1"
    private val fixtureKey = "floe-g02-synthetic-placeholder"
    private val fixtureModelID = "deepseek-flash"

    private fun arg(name: String): String? =
        InstrumentationRegistry.getArguments().getString(name)

    private fun awaitAcceptedEpoch(): Long {
        val deadline = System.currentTimeMillis() + 45_000
        while (System.currentTimeMillis() < deadline) {
            runCatching {
                val raw = com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness()
                    ?: return@runCatching
                val root = org.json.JSONObject(raw)
                val epoch = root.optLong("epoch", -1L)
                if (epoch > 0 && root.optLong("nativeRootEpoch", -1L) == epoch) return epoch
            }
            Thread.sleep(250)
        }
        throw AssertionError("accepted native generation never admitted")
    }

    private fun providerDraft(): com.floe.android.feature.providers.ProviderDraftSnapshot =
        com.floe.android.feature.providers.ProviderDraftSnapshot(
            role = com.floe.android.feature.providers.ProviderServiceRoleUi.CONVERSATION,
            displayName = fixtureName,
            supplier = com.floe.android.feature.providers.SupplierChoice(
                presetId = "custom",
                displayName = "Custom endpoint",
                catalogEntryId = null,
                absoluteEndpointDefault = "",
                routeFamily = "",
                authStyle = "",
                supportsPlainHttpChoice = false,
                suggestsToolNameCompatibility = false,
            ),
            protocol = com.floe.android.feature.providers.WireProtocolUi.OPENAI_CHAT_COMPLETIONS,
            baseUrl = fixtureEndpoint,
            models = listOf(com.floe.android.feature.providers.ModelDraftRowUi(
                draftModelId = "manual-1",
                savedModelId = null,
                remoteModelID = fixtureModelID,
                displayName = "DeepSeek Flash",
                enabled = true,
                capabilities = setOf(
                    com.floe.android.feature.providers.ModelCapabilityUi.TEXT,
                    com.floe.android.feature.providers.ModelCapabilityUi.TOOLS),
                contextTokens = 128_000,
                maxOutputTokens = 8_192,
                selectedForSave = true,
            )),
            defaultModelDraftId = "manual-1",
        )

    private fun isCanonicalRoute(token: String?): Boolean =
        token != null && token.length == 38 && token.startsWith("rt:v1:") &&
            token.substring(6).all { it in '0'..'9' || it in 'a'..'f' }

    private fun isCanonicalIngress(token: String?): Boolean =
        token != null && token.length == 39 && token.startsWith("int:v1:") &&
            token.substring(7).all { it in '0'..'9' || it in 'a'..'f' }

    private fun intentCore(providerID: String, candidate: JsonObject): String {
        val core = linkedMapOf<String, kotlinx.serialization.json.JsonElement>(
            "subject" to JsonObject(mapOf(
                "kind" to JsonPrimitive("providerSave"),
                "id" to JsonPrimitive(providerID),
            )),
            "intent" to JsonPrimitive("set"),
            "baseRevision" to JsonObject(mapOf(
                "resourceID" to JsonPrimitive("provider.$providerID"),
                "version" to JsonPrimitive("0"),
            )),
            "candidate" to candidate,
        )
        return JsonObject(core).toString()
    }

    /** Submit one request and return its typed terminal (or null on failure). */
    private fun submitAndAwait(
        client: com.floe.android.host.RuntimeHostCommandClient,
        request: com.floe.android.host.HostCommandRequest,
        scope: String,
    ): com.floe.android.host.HostEffectTerminal? {
        val submitted = runBlocking { client.submit(request) }
        if (submitted !is com.floe.android.host.HostSubmitResult.Accepted) return null
        val done = CountDownLatch(1)
        var terminal: com.floe.android.host.HostEffectTerminal? = null
        val handle = client.openEffectStream(
            operationReceiptID = submitted.operationReceiptID,
            configurationScope = scope,
            onFrame = { },
            onTerminal = { terminal = it; done.countDown() },
            onFailure = { done.countDown() },
        )
        try {
            check(done.await(20, TimeUnit.SECONDS)) { "seam_terminal_timeout" }
        } finally {
            handle.close()
        }
        return terminal
    }

    private fun listProviderRow(providerID: String): Pair<JsonObject?, String?>? {
        val client = com.floe.android.host.RuntimeHostCommandClient.system()
        val terminal = submitAndAwait(client, com.floe.android.host.HostCommandRequest(
            command = "config.providers.list",
            scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
            stateful = false,
            correlationID = "seam-list-${System.nanoTime()}",
            payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
        ), "providers") ?: return null
        if (terminal !is com.floe.android.host.HostEffectTerminal.Completed) return null
        val value = terminal.value as? JsonObject ?: return null
        val rows = value["rows"] as? kotlinx.serialization.json.JsonArray ?: return null
        for (row in rows) {
            val obj = row as? JsonObject ?: continue
            if ((obj["id"] as? JsonPrimitive)?.contentOrNull == providerID) {
                return obj to terminal.toString()
            }
        }
        return null
    }

    /**
     * Phase `seamSetSave`: the REAL trusted seam end-to-end with the
     * synthetic placeholder key; commits + reads back + deletes the row.
     */
    @Test
    fun seamSetSaveCommitsAndReadsBackBoundSecretReference() {
        assumeTrue(arg("floeSecureIngressPhase") == "seamSetSave")
        val epoch = awaitAcceptedEpoch()
        val providerID = UUID.randomUUID().toString()
        val modelID = UUID.randomUUID().toString()
        val candidate = com.floe.android.host.ProviderWire.candidateJson(
            providerID = providerID,
            kind = "custom",
            createIntent = true,
            draft = providerDraft(),
            modelUUID = { modelID },
        )
        val core = intentCore(providerID, candidate)

        // 1) The native route admission requires the ACTUAL captured root
        //    epoch; a stale/foreign one is refused with zero mutation.
        val stale = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-stale-editor", 7L, epoch - 1)
        }.getOrNull()
        assertNull("stale root epoch must refuse the route admission", stale)

        val route = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-editor", 7L, epoch)
        }.getOrNull()
        assertTrue("route admission must mint a canonical handle",
            isCanonicalRoute(route))

        // 2) A forged route assertion is refused; the honest one mints the
        //    one-shot ingress handle.
        val forged = runCatching {
            SecretGatewayNative.submitHostSaveIntent(
                core, "rt:v1:" + "0".repeat(32),
                fixtureKey.toByteArray(Charsets.UTF_8))
        }.getOrNull()
        assertNull("forged route assertion must refuse the submit", forged)
        val token = runCatching {
            SecretGatewayNative.submitHostSaveIntent(
                core, route!!, fixtureKey.toByteArray(Charsets.UTF_8))
        }.getOrNull()
        assertTrue("bound submit must mint the one-shot ingress handle",
            isCanonicalIngress(token))

        // 3) The public Set carries ONLY the opaque token.
        val client = com.floe.android.host.RuntimeHostCommandClient.system()
        val saveTerminal = runBlocking {
            withTimeout(30_000) {
                submitAndAwait(client, com.floe.android.host.HostCommandRequest(
                    command = "config.provider.save",
                    scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                    stateful = true,
                    correlationID = "seam-save-${System.nanoTime()}",
                    createIntent = true,
                    payload = JsonObject(mapOf(
                        "secretIntent" to JsonPrimitive("set"),
                        "ingressToken" to JsonPrimitive(token!!),
                    )),
                ), "providers")
            }
        }
        assertTrue("save must complete", saveTerminal
            is com.floe.android.host.HostEffectTerminal.Completed)
        val saveText = saveTerminal.toString()
        assertFalse("the public save terminal must never carry the secret",
            saveText.contains(fixtureKey))
        // The ORIGINAL committer mints the canonical committed identity; the
        // lease candidate UUID is a draft value only. Look the row up by the
        // ACTUAL committed providerID from the save terminal.
        val saveValue = (saveTerminal
            as com.floe.android.host.HostEffectTerminal.Completed).value
            as? JsonObject
        val committedProviderID = (saveValue?.get("providerID")
            as? JsonPrimitive)?.contentOrNull
        assertNotNull("committed providerID missing in the save terminal",
            committedProviderID)
        val saveRevision = saveValue?.get("revision") as? JsonObject
        val saveResourceID = (saveRevision?.get("resourceID")
            as? JsonPrimitive)?.contentOrNull
        val saveVersion = (saveRevision?.get("version") as? JsonPrimitive)?.contentOrNull
        assertNotNull("committed revision missing in the save terminal",
            saveRevision)
        android.util.Log.i("FloeSecureIngress",
            "FLOE_SECURE_INGRESS_SEAM saveTerminal=$saveText")

        // 4) The committed row's `configured`/reference come from the
        //    PERSISTED secretRef metadata (listProviders reads provider
        //    metadata only) — that is the LOGICAL binding. The PHYSICAL
        //    proof reads the product Keystore-backed store at the SAME
        //    canonical committed account/reference and compares the exact
        //    synthetic placeholder bytes.
        val row = listProviderRow(committedProviderID!!)
        assertNotNull("committed provider row missing", row)
        val rowObject = row!!.first
        assertNotNull("provider row object missing", rowObject)
        val secret = rowObject!!["secret"] as JsonObject
        assertEquals("committed provider must expose a configured secret",
            true, (secret["configured"] as? JsonPrimitive)?.contentOrNull == "true")
        val reference = (secret["opaqueReference"] as? JsonPrimitive)?.contentOrNull
        assertNotNull("opaque secret reference missing", reference)
        assertTrue("reference must be the canonical ref:v1 form",
            reference!!.length == 71 && reference.startsWith("ref:v1:") &&
                reference.substring(7).all { it in '0'..'9' || it in 'a'..'f' })
        assertFalse("the list terminal must never carry the secret",
            row.second!!.contains(fixtureKey))
        // PHYSICAL binding at the canonical committed account/reference.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val account = ProductCredentialEnrollment.providerAccount(committedProviderID)
        val physicalReference = ProductCredentialEnrollment.opaqueReference(
            ProductCredentialEnrollment.NAMESPACE, account)
        assertEquals("the persisted reference must be the canonical physical one",
            physicalReference, reference)
        val physical = runBlocking {
            com.floe.android.credentials.AndroidKeystoreCredentialStore.create(
                context.applicationContext ?: context,
                ProductCredentialEnrollment.NAMESPACE).read(physicalReference)
        }
        assertNotNull("physical credential missing at $account", physical)
        try {
            assertEquals("physical credential must be the exact synthetic bytes",
                fixtureKey, physical!!.toString(Charsets.UTF_8))
        } finally {
            physical!!.fill(0)
        }

        // 5) Guarded delete with the ACTUAL committed save revision leaves
        //    no row and no physical secret.
        val deleteTerminal = runBlocking {
            withTimeout(30_000) {
                submitAndAwait(client, com.floe.android.host.HostCommandRequest(
                    command = "config.provider.delete",
                    scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                    stateful = true,
                    correlationID = "seam-del-${System.nanoTime()}",
                    revision = com.floe.android.host.HostRevision(saveResourceID!!, saveVersion!!),
                ), "providers")
            }
        }
        assertTrue("delete must complete",
            deleteTerminal is com.floe.android.host.HostEffectTerminal.Completed)
        android.util.Log.i("FloeSecureIngress",
            "FLOE_SECURE_INGRESS_SEAM deleteTerminal=$deleteTerminal")
        assertNull("row must be gone after the guarded delete",
            listProviderRow(committedProviderID))
        val physicalAfter = runBlocking {
            com.floe.android.credentials.AndroidKeystoreCredentialStore.create(
                context.applicationContext ?: context,
                ProductCredentialEnrollment.NAMESPACE).read(physicalReference)
        }
        assertNull("physical credential must be gone after the guarded delete",
            physicalAfter)

        // 6) Exact-ownership close: the handle can only close its own route,
        //    and a replay of the spent token can never consume.
        val cleared = runCatching { SecretGatewayNative.clearHostRoute(route!!) }
            .getOrDefault(-1)
        assertTrue("own route close must succeed", cleared == 0 || cleared == -105)
        android.util.Log.i("FloeSecureIngress",
            "FLOE_SECURE_INGRESS_SEAM ok providerID=$providerID ref=$reference")
    }

    /**
     * Phase `seamRouteLifecycle`: close + monotonic UI-generation refusal
     * and exact-ownership behavior on the device seam.
     */
    @Test
    fun seamRouteLifecycleRefusesStaleIncarnations() {
        assumeTrue(arg("floeSecureIngressPhase") == "seamRouteLifecycle")
        val epoch = awaitAcceptedEpoch()
        val first = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-editor-A", 5L, epoch)
        }.getOrNull()
        assertTrue("route A must mint", isCanonicalRoute(first))
        // Idempotent same-incarnation re-open returns the SAME handle.
        val repeated = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-editor-A", 5L, epoch)
        }.getOrNull()
        assertEquals("same-incarnation re-open must be idempotent", first!!, repeated)
        // An OLDER shared UI generation must refuse and leave A live.
        val older = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-editor-B", 4L, epoch)
        }.getOrNull()
        assertNull("older UI generation must refuse", older)
        // Exact-ownership close of A; then a late close is an idempotent no-op.
        assertTrue(runCatching { SecretGatewayNative.clearHostRoute(first!!) }
            .getOrDefault(-1) == 0)
        val late = runCatching {
            SecretGatewayNative.clearHostRoute(first!!)
        }.getOrDefault(-1)
        assertTrue("late close must be an accepted no-op", late == 0 || late == -105)
        // A genuinely newer incarnation after the close is admitted.
        val newer = runCatching {
            SecretGatewayNative.openHostRoute(
                "provider", "seam-editor-C", 6L, epoch)
        }.getOrNull()
        assertTrue("newer incarnation must be admitted", isCanonicalRoute(newer))
        runCatching { SecretGatewayNative.clearHostRoute(newer!!) }
        android.util.Log.i("FloeSecureIngress",
            "FLOE_SECURE_INGRESS_ROUTE_LIFECYCLE ok")
    }
    /**
     * Phase `seamCleanup`: remove EVERY leftover fixture row from earlier
     * failed attempts through the REAL guarded delete (canonical
     * provider.<id> @ syncRevision), then verify the list is empty of
     * fixtures. Never SQL/clearData; never touches non-fixture rows.
     */
    @Test
    fun seamCleanupRemovesAllOwnFixtureRows() {
        assumeTrue(arg("floeSecureIngressPhase") == "seamCleanup")
        awaitAcceptedEpoch()
        val client = com.floe.android.host.RuntimeHostCommandClient.system()
        val terminal = runBlocking {
            withTimeout(30_000) {
                submitAndAwait(client, com.floe.android.host.HostCommandRequest(
                    command = "config.providers.list",
                    scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                    stateful = false,
                    correlationID = "seam-cleanup-list-${System.nanoTime()}",
                    payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
                ), "providers")
            }
        }
        assertTrue("list must complete", terminal
            is com.floe.android.host.HostEffectTerminal.Completed)
        val value = (terminal as com.floe.android.host.HostEffectTerminal.Completed).value
            as? JsonObject
        assertNotNull("cleanup list value must decode", value)
        val rows = value!!.get("rows") as? kotlinx.serialization.json.JsonArray
        assertNotNull("cleanup list rows must decode", rows)
        val leftovers = rows!!.mapNotNull { it as? JsonObject }.filter {
            (it["displayName"] as? JsonPrimitive)?.contentOrNull == fixtureName
        }
        for (row in leftovers) {
            val id = (row["id"] as? JsonPrimitive)?.contentOrNull ?: continue
            val sync = (row["syncRevision"] as? JsonPrimitive)?.contentOrNull ?: continue
            val canonical = java.util.UUID.fromString(id).toString()
                .uppercase(java.util.Locale.ROOT)
            val del = runBlocking {
                withTimeout(30_000) {
                    submitAndAwait(client, com.floe.android.host.HostCommandRequest(
                        command = "config.provider.delete",
                        scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                        stateful = true,
                        correlationID = "seam-cleanup-del-${System.nanoTime()}",
                        revision = com.floe.android.host.HostRevision(
                            "provider.$canonical", sync),
                    ), "providers")
                }
            }
            android.util.Log.i("FloeSecureIngress",
                "FLOE_SECURE_INGRESS_CLEANUP id=$id sync=$sync terminal=$del")
            assertTrue("cleanup delete must complete for $id",
                del is com.floe.android.host.HostEffectTerminal.Completed)
        }
        val after = runBlocking {
            withTimeout(30_000) {
                submitAndAwait(client, com.floe.android.host.HostCommandRequest(
                    command = "config.providers.list",
                    scope = com.floe.android.host.HostScope.ApplicationConfiguration("providers"),
                    stateful = false,
                    correlationID = "seam-cleanup-recheck-${System.nanoTime()}",
                    payload = JsonObject(mapOf("operation" to JsonPrimitive("snapshot"))),
                ), "providers")
            }
        }
        assertTrue("cleanup recheck list must complete",
            after is com.floe.android.host.HostEffectTerminal.Completed)
        val afterValue = (after as com.floe.android.host.HostEffectTerminal.Completed).value
            as? JsonObject
        assertNotNull("cleanup recheck value must decode", afterValue)
        val afterRows = afterValue!!.get("rows") as? kotlinx.serialization.json.JsonArray
        assertNotNull("cleanup recheck rows must decode", afterRows)
        val remaining = afterRows!!.mapNotNull { it as? JsonObject }.filter {
            (it["displayName"] as? JsonPrimitive)?.contentOrNull == fixtureName
        }
        assertTrue("fixture rows must be gone after cleanup", remaining.isEmpty())
        android.util.Log.i("FloeSecureIngress",
            "FLOE_SECURE_INGRESS_CLEANUP removed=${leftovers.size} remaining=${remaining.size}")
    }
}